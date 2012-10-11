module Database.DSH.TH (deriveDSH, deriveQA, deriveTupleRangeQA, deriveElim) where

import qualified Database.DSH.Internals  as DSH
import qualified Database.DSH.Impossible as DSH

import Language.Haskell.TH
import Control.Monad

-----------------------------------------
-- Deriving all DSH-relevant instances --
-----------------------------------------

deriveDSH :: Name -> Q [Dec]
deriveDSH n = do
  qa <- deriveQA n
  el <- deriveElim n
  return (qa ++ el)

-----------------
-- Deriving QA --
-----------------

deriveQA :: Name -> Q [Dec]
deriveQA name = do
  info <- reify name
  case info of
    TyConI (DataD    _cxt name1 tyVarBndrs cons _names) -> deriveTyConQA name1 tyVarBndrs cons
    TyConI (NewtypeD _cxt name1 tyVarBndrs con  _names) -> deriveTyConQA name1 tyVarBndrs [con]
    _                                                   -> fail errMsgExoticType

deriveTyConQA :: Name -> [TyVarBndr] -> [Con] -> Q [Dec]
deriveTyConQA name tyVarBndrs cons = do
  let context       = map (\tv -> ClassP ''DSH.QA [VarT (tyVarBndrToName tv)]) tyVarBndrs
  let typ           = foldl AppT (ConT name) (map (VarT . tyVarBndrToName) tyVarBndrs)
  let instanceHead  = AppT (ConT ''DSH.QA) typ
  let repDec        = deriveRep typ cons
  toExpDec <- deriveToExp cons
  frExpDec <- deriveFrExp cons
  return [InstanceD context instanceHead [repDec,toExpDec,frExpDec]]

deriveTupleRangeQA :: Int -> Int -> Q [Dec]
deriveTupleRangeQA x y = fmap concat (mapM (deriveQA . tupleTypeName) [x .. y])

-- Derive the Rep type function

deriveRep :: Type -> [Con] -> Dec
deriveRep typ cons = TySynInstD ''DSH.Rep [typ] (deriveRepCons cons)

deriveRepCons :: [Con] -> Type
deriveRepCons []  = error errMsgExoticType
deriveRepCons [c] = deriveRepCon c
deriveRepCons cs  = foldr1 (AppT . AppT (ConT ''(,)))
                           (map (AppT (ConT ''[]) . deriveRepCon) cs)

deriveRepCon :: Con -> Type
deriveRepCon con = case conToTypes con of
  [] -> ConT ''()
  ts -> foldr1 (AppT . AppT (ConT ''(,)))
               (map (AppT (ConT ''DSH.Rep)) ts)

-- Derive the toExp function of the QA class

