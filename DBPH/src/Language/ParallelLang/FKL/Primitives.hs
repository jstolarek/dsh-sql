{-
Module containing some primitive operations in AST form.

All of these are helper functions for the flattening transformation
-}
module Language.ParallelLang.FKL.Primitives where
    
import Language.ParallelLang.FKL.Data.FKL as F
import Language.ParallelLang.Common.Data.Val
import Language.ParallelLang.Common.Data.Type

type TExpr = F.Expr Type

indexF :: TExpr -> TExpr -> TExpr
indexF e1 e2 = let t1@(TyC "List" [t]) = typeOf e1
                   t2 = typeOf e2
                in F.App t (F.Var (t1 .-> t2 .-> t) "index" 0) [e1, e2]

distF :: TExpr -> TExpr -> TExpr 
distF e1 e2 = let t1 = typeOf e1
                  t2 = typeOf e2
                  ft = t1 .-> t2 .-> listT t1
               in F.App (listT t1) (F.Var ft "dist" 0) [e1, e2] 

lengthF :: TExpr -> TExpr
lengthF e1 = let t1 = typeOf e1
              in F.App intT (F.Var (t1 .-> intT) "length" 0) [e1]

promoteF :: TExpr -> TExpr -> TExpr
promoteF e1 e2 = let t1 = typeOf e1
                     t2 = typeOf e2
                     rt = extractShape t2 t1
                     ft = t1 .-> t2 .-> rt
                  in F.App rt (F.Var ft "promote" 0) [e1, e2]

restrictF :: TExpr -> TExpr -> TExpr
restrictF e1 e2 = let t1 = typeOf e1
                      rt = t1
                      ft = t1 .-> listT boolT .-> rt
                   in F.App rt (F.Var ft "restrict" 0) [e1, e2]

rangeF :: TExpr -> TExpr -> TExpr
rangeF e1 e2 = F.App (listT intT) (F.Var (intT .-> intT .-> listT intT) "range" 0) [e1, e2]

notF :: TExpr -> TExpr
notF e = F.App boolT (F.Var (boolT .-> boolT)"not" 0) [e]

combineF :: TExpr -> TExpr -> TExpr -> TExpr
combineF e1 e2 e3 = let t1 = typeOf e1 
                        t2 = typeOf e2
                        rt = t2
                        ft = t1 .-> t2 .-> t2 .-> rt
                     in F.App rt (F.Var ft "combine" 0) [e1, e2, e3]

insertF :: TExpr -> TExpr -> TExpr -> TExpr
insertF f v d@(F.Const _ (Int i)) = let t1 = typeOf f
                                        t2 = typeOf v
                                        rt = liftTypeN i t1
                                        ft = t1 .-> t2 .-> intT .-> rt
                                     in F.App rt (F.Var ft "insert" 0) [f, v, d]
insertF _ _ _ = error "Third argument to insert should be an integer"

extractF :: TExpr -> TExpr -> TExpr
extractF v d@(F.Const _ (Int i)) = let t1 = typeOf v
                                       rt = unliftTypeN i t1
                                       ft = t1 .-> intT .-> rt
                                    in F.App rt (F.Var ft "extract" 0) [v, d]
extractF _ _ = error "Second argument to extract should be an integer"

bPermuteF :: TExpr -> TExpr -> TExpr
bPermuteF e1 e2 = F.App (typeOf e1) (F.Var (typeOf e1 .-> typeOf e2 .-> typeOf e1) "bPermute" 0) [e1, e2] 

intF :: Int -> TExpr
intF i = F.Const intT $ Int i

varF :: Type -> String -> TExpr
varF t x = F.Var t x 0

zipF :: [TExpr] -> TExpr
zipF es = F.App resType (flip (F.Var zipType) 0 $ "zip" ++ (show $ length es)) es
  where
     types = map typeOf es
     resType = (TyC "tuple" types)
     zipType = foldr (.->) resType types
     
letF :: String -> Expr t -> Expr t -> Expr t
letF v e1 e2 = F.Let (typeOf e2) v e1 e2

tupleF :: [TExpr] -> TExpr
tupleF es = F.App resType (F.Var tType tName 0) es
    where
        resType = TyC "tuple" [typeOf e | e <- es]
        tName = "(" ++ replicate ((length es) - 1) ',' ++ ")"
        tType = foldr (.->) resType (map typeOf es)

projectF :: TExpr -> Int -> TExpr
projectF e i = let t = typeOf e
                in case t of
                    (TyC "tuple" ts) -> if length ts >= i 
                                            then Proj (ts !! (i - 1)) 0 e i
                                            else error "Provided tuple expression is not big enough"
                    _                -> error "Provided type is not a tuple"            