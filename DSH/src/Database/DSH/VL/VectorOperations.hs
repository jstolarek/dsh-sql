{-# LANGUAGE TemplateHaskell #-}
    
module Database.DSH.VL.VectorOperations where

import           Debug.Trace

import           Control.Applicative

import           Database.DSH.VL.Lang (VL(), VLVal(..), Nat(..), Expr1(..), AggrFun(..))

import           Database.DSH.Impossible
import           Database.DSH.VL.Data.GraphVector
import           Database.DSH.VL.Data.DBVector
import           Database.DSH.VL.VLPrimitives
import           Database.DSH.VL.MetaPrimitives
import qualified Database.DSH.Common.Lang as L
import           Database.DSH.Common.Type

zipPrim ::  Shape -> Shape -> Graph VL Shape
zipPrim (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    q' <- vlZip q1 q2
    return $ ValueVector q' $ zipLayout lyt1 lyt2
zipPrim _ _ = error "ziprim: Should not be possible"

zipLift ::  Shape -> Shape -> Graph VL Shape
zipLift (ValueVector d1 (Nest q1 lyt1)) (ValueVector _ (Nest q2 lyt2)) = do
    (q', r1, r2) <- vlZipS q1 q2
    lyt1'        <- chainRenameFilter r1 lyt1
    lyt2'        <- chainRenameFilter r2 lyt2
    return $ ValueVector d1 (Nest q' $ zipLayout lyt1' lyt2')
zipLift _ _ = error "zipLift: Should not be possible"

cartProductPrim :: Shape -> Shape -> Graph VL Shape
cartProductPrim (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    (q', p1, p2) <- vlCartProduct q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ ValueVector q' $ zipLayout lyt1' lyt2'
cartProductPrim _ _ = $impossible

cartProductLift :: Shape -> Shape -> Graph VL Shape
cartProductLift (ValueVector d1 (Nest q1 lyt1)) (ValueVector _ (Nest q2 lyt2)) = do
    (q', p1, p2) <- vlCartProductS q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ ValueVector d1 (Nest q' $ zipLayout lyt1' lyt2')
cartProductLift _ _ = $impossible

nestProductPrim :: Shape -> Shape -> Graph VL Shape
nestProductPrim (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
  q1' <- vlSegment q1
  ValueVector qj lytJ <- cartProductPrim (ValueVector q1' lyt1) (ValueVector q2 lyt2)
  return $ ValueVector q1 (Pair lyt1 (Nest qj lytJ))
nestProductPrim _ _ = $impossible

nestProductLift :: Shape -> Shape -> Graph VL Shape
nestProductLift (ValueVector qd1 (Nest qv1 lyt1)) (ValueVector _qd2 (Nest qv2 lyt2)) = do
    (qj, qp2) <- vlNestProductS qv1 qv2
    lyt2'     <- chainReorder qp2 lyt2
    let lytJ  = zipLayout lyt1 lyt2'
    return $ ValueVector qd1 (Nest qv1 (Pair lyt1 (Nest qj lytJ)))
nestProductLift _ _ = $impossible

equiJoinPrim :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
equiJoinPrim e1 e2 (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    (q', p1, p2) <- vlEquiJoin e1 e2 q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ ValueVector q' $ zipLayout lyt1' lyt2'
equiJoinPrim _ _ _ _ = $impossible

equiJoinLift :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
equiJoinLift e1 e2 (ValueVector d1 (Nest q1 lyt1)) (ValueVector _ (Nest q2 lyt2)) = do
    (q', p1, p2) <- vlEquiJoinS e1 e2 q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ ValueVector d1 (Nest q' $ zipLayout lyt1' lyt2')
equiJoinLift _ _ _ _ = $impossible

nestJoinPrim :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
nestJoinPrim e1 e2 (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    q1' <- vlSegment q1
    ValueVector qj lytJ <- equiJoinPrim e1 e2 (ValueVector q1' lyt1) (ValueVector q2 lyt2)
    return $ ValueVector q1 (Pair lyt1 (Nest qj lytJ))
nestJoinPrim _ _ _ _ = $impossible

-- △^L :: [[a]] -> [[b]] -> [[(a, [(a, b)])]] 

-- For the unlifted nestjoin, we could segment the left (outer) input
-- and then use the regular equijoin implementation. This trick does
-- not work here, as the lifted equijoin joins on the
-- descriptors. Therefore, we have to 'segment' **after** the join,
-- i.e. use the left input positions as descriptors
nestJoinLift :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
nestJoinLift e1 e2 (ValueVector qd1 (Nest qv1 lyt1)) (ValueVector _qd2 (Nest qv2 lyt2)) = do
    (qj, qp2) <- vlNestJoinS e1 e2 qv1 qv2
    lyt2'     <- chainReorder qp2 lyt2
    let lytJ  = zipLayout lyt1 lyt2'
    return $ ValueVector qd1 (Nest qv1 (Pair lyt1 (Nest qj lytJ)))
nestJoinLift _ _ _ _ = $impossible

semiJoinPrim :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
semiJoinPrim e1 e2 (ValueVector q1 lyt1) (ValueVector q2 _) = do
    (qj, r) <- vlSemiJoin e1 e2 q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ ValueVector qj lyt1'
semiJoinPrim _ _ _ _ = $impossible
    
semiJoinLift :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
semiJoinLift e1 e2 (ValueVector d1 (Nest q1 lyt1)) (ValueVector _ (Nest q2 _)) = do
    (qj, r) <- vlSemiJoinS e1 e2 q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ ValueVector d1 (Nest qj lyt1')
semiJoinLift _ _ _ _ = $impossible

antiJoinPrim :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
antiJoinPrim e1 e2 (ValueVector q1 lyt1) (ValueVector q2 _) = do
    (qj, r) <- vlAntiJoin e1 e2 q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ ValueVector qj lyt1'
antiJoinPrim _ _ _ _ = $impossible
    
antiJoinLift :: L.JoinExpr -> L.JoinExpr -> Shape -> Shape -> Graph VL Shape
antiJoinLift e1 e2 (ValueVector d1 (Nest q1 lyt1)) (ValueVector _ (Nest q2 _)) = do
    (qj, r) <- vlAntiJoinS e1 e2 q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ ValueVector d1 (Nest qj lyt1')
antiJoinLift _ _ _ _ = $impossible

nubPrim ::  Shape -> Graph VL Shape
nubPrim (ValueVector q lyt) = flip ValueVector lyt <$> vlUniqueS q
nubPrim _ = error "nubPrim: Should not be possible"

nubLift ::  Shape -> Graph VL Shape
nubLift (ValueVector d (Nest q lyt)) =  ValueVector d . flip Nest lyt <$> vlUniqueS q
nubLift _ = error "nubLift: Should not be possible"

numberPrim ::  Shape -> Graph VL Shape
numberPrim (ValueVector q lyt) = 
    ValueVector <$> vlNumber q 
                <*> (pure $ zipLayout lyt (InColumn 1))
numberPrim _ = error "numberPrim: Should not be possible"

numberLift ::  Shape -> Graph VL Shape
numberLift (ValueVector d (Nest q lyt)) = 
    ValueVector d <$> (Nest <$> vlNumberS q 
                            <*> (pure $ zipLayout lyt (InColumn 1)))
numberLift _ = error "numberLift: Should not be possible"

initPrim ::  Shape -> Graph VL Shape
initPrim (ValueVector q lyt) = do
    i       <- vlAggr AggrCount q
    (q', r) <- vlSelectPos q (L.SBRelOp L.Lt) i
    lyt'    <- chainRenameFilter r lyt
    return $ ValueVector q' lyt'
initPrim _ = error "initPrim: Should not be possible"

initLift ::  Shape -> Graph VL Shape
initLift (ValueVector qs (Nest q lyt)) = do
    is      <- vlAggrS AggrCount qs q
    (q', r) <- vlSelectPosS q (L.SBRelOp L.Lt) is
    lyt'    <- chainRenameFilter r lyt
    return $ ValueVector qs (Nest q' lyt')
initLift _ = error "initLift: Should not be possible"

lastPrim ::  Shape -> Graph VL Shape
lastPrim (ValueVector qs lyt@(Nest _ _)) = do
    i              <- vlAggr AggrCount qs
    (q, r)         <- vlSelectPos qs (L.SBRelOp L.Eq) i
    (Nest qr lyt') <- chainRenameFilter r lyt
    re             <- vlDescToRename q
    renameOuter re $ ValueVector qr lyt'
lastPrim (ValueVector qs lyt) = do
    i      <- vlAggr AggrCount qs
    (q, r) <- vlSelectPos qs (L.SBRelOp L.Eq) i
    lyt'   <- chainRenameFilter r lyt
    return $ PrimVal q lyt'
lastPrim _ = error "lastPrim: Should not be possible"

lastLift ::  Shape -> Graph VL Shape
lastLift (ValueVector d (Nest qs lyt@(Nest _ _))) = do
    is       <- vlAggrS AggrCount d qs
    (qs', r) <- vlSelectPosS qs (L.SBRelOp L.Eq) is
    lyt'     <- chainRenameFilter r lyt
    re       <- vlDescToRename qs'
    ValueVector d <$> renameOuter' re lyt'
lastLift (ValueVector d (Nest qs lyt)) = do
    is       <- vlAggrS AggrCount d qs
    (qs', r) <- vlSelectPosS qs (L.SBRelOp L.Eq) is
    lyt'     <- chainRenameFilter r lyt
    re       <- vlDescToRename d
    renameOuter re (ValueVector qs' lyt')
lastLift _ = error "lastLift: Should not be possible"

indexPrim ::  Shape -> Shape -> Graph VL Shape
indexPrim (ValueVector qs lyt@(Nest _ _)) (PrimVal i _) = do
    one            <- literal intT (VLInt 1)
    i'             <- vlBinExpr (L.SBNumOp L.Add) i one
    (q, r)         <- vlSelectPos qs (L.SBRelOp L.Eq) i'
    (Nest qr lyt') <- chainRenameFilter r lyt
    re             <- vlDescToRename q
    renameOuter re $ ValueVector qr lyt'
indexPrim (ValueVector qs lyt) (PrimVal i _) = do
    one    <- literal intT (VLInt 1)
    i'     <- vlBinExpr (L.SBNumOp L.Add) i one
    (q, r) <- vlSelectPos qs (L.SBRelOp L.Eq) i'
    lyt'   <- chainRenameFilter r lyt
    return $ PrimVal q lyt'
indexPrim _ _ = error "indexPrim: Should not be possible"

indexLift ::  Shape -> Shape -> Graph VL Shape
indexLift (ValueVector d (Nest qs lyt@(Nest _ _))) (ValueVector is (InColumn 1)) = do
    one       <- literal intT (VLInt 1)
    (ones, _) <- vlDistPrim one is
    is'       <- vlBinExpr (L.SBNumOp L.Add) is ones
    (qs', r)  <- vlSelectPosS qs (L.SBRelOp L.Eq) is'
    lyt'      <- chainRenameFilter r lyt
    re        <- vlDescToRename qs'
    ValueVector d <$> renameOuter' re lyt'
indexLift (ValueVector d (Nest qs lyt)) (ValueVector is (InColumn 1)) = do
    one       <- literal intT (VLInt 1)
    (ones, _) <- vlDistPrim one is
    is'       <- vlBinExpr (L.SBNumOp L.Add) is ones
    (qs', r)  <- vlSelectPosS qs (L.SBRelOp L.Eq) is'
    lyt'      <- chainRenameFilter r lyt
    re        <- vlDescToRename d
    renameOuter re (ValueVector qs' lyt')
indexLift _ _ = error "indexLift: Should not be possible"

appendPrim ::  Shape -> Shape -> Graph VL Shape
appendPrim = appendR

appendLift ::  Shape -> Shape -> Graph VL Shape
appendLift (ValueVector d lyt1) (ValueVector _ lyt2) = ValueVector d <$> appendR' lyt1 lyt2
appendLift _ _ = error "appendLift: Should not be possible"
    
reversePrim ::  Shape -> Graph VL Shape
reversePrim (ValueVector d lyt) = do
    (d', p) <- vlReverse d
    lyt'    <- chainReorder p lyt
    return (ValueVector d' lyt')
reversePrim _ = error "reversePrim: Should not be possible"

reverseLift ::  Shape -> Graph VL Shape
reverseLift (ValueVector d (Nest d1 lyt)) = do
    (d1', p) <- vlReverseS d1
    lyt'     <- chainReorder p lyt
    return (ValueVector d (Nest d1' lyt'))
reverseLift _ = error "vlReverseLift: Should not be possible"

the ::  Shape -> Graph VL Shape
the (ValueVector d lyt@(Nest _ _)) = do
    (_, prop)      <- vlSelectPos1 d (L.SBRelOp L.Eq) (N 1)
    (Nest q' lyt') <- chainRenameFilter prop lyt
    return $ ValueVector q' lyt'
the (ValueVector d lyt) = do
    (q', prop) <- vlSelectPos1 d (L.SBRelOp L.Eq) (N 1)
    lyt'       <- chainRenameFilter prop lyt
    return $ PrimVal q' lyt'
the _ = error "the: Should not be possible"

tailS ::  Shape -> Graph VL Shape
tailS (ValueVector d lyt) = do
    p          <- literal intT (VLInt 1)
    (q', prop) <- vlSelectPos d (L.SBRelOp L.Gt) p
    lyt'       <- chainRenameFilter prop lyt
    return $ ValueVector q' lyt'
tailS _ = error "tailS: Should not be possible"

theL ::  Shape -> Graph VL Shape
theL (ValueVector d (Nest q lyt)) = do
    (v, p2) <- vlSelectPos1S q (L.SBRelOp L.Eq) (N 1)
    prop    <- vlDescToRename d
    lyt'    <- chainRenameFilter p2 lyt
    (v', _) <- vlPropFilter prop v
    return $ ValueVector v' lyt'
theL _ = error "theL: Should not be possible"

tailL ::  Shape -> Graph VL Shape
tailL (ValueVector d (Nest q lyt)) = do
    one     <- literal intT (VLInt 1)
    (p, _)  <- vlDistPrim one d
    (v, p2) <- vlSelectPosS q (L.SBRelOp L.Gt) p
    lyt'    <- chainRenameFilter p2 lyt
    return $ ValueVector d (Nest v lyt')
tailL _ = error "tailL: Should not be possible"

sortWithS ::  Shape -> Shape -> Graph VL Shape
sortWithS (ValueVector q1 _) (ValueVector q2 lyt2) = do
    (v, p) <- vlSort q1 q2
    lyt2'  <- chainReorder p lyt2
    return $ ValueVector v lyt2'
sortWithS _e1 _e2 = error "vlSortS: Should not be possible"

sortWithL ::  Shape -> Shape -> Graph VL Shape
sortWithL (ValueVector _ (Nest v1 _)) (ValueVector d2 (Nest v2 lyt2)) = do
    (v, p) <- vlSort v1 v2
    lyt2'  <- chainReorder p lyt2
    return $ ValueVector d2 (Nest v lyt2')
sortWithL _ _ = error "vlSortL: Should not be possible"

-- move a descriptor from e1 to e2
unconcatV ::  Shape -> Shape -> Graph VL Shape
unconcatV (ValueVector d1 _) (ValueVector d2 lyt2) = 
    return $ ValueVector d1 (Nest d2 lyt2)

unconcatV _ _                                      = 
    $impossible

groupByKeyS ::  Shape -> Shape -> Graph VL Shape
groupByKeyS (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    (d, v, p) <- vlGroupBy q1 q2
    lyt2'     <- chainReorder p lyt2
    return $ ValueVector d (Pair lyt1 (Nest v lyt2') )
groupByKeyS _e1 _e2 = error $ "vlGroupByS: Should not be possible "

groupByKeyL ::  Shape -> Shape -> Graph VL Shape
groupByKeyL (ValueVector _ (Nest v1 lyt1)) (ValueVector d2 (Nest v2 lyt2)) = do
    (d, v, p) <- vlGroupBy v1 v2
    lyt2'     <- chainReorder p lyt2
    return $ ValueVector d2 (Nest d (Pair lyt1 (Nest v lyt2')))
groupByKeyL _ _ = error "vlGroupByL: Should not be possible"

concatLift ::  Shape -> Graph VL Shape
concatLift (ValueVector d (Nest d' vs)) = do
    p   <- vlDescToRename d'
    vs' <- renameOuter' p vs
    return $ ValueVector d vs'
concatLift _ = error "concatLift: Should not be possible"

lengthLift ::  Shape -> Graph VL Shape
lengthLift (ValueVector q (Nest qi _)) = do
    ls <- vlAggrS AggrCount q qi
    return $ ValueVector ls (InColumn 1)
lengthLift _ = $impossible

lengthV ::  Shape -> Graph VL Shape
lengthV q = do
    v' <- outer q
    v  <- vlAggr AggrCount v'
    return $ PrimVal v (InColumn 1)

cons ::  Shape -> Shape -> Graph VL Shape
cons q1@(PrimVal _ _) q2@(ValueVector _ _) = do
    n <- singletonPrim q1
    appendR n q2
cons q1 q2 = do
    n <- singletonVec q1
    appendR n q2

consLift ::  Shape -> Shape -> Graph VL Shape
consLift (ValueVector q1 lyt1) (ValueVector q2 (Nest qi lyt2)) = do
    s           <- vlSegment q1
    (v, p1, p2) <- vlAppend s qi
    lyt1'       <- renameOuter' p1 lyt1
    lyt2'       <- renameOuter' p2 lyt2
    lyt'        <- appendR' lyt1' lyt2'
    return $ ValueVector q2 (Nest v lyt')
consLift _ _ = $impossible
                        

restrict ::  Shape -> Shape -> Graph VL Shape
restrict(ValueVector q1 lyt) (ValueVector q2 (InColumn 1)) = do
    (v, p) <- vlRestrict q1 q2
    lyt'   <- chainRenameFilter p lyt
    return $ ValueVector v lyt'
restrict (AClosure n l i env arg e1 e2) bs = do
    l'   <- restrict l bs
    env' <- mapEnv (flip restrict bs) env
    return $ AClosure n l' i env' arg e1 e2
restrict e1 e2 = error $ "restrict: Can't construct restrict node " ++ show e1 ++ " " ++ show e2

combine ::  Shape -> Shape -> Shape -> Graph VL Shape
combine (ValueVector qb (InColumn 1)) (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    (v, p1, p2) <- vlCombine qb q1 q2
    lyt1'       <- renameOuter' p1 lyt1
    lyt2'       <- renameOuter' p2 lyt2
    lyt'        <- appendR' lyt1' lyt2'
    return $ ValueVector v lyt'
combine _ _ _ = $impossible


outer ::  Shape -> Graph VL DVec
outer (PrimVal _ _)            = $impossible
outer (ValueVector q _)        = return q
outer (Closure _ _ _ _ _)      = $impossible
outer (AClosure _ v _ _ _ _ _) = outer v

dist ::  Shape -> Shape -> Graph VL Shape
dist (PrimVal q lyt) q2 = do
    o      <- outer q2
    (v, p) <- vlDistPrim q o
    lyt'   <- chainReorder p lyt
    return $ ValueVector v lyt'
dist (ValueVector q lyt) q2 = do
    o      <- outer q2
    (d, p) <- vlDistDesc q o

    -- The outer vector does not have columns, it only describes the
    -- shape.
    o'     <- vlProject o []
    lyt'   <- chainReorder p lyt
    return $ ValueVector o' (Nest d lyt')
dist (Closure n env x f fl) q2 = do
    env' <- mapEnv (flip dist q2) env
    return $ AClosure n q2 1 env' x f fl
dist _ _ = $impossible

mapEnv :: (Shape -> Graph VL Shape) 
       -> [(String, Shape)] 
       -> Graph VL [(String, Shape)]
mapEnv f  ((x, p):xs) = do
    p'  <- f p
    xs' <- mapEnv f xs
    return $ (x, p') : xs'
mapEnv _f []          = return []

aggrPrim :: (Expr1 -> AggrFun) -> Shape -> Graph VL Shape
aggrPrim afun (ValueVector q (InColumn 1)) =
    PrimVal <$> vlAggr (afun (Column1 1)) q <*> (pure $ InColumn 1)
aggrPrim _ _ = $impossible

aggrLift :: (Expr1 -> AggrFun) -> Shape -> Graph VL Shape
aggrLift afun (ValueVector d (Nest q (InColumn 1))) = do
    qr <- vlAggrS (afun (Column1 1)) d q
    return $ ValueVector qr (InColumn 1)
aggrLift _ _ = $impossible

distL ::  Shape -> Shape -> Graph VL Shape
distL (ValueVector q1 lyt1) (ValueVector d (Nest q2 lyt2)) = do
    (qa, p)             <- vlAlign q1 q2
    lyt1'               <- chainReorder p lyt1
    let lyt             = zipLayout lyt1' lyt2
    ValueVector qf lytf <- fstL $ ValueVector qa lyt
    return $ ValueVector d (Nest qf lytf)
distL (AClosure n v i xs x f fl) q2 = do
    v' <- distL v q2
    xs' <- mapEnv (\y -> distL y v') xs
    return $ AClosure n v' (i + 1) xs' x f fl
distL _e1 _e2 = error $ "distL: Should not be possible" ++ show _e1 ++ "\n" ++ show _e2

ifList ::  Shape -> Shape -> Shape -> Graph VL Shape
ifList (PrimVal qb _) (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    (d1', _) <- vlDistPrim qb q1
    (d1, p1) <- vlRestrict q1 d1'
    qb' <- vlUnExpr (L.SUBoolOp L.Not) qb
    (d2', _) <- vlDistPrim qb' q2
    (d2, p2) <- vlRestrict q2 d2'
    r1 <- renameOuter' p1 lyt1
    r2 <- renameOuter' p2 lyt2
    lyt' <- appendR' r1 r2
    (d, _, _) <- vlAppend d1 d2
    return $ ValueVector d lyt'
ifList qb (PrimVal q1 lyt1) (PrimVal q2 lyt2) = do
    (ValueVector q lyt) <- ifList qb (ValueVector q1 lyt1) (ValueVector q2 lyt2)
    return $ PrimVal q lyt
ifList _ _ _ = $impossible

pairOpL ::  Shape -> Shape -> Graph VL Shape
pairOpL (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    q <- vlZip q1 q2
    let lyt = zipLayout lyt1 lyt2
    return $ ValueVector q lyt
pairOpL _ _ = $impossible

pairOp ::  Shape -> Shape -> Graph VL Shape
pairOp (PrimVal q1 lyt1) (PrimVal q2 lyt2) = do
    q <- vlZip q1 q2
    let lyt = zipLayout lyt1 lyt2
    return $ PrimVal q lyt
pairOp (ValueVector q1 lyt1) (ValueVector q2 lyt2) = do
    d   <- vlLit L.PossiblyEmpty [] [[VLNat 1, VLNat 1]]
    q1' <- vlUnsegment q1
    q2' <- vlUnsegment q2
    let lyt = zipLayout (Nest q1' lyt1) (Nest q2' lyt2)
    return $ PrimVal d lyt
pairOp (ValueVector q1 lyt1) (PrimVal q2 lyt2) = do
    q1' <- vlUnsegment q1
    let lyt = zipLayout (Nest q1' lyt1) lyt2
    return $ PrimVal q2 lyt
pairOp (PrimVal q1 lyt1) (ValueVector q2 lyt2) = do
    q2' <- vlUnsegment q2
    let lyt = zipLayout lyt1 (Nest q2' lyt2)
    return $ PrimVal q1 lyt
pairOp _ _ = $impossible

fstA ::  Shape -> Graph VL Shape
fstA (PrimVal _q (Pair (Nest q lyt) _p2)) = return $ ValueVector q lyt
fstA (PrimVal q (Pair p1 _p2)) = do
    let (p1', cols) = projectFromPos p1
    proj <- vlProject q (map Column1 cols)
    return $ PrimVal proj p1'
fstA e1 = error $ "fstA: " ++ show e1

fstL ::  Shape -> Graph VL Shape
fstL (ValueVector q (Pair p1 _p2)) = do
    let(p1', cols) = projectFromPos p1
    proj <- vlProject q (map Column1 cols)
    return $ ValueVector proj p1'
fstL s = error $ "fstL: " ++ show s

sndA ::  Shape -> Graph VL Shape
sndA (PrimVal _q (Pair _p1 (Nest q lyt))) = return $ ValueVector q lyt
sndA (PrimVal q (Pair _p1 p2)) = do
    let (p2', cols) = projectFromPos p2
    proj <- vlProject q (map Column1 cols)
    return $ PrimVal proj p2'
sndA _ = $impossible
    
sndL ::  Shape -> Graph VL Shape
sndL (ValueVector q (Pair _p1 p2)) = do
    let (p2', cols) = projectFromPos p2
    proj <- vlProject q (map Column1 cols)
    return $ ValueVector proj p2'
sndL s = trace (show s) $ $impossible
     
transposePrim :: Shape -> Graph VL Shape
transposePrim (ValueVector _ (Nest qi lyt)) = do
    (qo', qi') <- vlTranspose qi
    return $ ValueVector qo' (Nest qi' lyt)
transposePrim _ = $impossible

transposeLift :: Shape -> Graph VL Shape
transposeLift (ValueVector qo (Nest qm (Nest qi lyt))) = do
    (qm', qi') <- vlTransposeS qm qi
    return $ ValueVector qo (Nest qm' (Nest qi' lyt))
transposeLift _ = $impossible

reshapePrim :: Integer -> Shape -> Graph VL Shape
reshapePrim n (ValueVector q lyt) = do
    (qo, qi) <- vlReshape n q
    return $ ValueVector qo (Nest qi lyt)
reshapePrim _ _ = $impossible

reshapeLift :: Integer -> Shape -> Graph VL Shape
reshapeLift n (ValueVector qo (Nest qi lyt)) = do
    (qm, qi') <- vlReshapeS n qi
    return $ ValueVector qo (Nest qm (Nest qi' lyt))
reshapeLift _ _ = $impossible

projectFromPos :: Layout -> (Layout, [DBCol])
projectFromPos = (\(x,y,_) -> (x,y)) . (projectFromPosWork 1)
  where
    projectFromPosWork :: Int -> Layout -> (Layout, [DBCol], Int)
    projectFromPosWork c (InColumn i) = (InColumn c, [i], c + 1)
    projectFromPosWork c (Nest q l)   = (Nest q l, [], c)
    projectFromPosWork c (Pair p1 p2) = let (p1', cols1, c') = projectFromPosWork c p1
                                            (p2', cols2, c'') = projectFromPosWork c' p2
                                        in (Pair p1' p2', cols1 ++ cols2, c'')

quickConcatV :: Shape -> Graph VL Shape
quickConcatV (ValueVector _ (Nest q lyt)) = return $ ValueVector q lyt
quickConcatV (AClosure n v l fvs x f1 f2) | l > 1 = AClosure n <$> (quickConcatV v)
                                                          <*> pure (l - 1)
                                                          <*> (mapM (\(y, val) -> do
                                                                                     val' <- quickConcatV val
                                                                                     return (y, val')) fvs)
                                                          <*> pure x <*> pure f1 <*> pure f2
quickConcatV e                  = error $ "Not supported by quickConcatV: " ++ show e
                                             
concatV :: Shape -> Graph VL Shape
concatV (ValueVector _ (Nest q lyt)) = flip ValueVector lyt <$> vlUnsegment q
concatV (AClosure n v l fvs x f1 f2) | l > 1 = AClosure n <$> (concatV v)
                                                          <*> pure (l - 1)
                                                          <*> (mapM (\(y, val) -> do
                                                                                     val' <- concatV val
                                                                                     return (y, val')) fvs)
                                                          <*> pure x <*> pure f1 <*> pure f2
concatV e                  = error $ "Not supported by concatV: " ++ show e

singletonVec ::  Shape -> Graph VL Shape
singletonVec (ValueVector q lyt) = do
    (DVec d _) <- vlSingletonDescr
    return $ ValueVector (DVec d []) (Nest q lyt)
singletonVec _ = error "singletonVec: Should not be possible"

singletonPrim ::  Shape -> Graph VL Shape
singletonPrim (PrimVal q1 lyt) = return $ ValueVector q1 lyt
singletonPrim _ = error "singletonPrim: Should not be possible"

dbTable ::  String -> [L.Column] -> L.TableHints -> Graph VL Shape
dbTable n cs ks = do
    t <- vlTableRef n (map (mapSnd typeToVLType) cs) ks
    return $ ValueVector t (foldr1 Pair [InColumn i | i <- [1..length cs]])

mkLiteral ::  Type -> L.Val -> Graph VL Shape
mkLiteral t@(ListT _) (L.ListV es) = do
    ((descHd, descV), layout, _) <- toPlan (mkDescriptor [length es]) t 1 es
    let emptinessFlag = case es of
          []    -> L.PossiblyEmpty
          _ : _ -> L.NonEmpty
    (flip ValueVector layout) <$> (vlLit emptinessFlag (reverse descHd) $ map reverse descV)
mkLiteral (FunT _ _) _  = error "Not supported"
mkLiteral t e           = do
    ((descHd, [descV]), layout, _) <- toPlan (mkDescriptor [1]) (ListT t) 1 [e]
    flip PrimVal layout <$> vlLit L.NonEmpty (reverse descHd) [(reverse descV)]
                            
type Table = ([Type], [[VLVal]])

-- FIXME Check if inner list literals are nonempty and use flag VL
-- literals appropriately.
toPlan ::  Table -> Type -> Int -> [L.Val] -> Graph VL (Table, Layout, Int)
toPlan (descHd, descV) (ListT t) c es = 
    case t of
        PairT t1 t2 -> do
            let (e1s, e2s) = unzip $ map splitVal es
            (desc', l1, c') <- toPlan (descHd, descV) (ListT t1) c e1s
            (desc'', l2, c'') <- toPlan desc' (ListT t2) c' e2s
            return (desc'', Pair l1 l2, c'')

        ListT _ -> do
            let vs = map fromListVal es
            let d = mkDescriptor $ map length vs
            ((hd, vs'), l, _) <- toPlan d t 1 (concat vs)
            n <- vlLit L.PossiblyEmpty (reverse hd) (map reverse vs')
            return ((descHd, descV), Nest n l, c)
                                                                 
        FunT _ _ -> error "Functions are not db values"

        _ -> let (hd, vs) = mkColumn t es
             in return ((hd:descHd, zipWith (:) vs descV), (InColumn c), c + 1)

toPlan _ (FunT _ _) _ _ = $impossible
toPlan (descHd, descV) t c v = 
    let (hd, v') = mkColumn t v
    in return $ ((hd:descHd, zipWith (:) v' descV), (InColumn c), c + 1)

literal :: Type -> VLVal -> GraphM r VL DVec
literal t v = vlLit L.NonEmpty [t] [[VLNat 1, VLNat 1, v]]

fromListVal :: L.Val -> [L.Val]
fromListVal (L.ListV es) = es
fromListVal _            = error "fromListVal: Not a list"

splitVal :: L.Val -> (L.Val, L.Val)
splitVal (L.PairV e1 e2) = (e1, e2)
splitVal _               = error $ "splitVal: Not a tuple"

mkColumn :: Type -> [L.Val] -> (Type, [VLVal])
mkColumn t vs = (t, [pVal v | v <- vs])
                                            
mkDescriptor :: [Int] -> Table
mkDescriptor lengths = 
    let header = []
        body = map (\(d, p) -> [VLNat $ fromInteger p, VLNat $ fromInteger d]) 
               $ zip (concat [ replicate l p | (p, l) <- zip [1..] lengths] ) [1..]
    in (header, body)
