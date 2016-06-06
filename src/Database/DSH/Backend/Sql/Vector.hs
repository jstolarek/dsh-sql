{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE TemplateHaskell  #-}

-- | Definition of relational vector implementations.
module Database.DSH.Backend.Sql.Vector where

import           Data.Aeson
import           Data.Aeson.TH
import qualified Data.Vector                 as V

import           Database.Algebra.Dag.Common
import qualified Database.Algebra.Table.Lang as TA
import           Database.DSH.Common.Vector

--------------------------------------------------------------------------------

-- | The ordering columns of a data vector
newtype VecOrder    = VecOrder [TA.SortDir]

unOrd :: VecOrder -> Int
unOrd (VecOrder os) = length os

instance Monoid VecOrder where
    mempty = VecOrder []
    mappend (VecOrder o1) (VecOrder o2) = VecOrder (o1 ++ o2)

--------------------------------------------------------------------------------

-- | The natural key of a data vector
newtype VecKey      = VecKey { unKey :: Int }

instance Monoid VecKey where
    mempty = VecKey 0
    mappend (VecKey k1) (VecKey k2) = VecKey (k1 + k2)

instance ToJSON VecKey where
    toJSON (VecKey ks) = toJSON $ map kc [1..ks]

--------------------------------------------------------------------------------

-- | Outer key reference columns
newtype VecRef      = VecRef { unRef :: Int }

instance ToJSON VecRef where
    toJSON (VecRef rs) = toJSON $ map rc [1..rs]

-- | Derive inner references from an outer key.
keyRef :: VecKey -> VecRef
keyRef (VecKey i) = VecRef i

instance Monoid VecRef where
    mempty = VecRef 0
    mappend (VecRef r1) (VecRef r2) = VecRef (r1 + r2)

--------------------------------------------------------------------------------

-- | Payload columns of a data vector
newtype VecItems    = VecItems { unItems :: Int }

instance Monoid VecItems where
    mempty = VecItems 0
    mappend (VecItems i1) (VecItems i2) = VecItems (i1 + i2)

instance ToJSON VecItems where
    toJSON (VecItems is) = toJSON $ map ic [1..is]

--------------------------------------------------------------------------------

-- | Source columns of a transformation vector
newtype VecTransSrc = VecTransSrc { unSrc :: Int }

-- | Destination columns of a transformation vector
newtype VecTransDst = VecTransDst { unDst :: Int }

--------------------------------------------------------------------------------

-- | Key columns of a filter vector
newtype VecFilter = VecFilter Int

--------------------------------------------------------------------------------
-- Vectors over relational algebra plans.

-- | A data vector that references a table algebra plan
data TADVec = TADVec AlgNode VecOrder VecKey VecRef VecItems

-- | A rekeying vector that references a table algebra plan
data TAKVec = TAKVec AlgNode VecTransSrc VecTransDst

-- | A renaming vector that references a table algebra plan
data TARVec = TARVec AlgNode VecTransSrc VecTransDst

-- | Sorting of segments is a NOOP in the natural key backend.
data TASVec = TASVec

-- | A filtering vector that references a table algebra plan
data TAFVec = TAFVec AlgNode VecFilter

instance DagVector TADVec where
    vectorNodes (TADVec n _ _ _ _) = [n]

    updateVector n1 n2 (TADVec q o k r i)
        | q == n1   = TADVec n2 o k r i
        | otherwise = TADVec q o k r i

--------------------------------------------------------------------------------
-- SQL Vectors

-- | A data vector computed by a SQL query
data SqlVector c = SqlVector
    { vecCode  :: c
    , vecKey   :: VecKey
    , vecRef   :: VecRef
    , vecItems :: VecItems
    }

instance Show c => Show (SqlVector c) where
    show = show . vecCode 

instance RelationalVector (SqlVector c) where
    rvKeyCols vec  = map kc [1..unKey (vecKey vec)]
    rvRefCols vec  = map rc [1..unRef (vecRef vec)]
    rvItemCols vec = V.generate (unItems (vecItems vec)) (ic . (+ 1))

--------------------------------------------------------------------------------
-- Definition of column names

-- | Item columns
ic :: Int -> TA.Attr
ic i = "i" ++ show i

-- | Key columns
kc :: Int -> TA.Attr
kc i = "k" ++ show i

-- | Order columns
oc :: Int -> TA.Attr
oc i = "o" ++ show i

-- | Ref columns
rc :: Int -> TA.Attr
rc i = "r" ++ show i

-- | (Key) source columns
sc :: Int -> TA.Attr
sc i = "s" ++ show i

-- | (Key) destination columns
dc :: Int -> TA.Attr
dc i = "d" ++ show i

-- | Grouping columns
gc :: Int -> TA.Attr
gc i = "g" ++ show i

-- | Filter columns
fc :: Int -> TA.Attr
fc i = "f" ++ show i

-- | Synthesized order column (left)
lsoc :: TA.Attr
lsoc = "lso"

-- | Synthesized order column (right)
rsoc :: TA.Attr
rsoc = "rso"

-- | Synthesized order column
soc :: TA.Attr
soc = "so"

-- | Union side marker
usc :: TA.Attr
usc = "us"


--------------------------------------------------------------------------------
-- JSON serialization

$(deriveToJSON defaultOptions ''VecOrder)
$(deriveToJSON defaultOptions ''VecTransSrc)
$(deriveToJSON defaultOptions ''VecTransDst)
$(deriveToJSON defaultOptions ''TADVec)
$(deriveToJSON defaultOptions ''TAKVec)
$(deriveToJSON defaultOptions ''TARVec)
$(deriveToJSON defaultOptions ''SqlVector)

--------------------------------------------------------------------------------
