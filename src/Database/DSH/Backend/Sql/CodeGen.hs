{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE InstanceSigs      #-}
{-# LANGUAGE ParallelListComp  #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}

-- | Definition of the SQL backend for DSH: SQL code generation and execution of
-- SQL queries.
module Database.DSH.Backend.Sql.CodeGen
    ( sqlBackend
    , SqlBackend
    , SqlCode
    , SqlVector
    , unSql
    , unwrapSql
    , comprehensionCodeGen
    ) where

import           Text.Printf

import qualified Database.HDBC                            as H
import           Database.HDBC.ODBC

import           Control.Monad
import           Data.Aeson
import           Data.Aeson.TH
import qualified Data.ByteString.Char8                    as BSC
import qualified Data.ByteString.Lex.Fractional           as BD
import qualified Data.ByteString.Lex.Integral             as BI
import qualified Data.Map                                 as M
import           Data.Maybe
import qualified Data.Text                                as T
import qualified Data.Text.Encoding                       as TE
import qualified Data.Vector                              as V

import qualified Database.Algebra.Dag                     as D
import           Database.Algebra.Dag.Common
import           Database.Algebra.SQL.Compatibility
import           Database.Algebra.SQL.Materialization.CTE
import           Database.Algebra.SQL.Util
import qualified Database.Algebra.Table.Lang              as TA

import           Database.DSH.Backend
import           Database.DSH.Backend.Sql.Opt.OptimizeTA
import           Database.DSH.Backend.Sql.Serialize
import           Database.DSH.Backend.Sql.Vector
import qualified Database.DSH.CL                          as CL
import           Database.DSH.Common.Impossible
import           Database.DSH.Common.QueryPlan
import           Database.DSH.Common.Vector
import           Database.DSH.Compiler
import           Database.DSH.SL

--------------------------------------------------------------------------------

newtype SqlBackend = SqlBackend Connection

-- | Construct a PostgreSQL backend based on an HDBC PostgreSQL
-- connection.
sqlBackend :: Connection -> SqlBackend
sqlBackend = SqlBackend

newtype SqlCode = SqlCode { unSql :: String }

instance ToJSON SqlCode where
    toJSON (SqlCode sql) = toJSON sql

-- | A data vector computed by a SQL query
data SqlVector = SqlVector
    { vecCode  :: SqlCode
    , vecKey   :: VecKey
    , vecRef   :: VecRef
    , vecItems :: VecItems
    }

deriveToJSON defaultOptions ''SqlVector

instance RelationalVector SqlVector where
    rvKeyCols vec  = map kc [1..unKey (vecKey vec)]
    rvRefCols vec  = map rc [1..unRef (vecRef vec)]
    rvItemCols vec = V.generate (unItems (vecItems vec)) (ic . (+ 1))

unwrapSql :: BackendCode SqlBackend -> SqlCode
unwrapSql = vecCode . sqlVector

--------------------------------------------------------------------------------

-- | In a query shape, render each root node for the algebraic plan
-- into a separate SQL query.
generateSqlQueries :: QueryPlan TA.TableAlgebra TADVec -> Shape (BackendCode SqlBackend)
generateSqlQueries taPlan = renderSql $ queryShape taPlan
  where
    roots :: [AlgNode]
    roots = D.rootNodes $ queryDag taPlan

    (_sqlShared, sqlQueries) = renderOutputDSHWith PostgreSQL materialize (queryDag taPlan)

    nodeToQuery :: [(AlgNode, SqlCode)]
    nodeToQuery  = zip roots (map SqlCode sqlQueries)

    lookupNode :: AlgNode -> SqlCode
    lookupNode n = fromMaybe $impossible $ lookup n nodeToQuery

    -- We do not need order columns to reconstruct results: order information is
    -- encoded in the SQL queries' ORDER BY clause. We rely on the physical
    -- order of the result table.
    renderSql = fmap (\(TADVec q _ k r i) -> BC $ SqlVector (lookupNode q) k r i)

-- | Generate SQL queries from a comprehension expression
comprehensionCodeGen :: CL.Expr -> Shape SqlVector
comprehensionCodeGen q = fmap (\(BC vec) -> vec) shape
  where
    shape = generateSqlQueries $ optimizeTA $ implementVectorOps $ compileOptQ q

--------------------------------------------------------------------------------
-- Relational implementation of vector operators.


-- | Implement vector operators with relational algebra operators
implementVectorOps :: QueryPlan SL SLDVec -> QueryPlan TA.TableAlgebra TADVec
implementVectorOps vlPlan = mkQueryPlan dag shape tagMap
  where
    taPlan               = vl2Algebra (D.nodeMap $ queryDag vlPlan)
                                      (queryShape vlPlan)
    serializedPlan       = insertSerialize taPlan
    (dag, shape, tagMap) = runVecBuild serializedPlan

--------------------------------------------------------------------------------
-- Definition of the SQL backend

instance RelationalVector (BackendCode SqlBackend) where
    rvKeyCols (BC v) = rvKeyCols v
    rvItemCols (BC v) = rvItemCols v
    rvRefCols (BC v) = rvRefCols v

instance Backend SqlBackend where
    data BackendRow SqlBackend  = SqlRow !(M.Map String H.SqlValue)
    data BackendCode SqlBackend = BC { sqlVector :: SqlVector }
    data BackendPlan SqlBackend = QP (QueryPlan TA.TableAlgebra TADVec)

    execFlatQuery (SqlBackend conn) v = do
        stmt <- H.prepare conn (unSql $ vecCode $ sqlVector v)
        void $ H.execute stmt []
        map SqlRow <$> H.fetchAllRowsMap stmt

    generateCode :: BackendPlan SqlBackend -> Shape (BackendCode SqlBackend)
    generateCode (QP plan) = generateSqlQueries $ optimizeTA plan

    generatePlan :: QueryPlan SL SLDVec -> BackendPlan SqlBackend
    generatePlan = QP . implementVectorOps

    dumpPlan :: String -> Bool -> BackendPlan SqlBackend -> IO String
    dumpPlan prefix False (QP plan) = do
        let fileName = prefix ++ "_ta"
        exportPlan fileName plan
        return fileName
    dumpPlan prefix True (QP plan) = do
        let fileName = prefix ++ "_opt_ta"
        exportPlan fileName $ optimizeTA plan
        return fileName

    transactionally (SqlBackend conn) ma =
        H.withTransaction conn (ma . SqlBackend)

--------------------------------------------------------------------------------
-- Encoding of vector rows in SQL result rows.

instance Row (BackendRow SqlBackend) where
    data Scalar (BackendRow SqlBackend) = SqlScalar !H.SqlValue

    col !c (SqlRow !r) =
        case M.lookup c r of
            Just !v -> SqlScalar v
            Nothing -> error $ printf "col lookup %s failed in %s" c (show r)

    keyVal :: Scalar (BackendRow SqlBackend) -> KeyVal
    keyVal (SqlScalar !v) = case v of
        H.SqlInt32 !i      -> KInt (fromIntegral i)
        H.SqlInt64 !i      -> KInt (fromIntegral i)
        H.SqlWord32 !i     -> KInt (fromIntegral i)
        H.SqlWord64 !i     -> KInt (fromIntegral i)
        H.SqlInteger !i    -> KInt (fromIntegral i)
        H.SqlString !s     -> KByteString (BSC.pack s)
        H.SqlByteString !s -> KByteString s
        H.SqlLocalDate !d  -> KDay d
        v                  -> error $ printf "keyVal: %s" (show v)


    descrVal (SqlScalar (H.SqlInt32 !i))   = fromIntegral i
    descrVal (SqlScalar (H.SqlInteger !i)) = fromIntegral i
    descrVal (SqlScalar v)                 = error $ printf "descrVal: %s" (show v)

    integerVal (SqlScalar (H.SqlInteger !i))    = i
    integerVal (SqlScalar (H.SqlInt32 !i))      = fromIntegral i
    integerVal (SqlScalar (H.SqlInt64 !i))      = fromIntegral i
    integerVal (SqlScalar (H.SqlWord32 !i))     = fromIntegral i
    integerVal (SqlScalar (H.SqlWord64 !i))     = fromIntegral i
    integerVal (SqlScalar (H.SqlDouble !d))     = truncate d
    integerVal (SqlScalar (H.SqlByteString !s)) = case BI.readSigned BI.readDecimal s of
                                                      Just (i, s') | BSC.null s' -> i
                                                      _                        ->
                                                          error $ printf "integerVal: %s" (show s)
    integerVal (SqlScalar v)                    = error $ printf "integerVal: %s" (show v)

    doubleVal (SqlScalar (H.SqlDouble !d))     = d
    doubleVal (SqlScalar (H.SqlRational !d))   = fromRational d
    doubleVal (SqlScalar (H.SqlInteger !d))    = fromIntegral d
    doubleVal (SqlScalar (H.SqlInt32 !d))      = fromIntegral d
    doubleVal (SqlScalar (H.SqlInt64 !d))      = fromIntegral d
    doubleVal (SqlScalar (H.SqlWord32 !d))     = fromIntegral d
    doubleVal (SqlScalar (H.SqlWord64 !d))     = fromIntegral d
    doubleVal (SqlScalar (H.SqlByteString !c)) = case BD.readSigned BD.readDecimal c of
                                                     Just (!v, _) -> v
                                                     Nothing      -> $impossible
    doubleVal (SqlScalar v)                    = error $ printf "doubleVal: %s" (show v)

    boolVal (SqlScalar (H.SqlBool !b))       = b
    boolVal (SqlScalar (H.SqlInteger !i))    = i /= 0
    boolVal (SqlScalar (H.SqlInt32 !i))      = i /= 0
    boolVal (SqlScalar (H.SqlInt64 !i))      = i /= 0
    boolVal (SqlScalar (H.SqlWord32 !i))     = i /= 0
    boolVal (SqlScalar (H.SqlWord64 !i))     = i /= 0
    boolVal (SqlScalar (H.SqlByteString !s)) = case BI.readDecimal s of
                                                  Just (!d, _) -> d /= (0 :: Int)
                                                  Nothing      -> $impossible
    boolVal (SqlScalar v)                   = error $ printf "boolVal: %s" (show v)

    charVal (SqlScalar (H.SqlChar !c))       = c
    charVal (SqlScalar (H.SqlString (c:_)))  = c
    charVal (SqlScalar (H.SqlByteString !s)) = case T.uncons (TE.decodeUtf8 s) of
                                                   Just (!c, _) -> c
                                                   Nothing      -> $impossible
    charVal (SqlScalar v)                    = error $ printf "charVal: %s" (show v)

    textVal (SqlScalar (H.SqlString !t))     = T.pack t
    textVal (SqlScalar (H.SqlByteString !s)) = TE.decodeUtf8 s
    textVal (SqlScalar v)                    = error $ printf "textVal: %s" (show v)

    decimalVal (SqlScalar (H.SqlRational !d))   = fromRational d
    decimalVal (SqlScalar (H.SqlByteString !c)) =
        case BD.readSigned BD.readDecimal c of
            Just (!d, _) -> d
            Nothing      -> error $ show c
    decimalVal (SqlScalar v)                    = error $ printf "decimalVal: %s" (show v)

    dayVal (SqlScalar (H.SqlLocalDate d)) = d
    dayVal (SqlScalar v)                  = error $ printf "dayVal: %s" (show v)
