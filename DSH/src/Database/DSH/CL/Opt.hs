{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE TemplateHaskell     #-}
    
-- | This module performs optimizations on the Comprehension Language (CL).
module Database.DSH.CL.Opt 
  ( opt ) where
       
import           Debug.Trace
import           Text.Printf
                 
import           Control.Applicative((<$>))
import           Control.Arrow
-- import           Control.Monad

import           Data.Either

import qualified Data.Foldable as F

import           Data.List.NonEmpty(NonEmpty((:|)), (<|))
-- import qualified Data.List.NonEmpty as N

-- import qualified Data.Set as S
-- import           GHC.Exts

import           Database.DSH.Impossible

-- import           Database.DSH.Impossible
   
import           Language.KURE.Debug

import           Database.DSH.CL.Lang
import           Database.DSH.CL.Kure
import           Database.DSH.CL.OptUtils

import qualified Database.DSH.CL.Primitives as P

--------------------------------------------------------------------------------
-- Pushing filters towards the front of a qualifier list

pushFilters :: (Expr -> Bool) -> RewriteC Expr
pushFilters mayPush = pushFiltersOnComp
  where
    pushFiltersOnComp :: RewriteC Expr
    pushFiltersOnComp = do
        Comp _ _ _ <- idR
        compR idR pushFiltersQuals
        
    pushFiltersQuals :: RewriteC (NL Qual)
    pushFiltersQuals = (reverseNL . fmap initFlags)
                       -- FIXME using innermostR here is really inefficient!
                       ^>> innermostR tryPush 
                       >>^ (reverseNL . fmap snd)
                       
    tryPush :: RewriteC (NL (Bool, Qual))
    tryPush = do
        qualifiers <- idR 
        trace (show qualifiers) $ case qualifiers of
            q1@(True, GuardQ p) :* q2@(_, BindQ x _) :* qs ->
                if x `elem` freeVars p
                -- We can't push through the generator because it binds a
                -- variable we depend upon
                then return $ (False, GuardQ p) :* q2 :* qs
                   
                -- We can push
                else return $ q2 :* q1 :* qs
                
            q1@(True, GuardQ _) :* q2@(_, GuardQ _) :* qs  ->
                return $ q2 :* q1 :* qs

            (True, GuardQ p) :* (S q2@(_, BindQ x _))      ->
                if x `elem` freeVars p
                then return $ (False, GuardQ p) :* (S q2)
                else return $ q2 :* (S (False, GuardQ p))

            (True, GuardQ p) :* (S q2@(_, GuardQ _))       ->
                return $ q2 :* (S (False, GuardQ p))

            (True, BindQ _ _) :* _                         ->
                error "generators can't be pushed"

            (False, _) :* _                                ->
                fail "can't push: node marked as unpushable"

            S (True, q)                                    ->
                return $ S (False, q)

            S (False, _)                                   ->
                fail "can't push: already at front"
    
    initFlags :: Qual -> (Bool, Qual)
    initFlags q@(GuardQ p)  = (mayPush p, q)
    initFlags q@(BindQ _ _) = (False, q)

pushEquiFilters :: RewriteC Expr
pushEquiFilters = pushFilters isEquiJoinPred
       
isEquiJoinPred :: Expr -> Bool
isEquiJoinPred (BinOp _ Eq e1 e2) = isProj e1 && isProj e2
isEquiJoinPred _                  = False

isProj :: Expr -> Bool
isProj (AppE1 _ (Prim1 Fst _) e) = isProj e
isProj (AppE1 _ (Prim1 Snd _) e) = isProj e
isProj (AppE1 _ (Prim1 Not _) e) = isProj e
isProj (BinOp _ _ e1 e2)         = isProj e1 && isProj e2
isProj (Var _ _)                 = True
isProj _                         = False

--------------------------------------------------------------------------------
-- Rewrite general expressions into equi-join predicates

toJoinExpr :: Ident -> TranslateC Expr JoinExpr
toJoinExpr n = do
    e <- idR
    
    let prim1 :: (Prim1 a) -> TranslateC Expr UnOp
        prim1 (Prim1 Fst _) = return FstJ
        prim1 (Prim1 Snd _) = return SndJ
        prim1 (Prim1 Not _) = return NotJ
        prim1 _             = fail "toJoinExpr: primitive can't be translated to join primitive"
        
    case e of
        AppE1 _ p _   -> do
            p' <- prim1 p
            appe1T (toJoinExpr n) (\_ _ e1 -> UnOpJ p' e1)
        BinOp _ _ _ _ -> do
            binopT (toJoinExpr n) (toJoinExpr n) (\_ o e1 e2 -> BinOpJ o e1 e2)
        Lit _ v       -> do
            return $ ConstJ v
        Var _ x       -> do
            guardMsg (n == x) "toJoinExpr: wrong name"
            return InputJ
        _             -> do
            fail "toJoinExpr: can't translate to join expression"
            
-- | Try to transform an expression into an equijoin predicate. This will fail
-- if either the expression does not have the correct shape (equality with
-- simple projection expressions on both sides) or if one side of the predicate
-- has free variables which are not the variables of the qualifiers given to the
-- function.
splitJoinPredT :: Ident -> Ident -> TranslateC Expr (JoinExpr, JoinExpr)
splitJoinPredT x y = do
    BinOp _ Eq e1 e2 <- idR

    let fv1 = freeVars e1
        fv2 = freeVars e2
        
    if [x] == fv1 && [y] == fv2
        then binopT (toJoinExpr x) (toJoinExpr y) (\_ _ e1' e2' -> (e1', e2'))
        else if [y] == fv1 && [x] == fv2
             then binopT (toJoinExpr y) (toJoinExpr x) (\_ _ e1' e2' -> (e2', e1'))
             else fail "splitJoinPredT: not an equi-join predicate"

--------------------------------------------------------------------------------
-- Introduce simple equi joins

type TuplifyM = CompSM (RewriteC CL)

-- | Concstruct an equijoin generator
mkeqjoinT 
  :: Expr  -- ^ The predicate
  -> Ident -- ^ Identifier from the first generator
  -> Ident -- ^ Identifier from the second generator
  -> Expr  -- ^ First generator expression
  -> Expr  -- ^ Second generator expression
  -> Translate CompCtx TuplifyM (NL Qual) (RewriteC CL, Qual)
mkeqjoinT pred x y xs ys = do
    -- The predicate must be an equi join predicate
    (leftExpr, rightExpr) <- constT (return pred) >>> (liftstateT $ splitJoinPredT x y)

    -- Conditions for the rewrite are fulfilled. 
    let xst     = typeOf xs
        yst     = typeOf ys
        xt      = elemT xst
        yt      = elemT yst
        pt      = listT $ pairT xt yt
        jt      = xst .-> (yst .-> pt)
        tuplifyR = tuplify x (x, xt) (y, yt)
        joinGen = BindQ x 
                        (AppE2 pt 
                               (Prim2 (EquiJoin leftExpr rightExpr) jt) 
                               xs ys)

    return (tuplifyR, joinGen)

-- | Match an equijoin pattern in the middle of a qualifier list
eqjoinR :: Rewrite CompCtx TuplifyM (NL Qual)
eqjoinR = do
    -- We need two generators followed by a predicate
    BindQ x xs :* BindQ y ys :* GuardQ p :* qs <- promoteT idR
    
    (tuplifyR, q') <- mkeqjoinT p x y xs ys
                               
    -- Next, we apply the tuplify rewrite to the tail, i.e. to all following
    -- qualifiers
    -- FIXME why is extractT required here?
    qs' <- catchesT [ liftstateT $ (constT $ return qs) >>> (extractR tuplifyR)
                    , constT $ return qs
                    ]            

    -- Combine the new tuplifying rewrite with the current rewrite by chaining
    -- both rewrites
    constT $ modify (>>> tuplifyR)
    
    return $ q' :* qs'
    
-- | Matgch an equijoin pattern at the end of a qualifier list
eqjoinEndR :: Rewrite CompCtx TuplifyM (NL Qual)
eqjoinEndR = do
    -- We need two generators followed by a predicate
    BindQ x xs :* BindQ y ys :* (S (GuardQ p)) <- promoteT idR

    (tuplifyR, q') <- mkeqjoinT p x y xs ys

    -- Combine the new tuplifying rewrite with the current rewrite by chaining
    -- both rewrites
    constT $ modify (>>> tuplifyR)

    return (S q')

    
eqjoinQualsR :: Rewrite CompCtx TuplifyM (NL Qual) 
eqjoinQualsR = anytdR $ repeatR (eqjoinEndR <+ eqjoinR)
    
-- FIXME this should work without this amount of casting
-- FIXME and it should be RewriteC Expr
eqjoinCompR :: RewriteC CL
eqjoinCompR = do
    Comp t _ _      <- promoteT idR
    (tuplifyR, qs') <- statefulT idR $ childT 1 (promoteR eqjoinQualsR >>> projectT)
    e'              <- (tryR $ childT 0 tuplifyR) >>> projectT
    return $ inject $ Comp t e' qs'

--------------------------------------------------------------------------------
-- Introduce semi joins (existential quantification)

-- | Construct a semijoin qualifier given a predicate and two generators
-- Note that the splitJoinPred call implicitly checks that only x and y
-- occur free in the predicate and no further correlation takes place.
mksemijoinT :: Expr -> Ident -> Ident -> Expr -> Expr -> TranslateC (NL Qual) Qual
mksemijoinT pred x y xs ys = do
    (leftExpr, rightExpr) <- constT (return pred) >>> splitJoinPredT x y

    let xst = typeOf xs
        yst = typeOf ys
        jt  = xst .-> yst .-> xst

    -- => [ ... | ..., x <- xs semijoin(p1, p2) ys, ... ]
    return $ BindQ x (AppE2 xst (Prim2 (SemiJoin leftExpr rightExpr) jt) xs ys)

-- | Match a IN semijoin pattern in the middle of a qualifier list
elemR :: RewriteC (NL Qual)
elemR = do
    -- [ ... | ..., x <- xs, or [ p | y <- ys ], ... ]
    BindQ x xs :* GuardQ (AppE1 _ (Prim1 Or _) (Comp _ p (S (BindQ y ys)))) :* qs <- idR
    q' <- mksemijoinT p x y xs ys
    return $ q' :* qs

-- | Match a IN semijoin pattern at the end of a list
elemEndR :: RewriteC (NL Qual)
elemEndR = do
    -- [ ... | ..., x <- xs, or [ p | y <- ys ] ]
    BindQ x xs :* (S (GuardQ (AppE1 _ (Prim1 Or _) (Comp _ p (S (BindQ y ys)))))) <- idR
    q' <- mksemijoinT p x y xs ys
    return (S q')
    
existentialQualsR :: RewriteC (NL Qual)
existentialQualsR = anytdR $ repeatR (elemR <+ elemEndR)

semijoinR :: RewriteC CL
semijoinR = do
    Comp _ _ _ <- promoteT idR
    childR 1 (promoteR existentialQualsR)

--------------------------------------------------------------------------------
-- Introduce anti joins (universal quantification)

antijoinR :: RewriteC CL
antijoinR = fail "antijoinR not implemented"

------------------------------------------------------------------
-- Pulling out expressions from comprehension heads 

type HeadExpr = Either PathC (PathC, Type, Expr, NL Qual) 

-- | Collect expressions which we would like to replace in the comprehension
-- head: occurences of the variable bound by the only generator as well as
-- comprehensions nested in the head. We collect the expressions themself as
-- well as the paths to them.
collectExprT :: Ident -> TranslateC CL [HeadExpr] 
collectExprT x = prunetdT (collectVar <+ collectComp <+ blockLambda)
  where
    -- | Collect a variable if it refers to the name we are looking for
    collectVar :: TranslateC CL [HeadExpr]
    collectVar = do
        Var _ n <- promoteT idR
        guardM $ x == n
        path <- snocPathToPath <$> absPathT
        return [Left path]
    
    -- | Collect a comprehension and don't descend into it
    collectComp :: TranslateC CL [HeadExpr]
    collectComp = do
        Comp t h qs <- promoteT idR
        -- FIXME check here if the comprehension is eligible for unnesting?
        path <- snocPathToPath <$> absPathT
        return [Right (path, t, h, qs)]
        
    -- | don't descend past lambdas which shadow the name we are looking for
    blockLambda :: TranslateC CL [HeadExpr]
    blockLambda = do
        Lam _ n _ <- promoteT idR
        guardM $ n == x
        return []
        
-- | Apply a function n times
ntimes :: Int -> (a -> a) -> a -> a
ntimes 0 _ x = x
ntimes n f x = ntimes (n - 1) f (f x)

-- | Tuple accessor for position pos in left-deep tuples
tupleAt :: Expr -> Int -> Int -> Expr
tupleAt expr len pos = 
  case pos of
      pos | pos == 1               -> ntimes (len - 1) P.fst expr
      pos | 2 <= pos && pos <= len -> P.snd $ ntimes (len - pos) P.fst expr
      _                            -> $impossible                         
        
-- | Take an absolute path and drop the prefix of the path to a direct child of
-- the current node. This makes it a relative path starting from **some** direct
-- child of the current node.
dropPrefix :: Eq a => [a] -> [a] -> [a]
dropPrefix prefix xs = drop (1 + length prefix) xs

-- | Construct a left-deep tuple from at least two expressions
mkTuple :: Expr -> NonEmpty Expr -> Expr
mkTuple e1 es = F.foldl1 P.pair (e1 <| es)

constExprT :: Monad m => Expr -> Translate c m CL CL
constExprT expr = constT $ return $ inject expr
        
-- | Factor out expressions from a single-generator comprehension head, such
-- that only (pairs of) the generator variable and nested comprehensions in the
-- head remain. Beware: This rewrite /must/ be combined with a rewrite that
-- makes progress on the comprehension. Otherwise, a loop might occur when used
-- in a top-down fashion.
factoroutHeadR :: RewriteC CL
factoroutHeadR = do
    curr@(Comp t h (S (BindQ x xs))) <- promoteT idR
    (vars, comps) <- partitionEithers <$> (oneT $ collectExprT x)

    -- We abort if we did not find any interesting comprehensions in the head
    guardM $ not $ null comps

    pathPrefix <- rootPathT

    let varTy = elemT $ typeOf xs

        varExpr   = if null vars 
                    then [] 
                    else [(Var varTy x, map (dropPrefix pathPrefix) vars)]

        compExprs = map (\(p, t', h', qs) -> (Comp t' h' qs, [dropPrefix pathPrefix p])) comps
        
        exprs     = varExpr ++ compExprs
        
    trace ("collected: " ++ show (varExpr ++ compExprs)) $ return ()
    trace ("currently at: " ++ show curr ++ " --- " ++ show pathPrefix) $ return ()
        
    (mapBody, h', headTy) <- case exprs of
              -- If there is only one interesting expression (which must be a
              -- comprehension), we don't need to construct tuples.
              [(comp@(Comp _ _ _), [path])] -> do
                  let lamVarTy = typeOf comp

                  -- Replace the comprehension with the lambda variable
                  mapBody <- (oneT $ pathR path (constT $ return $ inject $ Var lamVarTy x)) >>> projectT

                  return (mapBody, comp, lamVarTy)

              -- If there are multiple expressions, we construct a left-deep tuple
              -- and replace the original expressions in the head with the appropriate
              -- tuple constructors.
              es@(e1 : e2 : er)    -> do
                  let -- Construct a tuple from all interesting expressions
                      headTuple      = mkTuple (fst e1) (fmap fst $ e2 :| er)

                      lamVarTy       = typeOf headTuple
                      lamVar         = Var lamVarTy x
                      
                      -- Map all paths to a tuple accessor for the tuple we
                      -- constructed for the comprehension head
                      tupleAccessors = trace ("typeOf headTuple: " ++ show lamVarTy) $ trace ("headTuple: " ++ show headTuple) $ zipWith (\paths i -> (tupleAt lamVar (length es) i, paths))
                                               (map snd es)
                                               [1..]
                                               
                      
                      -- For each path, construct a rewrite to replace the
                      -- original expression at this path with the tuple
                      -- accessor
                      rewritePerPath = [ pathR path (constExprT ta) 
                                       | (ta, paths) <- tupleAccessors
                                       , path <- paths ]
                                       
                  mapBody <- (oneT $ serialise rewritePerPath) >>> projectT
                  return (mapBody, headTuple, lamVarTy)

              _            -> $impossible
              
    let lamTy = headTy .-> (elemT t)
    return $ inject $ P.map (Lam lamTy x mapBody) (Comp (listT headTy) h' (S (BindQ x xs)))

------------------------------------------------------------------
-- Nestjoin introduction: unnesting in a comprehension head
    
-- FIXME this should work on left-deep tuples
tupleComponentsT :: TranslateC CL (NonEmpty Expr)
tupleComponentsT = do
    AppE2 _ (Prim2 Pair _) _ _ <- promoteT idR
    descendT
    
  where
    descendT :: TranslateC CL (NonEmpty Expr)
    descendT = descendPairT <+ singleT
    
    descendPairT :: TranslateC CL (NonEmpty Expr)
    descendPairT = do
        AppE2 _ (Prim2 Pair _) e _ <- promoteT idR
        tl <- childT 1 descendT
        return $ e <| tl
        
    singleT :: TranslateC CL (NonEmpty Expr)
    singleT = (:| []) <$> (promoteT idR)

    
-- | Base case for nestjoin introduction: consider comprehensions in which only
-- a single inner comprehension occurs in the head.
unnestHeadBaseT :: TranslateC CL Expr
unnestHeadBaseT = singleCompT <+ varCompPairT
  where
    -- The base case: a single comprehension nested in the head of the outer
    -- comprehension.
    -- [ [ h y | y <- ys, p ] | x <- xs ]
    singleCompT :: TranslateC CL Expr
    singleCompT = trace "singleCompT" $ do
        -- [ [ h | y <- ys, p ] | x <- xs ]
        Comp t1 (Comp t2 h ((BindQ y ys) :* (S (GuardQ p)))) (S (BindQ x xs)) <- promoteT idR
        
        -- Split the join predicate
        (leftExpr, rightExpr) <- constT (return p) >>> splitJoinPredT x y
        
        let xt       = elemT $ typeOf xs
            yt       = elemT $ typeOf ys
            tupType  = pairT xt (listT yt)
            joinType = listT xt .-> (listT yt .-> listT tupType)
            joinVar  = Var tupType x
            
        -- In the head of the inner comprehension, replace x with (snd x)
        h' <- constT (return h) >>> (extractR $ tryR $ subst x (P.fst joinVar))

        -- the nestjoin operator combining xs and ys: 
        -- xs nj(p) ys
        let xs'        = AppE2 (listT tupType) (Prim2 (NestJoin leftExpr rightExpr) joinType) xs ys

            headComp = case h of
                -- The simple case: the inner comprehension looked like [ y | y < ys, p ]
                -- => We can remove the inner comprehension entirely
                Var _ y' | y == y' -> P.snd joinVar
                
                -- The complex case: the inner comprehension has a non-idenity
                -- head: 
                -- [ h | y <- ys, p ] => [ h[fst x/x] | y <- snd x ] 
                -- It is safe to re-use y here, because we just re-bind the generator.
                _               -> Comp t2 h' (S $ BindQ y (P.snd joinVar))
                
        return $ Comp t1 headComp (S (BindQ x xs'))
        
    -- The head of the outer comprehension consists of a pair of generator
    -- variable and inner comprehension
    -- [ (x, [ h y | y <- ys, p ]) | x <- xs ]
    varCompPairT :: TranslateC CL Expr
    varCompPairT = trace "varCompPairT" $ do
        Comp _ (AppE2 _ (Prim2 Pair _) (Var _ x) _) (S (BindQ x' _)) <- promoteT idR
        guardM $ x == x'
        -- Reduce to the base case, then unnest, then patch the variable back in
        removeVarR >>> injectT >>> singleCompT >>> arr (patchVar x)
        
    -- Support rewrite: remove the variable from the outer comprehension head
    -- [ (x, [ h y | y <- ys, p ]) | x <- xs ]
    -- => [ [ h y | y <- ys, p ] | x <- xs ]
    removeVarR :: TranslateC CL Expr
    removeVarR = do
        Comp _ (AppE2 t (Prim2 Pair _) (Var _ x) comp) (S (BindQ x' xs)) <- promoteT idR
        guardM $ x == x'
        let t' = listT $ sndT t
        return $ Comp t' comp (S (BindQ x xs))

patchVar :: Ident -> Expr -> Expr
patchVar x (Comp _ e qs@(S (BindQ x' je))) | x == x' = 
    let joinBindType = elemT $ typeOf je
        e'           = P.pair (P.fst (Var joinBindType x)) e
        resultType   = listT $ pairT (fstT joinBindType) (typeOf e)
    in Comp resultType e' qs
patchVar _ _             = $impossible
    
unnestHeadR :: RewriteC CL
unnestHeadR = simpleHeadR <+ tupleHeadR
  where 
    simpleHeadR :: RewriteC CL
    simpleHeadR = trace "simpleHeadR" $ do
        unnestHeadBaseT >>> injectT

    tupleHeadR :: RewriteC CL
    tupleHeadR = do
        Comp _ h qs <- promoteT idR
        headExprs <- oneT tupleComponentsT 
        
        trace ("unnestHeadR: " ++ show h ++ " " ++ show headExprs) $ return ()
    
        let mkSingleComp :: Expr -> Expr
            mkSingleComp expr = Comp (listT $ typeOf expr) expr qs
            
            headExprs' = case headExprs of
                v@(Var _ _) :| (comp : comps) -> P.pair v comp :| comps
                comps                         -> comps
                
            singleComps = fmap mkSingleComp headExprs'
            
        -- FIXME fail if all translates failed -> define alternative to mapT
        unnestedComps <- constT (return singleComps) >>> mapT (injectT >>> unnestHeadBaseT)
        
        return $ inject $ F.foldl1 P.zip unnestedComps
        
nestjoinR :: RewriteC CL
nestjoinR = do
    Comp _ _ _ <- promoteT idR
    unnestHeadR <+ (factoroutHeadR >>> childR 1 unnestHeadR)
    
------------------------------------------------------------------
-- Filter pushdown

selectR :: RewriteC (NL Qual)
selectR = pushR <+ pushEndR
  where
    pushR :: RewriteC (NL Qual)
    pushR = do
        (BindQ x xs) :* GuardQ p :* qs <- idR
        
        -- We only push predicates into generators if the predicate depends
        -- solely on this generator
        let fvs = freeVars p
        guardM $ [x] == fvs
        
        return $ BindQ x (P.filter (Lam ((elemT $ typeOf xs) .-> boolT) x p) xs) :* qs
        
        
    pushEndR :: RewriteC (NL Qual)
    pushEndR = do
        (BindQ x xs) :* (S (GuardQ p)) <- idR
        
        -- We only push predicates into generators if the predicate depends
        -- solely on this generator
        let fvs = freeVars p
        guardM $ [x] == fvs
        
        return $ S $ BindQ x (P.filter (Lam ((elemT $ typeOf xs) .-> boolT) x p) xs)

------------------------------------------------------------------
-- Simple housecleaning support rewrites.
    
-- | Eliminate a map with an identity body
-- map (\x -> x) xs => xs
identityMapR :: RewriteC Expr
identityMapR = do
    AppE2 _ (Prim2 Map _) (Lam _ x (Var _ x')) xs <- idR
    guardM $ x == x'
    return xs
    
-- | Eliminate a comprehension with an identity head
-- [ x | x <- xs ] => xs
identityCompR :: RewriteC Expr
identityCompR = do
    Comp _ (Var _ x) (S (BindQ x' xs)) <- idR
    guardM $ x == x'
    return xs
    
-- | Eliminate tuple construction if the elements are first and second of the
-- same tuple:
-- pair (fst x) (snd x) => x
pairR :: RewriteC Expr
pairR = do
    AppE2 _ (Prim2 Pair _) (AppE1 _ (Prim1 Fst _) v@(Var _ x)) (AppE1 _ (Prim1 Snd _) (Var _ x')) <- idR
    guardM $ x == x'
    return v
    
mergeFilterR :: RewriteC Expr
mergeFilterR = do
    AppE2 t (Prim2 Filter _) 
            (Lam t1 x1 p1)
            (AppE2 _ (Prim2 Filter _)
                     (Lam t2 x2 p2)
                     xs)                <- idR

    let xt = elemT $ typeOf xs
                     
    p2' <- (constT $ return $ inject p2) >>> subst x2 (Var xt x1) >>> projectT
    
    let p' = BinOp (xt .-> boolT) Conj p1 p2'
    
    return $ P.filter (Lam (xt .-> boolT) x1 p') xs

cleanupR :: RewriteC Expr
cleanupR = identityMapR <+ identityCompR <+ pairR <+ mergeFilterR
    
------------------------------------------------------------------
-- Simple normalization rewrites

-- | Split conjunctive predicates.
splitConjunctsR :: RewriteC (NL Qual)
splitConjunctsR = splitR <+ splitEndR
  where
    splitR :: RewriteC (NL Qual)
    splitR = do
        (GuardQ (BinOp _ Conj p1 p2)) :* qs <- idR
        return $ GuardQ p1 :* GuardQ p2 :* qs
    
    splitEndR :: RewriteC (NL Qual)
    splitEndR = do
        (S (GuardQ (BinOp _ Conj p1 p2))) <- idR
        return $ GuardQ p1 :* (S $ GuardQ p2)
    
-- | Normalize a guard expressing existential quantification:
-- not $ null [ ... | x <- xs, p ] (not $ length [ ... ] == 0)
-- => or [ p | x <- xs ]
normalizeExistentialR :: RewriteC Qual
normalizeExistentialR = do
    GuardQ (AppE1 _ (Prim1 Not _) 
               (BinOp _ Eq 
                   (AppE1 _ (Prim1 Length _) 
                       (Comp _ _ (BindQ x xs :* (S (GuardQ p)))))
                   (Lit _ (IntV 0)))) <- idR

    return $ GuardQ (P.or (Comp (listT boolT) p (S (BindQ x xs))))

-- | Normalize a guard expressing universal quantification:
-- null [ ... | x <- xs, p ] (length [ ... ] == 0)
-- => and [ not p | x <- xs ]
normalizeUniversalR :: RewriteC Qual
normalizeUniversalR = do
    GuardQ (BinOp _ Eq 
                (AppE1 _ (Prim1 Length _) 
                    (Comp _ _ (BindQ x xs :* (S (GuardQ p)))))
                (Lit _ (IntV 0))) <- idR

    return $ GuardQ (P.and (Comp (listT boolT) (P.not p) (S (BindQ x xs))))
    
normalizeR :: RewriteC CL
normalizeR = repeatR $ anytdR $ promoteR splitConjunctsR
                                <+ promoteR normalizeExistentialR
                                <+ promoteR normalizeUniversalR
        
------------------------------------------------------------------
-- Rewrite Strategy
        
test2 :: RewriteC CL
-- test2 = (semijoinR <+ nestjoinR) >>> repeatR (anytdR (promoteR cleanupR))
-- test2 = semijoinR
-- test2 = anytdR (promoteR $ splitConjunctsR <+ splitConjunctsEndR)
-- test2 = anytdR eqjoinCompR
test2 = anytdR $ promoteR normalizeExistentialR
        
strategy :: RewriteC CL
-- strategy = {- anybuR (promoteR pushEquiFilters) >>> -} anytdR eqjoinCompR
-- strategy = repeatR (anybuR normalizeR)
-- strategy = repeatR (anytdR $ promoteR selectR >+> promoteR cleanupR)

compStrategy :: RewriteC Expr
compStrategy = do
    -- Don't try anything on a non-comprehension
    Comp _ _ _ <- idR 
    repeatR $ (extractR semijoinR)
              >+> (extractR antijoinR)
              >+> (tryR pushEquiFilters >>> extractR eqjoinCompR)

strategy = -- First, 
           (tryR $ anytdR $ promoteR normalizeR) 
           >>> (repeatR $ anytdR $ promoteR compStrategy)
           
           
           

opt :: Expr -> Expr
opt expr = trace ("optimize query " ++ show expr) 
           $ either (\msg -> trace msg expr) (\expr -> trace (show expr) expr) rewritten
  where
    rewritten = applyExpr (strategy >>> projectT) expr
