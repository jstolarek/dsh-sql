module Database.DSH.VL.VectorPrimitives where

import Database.DSH.VL.Data.DBVector
import Database.Algebra.VL.Data (VLType(), TypedColumn, Key, VLVal(), VecCompOp(), ISTransProj, Expr1, Expr2, Nat, AggrFun)

-- FIXME this should import a module from TableAlgebra which defines
-- common types like schema info and abstract column types.
import Database.Algebra.Pathfinder()

-- * Vector primitive constructor functions

{-

FIXME
consistent naming scheme:

- atom = A
- lifted is the standard case
- difference between lifted and segmented -> segmented S
- common prefix: vec. vl is reserved for the actual VL operators
-}

class VectorAlgebra a where
  singletonDescr :: GraphM r a DVec
  
  vecLit :: [VLType] -> [[VLVal]] -> GraphM r a DVec
  vecTableRef :: String -> [TypedColumn] -> [Key] -> GraphM r a DVec

  vecUniqueS :: DVec -> GraphM r a DVec

  vecNumber :: DVec -> GraphM r a DVec
  vecNumberS :: DVec -> GraphM r a DVec  

  descToRename :: DVec -> GraphM r a RVec

  vecSegment :: DVec -> GraphM r a DVec
  vecUnsegment :: DVec -> GraphM r a DVec
  
  vecAggr :: AggrFun -> DVec -> GraphM r a DVec
  vecAggrS :: AggrFun -> DVec -> DVec -> GraphM r a DVec

  -- FIXME operator too specialized. should be implemented using number + select
  selectPos1 :: DVec -> VecCompOp -> Nat -> GraphM r a (DVec, RVec)
  selectPos1S :: DVec -> VecCompOp -> Nat -> GraphM r a (DVec, RVec)

  vecReverse :: DVec -> GraphM r a (DVec, PVec)
  vecReverseS :: DVec -> GraphM r a (DVec, PVec)
  
  -- FIXME this operator is too specialized. Could be implemented with NOT, PROJECT
  -- and some operator that materializes positions.
  falsePositions :: DVec -> GraphM r a DVec

  vecSelect:: Expr1 -> DVec -> GraphM r a DVec

  vecSortSimple :: [Expr1] -> DVec -> GraphM r a (DVec, PVec)
  vecGroupSimple :: [Expr1] -> DVec -> GraphM r a (DVec, DVec, PVec)

  projectRename :: ISTransProj -> ISTransProj -> DVec -> GraphM r a RVec

  vecProject :: [Expr1] -> DVec -> GraphM r a DVec
  
  vecGroupBy :: DVec -> DVec -> GraphM r a (DVec, DVec, PVec)

  -- | The VL aggregation operator groups the input vector by the
  -- given columns and then performs the list of aggregations
  -- described by the second argument. The result is a flat vector,
  -- since all groups are reduced via aggregation. The operator
  -- operates segmented, i.e. always groups by descr first. This
  -- operator must be used with care: It does not determine the
  -- complete set of descr value to check for empty inner lists.
  vecGroupAggr :: [Expr1] -> [AggrFun] -> DVec -> GraphM r a DVec

  vecSort :: DVec -> DVec -> GraphM r a (DVec, PVec)
  -- FIXME is distprim really necessary? could maybe be replaced by distdesc
  vecDistPrim :: DVec -> DVec -> GraphM r a (DVec, PVec)
  vecDistDesc :: DVec -> DVec -> GraphM r a (DVec, PVec)
  vecDistSeg :: DVec -> DVec -> GraphM r a (DVec, PVec)

  -- | propRename uses a propagation vector to rename a vector (no filtering or reordering).
  vecPropRename :: RVec -> DVec -> GraphM r a DVec
  -- | propFilter uses a propagation vector to rename and filter a vector (no reordering).
  vecPropFilter :: RVec -> DVec -> GraphM r a (DVec, RVec)
  -- | propReorder uses a propagation vector to rename, filter and reorder a vector.
  vecPropReorder :: PVec -> DVec -> GraphM r a (DVec, PVec)
  vecAppend :: DVec -> DVec -> GraphM r a (DVec, RVec, RVec)
  vecRestrict :: DVec -> DVec -> GraphM r a (DVec, RVec)
  
  vecBinExpr :: Expr2 -> DVec -> DVec -> GraphM r a DVec

  -- FIXME could be implemented using number and select
  selectPos :: DVec -> VecCompOp -> DVec -> GraphM r a (DVec, RVec)
  selectPosS :: DVec -> VecCompOp -> DVec -> GraphM r a (DVec, RVec)

  -- FIXME better name: zip
  vecZip :: DVec -> DVec -> GraphM r a DVec

  -- FIXME better name: zipSeg
  vecZipS :: DVec -> DVec -> GraphM r a (DVec, RVec, RVec)

  vecCartProduct :: DVec -> DVec -> GraphM r a (DVec, PVec, PVec)
  vecCartProductS :: DVec -> DVec -> GraphM r a (DVec, PVec, PVec)

  vecEquiJoin :: Expr1 -> Expr1 -> DVec -> DVec -> GraphM r a (DVec, PVec, PVec)
  vecEquiJoinS :: Expr1 -> Expr1 -> DVec -> DVec -> GraphM r a (DVec, PVec, PVec)
  
  vecSemiJoin :: Expr1 -> Expr1 -> DVec -> DVec -> GraphM r a (DVec, RVec)
  vecSemiJoinS :: Expr1 -> Expr1 -> DVec -> DVec -> GraphM r a (DVec, RVec)

  vecAntiJoin :: Expr1 -> Expr1 -> DVec -> DVec -> GraphM r a (DVec, RVec)
  vecAntiJoinS :: Expr1 -> Expr1 -> DVec -> DVec -> GraphM r a (DVec, RVec)

  vecCombine :: DVec -> DVec -> DVec -> GraphM r a (DVec, RVec, RVec)
  
