{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE InstanceSigs          #-}

-- | Infrastructure for KURE-based rewrites on FKL expressions
module Database.DSH.FKL.Kure
    ( -- * Re-export relevant KURE modules
      module Language.KURE
    , module Language.KURE.Lens

      -- * The KURE monad
    , RewriteM, RewriteStateM, TransformF, RewriteF, LensF
    
      -- * Setters and getters for the translation state
    , get, put, modify, initialCtx
    
      -- * Changing between stateful and non-stateful transforms
    , statefulT, liftstateT

      -- * The KURE context
    , FlatCtx(..), CrumbF(..), PathF

      -- * Congruence combinators
    , tableT, papp1T, papp2T, papp3T, binopT, unopT
    , ifT, constExprT

    , tableR, papp1R, papp2R, papp3R, binopR, unopR
    , ifR, constExprR
    
    ) where
    
       
import           Control.Monad
import           Data.Monoid

import           Language.KURE
import           Language.KURE.Lens
       
import           Database.DSH.Common.RewriteM
import           Database.DSH.Common.Lang
import           Database.DSH.Common.Type
import           Database.DSH.FKL.Lang
                 
--------------------------------------------------------------------------------
-- Convenience type aliases

type TransformF a b = Transform FlatCtx (RewriteM Int) a b
type RewriteF a     = TransformF a a
type LensF a b      = Lens FlatCtx (RewriteM Int) a b

--------------------------------------------------------------------------------

data CrumbF = AppFun
            | PApp1Arg
            | PApp2Arg1
            | PApp2Arg2
            | PApp3Arg1
            | PApp3Arg2
            | PApp3Arg3
            | BinOpArg1
            | BinOpArg2
            | UnOpArg
            | IfCond
            | IfThen
            | IfElse
            | UnConcatArg1
            | UnConcatArg2
            | QuickConcatArg
            deriving (Eq, Show)

type AbsPathF = AbsolutePath CrumbF

type PathF = Path CrumbF

-- | The context for KURE-based FKL rewrites
data FlatCtx = FlatCtx { fkl_path :: AbsPathF }
                       
instance ExtendPath FlatCtx CrumbF where
    c@@n = c { fkl_path = fkl_path c @@ n }
    
instance ReadPath FlatCtx CrumbF where
    absPath c = fkl_path c

initialCtx :: FlatCtx
initialCtx = FlatCtx { fkl_path = mempty }

{- FIXME will be needed again when let-bindings are added
-- | Record a variable binding in the context
bindVar :: Ident -> FlatCtx -> FlatCtx
bindVar n ctx = ctx { fkl_bindings = n : fkl_bindings ctx }

inScopeNames :: FlatCtx -> [Ident]
inScopeNames = fkl_bindings

boundIn :: Ident -> FlatCtx -> Bool
boundIn n ctx = n `elem` (fkl_bindings ctx)

freeIn :: Ident -> FlatCtx -> Bool
freeIn n ctx = n `notElem` (fkl_bindings ctx)

-- | Generate a fresh name that is not bound in the current context.
freshNameT :: [Ident] -> TransformF a Ident
freshNameT avoidNames = do
    ctx <- contextT
    constT $ freshName (avoidNames ++ inScopeNames ctx)
-}

--------------------------------------------------------------------------------
-- Support for stateful transforms

-- | Run a stateful transform with an initial state and turn it into a regular
-- (non-stateful) transform
statefulT :: s -> Transform FlatCtx (RewriteStateM s) a b -> TransformF a (s, b)
statefulT s t = resultT (stateful s) t

-- | Turn a regular rewrite into a stateful rewrite
liftstateT :: Transform FlatCtx (RewriteM Int) a b -> Transform FlatCtx (RewriteStateM s) a b
liftstateT t = resultT liftstate t

--------------------------------------------------------------------------------
-- Congruence combinators for FKL expressions

tableT :: Monad m => (Type -> String -> [Column] -> TableHints -> b)
                  -> Transform FlatCtx m Expr b
tableT f = contextfreeT $ \expr -> case expr of
                      Table ty n cs ks -> return $ f ty n cs ks
                      _                -> fail "not a table node"
{-# INLINE tableT #-}                      

                      
tableR :: Monad m => Rewrite FlatCtx m Expr
tableR = tableT Table
{-# INLINE tableR #-}

ifT :: Monad m => Transform FlatCtx m Expr a1
               -> Transform FlatCtx m Expr a2
               -> Transform FlatCtx m Expr a3
               -> (Type -> a1 -> a2 -> a3 -> b)
               -> Transform FlatCtx m Expr b
ifT t1 t2 t3 f = transform $ \c expr -> case expr of
                    If ty e1 e2 e3 -> f ty <$> apply t1 (c@@IfCond) e1               
                                           <*> apply t2 (c@@IfThen) e2
                                           <*> apply t3 (c@@IfElse) e3
                    _              -> fail "not an if expression"
{-# INLINE ifT #-}                      
                    
ifR :: Monad m => Rewrite FlatCtx m Expr
               -> Rewrite FlatCtx m Expr
               -> Rewrite FlatCtx m Expr
               -> Rewrite FlatCtx m Expr
ifR t1 t2 t3 = ifT t1 t2 t3 If               
{-# INLINE ifR #-}                      

{- FIXME will be needed again when let-bindings are added.
varT :: Monad m => (Type -> Ident -> b) -> Transform FlatCtx m Expr b
varT f = contextfreeT $ \expr -> case expr of
                    Var ty n -> return $ f ty n
                    _        -> fail "not a variable"
{-# INLINE varT #-}                      
                    
varR :: Monad m => Rewrite FlatCtx m Expr
varR = varT Var
{-# INLINE varR #-}                      
-}

binopT :: Monad m => Transform FlatCtx m Expr a1
                  -> Transform FlatCtx m Expr a2
                  -> (Type -> Lifted ScalarBinOp -> a1 -> a2 -> b)
                  -> Transform FlatCtx m Expr b
binopT t1 t2 f = transform $ \c expr -> case expr of
                     BinOp ty op e1 e2 -> f ty op <$> apply t1 (c@@BinOpArg1) e1 <*> apply t2 (c@@BinOpArg2) e2
                     _                 -> fail "not a binary operator application"
{-# INLINE binopT #-}                      

binopR :: Monad m => Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr
binopR t1 t2 = binopT t1 t2 BinOp
{-# INLINE binopR #-}                      

unopT :: Monad m => Transform FlatCtx m Expr a
                 -> (Type -> Lifted ScalarUnOp -> a -> b)
                 -> Transform FlatCtx m Expr b
unopT t f = transform $ \ctx expr -> case expr of
                     UnOp ty op e -> f ty op <$> apply t (ctx@@UnOpArg) e
                     _            -> fail "not an unary operator application"
{-# INLINE unopT #-}

unopR :: Monad m => Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr
unopR t = unopT t UnOp
{-# INLINE unopR #-}
                     
papp1T :: Monad m => Transform FlatCtx m Expr a
                  -> (Type -> Lifted Prim1 -> a -> b)
                  -> Transform FlatCtx m Expr b
papp1T t f = transform $ \c expr -> case expr of
                      PApp1 ty p e -> f ty p <$> apply t (c@@PApp1Arg) e                  
                      _            -> fail "not a unary primitive application"
{-# INLINE papp1T #-}                      
                      
papp1R :: Monad m => Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr
papp1R t = papp1T t PApp1
{-# INLINE papp1R #-}                      

quickconcatT :: Monad m => Transform FlatCtx m Expr a
                        -> (Type -> a -> b)
                        -> Transform FlatCtx m Expr b
quickconcatT t f = transform $ \c expr -> case expr of
                        QuickConcat ty e -> f ty <$> apply t (c@@QuickConcatArg) e                  
                        _                -> fail "not a quickconcat application"
{-# INLINE quickconcatT #-}                      
                      
quickconcatR :: Monad m => Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr
quickconcatR t = quickconcatT t QuickConcat
{-# INLINE quickconcatR #-}                      

                      
papp2T :: Monad m => Transform FlatCtx m Expr a1
                  -> Transform FlatCtx m Expr a2
                  -> (Type -> Lifted Prim2 -> a1 -> a2 -> b)
                  -> Transform FlatCtx m Expr b
papp2T t1 t2 f = transform $ \c expr -> case expr of
                     PApp2 ty p e1 e2 -> f ty p <$> apply t1 (c@@PApp2Arg1) e1 <*> apply t2 (c@@PApp2Arg2) e2
                     _                -> fail "not a binary primitive application"
{-# INLINE papp2T #-}                      

papp2R :: Monad m => Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr
papp2R t1 t2 = papp2T t1 t2 PApp2
{-# INLINE papp2R #-}                      

unconcatT :: Monad m => Transform FlatCtx m Expr a1
                  -> Transform FlatCtx m Expr a2
                  -> (Nat -> Type -> a1 -> a2 -> b)
                  -> Transform FlatCtx m Expr b
unconcatT t1 t2 f = transform $ \c expr -> case expr of
                     UnConcat n ty e1 e2 -> f n ty <$> apply t1 (c@@UnConcatArg1) e1 <*> apply t2 (c@@UnConcatArg2) e2
                     _                -> fail "not a unconcat call"
{-# INLINE unconcatT #-}                      

unconcatR :: Monad m => Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr
unconcatR t1 t2 = unconcatT t1 t2 UnConcat
{-# INLINE unconcatR #-}                      

papp3T :: Monad m => Transform FlatCtx m Expr a1
                  -> Transform FlatCtx m Expr a2
                  -> Transform FlatCtx m Expr a3
                  -> (Type -> Lifted Prim3 -> a1 -> a2 -> a3 -> b)
                  -> Transform FlatCtx m Expr b
papp3T t1 t2 t3 f = transform $ \c expr -> case expr of
                     PApp3 ty p e1 e2 e3 -> f ty p 
                                            <$> apply t1 (c@@PApp3Arg1) e1 
                                            <*> apply t2 (c@@PApp3Arg2) e2
                                            <*> apply t3 (c@@PApp3Arg3) e3
                     _                -> fail "not a ternary primitive application"
{-# INLINE papp3T #-}                      

papp3R :: Monad m 
       => Rewrite FlatCtx m Expr 
       -> Rewrite FlatCtx m Expr 
       -> Rewrite FlatCtx m Expr 
       -> Rewrite FlatCtx m Expr
papp3R t1 t2 t3 = papp3T t1 t2 t3 PApp3
{-# INLINE papp3R #-}                      

constExprT :: Monad m => (Type -> Val -> b) -> Transform FlatCtx m Expr b
constExprT f = contextfreeT $ \expr -> case expr of
                    Const ty v -> return $ f ty v
                    _          -> fail "not a constant"
{-# INLINE constExprT #-}                      
                    
constExprR :: Monad m => Rewrite FlatCtx m Expr
constExprR = constExprT Const
{-# INLINE constExprR #-}                      
                    
--------------------------------------------------------------------------------
       
instance Walker FlatCtx Expr where
    allR :: forall m. MonadCatch m => Rewrite FlatCtx m Expr -> Rewrite FlatCtx m Expr
    allR r = readerT $ \e -> case e of
            Table{}       -> idR
            PApp1{}       -> papp1R (extractR r)
            PApp2{}       -> papp2R (extractR r) (extractR r)
            PApp3{}       -> papp3R (extractR r) (extractR r) (extractR r)
            BinOp{}       -> binopR (extractR r) (extractR r)
            UnOp{}        -> unopR (extractR r)
            If{}          -> ifR (extractR r) (extractR r) (extractR r)
            Const{}       -> idR
            UnConcat{}    -> unconcatR (extractR r) (extractR r)
            QuickConcat{} -> quickconcatR (extractR r)

--------------------------------------------------------------------------------
-- I find it annoying that Applicative is not a superclass of Monad.

(<$>) :: Monad m => (a -> b) -> m a -> m b
(<$>) = liftM
{-# INLINE (<$>) #-}

(<*>) :: Monad m => m (a -> b) -> m a -> m b
(<*>) = ap
{-# INLINE (<*>) #-}

