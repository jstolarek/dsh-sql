{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Backend.Sql.Opt.Properties.BottomUp where

import qualified Data.Set.Monad                                   as S

import           Database.Algebra.Dag
import           Database.Algebra.Dag.Common
import           Database.Algebra.Table.Lang

import           Database.DSH.Common.Impossible

import           Database.DSH.Common.Opt

import           Database.DSH.Backend.Sql.Opt.Properties.Card1
import           Database.DSH.Backend.Sql.Opt.Properties.Cols
import           Database.DSH.Backend.Sql.Opt.Properties.Const
import           Database.DSH.Backend.Sql.Opt.Properties.Empty
import           Database.DSH.Backend.Sql.Opt.Properties.FD
import           Database.DSH.Backend.Sql.Opt.Properties.Keys
import           Database.DSH.Backend.Sql.Opt.Properties.Nullable
import           Database.DSH.Backend.Sql.Opt.Properties.Order
import           Database.DSH.Backend.Sql.Opt.Properties.Types

-- FIXME this is (almost) identical to its X100 counterpart -> merge
inferWorker :: NodeMap TableAlgebra -> TableAlgebra -> AlgNode -> NodeMap BottomUpProps -> BottomUpProps
inferWorker _ op n pm =
    let res =
           case op of
                TerOp{}        -> $impossible
                BinOp vl c1 c2 ->
                  let c1Props = lookupUnsafe pm "no children properties" c1
                      c2Props = lookupUnsafe pm "no children properties" c2
                  in inferBinOp vl c1Props c2Props
                UnOp vl c      ->
                  let cProps = lookupUnsafe pm "no children properties" c
                  in inferUnOp vl cProps
                NullaryOp vl   -> inferNullOp vl
    in case res of
            Left msg -> error $ "Inference failed at node " ++ show n ++ ": " ++ msg
            Right props -> props

inferNullOp :: NullOp -> Either String BottomUpProps
inferNullOp op = do
  let opCols     = inferColsNullOp op
      opKeys     = inferKeysNullOp op
      opEmpty    = inferEmptyNullOp op
      opCard1    = inferCard1NullOp op
      -- We only care for rownum-generated columns. Therefore, For
      -- nullary operators order is empty.
      opOrder    = []
      opConst    = inferConstNullOp op
      opNullable = inferNullableNullOp op
      opFDs      = inferFDNullOp opCols opKeys op
  return BUProps { pCols     = opCols
                 , pKeys     = opKeys
                 , pEmpty    = opEmpty
                 , pCard1    = opCard1
                 , pOrder    = opOrder
                 , pConst    = opConst
                 , pNullable = opNullable
                 , pFunDeps  = opFDs
                 }

inferUnOp :: UnOp -> BottomUpProps -> Either String BottomUpProps
inferUnOp op cProps = do
  let opCols     = inferColsUnOp (pCols cProps) op
      opKeys     = inferKeysUnOp (pKeys cProps) (pCard1 cProps) (S.map fst $ pCols cProps) op
      opEmpty    = inferEmptyUnOp (pEmpty cProps) op
      opCard1    = inferCard1UnOp (pCard1 cProps) (pEmpty cProps) op
      opOrder    = inferOrderUnOp (pOrder cProps) op
      opConst    = inferConstUnOp (pConst cProps) op
      opNullable = inferNullableUnOp (pNullable cProps) op
      opFDs      = inferFDUnOp cProps op
  return BUProps { pCols     = opCols
                 , pKeys     = opKeys
                 , pEmpty    = opEmpty
                 , pCard1    = opCard1
                 , pOrder    = opOrder
                 , pConst    = opConst
                 , pNullable = opNullable
                 , pFunDeps  = opFDs
                 }

inferBinOp :: BinOp -> BottomUpProps -> BottomUpProps -> Either String BottomUpProps
inferBinOp op c1Props c2Props = do
  let opCols     = inferColsBinOp (pCols c1Props) (pCols c2Props) op
      opKeys     = inferKeysBinOp (pKeys c1Props) (pKeys c2Props) (pCard1 c1Props) (pCard1 c2Props) op
      opEmpty    = inferEmptyBinOp (pEmpty c1Props) (pEmpty c2Props) op
      opCard1    = inferCard1BinOp (pCard1 c1Props) (pCard1 c2Props) op
      opOrder    = inferOrderBinOp (pOrder c1Props) (pOrder c2Props) op
      opConst    = inferConstBinOp (pConst c1Props) (pConst c2Props) op
      opNullable = inferNullableBinOp c1Props c2Props op
      opFDs      = inferFDBinOp c1Props c2Props opKeys opCols op
  return BUProps { pCols     = opCols
                 , pKeys     = opKeys
                 , pEmpty    = opEmpty
                 , pCard1    = opCard1
                 , pOrder    = opOrder
                 , pConst    = opConst
                 , pNullable = opNullable
                 , pFunDeps  = opFDs
                 }

inferBottomUpProperties :: [AlgNode] -> AlgebraDag TableAlgebra -> NodeMap BottomUpProps
inferBottomUpProperties = inferBottomUpG inferWorker
