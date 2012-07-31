module Language.ParallelLang.VL.VectorPrimitives where

import Language.ParallelLang.VL.Data.DBVector
import Database.Algebra.VL.Data (VLType(), TypedColumn, Key, VLVal(), VecOp(), ISTransProj, DescrProj, PosProj, PayloadProj)

-- FIXME this should import a module from TableAlgebra which defines 
-- common types like schema info and abstract column types.
import Database.Algebra.Pathfinder()

-- * Vector primitive constructor functions

class VectorAlgebra a where
  unique :: DBV -> GraphM r a DBV
  uniqueL :: DBV -> GraphM r a DBV
  groupBy :: DBV -> DBV -> GraphM r a (DescrVector, DBV, PropVector)
  sortWith :: DBV -> DBV -> GraphM r a (DBV, PropVector)
  notPrim :: DBP -> GraphM r a DBP
  notVec :: DBV -> GraphM r a DBV
  lengthA :: DescrVector -> GraphM r a DBP
  lengthSeg :: DescrVector -> DescrVector -> GraphM r a DBV
  descToRename :: DescrVector -> GraphM r a RenameVector
  toDescr :: DBV -> GraphM r a DescrVector
  distPrim :: DBP -> DescrVector -> GraphM r a (DBV, PropVector)
  distDesc :: DBV -> DescrVector -> GraphM r a (DBV, PropVector)
  distLift :: DBV -> DescrVector -> GraphM r a (DBV, PropVector)
  -- | propRename uses a propagation vector to rename a vector (no filtering or reordering).
  propRename :: RenameVector -> DBV -> GraphM r a DBV
  -- | propFilter uses a propagation vector to rename and filter a vector (no reordering).
  propFilter :: RenameVector -> DBV -> GraphM r a (DBV, RenameVector)
  -- | propReorder uses a propagation vector to rename, filter and reorder a vector.
  propReorder :: PropVector -> DBV -> GraphM r a (DBV, PropVector)
  singletonDescr :: GraphM r a DescrVector
  append :: DBV -> DBV -> GraphM r a (DBV, RenameVector, RenameVector)
  segment :: DBV -> GraphM r a DBV
  restrictVec :: DBV -> DBV -> GraphM r a (DBV, RenameVector)
  combineVec :: DBV -> DBV -> DBV -> GraphM r a (DBV, RenameVector, RenameVector)
  constructLiteralValue :: [VLType] -> [VLVal] -> GraphM r a DBP
  constructLiteralTable :: [VLType] -> [[VLVal]] -> GraphM r a DBV
  tableRef :: String -> [TypedColumn] -> [Key] -> GraphM r a DBV
  binOp :: VecOp -> DBP -> DBP -> GraphM r a DBP
  binOpL :: VecOp -> DBV -> DBV -> GraphM r a DBV
  vecSum :: VLType -> DBV -> GraphM r a DBP
  vecSumLift :: DescrVector -> DBV -> GraphM r a DBV
  vecMin :: DBV -> GraphM r a DBP
  vecMinLift :: DBV -> GraphM r a DBV
  vecMax :: DBV -> GraphM r a DBP
  vecMaxLift :: DBV -> GraphM r a DBV 
  selectPos :: DBV -> VecOp -> DBP -> GraphM r a (DBV, RenameVector)
  selectPosLift :: DBV -> VecOp -> DBV -> GraphM r a (DBV, RenameVector)
  projectL :: DBV -> [DBCol] -> GraphM r a DBV
  projectA :: DBP -> [DBCol] -> GraphM r a DBP
  pairA :: DBP -> DBP -> GraphM r a DBP
  pairL :: DBV -> DBV -> GraphM r a DBV
  zipL :: DBV -> DBV -> GraphM r a (DBV, RenameVector, RenameVector)
  integerToDoubleA :: DBP -> GraphM r a DBP
  integerToDoubleL :: DBV -> GraphM r a DBV
  reverseA :: DBV -> GraphM r a (DBV, PropVector)
  reverseL :: DBV -> GraphM r a (DBV, PropVector)
  falsePositions :: DBV -> GraphM r a DBV
  cartProductFlat :: DBV -> DBV -> GraphM r a DBV
  thetaJoinFlat :: (VecOp, DBCol, DBCol) -> DBV -> DBV -> GraphM r a DBV
  selectItem :: DBV -> GraphM r a DBV
  projectRename :: ISTransProj -> ISTransProj -> DBV -> GraphM r a RenameVector
  projectValue :: DescrProj -> PosProj -> [PayloadProj] -> DBV -> GraphM r a DBV
  binOpSingle :: (VecOp, DBCol, DBCol) -> DBV -> GraphM r a DBV