deriveToExp :: [Con] -> Q Dec
deriveToExp [] = fail errMsgExoticType
deriveToExp cons = do
  clauses <- sequence (zipWith3 deriveToExpClause (repeat (length cons)) [0 .. ] cons)
  return (FunD 'DSH.toExp clauses)

deriveToExpClause :: Int -- Total number of constructors
                  -> Int -- Index of the constructor
                  -> Con
                  -> Q Clause
deriveToExpClause 0 _ _ = fail errMsgExoticType
deriveToExpClause 1 _ con = do
  (pat1,names1) <- conToPattern con
  let exp1 = deriveToExpMainExp names1
  let body1 = NormalB exp1
  return (Clause [pat1] body1 [])
deriveToExpClause n i con = do
  (pat1,names1) <- conToPattern con
  let exp1 = deriveToExpMainExp names1
  expList1 <- [| DSH.ListE [ $(return exp1) ] |]
  expEmptyList <- [| DSH.ListE [] |]
  let lists = replicate i expEmptyList ++ [expList1] ++ replicate (n - i - 1) expEmptyList
  let exp2 = foldr1 (AppE . AppE (ConE 'DSH.PairE)) lists
  let body1 = NormalB exp2
  return (Clause [pat1] body1 [])

deriveToExpMainExp :: [Name] -> Exp
deriveToExpMainExp []     = ConE 'DSH.UnitE
deriveToExpMainExp [name] = AppE (VarE 'DSH.toExp) (VarE name)
deriveToExpMainExp names  = foldr1 (AppE . AppE (ConE 'DSH.PairE))
                                   (map (AppE (VarE 'DSH.toExp) . VarE) names)
-- Derive to frExp function of the QA class

deriveFrExp :: [Con] -> Q Dec
deriveFrExp cons = do
  clauses <- sequence (zipWith3 deriveFrExpClause (repeat (length cons)) [0 .. ] cons)
  imp <- DSH.impossible
  let lastClause = Clause [WildP] (NormalB imp) []
  return (FunD 'DSH.frExp (clauses ++ [lastClause]))

deriveFrExpClause :: Int -- Total number of constructors
                  -> Int -- Index of the constructor
                  -> Con
                  -> Q Clause
deriveFrExpClause 1 _ con = do
  (_,names1) <- conToPattern con
  let pat1 = deriveFrExpMainPat names1
  let exp1 = foldl AppE (ConE (conToName con)) (map (AppE (VarE 'DSH.frExp) . VarE) names1)
  let body1 = NormalB exp1
  return (Clause [pat1] body1 [])
deriveFrExpClause n i con = do
  (_,names1) <- conToPattern con
  let pat1 = deriveFrExpMainPat names1
  let patList1 = ConP 'DSH.ListE [ConP '(:) [pat1,WildP]]
  let lists = replicate i WildP ++ [patList1] ++ replicate (n - i - 1) WildP
  let pat2 = foldr1 (\p1 p2 -> ConP 'DSH.PairE [p1,p2]) lists
  let exp1 = foldl AppE (ConE (conToName con)) (map (AppE (VarE 'DSH.frExp) . VarE) names1)
  let body1 = NormalB exp1
  return (Clause [pat2] body1 [])

deriveFrExpMainPat :: [Name] -> Pat
deriveFrExpMainPat [] = ConP 'DSH.UnitE []
deriveFrExpMainPat [name] = VarP name
deriveFrExpMainPat names  = foldr1 (\p1 p2 -> ConP 'DSH.PairE [p1,p2]) (map VarP names)

-------------------
-- Deriving Elim --
-------------------

deriveElim :: Name -> Q [Dec]
deriveElim name = do
  info <- reify name
  case info of
    TyConI (DataD    _cxt name1 tyVarBndrs cons _names) -> deriveTyConElim name1 tyVarBndrs cons
    TyConI (NewtypeD _cxt name1 tyVarBndrs con  _names) -> deriveTyConElim name1 tyVarBndrs [con]
    _ -> fail errMsgExoticType

deriveTyConElim :: Name -> [TyVarBndr] -> [Con] -> Q [Dec]
deriveTyConElim name tyVarBndrs cons = do
  resultTyName <- newName "r"
  let resTy = VarT resultTyName
  let ty = foldl AppT (ConT name) (map (VarT . tyVarBndrToName) tyVarBndrs)
  let context = ClassP ''DSH.QA [resTy] :
                map (\tv -> ClassP ''DSH.QA [VarT (tyVarBndrToName tv)]) tyVarBndrs
  let instanceHead = AppT (AppT (ConT ''DSH.Elim) ty) resTy
  let eliminatorDec = deriveEliminator ty resTy cons
  elimDec <- deriveElimFun cons
  return [InstanceD context instanceHead [eliminatorDec,elimDec]]

-- Derive the Eliminator type function

deriveEliminator :: Type -> Type -> [Con] -> Dec
deriveEliminator typ resTy cons = TySynInstD ''DSH.Eliminator [typ,resTy] (deriveEliminatorCons resTy cons)

deriveEliminatorCons :: Type -> [Con] -> Type
deriveEliminatorCons _ []  = error errMsgExoticType
deriveEliminatorCons resTy cs  =
  foldr (AppT . AppT ArrowT . deriveEliminatorCon resTy)
        (AppT (ConT ''DSH.Q) resTy)
        cs

deriveEliminatorCon :: Type -> Con -> Type
deriveEliminatorCon resTy con =
  foldr (AppT . AppT ArrowT . AppT (ConT ''DSH.Q))
        (AppT (ConT ''DSH.Q) resTy)
        (conToTypes con)

-- Derive the elim function of the Elim type class

deriveElimFun :: [Con] -> Q Dec
deriveElimFun cons = do
  clause1 <- deriveElimFunClause cons
  return (FunD 'DSH.elim [clause1])

deriveElimFunClause :: [Con] -> Q Clause
deriveElimFunClause cons = do
  en  <- newName "e"
  fns <- mapM (\ _ -> newName "f") cons
  let fes = map VarE fns
  let pats1 = ConP 'DSH.Q [VarP en] : map VarP fns

  fes2 <- zipWithM deriveElimToLamExp fes (map (length . conToTypes) cons)

  let e       = VarE en
  let liste   = AppE (ConE 'DSH.ListE) (ListE (deriveElimFunClauseExp e fes2))
  let concate = AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Concat)) liste
  let heade   = AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Head)) concate
  let qe      = AppE (ConE 'DSH.Q) heade
  return (Clause pats1 (NormalB qe) [])

deriveElimToLamExp :: Exp -> Int -> Q Exp
deriveElimToLamExp f 0 =
  return (AppE (VarE 'const) (AppE (VarE 'DSH.unQ) f))
deriveElimToLamExp f 1 = do
  xn <- newName "x"
  let xe = VarE xn
  let xp = VarP xn
  let qe = AppE (ConE 'DSH.Q) xe
  let fappe = AppE f qe
  let unqe = AppE (VarE 'DSH.unQ) fappe
  return (LamE [xp] unqe)
deriveElimToLamExp f n = do
  xn <- newName "x"
  let xe = VarE xn
  let xp = VarP xn
  let fste = AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Fst)) xe
  let snde = AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Snd)) xe
  let qe = AppE (ConE 'DSH.Q) fste
  let fappe = AppE f qe
  f' <- deriveElimToLamExp fappe (n - 1)
  return (LamE [xp] (AppE f' snde))

deriveElimFunClauseExp :: Exp -> [Exp] -> [Exp]
deriveElimFunClauseExp _ [] = error errMsgExoticType
deriveElimFunClauseExp e [f] = [AppE (ConE 'DSH.ListE) (ListE [AppE f e])]
deriveElimFunClauseExp e fs = go e fs
  where
  go :: Exp -> [Exp] -> [Exp]
  go _ []  = error errMsgExoticType
  go e1 [f1] =
    let paire = AppE (AppE (ConE 'DSH.PairE) (AppE (ConE 'DSH.LamE) f1)) e1
    in  [AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Map)) paire]
  go e1 (f1 : fs1) =
    let fste  = AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Fst)) e1
        snde  = AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Snd)) e1
        paire = AppE (AppE (ConE 'DSH.PairE) (AppE (ConE 'DSH.LamE) f1)) fste
        mape  = AppE (AppE (ConE 'DSH.AppE) (ConE 'DSH.Map)) paire
    in  mape : go snde fs1

-- Helper Functions

conToTypes :: Con -> [Type]
conToTypes (NormalC _name strictTypes) = map snd strictTypes
conToTypes (RecC _name varStrictTypes) = map (\(_,_,t) -> t) varStrictTypes
conToTypes (InfixC st1 _name st2) = [snd st1,snd st2]
conToTypes (ForallC _tyVarBndrs _cxt con) = conToTypes con

tyVarBndrToName :: TyVarBndr -> Name
tyVarBndrToName (PlainTV name) = name
tyVarBndrToName (KindedTV name _kind) = name

conToPattern :: Con -> Q (Pat,[Name])
conToPattern (NormalC name strictTypes) = do
  ns <- mapM (\ _ -> newName "x") strictTypes
  return (ConP name (map VarP ns),ns)
conToPattern (RecC name varStrictTypes) = do
  ns <- mapM (\ _ -> newName "x") varStrictTypes
  return (ConP name (map VarP ns),ns)
conToPattern (InfixC st1 name st2) = do
  ns <- mapM (\ _ -> newName "x") [st1,st2]
  return (ConP name (map VarP ns),ns)
conToPattern (ForallC _tyVarBndr _cxt con) = conToPattern con

conToName :: Con -> Name
conToName (NormalC name _) = name
conToName (RecC name _) = name
conToName (InfixC _ name _) = name
conToName (ForallC _ _ con)	= conToName con

-- Error messages

errMsgExoticType :: String
errMsgExoticType =  "Automatic derivation of DSH related type class instances only works for Haskell 98 types."