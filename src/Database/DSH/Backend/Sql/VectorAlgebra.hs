{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ParallelListComp      #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeSynonymInstances  #-}

-- | Implementation of vector primitives in terms of table algebra
-- operators.
module Database.DSH.Backend.Sql.VectorAlgebra () where

import           Control.Applicative              hiding (Const)
import qualified Data.List.NonEmpty               as N
import           GHC.Exts

import           Database.Algebra.Dag.Build
import           Database.Algebra.Dag.Common
import           Database.Algebra.Table.Construct
import           Database.Algebra.Table.Lang

import qualified Database.DSH.Common.Lang         as L
import qualified Database.DSH.Common.Type         as T
import           Database.DSH.Common.Vector
import           Database.DSH.Common.Impossible
import qualified Database.DSH.VL                  as VL

--------------------------------------------------------------------------------
-- Some general helpers

-- | Results are stored in column:
pos, item', item, descr, descr', descr'', pos', pos'', pos''', posold, posnew, ordCol, resCol, absPos, descri, descro, posi, poso:: Attr
pos       = "pos"
item      = "item1"
item'     = "itemtmp"
descr     = "descr"
descr'    = "descr1"
descr''   = "descr2"
pos'      = "pos1"
pos''     = "pos2"
pos'''    = "pos3"
posold    = "posold"
posnew    = "posnew"
ordCol    = "ord"
resCol    = "res"
absPos    = "abspos"
descro    = "descro"
descri    = "descri"
poso      = "poso"
posi      = "posi"

itemi :: Int -> Attr
itemi i = "item" ++ show i

itemi' :: Int -> Attr
itemi' i = "itemtmp" ++ show i

algVal :: L.ScalarVal -> AVal
algVal (L.IntV i)     = int (fromIntegral i)
algVal (L.BoolV t)    = bool t
algVal L.UnitV        = int (-1)
algVal (L.StringV s)  = string s
algVal (L.DoubleV d)  = double d
algVal (L.DateV d)    = date d
algVal (L.DecimalV d) = dec d

algTy :: T.ScalarType -> ATy
algTy T.IntT     = intT
algTy T.DoubleT  = doubleT
algTy T.BoolT    = boolT
algTy T.StringT  = stringT
algTy T.UnitT    = intT
algTy T.DateT    = dateT
algTy T.DecimalT = decT

cP :: Attr -> Proj
cP a = (a, ColE a)

eP :: Attr -> Expr -> Proj
eP = (,)

mP :: Attr -> Attr -> Proj
mP n o = (n, ColE o)

projAddCols :: [VL.DBCol] -> [Proj] -> AlgNode -> Build TableAlgebra AlgNode
projAddCols cols projs q = proj ([cP descr, cP pos] ++ map (cP . itemi) cols ++ projs) q

itemProj :: [VL.DBCol] -> [Proj] -> [Proj]
itemProj cols projs = projs ++ [ cP $ itemi i | i <- cols ]

binOp :: L.ScalarBinOp -> Expr -> Expr -> Expr
binOp (L.SBNumOp L.Add)       = BinAppE Plus
binOp (L.SBNumOp L.Sub)       = BinAppE Minus
binOp (L.SBNumOp L.Div)       = BinAppE Div
binOp (L.SBNumOp L.Mul)       = BinAppE Times
binOp (L.SBNumOp L.Mod)       = BinAppE Modulo
binOp (L.SBRelOp L.Eq)        = BinAppE Eq
binOp (L.SBRelOp L.NEq)       = BinAppE NEq
binOp (L.SBRelOp L.Gt)        = BinAppE Gt
binOp (L.SBRelOp L.GtE)       = BinAppE GtE
binOp (L.SBRelOp L.Lt)        = BinAppE Lt
binOp (L.SBRelOp L.LtE)       = BinAppE LtE
binOp (L.SBBoolOp L.Conj)     = BinAppE And
binOp (L.SBBoolOp L.Disj)     = BinAppE Or
binOp (L.SBStringOp L.Like)   = BinAppE Like
binOp (L.SBDateOp L.AddDays)  = \e1 e2 -> BinAppE Plus e2 e1
binOp (L.SBDateOp L.SubDays)  = \e1 e2 -> BinAppE Minus e2 e1
binOp (L.SBDateOp L.DiffDays) = \e1 e2 -> BinAppE Minus e2 e1

unOp :: L.ScalarUnOp -> UnFun
unOp (L.SUBoolOp L.Not)             = Not
unOp (L.SUCastOp (L.CastDouble))    = Cast doubleT
unOp (L.SUCastOp (L.CastDecimal))   = Cast decT
unOp (L.SUNumOp L.Sin)              = Sin
unOp (L.SUNumOp L.Cos)              = Cos
unOp (L.SUNumOp L.Tan)              = Tan
unOp (L.SUNumOp L.ASin)             = ASin
unOp (L.SUNumOp L.ACos)             = ACos
unOp (L.SUNumOp L.ATan)             = ATan
unOp (L.SUNumOp L.Sqrt)             = Sqrt
unOp (L.SUNumOp L.Exp)              = Exp
unOp (L.SUNumOp L.Log)              = Log
unOp (L.SUTextOp (L.SubString f t)) = SubString f t
unOp (L.SUDateOp L.DateDay)         = DateDay
unOp (L.SUDateOp L.DateMonth)       = DateMonth
unOp (L.SUDateOp L.DateYear)        = DateYear

taExprOffset :: Int -> VL.Expr -> Expr
taExprOffset o (VL.BinApp op e1 e2) = binOp op (taExprOffset o e1) (taExprOffset o e2)
taExprOffset o (VL.UnApp op e)      = UnAppE (unOp op) (taExprOffset o e)
taExprOffset o (VL.Column c)        = ColE $ itemi $ c + o
taExprOffset _ (VL.Constant v)      = ConstE $ algVal v
taExprOffset o (VL.If c t e)        = IfE (taExprOffset o c) (taExprOffset o t) (taExprOffset o e)

taExpr :: VL.Expr -> Expr
taExpr = taExprOffset 0

aggrFun :: VL.AggrFun -> AggrType
aggrFun (VL.AggrSum _ e) = Sum $ taExpr e
aggrFun (VL.AggrMin e)   = Min $ taExpr e
aggrFun (VL.AggrMax e)   = Max $ taExpr e
aggrFun (VL.AggrAvg e)   = Avg $ taExpr e
aggrFun (VL.AggrAll e)   = All $ taExpr e
aggrFun (VL.AggrAny e)   = Any $ taExpr e
aggrFun VL.AggrCount     = Count

-- Common building blocks

groupJoinDefault :: AlgNode -> [DBCol] -> AVal -> Build TableAlgebra AlgNode
groupJoinDefault qa ocols defaultVal =
    proj ([cP descr, cP pos]
          ++ map (cP . itemi) ocols
          ++ [eP acol (BinAppE Coalesce (ColE acol) (ConstE defaultVal))])
         qa
  where
    acol  = itemi $ length ocols + 1

-- -- | Add default values for empty groups produced by a groupjoin.
-- groupJoinDefault :: AlgNode
--                  -> AlgNode
--                  -> [DBCol]
--                  -> AVal
--                  -> Build TableAlgebra AlgNode
-- groupJoinDefault qo qa ocols defaultVal =
--     (projM ([cP descr, cP pos] ++ items
--             ++
--             [eP (itemi acol) (ConstE defaultVal)])
--      $ (return qo)
--        `differenceM`
--        (proj ([cP descr, cP pos] ++ items) qa))
--     `unionM`
--     (return qa)
--   where
--     items = map (cP . itemi) ocols
--     acol  = length ocols + 1

-- | For a segmented aggregate operator, apply the aggregate
-- function's default value for the empty segments. The first argument
-- specifies the outer descriptor vector, while the second argument
-- specifies the result vector of the aggregate.
segAggrDefault :: AlgNode -> AlgNode -> AVal -> Build TableAlgebra AlgNode
segAggrDefault qo qa dv =
    return qa
    `unionM`
    projM [cP descr, eP item (ConstE dv)]
        (differenceM
            (proj [mP descr pos] qo)
            (proj [cP descr] qa))

-- | If an aggregate's input is empty, add the aggregate functions
-- default value. The first argument 'q' is the original input vector,
-- whereas the second argument 'qa' is the aggregate's output.
aggrDefault :: AlgNode -> AlgNode -> AVal -> Build TableAlgebra AlgNode
aggrDefault q qa dv = do
    -- If the input is empty, produce a tuple with the default value.
    qd <- projM [eP descr (ConstE $ int 2), eP pos (ConstE $ int 1), eP item (ConstE dv)]
          $ (litTable (int 1) descr AInt)
            `differenceM`
            (proj [cP descr] q)

    -- For an empty input, there will be two tuples in
    -- the union result: the aggregate output with NULL
    -- and the default value.
    qu <- qa `union` qd

    -- Perform an argmax on the descriptor to get either
    -- the sum output (for a non-empty input) or the
    -- default value (which has a higher descriptor).
    projM [eP descr (ConstE $ int 1), cP pos, cP item]
       $ eqJoinM descr' descr
            (aggr [(Max $ ColE descr, descr')] [] qu)
            (return qu)


-- | The default value for sums over empty lists for all possible
-- numeric input types.
sumDefault :: T.ScalarType -> (ATy, AVal)
sumDefault T.IntT     = (AInt, int 0)
sumDefault T.DoubleT  = (ADouble, double 0)
sumDefault T.DecimalT = (ADec, dec 0)
sumDefault _          = $impossible

doZip :: (AlgNode, [VL.DBCol]) -> (AlgNode, [VL.DBCol]) -> Build TableAlgebra (AlgNode, [VL.DBCol])
doZip (q1, cols1) (q2, cols2) = do
  let offset = length cols1
  let cols' = cols1 ++ map (+offset) cols2
  r <- projM (cP descr : cP pos : map (cP . itemi) cols')
         $ eqJoinM pos pos'
           (return q1)
           (proj ((mP pos' pos):[ mP (itemi $ i + offset) (itemi i) | i <- cols2 ]) q2)
  return (r, cols')

joinPredicate :: Int -> L.JoinPredicate VL.Expr -> [(Expr, Expr, JoinRel)]
joinPredicate o (L.JoinPred conjs) = N.toList $ fmap joinConjunct conjs
  where
    joinConjunct :: L.JoinConjunct VL.Expr -> (Expr, Expr, JoinRel)
    joinConjunct (L.JoinConjunct e1 op e2) = (taExpr e1, taExprOffset o e2, joinOp op)

    joinOp :: L.BinRelOp -> JoinRel
    joinOp L.Eq  = EqJ
    joinOp L.Gt  = GtJ
    joinOp L.GtE = GeJ
    joinOp L.Lt  = LtJ
    joinOp L.LtE = LeJ
    joinOp L.NEq = NeJ

windowFunction :: VL.WinFun -> WinFun
windowFunction (VL.WinSum e)        = WinSum $ taExpr e
windowFunction (VL.WinMin e)        = WinMin $ taExpr e
windowFunction (VL.WinMax e)        = WinMax $ taExpr e
windowFunction (VL.WinAvg e)        = WinAvg $ taExpr e
windowFunction (VL.WinAll e)        = WinAll $ taExpr e
windowFunction (VL.WinAny e)        = WinAny $ taExpr e
windowFunction (VL.WinFirstValue e) = WinFirstValue $ taExpr e
windowFunction VL.WinCount          = WinCount

frameSpecification :: VL.FrameSpec -> FrameBounds
frameSpecification VL.FAllPreceding   = ClosedFrame FSUnboundPrec FECurrRow
frameSpecification (VL.FNPreceding n) = ClosedFrame (FSValPrec n) FECurrRow

-- The VectorAlgebra instance for TA algebra

instance VL.VectorAlgebra TableAlgebra where
  type DVec TableAlgebra = NDVec

  vecAlign (ADVec q1 cols1) (ADVec q2 cols2) = do
    (r, cols') <- doZip (q1, cols1) (q2, cols2)
    return $ ADVec r cols'

  vecZip (ADVec q1 cols1) (ADVec q2 cols2) = do
    (r, cols') <- doZip (q1, cols1) (q2, cols2)
    return $ ADVec r cols'

  vecLit tys vs = do
    qr <- litTable' (map (map algVal) vs)
                    ((descr, intT):(pos, intT):[(itemi i, algTy t) | (i, t) <- zip [1..] tys])
    return $ ADVec qr [1..length tys]

  vecPropRename (RVec q1) (ADVec q2 cols) = do
    q <- tagM "propRename"
         $ projM (itemProj cols [mP descr posnew, cP pos])
         $ eqJoin posold descr q1 q2
    return $ ADVec q cols

  vecPropFilter (RVec q1) (ADVec q2 cols) = do
    q <- rownumM pos' [posnew, pos] [] $ eqJoin posold descr q1 q2
    qr1 <- ADVec <$> proj (itemProj cols [mP descr posnew, mP pos pos']) q <*> pure cols
    qr2 <- RVec <$> proj [mP posold pos, mP posnew pos'] q
    return $ (qr1, qr2)

  -- For TA algebra, the filter and reorder cases are the same, since
  -- numbering to generate positions is done with a rownum and involves sorting.
  vecPropReorder (PVec q1) e2 = do
    (p, (RVec r)) <- VL.vecPropFilter (RVec q1) e2
    return (p, PVec r)

  vecUnboxNested (RVec qu) (ADVec qi cols) = do
    -- Perform a segment join between inner vector and outer unboxing
    -- rename vector. This implicitly discards any unreferenced
    -- segments in qi.
    q <- projM (itemProj cols [mP descr posnew, cP pos, mP posold pos'])
         $ rownumM pos [pos'] []
         $ eqJoinM posold descr'
             (return qu)
             (proj (itemProj cols [mP descr' descr, mP pos' pos]) qi)

    -- The unboxed vector containing one segment from the inner vector.
    qv <- proj (itemProj cols [cP descr, cP pos]) q
    -- A rename vector in case the inner vector has inner vectors as
    -- well.
    qr <- proj [mP posnew pos, cP posold] q

    return (ADVec qv cols, RVec qr)

  vecCombine (ADVec qb _) (ADVec q1 cols) (ADVec q2 _) = do
    d1 <- projM [cP pos', cP pos]
            $ rownumM pos' [pos] []
            $ select (ColE item) qb
    d2 <- projM [cP pos', cP pos]
          $ rownumM pos' [pos] []
          $ select (UnAppE Not (ColE item)) qb
    q <- eqJoinM pos' posold
            (return d1)
            (proj (itemProj cols [mP posold pos, cP descr]) q1)
         `unionM`
         eqJoinM pos' posold
            (return d2)
            (proj (itemProj cols [mP posold pos, cP descr]) q2)
    qr <- proj (itemProj cols [cP descr, cP pos]) q
    qp1 <- proj [mP posnew pos, mP posold pos'] d1
    qp2 <- proj [mP posnew pos, mP posold pos'] d2
    return $ (ADVec qr cols, RVec qp1, RVec qp2)

  vecSegment (ADVec q cols) = ADVec <$> proj (itemProj cols [mP descr pos, cP pos]) q <*> pure cols

  vecUnsegment (ADVec q cols) = do
    qr <- proj (itemProj cols [cP pos, eP descr (ConstE $ int 1)]) q
    return $ ADVec qr cols

  vecDistLift (ADVec q1 cols1) (ADVec q2 cols2) = do
    let cols2'    = [ i + length cols1 | i <- cols2 ]
        shiftProj = [ mP (itemi i') (itemi i) | i <- cols2 | i' <- cols2' ]
        resCols   = cols1 ++ cols2'
    q   <- eqJoinM pos' descr
             (proj (itemProj cols1 [mP pos' pos]) q1)
             (proj ([cP descr, cP pos] ++ shiftProj) q2)

    qr1 <- proj (itemProj resCols [cP descr, cP pos]) q
    qr2 <- proj [mP posold pos', mP posnew pos] q
    return (ADVec qr1 resCols, PVec qr2)

  vecWinFun a w (ADVec q cols1) = do
    let wfun      = windowFunction a
        frameSpec = frameSpecification w
        winCol    = itemi $ length cols1 + 1
    qw <- winFun (winCol, wfun) [] [(ColE pos, Asc)] (Just frameSpec) q
    return $ ADVec qw (cols1 ++ [length cols1 + 1])

  vecAggr a (ADVec q _) = do
    -- The aggr operator itself
    qa <- projM [eP descr (ConstE $ int 1), eP pos (ConstE $ int 1), cP item]
          $ aggr [(aggrFun a, item)] [] q
    -- For sum, add the default value for empty inputs
    qd <- case a of
              VL.AggrSum t _ -> aggrDefault q qa (snd $ sumDefault t)
              VL.AggrAll _   -> aggrDefault q qa (bool True)
              VL.AggrAny _   -> aggrDefault q qa (bool False)
              _              -> return qa

    return $ ADVec qd [1]

  vecAggrNonEmpty as (ADVec q _) = do
    let resCols = [1 .. N.length as]

    let aggrFuns = [ (aggrFun a, itemi i)
                   | a <- N.toList as
                   | i <- resCols
                   ]

    qa <- projM (itemProj resCols [eP descr (ConstE $ int 1), eP pos (ConstE $ int 1)])
          $ aggr aggrFuns [] q

    return $ ADVec qa resCols


  vecAggrS a (ADVec qo _) (ADVec qi _) = do
    qa <- aggr [(aggrFun a, item)] [(descr, ColE descr)] qi
    qd <- case a of
              VL.AggrSum t _ -> segAggrDefault qo qa (snd $ sumDefault t)
              VL.AggrAny _   -> segAggrDefault qo qa (bool False)
              VL.AggrAll _   -> segAggrDefault qo qa (bool True)

              VL.AggrCount   -> segAggrDefault qo qa (int 0)
              _              -> return qa

    qr <- rownum' pos [(ColE descr, Asc)] [] qd

    return $ ADVec qr [1]

  vecAggrNonEmptyS as (ADVec q _) = do
    let resCols = [1 .. N.length as]

    let aggrFuns = [ (aggrFun a, itemi i)
                   | a <- N.toList as
                   | i <- resCols
                   ]

    -- Compute aggregate output per segment and new positions
    qa <- projM (itemProj resCols [cP descr, cP pos])
          $ rownumM pos [descr] []
          $ aggr aggrFuns [(descr, ColE descr)] q

    return $ ADVec qa resCols

  vecReverse (ADVec q cols) = do
    q' <- rownum' pos' [(ColE pos, Desc)] [] q
    r <- proj (itemProj cols [cP descr, mP pos pos']) q'
    p <- proj [mP posold pos, mP posnew pos'] q'
    return (ADVec r cols, PVec p)

  vecReverseS (ADVec q cols) = do
    q' <- rownum' pos' [(ColE descr, Asc), (ColE pos, Desc)] [] q
    r <- proj (itemProj cols [cP descr, mP pos pos']) q'
    p <- proj [mP posold pos, mP posnew pos'] q'
    return (ADVec r cols, PVec p)

  vecUniqueS (ADVec q cols) = do
    let groupCols = map (\c -> (c, ColE c)) (descr : map itemi cols)
    qr <- rownumM pos [pos] []
          $ aggr [(Min (ColE pos), pos)] groupCols q
    return $ ADVec qr cols

  descToRename (ADVec q1 _) = RVec <$> proj [mP posnew descr, mP posold pos] q1

  singletonDescr = do
    q <- litTable' [[int 1, int 1]] [(descr, intT), (pos, intT)]
    return $ ADVec q []

  vecAppend (ADVec q1 cols) (ADVec q2 _) = do
    q <- rownumM posnew [ordCol, pos] []
           $ projAddCols cols [eP ordCol (ConstE (int 1))] q1
             `unionM`
             projAddCols cols [eP ordCol (ConstE (int 2))] q2
    qv <- tagM "append r" (proj (itemProj cols [mP pos posnew, cP descr]) q)
    qp1 <- tagM "append r1"
           $ projM [mP posold pos, cP posnew]
           $ select (BinAppE Eq (ColE ordCol) (ConstE $ int 1)) q
    qp2 <- tagM "append r2"
           $ projM [mP posold pos, cP posnew]
           $ select (BinAppE Eq (ColE ordCol) (ConstE $ int 2)) q
    return $ (ADVec qv cols, RVec qp1, RVec qp2)

  vecAppendS (ADVec q1 cols) (ADVec q2 _) = do
    q <- rownumM posnew [descr, ordCol, pos] []
           $ projAddCols cols [eP ordCol (ConstE (int 1))] q1
             `unionM`
             projAddCols cols [eP ordCol (ConstE (int 2))] q2
    qv <- tagM "append r" (proj (itemProj cols [mP pos posnew, cP descr]) q)
    qp1 <- tagM "append r1"
           $ projM [mP posold pos, cP posnew]
           $ select (BinAppE Eq (ColE ordCol) (ConstE $ int 1)) q
    qp2 <- tagM "append r2"
           $ projM [mP posold pos, cP posnew]
           $ select (BinAppE Eq (ColE ordCol) (ConstE $ int 2)) q
    return $ (ADVec qv cols, RVec qp1, RVec qp2)

  vecSelect expr (ADVec q cols) = do
    qs <- rownumM posnew [pos] []
          $ select (taExpr expr) q
    qv <- proj (itemProj cols [cP descr, mP pos posnew]) qs
    qr <- proj [mP posold pos, cP posnew] qs
    return (ADVec qv cols, RVec qr)

  vecTableRef tableName schema = do
    q <- -- generate the pos column
         rownumM pos orderCols []
         -- map table columns to item columns, add constant descriptor
         $ projM (eP descr (ConstE (int 1)) : [ mP (itemi i) c | (c, i) <- numberedColNames ])
         $ dbTable tableName taColumns (map Key taKeys)
    return $ ADVec q (map snd numberedColNames)

    where
      numberedColNames = zipWith (\((L.ColName c), _) i -> (c, i))
                                 (N.toList $ L.tableCols schema)
                                 [1..]

      taColumns = [ (c, algTy t)
                  | (L.ColName c, t) <- N.toList $ L.tableCols schema
                  ]

      taKeys =    [ [ itemi $ colIndex c | L.ColName c <- N.toList k ]
                  | L.Key k <- N.toList $ L.tableKeys schema
                  ]

      colIndex :: Attr -> Int
      colIndex n =
          case lookup n numberedColNames of
              Just i  -> i
              Nothing -> $impossible

      -- the initial table order is generated as follows:
      -- * if there are known keys for the table, we take the shortest one, in the hope
      --   that it will be the primary key. A sorting operation then might be able to
      --   use a primary key index.
      -- * without a key, we just take an arbitrary column (here, the first).
      orderCols = case sortWith length taKeys of
                      k : _ -> k
                      []    -> [itemi 1]

  vecGroupS groupExprs (ADVec q1 cols1) = do
      -- apply the grouping expressions and compute surrogate values
      -- from the grouping values
      let groupProjs = [ eP (itemi' i) (taExpr e) | e <- groupExprs | i <- [1..] ]
          groupCols = map fst groupProjs
      qg <- rowrankM resCol [ (ColE c, Asc) | c <- (descr : groupCols) ]
            $ proj (itemProj cols1 ([cP descr, cP pos] ++ groupProjs)) q1

      -- Create the outer vector, containing surrogate values and the
      -- grouping values
      qo <- distinctM
            $ proj ([cP descr, mP pos resCol]
                    ++ [ mP (itemi i) c | c <- groupCols | i <- [1..] ]) qg

      -- Create new positions for the inner vector
      qp <- rownum posnew [resCol, pos] [] qg

      -- Create the inner vector, containing the actual groups
      qi <- proj (itemProj cols1 [mP descr resCol, mP pos posnew]) qp

      qprop <- proj [mP posold pos, cP posnew] qp

      return (ADVec qo [1 .. length groupExprs], ADVec qi cols1, PVec qprop)

  vecGroup groupExprs (ADVec q1 cols1) = do
      -- apply the grouping expressions and compute surrogate values
      -- from the grouping values
      let groupProjs = [ eP (itemi' i) (taExpr e) | e <- groupExprs | i <- [1..] ]
          groupCols = map fst groupProjs
      qg <- rowrankM resCol [ (ColE c, Asc) | c <- groupCols ]
            $ proj (itemProj cols1 ([cP descr, cP pos] ++ groupProjs)) q1

      -- Create the outer vector, containing surrogate values and the
      -- grouping values
      qo <- distinctM
            $ proj ([cP descr, mP pos resCol]
                    ++ [ mP (itemi i) c | c <- groupCols | i <- [1..] ]) qg

      -- Create new positions for the inner vector
      qp <- rownum posnew [resCol, pos] [] qg

      -- Create the inner vector, containing the actual groups
      qi <- proj (itemProj cols1 [mP descr resCol, mP pos posnew]) qp

      qprop <- proj [mP posold pos, cP posnew] qp

      return (ADVec qo [1 .. length groupExprs], ADVec qi cols1, PVec qprop)

  vecCartProduct (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'

    q <- projM ([cP descr, cP pos, cP pos', cP pos''] ++ itemProj1 ++ itemProj2)
           $ rownumM pos [pos', pos''] []
           $ crossM
             (proj ([cP descr, mP pos' pos] ++ itemProj1) q1)
             (proj ((mP pos'' pos) : shiftProj2) q2)

    qv <- proj ([cP  descr, cP pos] ++ itemProj1 ++ itemProj2) q
    qp1 <- proj [mP posold pos', mP posnew pos] q
    qp2 <- proj [mP posold pos'', mP posnew pos] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp1, PVec qp2)

  vecCartProductS (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'
    q <- projM ([cP descr, cP pos, cP pos', cP pos''] ++ itemProj1 ++ itemProj2)
           $ rownumM pos [descr, descr', pos', pos''] []
           $ eqJoinM descr descr'
             (proj ([cP descr, mP pos' pos] ++ itemProj1) q1)
             (proj ([mP descr' descr, mP pos'' pos] ++ shiftProj2) q2)
    qv <- proj ([cP  descr, cP pos] ++ itemProj1 ++ itemProj2) q
    qp1 <- proj [mP posold pos', mP posnew pos] q
    qp2 <- proj [mP posold pos'', mP posnew pos] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp1, PVec qp2)

  vecNestProduct (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'

    q <- projM ([mP descr pos', cP pos, cP pos', cP pos''] ++ itemProj1 ++ itemProj2)
           $ rownumM pos [pos', pos''] []
           $ crossM
             (proj ([cP descr, mP pos' pos] ++ itemProj1) q1)
             (proj ((mP pos'' pos) : shiftProj2) q2)

    qv <- proj ([cP descr, cP pos] ++ itemProj1 ++ itemProj2) q
    qp1 <- proj [mP posold pos', mP posnew pos] q
    qp2 <- proj [mP posold pos'', mP posnew pos] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp1, PVec qp2)

  -- FIXME merge common parts of vecCartProductS and vecNestProductS
  vecNestProductS (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'

    q <- projM ([mP descr pos', cP pos, cP pos', cP pos''] ++ itemProj1 ++ itemProj2)
           $ rownumM pos [descr, pos', pos''] []
           $ eqJoinM descr descr'
             (proj ([cP descr, mP pos' pos] ++ itemProj1) q1)
             (proj ([mP descr' descr, mP pos'' pos] ++ shiftProj2) q2)
    qv <- proj ([cP  descr, cP pos] ++ itemProj1 ++ itemProj2) q
    qp2 <- proj [mP posold pos'', mP posnew pos] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp2)

  vecThetaJoin joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'

    q <- projM ([cP descr, cP pos, cP pos', cP pos''] ++ itemProj1 ++ itemProj2)
           $ rownumM pos [pos', pos''] []
           $ thetaJoinM (joinPredicate (length cols1) joinPred)
             (proj ([ cP descr
                    , mP pos' pos
                    ] ++ itemProj1) q1)
             (proj ([ mP pos'' pos
                    ] ++ shiftProj2) q2)

    qv <- tagM "eqjoin/1" $ proj ([cP  descr, cP pos] ++ itemProj1 ++ itemProj2) q
    qp1 <- proj [mP posold pos', mP posnew pos] q
    qp2 <- proj [mP posold pos'', mP posnew pos] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp1, PVec qp2)

  vecNestJoin joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'

    q <- projM ([cP pos, cP pos', cP posnew] ++ itemProj1 ++ itemProj2)
           $ rownumM posnew [pos, pos'] []
           $ thetaJoinM (joinPredicate (length cols1) joinPred)
                 (return q1)
                 (proj ([ mP pos' pos] ++ shiftProj2) q2)

    qv  <- proj ([mP descr pos, mP pos posnew] ++ itemProj1 ++ itemProj2) q
    qp1 <- proj [mP posold pos, cP posnew] q
    qp2 <- proj [mP posold pos', cP posnew] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp1, PVec qp2)

  vecThetaJoinS joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'

    q <- projM ([cP descr, cP pos, cP pos', cP pos''] ++ itemProj1 ++ itemProj2)
           $ rownumM pos [pos', pos''] []
           $ thetaJoinM ((ColE descr, ColE descr', EqJ) : joinPredicate (length cols1) joinPred)
             (proj ([ cP descr
                    , mP pos' pos
                    ] ++ itemProj1) q1)
             (proj ([ mP descr' descr
                    , mP pos'' pos
                    ] ++ shiftProj2) q2)

    qv <- proj ([cP  descr, cP pos] ++ itemProj1 ++ itemProj2) q
    qp1 <- proj [mP posold pos', mP posnew pos] q
    qp2 <- proj [mP posold pos'', mP posnew pos] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp1, PVec qp2)

  -- There is only one difference between EquiJoinS and NestJoinS. For
  -- NestJoinS, we 'segment' after the join, i.e. use the left input
  -- positions as the result descriptor.
  -- FIXME merge the common parts.
  vecNestJoinS joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)
        itemProj2  = map (cP . itemi) cols2'

    q <- projM ([mP descr pos', cP pos, cP pos', cP pos''] ++ itemProj1 ++ itemProj2)
           $ rownumM pos [descr, pos', pos''] []
           $ thetaJoinM ((ColE descr, ColE descr', EqJ) : joinPredicate (length cols1) joinPred)
             (proj ([ cP descr
                    , mP pos' pos
                    ] ++ itemProj1) q1)
             (proj ([ mP descr' descr
                    , mP pos'' pos
                    ] ++ shiftProj2) q2)

    qv <- proj ([cP  descr, cP pos] ++ itemProj1 ++ itemProj2) q
    qp2 <- proj [mP posold pos'', mP posnew pos] q
    return (ADVec qv (cols1 ++ cols2'), PVec qp2)

  vecUnboxScalar (ADVec qo colso) (ADVec qi colsi) = do
    let colsi'     = [((length colso) + 1) .. ((length colso) + (length colsi))]
        shiftProji = zipWith mP (map itemi colsi') (map itemi colsi)
        itemProji  = map (cP . itemi) colsi'

    qu <- projM ([cP descr, cP pos] ++ (map (cP . itemi) colso) ++ itemProji)
              $ eqJoinM pos descr'
                  (return qo)
                  (proj ([mP descr' descr] ++ shiftProji) qi)
    return $ ADVec qu (colso ++ colsi')

  vecSelectPos (ADVec qe cols) op (ADVec qi _) = do
    qs <- selectM (binOp op (ColE pos) (ColE item'))
          $ crossM
              (return qe)
              (proj [mP item' item] qi)

    q' <- case op of
            -- If we select positions from the beginning, we can re-use the old
            -- positions
            (L.SBRelOp L.Lt)  -> projAddCols cols [mP posnew pos] qs
            (L.SBRelOp L.LtE) -> projAddCols cols [mP posnew pos] qs
            -- Only if selected positions don't start at the beginning (i.e. 1)
            -- do we have to recompute them.
            _      -> rownum posnew [pos] [] qs

    qr <- proj (itemProj cols [cP descr, mP pos posnew]) q'
    -- A regular rename vector for re-aligning inner vectors
    qp <- proj [ mP posold pos, cP posnew ] q'
    -- An unboxing rename vector
    qu <- proj [ mP posold pos, mP posnew descr ] q'
    return $ (ADVec qr cols, RVec qp, RVec qu)

  vecSelectPosS (ADVec qe cols) op (ADVec qi _) = do
    qs <- rownumM posnew [pos] []
          $ selectM (binOp op (ColE absPos) (ColE item'))
          $ eqJoinM descr pos'
              (rownum absPos [pos] [ColE descr] qe)
              (proj [mP pos' pos, mP item' item] qi)

    qr <- proj (itemProj cols [cP descr, mP pos posnew]) qs
    qp <- proj [ mP posold pos, cP posnew ] qs
    qu <- proj [ mP posnew descr, mP posold pos] qs
    return $ (ADVec qr cols, RVec qp, RVec qu)

  vecSelectPos1 (ADVec qe cols) op posConst = do
    let posConst' = VInt $ fromIntegral posConst
    qs <- select (binOp op (ColE pos) (ConstE posConst')) qe

    q' <- case op of
            -- If we select positions from the beginning, we can re-use the old
            -- positions
            (L.SBRelOp L.Lt)  -> projAddCols cols [mP posnew pos] qs
            (L.SBRelOp L.LtE) -> projAddCols cols [mP posnew pos] qs
            -- Only if selected positions don't start at the beginning (i.e. 1)
            -- do we have to recompute them.
            _      -> rownum posnew [pos] [] qs

    qr <- proj (itemProj cols [cP descr, mP pos posnew]) q'
    qp <- proj [ mP posold pos, cP posnew ] q'
    qu <- proj [ mP posold pos, mP posnew descr ] q'
    return $ (ADVec qr cols, RVec qp, RVec qu)

  -- If we select positions in a lifted way, we need to recompute
  -- positions in any case.
  vecSelectPos1S (ADVec qe cols) op posConst = do
    let posConst' = VInt $ fromIntegral posConst
    qs <- rownumM posnew [pos] []
          $ selectM (binOp op (ColE absPos) (ConstE posConst'))
          $ rownum absPos [pos] [ColE descr] qe

    qr <- proj (itemProj cols [cP descr, mP pos posnew]) qs
    qp <- proj [ mP posold pos, cP posnew ] qs
    qu <- proj [ mP posold pos, mP posnew descr ] qs
    return $ (ADVec qr cols, RVec qp, RVec qu)

  vecProject projs (ADVec q _) = do
    let projs' = zipWith (\i e -> (itemi i, taExpr e)) [1 .. length projs] projs
    qr <- proj ([cP descr, cP pos] ++ projs') q
    return $ ADVec qr [1 .. (length projs)]

  vecZipS (ADVec q1 cols1) (ADVec q2 cols2) = do
    q1' <- rownum pos'' [pos] [ColE descr] q1
    q2' <- rownum pos''' [pos] [ColE descr] q2
    let offset      = length cols1
        cols2'      = map (+ offset) cols2
        allCols     = cols1 ++ cols2'
        allColsProj = map (cP . itemi) allCols
        shiftProj   = zipWith mP (map itemi cols2') (map itemi cols2)
    qz <- rownumM posnew [descr, pos''] []
          $ projM ([cP pos', cP pos, cP descr] ++ allColsProj)
          $ thetaJoinM [(ColE descr, ColE descr', EqJ), (ColE pos'', ColE pos''', EqJ)]
              (return q1')
              (proj ([mP descr' descr, mP pos' pos, cP pos'''] ++ shiftProj) q2')

    r1 <- proj [mP posold pos'', cP posnew] qz
    r2 <- proj [mP posold pos''', cP posnew] qz
    qr <- proj ([cP descr, mP pos posnew] ++ allColsProj) qz
    return (ADVec qr allCols, RVec r1, RVec r2)

  vecGroupAggr groupExprs aggrFuns (ADVec q _) = do
    let partAttrs = (descr, cP descr)
                    :
                    [ (itemi i, eP (itemi i) (taExpr e)) | e <- groupExprs | i <- [1..] ]

        pw = length groupExprs

        pfAggrFuns = [ (aggrFun a, itemi $ pw + i) | a <- N.toList aggrFuns | i <- [1..] ]

    -- GroupAggr(e, f) has to mimic the behaviour of GroupS(e) +
    -- AggrS(f) exactly. GroupScalarS determines the order of the
    -- groups by the sort order of the grouping keys (implicitly via
    -- RowRank). GroupAggr has to provide the aggregated groups in the
    -- same order to be aligned. Therefore, we sort by /all/ grouping
    -- attributes.
    qa <- rownumM pos (map fst partAttrs) []
          $ aggr pfAggrFuns (map snd partAttrs) q

    return $ ADVec qa [1 .. length groupExprs + N.length aggrFuns]

  vecNumber (ADVec q cols) = do
    let nrIndex = length cols + 1
        nrItem = itemi nrIndex
    qr <- projAddCols cols [eP nrItem (ColE pos)] q
    return $ ADVec qr (cols ++ [nrIndex])

  -- The TA implementation of lifted number does not come for
  -- free: To generate the absolute numbers for every sublist
  -- (i.e. descriptor partition), we have to use a partitioned
  -- rownumber.
  vecNumberS (ADVec q cols) = do
    let nrIndex = length cols + 1
        nrItem = itemi nrIndex
    qr <- rownum nrItem [pos] [ColE descr] q
    return $ ADVec qr (cols ++ [nrIndex])

  vecSemiJoin joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)

    q <- rownumM pos [posold] []
         $ projM (itemProj cols1 [cP descr, mP posold pos])
         $ semiJoinM (joinPredicate (length cols1) joinPred)
             (proj (itemProj cols1 [cP descr, cP pos]) q1)
             (proj shiftProj2 q2)
    qj <- tagM "semijoin/1" $ proj (itemProj cols1 [cP descr, cP pos]) q
    r  <- proj [cP posold, mP posold posnew] q
    return $ (ADVec qj cols1, RVec r)

  vecSemiJoinS joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)

    q <- rownumM pos [descr, posold] []
         $ projM (itemProj cols1 [cP descr, mP posold pos])
         $ semiJoinM ((ColE descr, ColE descr', EqJ) : joinPredicate (length cols1) joinPred)
             (proj (itemProj cols1 [cP descr, cP pos]) q1)
             (proj ([mP descr' descr] ++ shiftProj2) q2)
    qj <- tagM "semijoinLift/1" $ proj (itemProj cols1 [cP descr, cP pos]) q
    r  <- proj [cP posold, mP posold posnew] q
    return $ (ADVec qj cols1, RVec r)

  vecAntiJoin joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)

    q <- rownumM pos [posold] []
         $ projM (itemProj cols1 [cP descr, mP posold pos])
         $ antiJoinM (joinPredicate (length cols1) joinPred)
             (proj (itemProj cols1 [cP descr, cP pos]) q1)
             (proj shiftProj2 q2)
    qj <- tagM "antijoin/1" $ proj (itemProj cols1 [cP descr, cP pos]) q
    r  <- proj [cP posold, mP posold posnew] q
    return $ (ADVec qj cols1, RVec r)

  vecAntiJoinS joinPred (ADVec q1 cols1) (ADVec q2 cols2) = do
    let cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)

    q <- rownumM pos [descr, posold] []
         $ projM (itemProj cols1 [cP descr, mP posold pos])
         $ antiJoinM ((ColE descr, ColE descr', EqJ) : joinPredicate (length cols1) joinPred)
             (proj (itemProj cols1 [cP descr, cP pos]) q1)
             (proj ([mP descr' descr] ++ shiftProj2) q2)
    qj <- tagM "antijoinLift/1" $ proj (itemProj cols1 [cP descr, cP pos]) q
    r  <- proj [cP posold, mP posold posnew] q
    return $ (ADVec qj cols1, RVec r)

  vecSort sortExprs (ADVec q1 cols1) = do
    let sortProjs = zipWith (\i e -> (itemi' i, taExpr e)) [1..] sortExprs
    -- Including positions implements stable sorting
    qs <- rownumM pos' (map fst sortProjs ++ [pos]) []
          $ projAddCols cols1 sortProjs q1

    qr1 <- proj (itemProj cols1 [cP descr, mP pos pos']) qs
    qr2 <- proj [mP posold pos, mP posnew pos'] qs

    return (ADVec qr1 cols1, PVec qr2)

  vecSortS sortExprs (ADVec q1 cols1) = do
    let sortProjs = zipWith (\i e -> (itemi' i, taExpr e)) [1..] sortExprs
    -- Including positions implements stable sorting
    qs <- rownumM pos' ([descr] ++ map fst sortProjs ++ [pos]) []
          $ projAddCols cols1 sortProjs q1

    qr1 <- proj (itemProj cols1 [cP descr, mP pos pos']) qs
    qr2 <- proj [mP posold pos, mP posnew pos'] qs

    return (ADVec qr1 cols1, PVec qr2)

  -- FIXME none of vecReshape, vecReshapeS, vecTranspose and
  -- vecTransposeS deal with empty inner inputs correctly!
  vecReshape n (ADVec q cols) = do
    let dExpr = BinAppE Div (BinAppE Minus (ColE pos) (ConstE $ int 1)) (ConstE $ int $ n + 1)
    qi <- proj (itemProj cols [cP pos, eP descr dExpr]) q
    qo <- projM [eP descr (ConstE $ int 1), cP pos]
          $ distinctM
          $ proj [mP pos descr] qi
    return (ADVec qo [], ADVec qi cols)

  vecReshapeS n (ADVec q cols) = do
    let dExpr = BinAppE Div (BinAppE Minus (ColE absPos) (ConstE $ int 1)) (ConstE $ int $ n + 1)
    qr <- -- Make the new descriptors valid globally
          -- FIXME need a rowrank instead!
          rownumM descr'' [descr, descr'] []
          -- Assign the inner list elements to sublists. Generated
          -- descriptors are _per_ inner list!
          $ projM (itemProj cols [cP descr, cP pos, eP descr' dExpr])
          -- Generate absolute positions for the inner lists
          $ rownum absPos [pos] [ColE descr] q

    -- We can compute the 'middle' descriptor vector from the original
    -- inner vector.
    qm <- distinctM $ proj [cP descr, mP pos descr''] qr

    qi <- proj (itemProj cols [mP descr descr'', cP pos]) qr

    return (ADVec qm [], ADVec qi cols)

  vecTranspose (ADVec q cols) = do
    qi <- projM (itemProj cols [mP descr descr', mP pos pos'])
          -- Generate new positions. We use absolute positions as the
          -- new descriptor here. This implements the swapping of row
          -- and column ids (here: descr and pos) that is the core of
          -- transposition.
          $ rownumM pos' [descr', pos] []
          -- Generate absolute positions for the inner lists
          $ rownum descr' [pos] [ColE descr] q

    qo <- projM [eP descr (ConstE $ int 1), cP pos]
          $ distinctM
          $ proj [mP pos descr] qi

    return (ADVec qo [], ADVec qi cols)

  vecTransposeS (ADVec qo _) (ADVec qi cols) = do
    qr  <- -- Generate new globally valid positions for the inner vector
           rownumM pos' [descr', absPos] []
           -- Absolute positions form the new inner descriptor. However, so
           -- far they are relative to the outer descriptor. Here, make them
           -- "globally" valid.
           $ rowrankM descr' [(ColE descro, Asc), (ColE absPos, Asc)]
           -- As usual, generate absolute positions
           $ rownumM absPos [posi] [ColE descri]
           -- Join middle and inner vector because we need to know to which
           -- outer list each leaf element belongs
           $ eqJoinM poso descri
               (proj [mP descro descr, mP poso pos] qo)
               (proj (itemProj cols [mP descri descr, mP posi pos]) qi)

    qi' <- proj (itemProj cols [mP descr descr', mP pos pos']) qr
    qm  <- distinctM $ proj [mP descr descro, mP pos descr'] qr

    return (ADVec qm [], ADVec qi' cols)

  vecGroupJoin p a (ADVec q1 cols1) (ADVec q2 cols2) = do
    let itemProj1  = map (cP . itemi) cols1
        cols2'     = [((length cols1) + 1) .. ((length cols1) + (length cols2))]
        shiftProj2 = zipWith mP (map itemi cols2') (map itemi cols2)

        acol       = length cols1 + 1

    -- We group primarily by left input positions, because they
    -- identify the groups generated by the join. The result has to
    -- contain left input segment and item columns as well. We can
    -- include them in the grouping criteria because they are
    -- functionally determined by positions (pos is key in the left
    -- input).
    let groupCols = [(pos, ColE pos), (descr, ColE descr)]
                    ++
                    [ (c, ColE c) | i <- cols1, let c = itemi i ]

    qa <- projM ([cP descr, cP pos] ++ itemProj1 ++ [cP $ itemi acol])
          $ aggrM [(aggrFun a, itemi acol)] groupCols
          $ leftOuterJoinM (joinPredicate (length cols1) p)
              (return q1)
              (proj shiftProj2 q2)

    qd <- case a of
              VL.AggrSum t _ -> groupJoinDefault qa cols1 (snd $ sumDefault t)
              VL.AggrAny _   -> groupJoinDefault qa cols1 (bool False)
              VL.AggrAll _   -> groupJoinDefault qa cols1 (bool True)
              VL.AggrCount   -> groupJoinDefault qa cols1 (int 0)
              _              -> select (UnAppE Not (UnAppE IsNull (ColE $ itemi acol))) qa

    return $ ADVec qd (cols1 ++ [acol])
