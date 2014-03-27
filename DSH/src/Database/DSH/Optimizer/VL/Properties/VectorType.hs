{-# LANGUAGE TemplateHaskell #-}

-- FIXME introduce consistency checks for schema inference
module Database.DSH.Optimizer.VL.Properties.VectorType where

import           Control.Monad
import           Data.Functor
import qualified Data.List.NonEmpty as N
       
import           Database.DSH.Optimizer.VL.Properties.Types
  
import           Database.DSH.VL.Lang
  
{- Implement more checks: check the input types for correctness -}

vectorWidth :: VectorProp VectorType -> Int
vectorWidth (VProp (ValueVector w))  = w
vectorWidth _                        = error "vectorWidth: non-ValueVector input"

inferVectorTypeNullOp :: NullOp -> Either String (VectorProp VectorType)
inferVectorTypeNullOp op =
  case op of
    SingletonDescr  -> Right $ VProp $ ValueVector 0
    Lit _ t _       -> Right $ VProp $ ValueVector $ length t
    TableRef _ cs _ -> Right $ VProp $ ValueVector $ length cs
  
unpack :: VectorProp VectorType -> Either String VectorType
unpack (VProp s) = Right s
unpack _         = Left "Input is not a single vector property" 

inferVectorTypeUnOp :: VectorProp VectorType -> UnOp -> Either String (VectorProp VectorType)
inferVectorTypeUnOp s op = 
  case op of
    UniqueS -> VProp <$> unpack s
    Aggr _ -> Right $ VProp $ ValueVector 1
    AggrNonEmpty as -> Right $ VProp $ ValueVector $ N.length as
    DescToRename -> Right $ VProp $ RenameVector
    Segment -> VProp <$> unpack s
    Unsegment -> VProp <$> unpack s
    Reverse -> liftM2 VPropPair (unpack s) (Right PropVector)
    ReverseS -> liftM2 VPropPair (unpack s) (Right PropVector)
    SelectPos1 _ _ -> liftM2 VPropPair (unpack s) (Right PropVector)
    SelectPos1S _ _ -> liftM2 VPropPair (unpack s) (Right PropVector)
    R1 -> 
      case s of
        VPropPair s1 _ -> Right $ VProp s1
        VPropTriple s1 _ _ -> Right $ VProp s1
        _ -> Left "Input of R1 is not a tuple"
    R2 -> 
      case s of
        VPropPair _ s2 -> Right $ VProp s2
        VPropTriple _ s2 _ -> Right $ VProp s2
        _ -> Left "Input of R2 is not a tuple"
    R3 -> 
      case s of
        VPropTriple s3 _ _ -> Right $ VProp s3
        _ -> Left "Input of R3 is not a tuple"

    Project valProjs -> Right $ VProp $ ValueVector $ length valProjs

    Select _ -> VProp <$> unpack s
    SortSimple _ -> liftM2 VPropPair (unpack s) (Right PropVector)

    GroupSimple es -> 
      case s of
        VProp t@(ValueVector _) -> 
          Right $ VPropTriple (ValueVector $ length es) t PropVector
        _                                                    -> 
          Left "Input of GroupSimple is not a value vector"
    Only -> VProp <$> unpack s
    Singleton -> VProp <$> unpack s
    GroupAggr g as -> Right $ VProp $ ValueVector (length g + N.length as)
    Number -> do
        ValueVector w <- unpack s
        return $ VProp $ ValueVector (w + 1)
    NumberS -> do
        ValueVector w <- unpack s
        return $ VProp $ ValueVector (w + 1)

    Reshape _ -> liftM2 VPropPair (return $ ValueVector 0) (unpack s)
    ReshapeS _ -> liftM2 VPropPair (return $ ValueVector 0) (unpack s)
    Transpose -> liftM2 VPropPair (return $ ValueVector 0) (unpack s)
  
reqValVectors :: VectorProp VectorType 
                 -> VectorProp VectorType 
                 -> (Int -> Int -> VectorProp VectorType)
                 -> String 
                 -> Either String (VectorProp VectorType)
reqValVectors (VProp (ValueVector w1)) (VProp (ValueVector w2)) f _ =
  Right $ f w1 w2
reqValVectors _ _ _ e =
  Left $ "Inputs of " ++ e ++ " are not ValueVectors"
      
inferVectorTypeBinOp :: VectorProp VectorType -> VectorProp VectorType -> BinOp -> Either String (VectorProp VectorType)
inferVectorTypeBinOp s1 s2 op = 
  case op of
    GroupBy -> 
      case (s1, s2) of
        (VProp t1@(ValueVector _), VProp t2@(ValueVector _)) -> 
          Right $ VPropTriple t1 t2 PropVector
        _                                                    -> 
          Left "Input of GroupBy is not a value vector"
    Sort ->
      case (s1, s2) of
        (VProp (ValueVector _), VProp t2@(ValueVector _)) -> 
          Right $ VPropPair t2 PropVector
        _                                                    -> 
          Left "Input of SortWith is not a value vector"
    AggrS _ -> return $ VProp $ ValueVector 1
    AggrNonEmptyS as -> Right $ VProp $ ValueVector $ N.length as
    DistPrim -> liftM2 VPropPair (unpack s1) (Right PropVector)
    DistDesc -> liftM2 VPropPair (unpack s1) (Right PropVector)

    Align -> do
        ValueVector w1 <- unpack s1
        ValueVector w2 <- unpack s2
        return $ VPropPair (ValueVector $ w1 + w2) PropVector

    PropRename -> Right s2
    PropFilter -> liftM2 VPropPair (unpack s2) (Right RenameVector)
    PropReorder -> liftM2 VPropPair (unpack s2) (Right PropVector)
    Append -> 
      case (s1, s2) of
        (VProp (ValueVector w1), VProp (ValueVector w2)) | w1 == w2 -> 
          Right $ VPropTriple (ValueVector w1) RenameVector RenameVector
        (VProp (ValueVector w1), VProp (ValueVector w2)) -> 
          Left $ "Inputs of Append do not have the same width " ++ (show w1) ++ " " ++ (show w2)
        v -> 
          Left $ "Input of Append is not a ValueVector " ++ (show v)

    Restrict -> liftM2 VPropPair (unpack s1) (Right RenameVector)
    BinExpr _ -> Right $ VProp $ ValueVector 1
    SelectPos _ -> liftM2 VPropPair (unpack s1) (Right RenameVector)
    SelectPosS _ -> liftM2 VPropPair (unpack s1) (Right RenameVector)
    Zip ->
      case (s1, s2) of
        (VProp (ValueVector w1), VProp (ValueVector w2)) -> Right $ VProp $ ValueVector $ w1 + w2
        _                                                -> Left "Inputs of PairL are not ValueVectors"
    ZipS -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (ValueVector $ w1 + w2) RenameVector RenameVector) "ZipL"
    CartProduct -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (ValueVector $ w1 + w2) PropVector PropVector) "CartProduct"
    CartProductS -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (ValueVector $ w1 + w2) PropVector PropVector) "CartProductS"
    NestProductS -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (ValueVector $ w1 + w2) PropVector PropVector) "NestProductS"
    EquiJoin _ _ -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (ValueVector $ w1 + w2) PropVector PropVector) "EquiJoin"
    EquiJoinS _ _ -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (ValueVector $ w1 + w2) PropVector PropVector) "EquiJoinS"
    NestJoinS _ _ -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (ValueVector $ w1 + w2) PropVector PropVector) "NestJoinS"
    SemiJoin _ _ -> liftM2 VPropPair (unpack s1) (Right RenameVector)
    SemiJoinS _ _ -> liftM2 VPropPair (unpack s1) (Right RenameVector)
    AntiJoin _ _ -> liftM2 VPropPair (unpack s1) (Right RenameVector)
    AntiJoinS _ _ -> liftM2 VPropPair (unpack s1) (Right RenameVector)

    TransposeS -> liftM2 VPropPair (return $ ValueVector 0) (unpack s2)

inferVectorTypeTerOp :: VectorProp VectorType -> VectorProp VectorType -> VectorProp VectorType -> TerOp -> Either String (VectorProp VectorType)
inferVectorTypeTerOp _ s2 s3 op = 
  case op of
    Combine -> 
      case (s2, s3) of
        (VProp (ValueVector w1), VProp (ValueVector w2)) | w1 == w2 -> 
          Right $ VPropTriple (ValueVector w1) RenameVector RenameVector
        (VProp (ValueVector _), VProp (ValueVector _))              -> 
          Left $ "Inputs of CombineVec do not have the same width"
        _                                                           -> 
          Left $ "Inputs of CombineVec are not ValueVectors/DescrVectors " ++ (show (s2, s3))
