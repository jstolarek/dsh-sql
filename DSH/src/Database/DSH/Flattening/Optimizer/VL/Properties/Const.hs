module Optimizer.VL.Properties.Const where

import Optimizer.VL.Properties.Common
import Optimizer.VL.Properties.Types
import Database.Algebra.VL.Data
  
unp :: Show a => VectorProp a -> Either String a
unp = unpack "Properties.Const"

mapUnp :: Show a => VectorProp a
          -> VectorProp a 
          -> (a -> a -> VectorProp a) 
          -> Either String (VectorProp a)
mapUnp = mapUnpack "Properties.Empty"  
         
fromDBV :: ConstVec -> Either String (ConstDescr, [ConstPayload])
fromDBV = undefined

fromDBP :: ConstVec -> Either String [ConstPayload]
fromDBP = undefined
         
fromDescrVec :: ConstVec -> Either String ConstDescr
fromDescrVec = undefined
               
fromRenameVec :: ConstVec -> Either String (SourceConstDescr, TargetConstDescr)
fromRenameVec = undefined

fromPropVec :: ConstVec -> Either String (SourceConstDescr, TargetConstDescr)
fromPropVec = undefined

inferConstVecNullOp :: NullOp -> Either String (VectorProp ConstVec)
inferConstVecNullOp op = 
  case op of
    SingletonDescr                    -> return $ VProp $ DescrVecConst $ ConstDescr $ N 1
    ConstructLiteralTable _ _         -> undefined
    ConstructLiteralValue _ vals      -> return $ VProp $ DBVConst (ConstDescr $ N 1) $ map ConstPL vals
    TableRef              _ cols _    -> return $ VProp $ DBVConst (ConstDescr $ N 1) $ map (const NonConstPL) cols

