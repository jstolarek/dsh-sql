{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE TemplateHaskell     #-}
    
-- | Introduce simple equi joins.
module Database.DSH.CL.Opt.FlatJoin
  ( semijoinR
  , antijoinR
  , eqjoinR
  ) where
  
import Control.Arrow

import Database.DSH.CL.Lang
import Database.DSH.CL.Kure
import Database.DSH.CL.Opt.Aux

--------------------------------------------------------------------------------
-- Introduce simple equi joins

-- | Concstruct an equijoin generator
mkeqjoinT 
  :: Expr  -- ^ The predicate
  -> Ident -- ^ Identifier from the first generator
  -> Ident -- ^ Identifier from the second generator
  -> Expr  -- ^ First generator expression
  -> Expr  -- ^ Second generator expression
  -> Translate CompCtx TuplifyM (NL Qual) (RewriteC CL, Qual)
mkeqjoinT joinPred x y xs ys = do
    -- The predicate must be an equi join predicate
    (leftExpr, rightExpr) <- constT (return joinPred) >>> (liftstateT $ splitJoinPredT x y)

    -- Conditions for the rewrite are fulfilled. 
    let xst          = typeOf xs
        yst          = typeOf ys
        xt           = elemT xst
        yt           = elemT yst
        pt           = listT $ pairT xt yt
        jt           = xst .-> (yst .-> pt)
        tuplifyHeadR = tuplifyR x (x, xt) (y, yt)
        joinGen      = BindQ x 
                         (AppE2 pt 
                           (Prim2 (EquiJoin leftExpr rightExpr) jt) 
                           xs ys)

    return (tuplifyHeadR, joinGen)

-- | Match an equijoin pattern in the middle of a qualifier list
eqjoinQualR :: Rewrite CompCtx TuplifyM (NL Qual)
eqjoinQualR = do
    -- We need two generators followed by a predicate
    BindQ x xs :* BindQ y ys :* GuardQ p :* qs <- promoteT idR
    
    (tuplifyHeadR, q') <- mkeqjoinT p x y xs ys
                               
    -- Next, we apply the tuplifyHeadR rewrite to the tail, i.e. to all following
    -- qualifiers
    -- FIXME why is extractT required here?
    qs' <- catchesT [ liftstateT $ (constT $ return qs) >>> (extractR tuplifyHeadR)
                    , constT $ return qs
                    ]            

    -- Combine the new tuplifying rewrite with the current rewrite by chaining
    -- both rewrites
    constT $ modify (>>> tuplifyHeadR)
    
    return $ q' :* qs'
    
-- | Matgch an equijoin pattern at the end of a qualifier list
eqjoinQualEndR :: Rewrite CompCtx TuplifyM (NL Qual)
eqjoinQualEndR = do
    -- We need two generators followed by a predicate
    BindQ x xs :* BindQ y ys :* (S (GuardQ p)) <- promoteT idR

    (tuplifyHeadR, q') <- mkeqjoinT p x y xs ys

    -- Combine the new tuplifying rewrite with the current rewrite by chaining
    -- both rewrites
    constT $ modify (>>> tuplifyHeadR)

    return (S q')

-- FIXME return after the first match
eqjoinQualsR :: Rewrite CompCtx TuplifyM (NL Qual) 
eqjoinQualsR = anytdR $ repeatR (eqjoinQualEndR <+ eqjoinQualR)
    
eqjoinR :: RewriteC CL
eqjoinR = do
    Comp t _ _          <- promoteT idR
    (tuplifyHeadR, qs') <- statefulT idR $ childT 1 (promoteR eqjoinQualsR >>> projectT)
    e'                  <- (tryR $ childT 0 tuplifyHeadR) >>> projectT
    return $ inject $ Comp t e' qs'

--------------------------------------------------------------------------------
-- Introduce semi joins (existential quantification)

-- | Construct a semijoin qualifier given a predicate and two generators
-- Note that the splitJoinPred call implicitly checks that only x and y
-- occur free in the predicate and no further correlation takes place.
mksemijoinT :: Expr -> Ident -> Ident -> Expr -> Expr -> TranslateC (NL Qual) Qual
mksemijoinT joinPred x y xs ys = do
    (leftExpr, rightExpr) <- constT (return joinPred) >>> splitJoinPredT x y

    let xst = typeOf xs
        yst = typeOf ys
        jt  = xst .-> yst .-> xst

    -- => [ ... | ..., x <- xs semijoin(p1, p2) ys, ... ]
    return $ BindQ x (AppE2 xst (Prim2 (SemiJoin leftExpr rightExpr) jt) xs ys)

-- | Match a IN semijoin pattern in the middle of a qualifier list
elemR :: RewriteC (NL Qual)
elemR = do
    -- [ ... | ..., x <- xs, or [ True | y <- ys, p ], ... ]
    BindQ x xs :* GuardQ (AppE1 _ (Prim1 Or _) (Comp _ (Lit _ (BoolV True)) 
                                                       (BindQ y ys :* (S (GuardQ p))))) :* qs <- idR
    q' <- mksemijoinT p x y xs ys
    return $ q' :* qs

-- | Match a IN semijoin pattern at the end of a list
elemEndR :: RewriteC (NL Qual)
elemEndR = do
    -- [ ... | ..., x <- xs, or [ True | y <- ys, p ] ]
    BindQ x xs :* (S (GuardQ (AppE1 _ (Prim1 Or _) (Comp _ (Lit _ (BoolV True)) 
                                                           ((BindQ y ys) :* (S (GuardQ p))))))) <- idR
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

-- | Construct an antijoin qualifier given a predicate and two generators. Note
-- that the splitJoinPred call implicitly checks that only x and y occur free in
-- the predicate and no further correlation takes place.
mkantijoinT :: Expr -> Ident -> Ident -> Expr -> Expr -> TranslateC (NL Qual) Qual
mkantijoinT joinPred x y xs ys = do
    (leftExpr, rightExpr) <- constT (return joinPred) >>> splitJoinPredT x y

    let xst = typeOf xs
        yst = typeOf ys
        jt  = xst .-> yst .-> xst

    -- => [ ... | ..., x <- xs semijoin(p1, p2) ys, ... ]
    return $ BindQ x (AppE2 xst (Prim2 (AntiJoin leftExpr rightExpr) jt) xs ys)

-- | Match a NOT IN antijoin pattern in the middle of a qualifier list
notinR :: RewriteC (NL Qual)
notinR = do
    -- [ ... | ..., x <- xs, and [ True | y <- ys, not p ], ... ]
    BindQ x xs :* GuardQ (AppE1 _ (Prim1 And _) 
                                  (Comp _ (Lit _ (BoolV True)) 
                                          (BindQ y ys :* (S (GuardQ (AppE1 _ (Prim1 Not _) p)))))) :* qs <- idR
    q' <- mkantijoinT p x y xs ys
    return $ q' :* qs

-- | Match a NOT IN antijoin pattern at the end of a list
notinEndR :: RewriteC (NL Qual)
notinEndR = do
    -- [ ... | ..., x <- xs, and [ True | y <- ys, not p ] ]
    BindQ x xs :* (S (GuardQ (AppE1 _ (Prim1 And _) 
                                      (Comp _ (Lit _ (BoolV True)) 
                                              ((BindQ y ys) :* (S (GuardQ (AppE1 _ (Prim1 Not _) p)))))))) <- idR
    q' <- mkantijoinT p x y xs ys
    return (S q')
    
universalQualsR :: RewriteC (NL Qual)
universalQualsR = anytdR $ repeatR (notinR <+ notinEndR)

antijoinR :: RewriteC CL
antijoinR = do
    Comp _ _ _ <- promoteT idR
    childR 1 (promoteR universalQualsR)