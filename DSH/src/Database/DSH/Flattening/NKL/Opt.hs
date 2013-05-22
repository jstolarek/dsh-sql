{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Flattening.NKL.Opt where
       
import           Debug.Trace
import           Text.Printf


import qualified Data.Set as S

import           Database.DSH.Flattening.Common.Data.Op
import qualified Database.DSH.Flattening.Common.Data.Type as T
import           Database.DSH.Flattening.Common.Data.Val
import qualified Database.DSH.Flattening.NKL.Data.NKL as NKL
import           Database.DSH.Flattening.NKL.Data.NKL(Prim2(..), Prim2Op(..), Prim1(..), Prim1Op(..))
import           Database.DSH.Flattening.NKL.Quote
import qualified Database.DSH.Flattening.NKL.Quote as Q
import           Database.DSH.Impossible
       
-- Perform simple optimizations on the NKL
opt' :: ExprQ -> ExprQ
opt' e =
  case e of 
    tab@(Table) -> tab
    App t e1 e2 -> App t (opt' e1) (opt' e2)

    -- concatPrim2 Map pattern: concat $ map (\x -> body) xs
    AppE1 t
          (Prim1 Concat concatTy)
          (AppE2 innerTy
                 (Prim2 Map mapTy) 
                 (Lam (FunT elemTy resTy) var body) xs) ->
      -- We first test wether the mapped-over list matches a certain pattern:
      -- if p [()] []
      case opt' xs of
        -- In that case, the following rewrite applies
        -- concat $ map (\x -> e) (if p then [()] else [])
        -- => if p then [e] else []
        -- FIXME to be really sound here, we need to check wether body'
        -- references var.
        If _ p (Const _ (ListV [UnitV])) (Const _ (ListV [])) -> 
          trace ("r1 " ++ (show e)) $ opt' $ If t p (opt' body) (Const t (ListV []))

        -- Try to do smart things depending on what is mapped over the list
        xs' ->
            case opt' body of
              BinOp _ Cons singletonExpr (Const _ (ListV [])) ->
                -- Singleton list construction cancelled out by concat:
                -- concatPrim2 Map (\x -> [e]) xs => map (\x -> e) xs
                trace ("r2 " ++ (show e)) $ opt' $ AppE2 t 
                         -- FIXME typeOf is potentially dangerous since the type
                         -- language includes variables.
                         (Prim2 Map ((elemTy .-> (typeOf body)) .-> ((ListT elemTy) .-> t)))
                         (Lam (elemTy .-> (typeOf body))
                              var
                              singletonExpr)
                         (opt' xs)
                         
              {- UNSOUND
              -- Merge nested loops by introducing a cartesian product:
              -- concat $ map (\x -> map (\y -> e) ys) xs
              -- => map (\(x, y) -> e) (xs × ys)
              -- 
              -- Actually, since we can't match on lambda arguments and there
              -- is no let-binding, we rewrite the lambda into the following:
              -- (\x -> e[x/fst x][y/snd x])
              -- 
              -- Note that we re-use x to avoid the need for fresh variables,
              -- which is fine here.
              AppE2 _ (Prim2 Map _) (Lam (Fn elemTy2 resTy2) innerVar innerBody) ys ->
                let productType = T.Pair elemTy elemTy2

                    tupleComponent :: (Type -> Prim1) -> Type -> Expr
                    tupleComponent f ty = (AppE1 ty (f (productType .-> ty)) (Var productType var))

                    innerBody' = subst innerVar 
                                       (tupleComponent Snd elemTy2) 
                                       (subst var (tupleComponent Fst elemTy) innerBody)

                    ys'        = opt' ys

                in trace ("r6 " ++ (show e)) $ opt' $ AppE2 t 
                                (Prim2 Map ((productType .-> resTy2) .-> (ListT productType .-> ListT resTy2)))
                                (Lam (productType .-> resTy2) var innerBody')
                                (AppE2 (ListT productType) 
                                       (CartProduct (ListT elemTy .-> (ListT elemTy2 .-> (ListT productType)))) 
                                       xs' 
                                       ys')
              -}
              
              -- Pull the projection part from a nested comprehension:
              -- concat $ map (\x1 -> map (\x2 -> e) ys) xs
              -- => map (\x1 -> e[x1/fst x1][x2/snd x1]) $ concat $ map (\x1 -> map (\x2 -> (x1, x2)) ys) xs
              
              -- Pull a filter from a nested comprehension
              -- concat $ map (\x1 -> map (\x2 -> (x1, x2)) (filter (\x2 -> p) ys) xs
              -- => filter (\x1 -> p[x1/fst x1][x2/snd x1]) $ concat $ map (\x1 -> map (\x2 -> (x1, x2)) ys) xs
              
              -- Turn a nested iteration into a cartesian product.
              -- concat $ map (\x1 -> map (\x2 -> (x1, x2)) ys) xs
              -- => (x1 × x2)
              -- provided that x1, x2 do not occur free in ys!
              
              -- Eliminate (lifted) identity
              -- map (\x -> x) xs
              -- => xs
              -- -> AppE2
              
              -- Eliminate pair construction/deconstruction pairs
              -- (fst x, snd x)
              -- => x
              -- -> AppE2 Pair
              
              -- Prim2 Filter pattern: concat (map  (\x -> if p [x] []) xs)
              If _
                 -- the filter condition
                 p 
                 -- then-branch: singleton list
                 (BinOp _ Cons (Var _ var') (Const _ (ListV [])))
                 -- else-branch: empty list
                 (Const _ (ListV [])) | var == var' ->

                -- Turns into: filter (\x -> e) xs
                trace ("r3 " ++ (show e)) $ opt' $ AppE2 t
                             (Prim2 Filter ((elemTy .-> Q.BoolT) .-> ((ListT elemTy) .-> t)))
                             (Lam (elemTy .-> BoolT) var p)
                             (opt' xs)

              -- More general filter pattern:
              -- concat (map (\x -> if p [e] []) xs)
              -- => map (\x -> e) (filter (\x -> p) xs)
              If _
                 -- the filter condition
                 p 
                 -- then-branch: singleton list over an arbitrary expression
                 (BinOp _ Cons bodyExpr (Const _ (ListV [])))
                 -- else-branch: empty list
                 (Const _ (ListV [])) ->

                trace ("r4 " ++ (show e)) $ opt' $ AppE2 t
                             (Prim2 Map ((elemTy .-> (elemT resTy)) .-> ((ListT elemTy) .-> t)))
                             (Lam (elemTy .-> (elemT resTy)) var bodyExpr)
                             (AppE2 t
                                    (Prim2 Filter ((elemTy .-> BoolT) .-> ((ListT elemTy) .-> t)))
                                    (Lam (elemTy .-> BoolT) var p)
                                    (opt' xs))

              body' -> 
                  -- We could not do anything smart
                  AppE1 t
                        (Prim1 Concat concatTy)
                        (AppE2 innerTy
                               (Prim2 Map mapTy) 
                               (Lam (FunT elemTy resTy) var body') xs')
    AppE1 t p1 e1 -> AppE1 t p1 (opt' e1)
    AppE2 t p1 e1 e2 -> AppE2 t p1 (opt' e1) (opt' e2)
    [nkl|(42::int + 23::int)::int|] -> undefined
    BinOp t op e1 e2 -> BinOp t op (opt' e1) (opt' e2)
    Lam t v e1 -> Lam t v (opt' e1)
  
    -- Merge nested conditionals:
    -- if c1 (if c2 t []) []
    -- -> if c1 && c2 t []
    If t1
       c1
       (If _
           c2
           t
           (Const _ (ListV [])))
       (Const _ (ListV [])) ->

      trace ("r5 " ++ (show e)) $ opt' $ If t1 
                (BinOp BoolT Conj c1 c2)
                t
                (Const t1 (ListV []))
           
    If t ce te ee -> If t (opt' ce) (opt' te) (opt' ee)
    constant@(Const _ _) -> constant
    var@(Var _ _) -> var
    
-- Substitution: subst v r e ~ e[v/r]
subst :: String -> ExprQ -> ExprQ -> ExprQ
subst _ _ t@(Table) = t
subst v r (App t e1 e2)     = App t (subst v r e1) (subst v r e2)
subst v r (AppE1 t p e)     = AppE1 t p (subst v r e)
subst v r (AppE2 t p e1 e2) = AppE2 t p (subst v r e1) (subst v r e2)
subst v r (BinOp t o e1 e2) = BinOp t o (subst v r e1) (subst v r e2)
-- FIXME for the moment, we assume that all lambda variables are unique
-- and we don't need to check for name capturing/do alpha-conversion.
subst v r lam@(Lam t v' e)  = if v == v' 
                              then lam
                              else Lam t v' (subst v r e)
subst _ _ c@(Const _ _)     = c
subst v r var@(Var _ v')    = if v == v' then r else var
subst v r (If ty c t e)     = If ty (subst v r c) (subst v r t) (subst v r e)

freeVars :: ExprQ -> S.Set String
freeVars e = undefined

opt :: NKL.Expr -> NKL.Expr
opt e = if (e /= e') 
        then trace (printf "%s\n---->\n%s" (show e) (show e')) e'
        else trace (show e) e'
  where e' = fromExprQ $ opt' $ toExprQ e