inferConstVecUnOp :: (VectorProp ConstVec) -> UnOp -> Either String (VectorProp ConstVec)
inferConstVecUnOp c op = 
  case op of
    Unique -> return c

    UniqueL -> return c

    NotPrim -> return c

    NotVec -> return c

    LengthA -> do
      d <- unp c >>= fromDescrVec
      return $ VProp $ DBPConst [NonConstPL]

    DescToRename -> do
      d <- unp c >>= fromDescrVec
      return $ VProp $ DescrVecConst d

    ToDescr -> do
      (d, _) <- unp c >>= fromDBV
      return $ VProp $ DescrVecConst d

    Segment -> do
      (_, constCols) <- unp c >>= fromDBV
      return $ VProp $ DBVConst NonConstDescr constCols

    VecSum _ -> return c

    VecMin -> return c

    VecMinL -> return c

    VecMax -> return c

    VecMaxL -> return c

    ProjectL ps -> do
      (d, cols) <- unp c >>= fromDBV
      let cols' = map (cols !!) ps
      return $ VProp $ DBVConst d cols'

    ProjectA ps -> do
      cols <- unp c >>= fromDBP
      let cols' = map (cols !!) ps
      return $ VProp $ DBPConst cols'

    IntegerToDoubleA -> return c

    IntegerToDoubleL -> return c

    ReverseA -> do
      (d, cs) <- unp c >>= fromDBV
      return $ VPropPair (DBVConst d cs) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))

    ReverseL -> do
      (d, cs) <- unp c >>= fromDBV
      return $ VPropPair (DBVConst d cs) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))

    FalsePositions -> do
      (d, cs) <- unp c >>= fromDBV
      return $ VProp $ DBVConst d [NonConstPL]

    ProjectRename (targetIS, sourceIS)  -> do
      -- FIXME this is not precise -- take care of of the source space.
      (d, _) <- unp c >>= fromDBV
      let d' = case targetIS of
            STDescrCol -> d
            STPosCol -> NonConstDescr
            STNumber -> NonConstDescr
      return $ VProp $ RenameVecConst (SC NonConstDescr) (TC d')

    ProjectValue (dp, _, vps)   -> do
      (constDescr, constCols) <- unp c >>= fromDBV
      let constDescr' = case dp of
            DescrConst n  -> ConstDescr n
            DescrIdentity -> constDescr
            DescrPosCol   -> NonConstDescr
            
          constProj PLNumber     = NonConstPL
          constProj (PLConst v)  = ConstPL v
          constProj (PLCol i)    = constCols !! i
      
      return $ VProp $ DBVConst constDescr' $ map constProj vps

    SelectItem       -> do
      (d, _) <- unp c >>= fromDBV
      return $ VProp $ DBVConst d [ConstPL $ VLBool True]
      
    Only             -> undefined
    Singleton        -> undefined

    VecBinOpSingle _ -> do
      (d, cols) <- unp c >>= fromDBV
      -- FIXME This is not precise: implement constant folding 
      return $ VProp $ DBVConst d [NonConstPL]

    R1 -> 
      case c of
        VProp _           -> Left "Properties.Const: not a pair/triple"
        VPropPair b _     -> Right $ VProp b
        VPropTriple b _ _ -> Right $ VProp b
    R2 ->
      case c of
        VProp _           -> Left "Properties.Const: not a pair/triple"
        VPropPair _ b     -> Right $ VProp b
        VPropTriple _ b _ -> Right $ VProp b
    R3 ->
      case c of
        VPropTriple _ _ b -> Right $ VProp b
        _                 -> Left "Properties.Const: not a triple"

inferConstVecBinOp :: (VectorProp ConstVec) -> (VectorProp ConstVec) -> BinOp -> Either String (VectorProp ConstVec)
inferConstVecBinOp c1 c2 op = 
  case op of
    GroupBy -> do
      -- FIXME handle the special case of constant payload columns in the right input (qe)
      (dq, cols) <- unp c1 >>= fromDBV
      return $ VPropTriple (DescrVecConst dq) (DBVConst NonConstDescr cols) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))

    SortWith -> do
      (d, cols) <- unp c2 >>= fromDBV
      return $ VPropPair  (DBVConst d cols) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))

    LengthSeg -> undefined

    DistPrim -> do
      d <- unp c2 >>= fromDescrVec
      cols <- unp c1 >>= fromDBP
      return $ VPropPair (DBVConst d cols) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))

    DistDesc -> do
      (_, cols) <- unp c1 >>= fromDBV
      return $ VPropPair (DBVConst NonConstDescr cols) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))

    DistLift -> do
      d <- unp c2 >>= fromDescrVec
      (_, cols) <- unp c1 >>= fromDBV
      return $ VPropPair (DBVConst d cols) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))
      
    PropRename -> do
      (_, cols) <- unp c1 >>= fromDBV
      (SC source, TC target) <- unp c2 >>= fromRenameVec

      return $ VProp $ DBVConst target cols
      
    PropFilter -> do
      (_, cols) <- unp c1 >>= fromDBV
      (SC source, TC target) <- unp c2 >>= fromRenameVec
  
      return $ VProp $ DBVConst target cols

    PropReorder -> do
      (_, cols) <- unp c1 >>= fromDBV
      (SC source, TC target) <- unp c2 >>= fromPropVec
      
      return $ VPropPair (DBVConst target cols) (PropVecConst (SC NonConstDescr) (TC NonConstDescr))

    Append -> do
      (d1, cols1) <- unp c1 >>= fromDBV
      (d2, cols2) <- unp c2 >>= fromDBV
      
      let constCols = map sameConst $ zip cols1 cols2

          sameConst ((ConstPL v1), (ConstPL v2)) | v1 == v2 = ConstPL v1
          sameConst (_, _)                                  = NonConstPL
          
          d = case (d1, d2) of
            (ConstDescr n1, ConstDescr n2) | n1 == n2 -> ConstDescr n1
            _                                         -> NonConstDescr
            
          propVecs = PropVecConst (SC NonConstDescr) (TC NonConstDescr)
          
      return $ VPropTriple (DBVConst d constCols) propVecs propVecs

    RestrictVec -> do
      (d, cols) <- unp c1 >>= fromDBV
      return $ VPropPair (DBVConst d cols) (RenameVecConst (SC NonConstDescr) (TC NonConstDescr))
      
    -- FIXME implement constant folding
    VecBinOp _ -> do
      cols1 <- unp c1 >>= fromDBP
      cols2 <- unp c2 >>= fromDBP
      
      return $ VProp $ DBPConst [NonConstPL]
      
    
    VecBinOpL _ -> do
      (d1, cols1) <- unp c1 >>= fromDBV
      (_, cols2) <- unp c2 >>= fromDBV
      
      return $ VProp $ DBVConst d1 [NonConstPL]

    -- FIXME handle special cases: empty input, cardinality 1 and const input, ...
    VecSumL -> return $ VProp $ DBVConst NonConstDescr [NonConstPL]

    SelectPos _ -> undefined

    SelectPosL _ -> undefined

    PairA -> do
      cols1 <- unp c1 >>= fromDBP
      cols2 <- unp c2 >>= fromDBP
      
      let cols = cols1 ++ cols2
          
      return $ VProp $ DBPConst cols

    PairL -> do
      (d1, cols1) <- unp c1 >>= fromDBV
      (_, cols2)  <- unp c2 >>= fromDBV
      
      let cols = cols1 ++ cols2
          
      return $ VProp $ DBVConst d1 cols

    ZipL -> do
      (d1, cols1) <- unp c1 >>= fromDBV
      (_, cols2)  <- unp c2 >>= fromDBV
      
      let cols = cols1 ++ cols2
          renameVec = RenameVecConst (SC NonConstDescr) (TC NonConstDescr)
          
      return $ VPropTriple (DBVConst d1 cols) renameVec renameVec
  
    CartProductFlat -> do
      (_, cols1) <- unp c1 >>= fromDBV
      (_, cols2) <- unp c2 >>= fromDBV

      let constCols = map sameConst $ zip cols1 cols2

          sameConst ((ConstPL v1), (ConstPL v2)) | v1 == v2 = ConstPL v1
          sameConst (_, _)                                  = NonConstPL
      
      return $ VProp $ DBVConst (ConstDescr $ N 1) constCols

    ThetaJoinFlat _ -> undefined

inferConstVecTerOp :: (VectorProp ConstVec) -> (VectorProp ConstVec) -> (VectorProp ConstVec) -> TerOp -> Either String (VectorProp ConstVec)
inferConstVecTerOp c1 c2 c3 op = 
  case op of
    CombineVec -> do
      (d1, cols1) <- unp c1 >>= fromDBV
      (_, cols2)  <- unp c2 >>= fromDBV
      (_, cols3)  <- unp c3 >>= fromDBV

      let constCols = map sameConst $ zip cols1 cols2

          sameConst ((ConstPL v1), (ConstPL v2)) | v1 == v2 = ConstPL v1
          sameConst (_, _)                                  = NonConstPL
          
          renameVec = RenameVecConst (SC NonConstDescr) (TC NonConstDescr)

      return $ VPropTriple (DBVConst d1 constCols) renameVec renameVec
  
