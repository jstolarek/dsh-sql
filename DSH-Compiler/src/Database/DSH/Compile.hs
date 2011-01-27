{-# LANGUAGE ScopedTypeVariables, TemplateHaskell, ParallelListComp #-}
module Database.DSH.Compile where

import Database.DSH.Internals

import Database.DSH.Pathfinder

import qualified Data.Array as A
import qualified Data.List as L
import Data.Maybe (fromJust, isNothing, isJust)
import Data.List (sortBy)
import Control.Monad.Reader
import Control.Exception (evaluate)

import qualified Text.XML.HaXml as X
import Text.XML.HaXml (Content(..), AttValue(..), tag, deep, children, xmlParse, Document(..))

import Database.HDBC
import Data.Convertible

-- | Wrapper type with phantom type for algebraic plan
-- The type variable represents the type of the result of the plan
newtype AlgebraXML a = Algebra String

-- | Wrapper type with phantom type for SQL plan
-- The type variable represents the type of the result of the plan
newtype SQLXML a = SQL String
 deriving Show

-- | Type representing a query bundle, the type variable represents the type
-- of the result of the query bundle. A bundle consists of pair of numbered queries.
-- Each query consists of the query itself, a schema explaining its types.
-- If the query is a nested value in the result of another query the optional attribute
-- represents (queryID, columnID). The queryId refers to the number of the query in the bundle
-- the columnID refers 
newtype QueryBundle a = Bundle [(Int, (String, SchemaInfo, Maybe (Int, Int)))]

-- | Description of a table. The field iterN contains the name of the iter column
-- the items field contains a list of item column names and their position within the result.
data SchemaInfo = SchemaInfo {iterN :: String, items :: [(String, Int)]}

-- | Description of result data of a query. The field iterR contains the column number of
-- the iter column. resCols contains a for all items columns their column number in the result.
data ResultInfo = ResultInfo {iterR :: Int, resCols :: [(String, Int)]}
 deriving Show

-- | Translate the algebraic plan to SQL and then execute it using the provided 
-- DB connection. If debug is switchd on the SQL code is written to a file 
-- named query.sql
executePlan :: forall a. forall conn. (QA a, IConnection conn) => Bool -> conn -> AlgebraXML a -> IO Norm
executePlan debug c p = do
                        sql@(SQL s) <- algToSQL p
                        when debug (writeFile "query.sql" s)
                        runSQL c $ extractSQL sql

algToAlg :: AlgebraXML a -> IO (AlgebraXML a)
algToAlg (Algebra s) = do
                        r <- compileFerryOpt s OutputXml Nothing
                        case r of
                           (Right sql) -> return $ Algebra sql
                           (Left err) -> error $ "Pathfinder compilation for input: \n"
                                                   ++ s ++ "\n failed with error: \n"
                                                   ++ err

-- | Translate an algebraic plan into SQL code using Pathfinder
algToSQL :: AlgebraXML a -> IO (SQLXML a)
algToSQL (Algebra s) = do
                         r <- compileFerryOpt s OutputSql Nothing
                         case r of
                            (Right sql) -> return $ SQL sql
                            (Left err) -> error $ "Pathfinder compilation for input: \n"
                                                    ++ s ++ "\n failed with error: \n"
                                                    ++ err

-- | Extract the SQL queries from the XML structure generated by pathfinder
extractSQL :: SQLXML a -> QueryBundle a
extractSQL (SQL q) = let (Document _ _ r _) = xmlParse "query" q
                      in Bundle $ map extractQuery $ (deep $ tag "query_plan") (CElem r $impossible)
    where
        extractQuery c@(CElem (X.Elem n attrs cs) _) = let qId = case fmap attrToInt $ lookup "id" attrs of
                                                                    Just x -> x
                                                                    Nothing -> $impossible
                                                           rId = fmap attrToInt $ lookup "idref" attrs
                                                           cId = fmap attrToInt $ lookup "colref" attrs
                                                           ref = liftM2 (,) rId cId
                                                           query = extractCData $  head $ concatMap children $ deep (tag "query") c
                                                           schema = toSchemeInf $ map process $ concatMap (\x -> deep (tag "column") x) $ deep (tag "schema") c
                                                        in (qId, (query, schema, ref))
        extractQuery _ = $impossible
        attrToInt :: AttValue -> Int
        attrToInt (AttValue [(Left i)]) = read i
        attrToInt _ = $impossible
        attrToString :: AttValue -> String
        attrToString (AttValue [(Left i)]) = i
        attrToString _ = $impossible
        extractCData :: Content i -> String
        extractCData (CString _ d _) = d
        extractCData _ = $impossible
        toSchemeInf :: [(String, Maybe Int)] -> SchemaInfo
        toSchemeInf results = let iterName = fst $ head $ filter (\(_, p) -> isNothing p) results
                                  cols = map (\(n, v) -> (n, fromJust v)) $ filter (\(_, p) -> isJust p) results
                               in SchemaInfo iterName cols
        process :: Content i -> (String, Maybe Int)
        process (CElem (X.Elem _ attrs _) _) = let name = fromJust $ fmap attrToString $ lookup "name" attrs
                                                   pos = fmap attrToInt $ lookup "position" attrs
                                                in (name, pos)
        process _ = $impossible

-- | Execute the given SQL queries and assemble the results into one structure
runSQL :: forall a. forall conn. (QA a, IConnection conn) => conn -> QueryBundle a -> IO Norm
runSQL c (Bundle queries) = do
                             results <- mapM (runQuery c) queries
                             let (queryMap, valueMap) = foldr buildRefMap ([],[]) results
                             let ty = reify (undefined :: a)
                             let results' = runReader (processResults 0 ty) (queryMap, valueMap)
                             return $ case lookup 1 results' of
                                         Just x -> x 
                                         Nothing -> ListN [] ty

-- | Type of the environment under which we reconstruct ordinary haskell data from the query result.
-- The first component of the reader monad contains a mapping from (queryNumber, columnNumber) to 
-- the number of a nested query. The second component is a tuple consisting of query number associated
-- with a pair of the raw result data partitioned by iter, and a description of this result data.
type QueryR = Reader ([((Int, Int), Int)] ,[(Int, ([(Int, [[SqlValue]])], ResultInfo))])

-- | Retrieve the data asociated with query i.
getResults :: Int -> QueryR [(Int, [[SqlValue]])]
getResults i = do
                env <- ask
                return $ case lookup i $ snd env of
                              Just x -> fst x
                              Nothing -> $impossible

-- | Get the position of item i of query q
getColResPos :: Int -> Int -> QueryR Int
getColResPos q i = do
                    env <- ask
                    return $ case lookup q $ snd env of
                                Just (_, ResultInfo _ x) -> snd (x !! i)
                                Nothing -> $impossible

-- | Get the id of the query that is nested in column c of query q.
findQuery :: (Int, Int) -> QueryR Int
findQuery (q, c) = do
                    env <- ask
                    return $ (\x -> case x of
                                  Just x' -> x'
                                  Nothing -> error $ show $ fst env) $ lookup (q, c + 1) $ fst env

-- | Reconstruct the haskell value out of the result of query i with type ty.
processResults :: Int -> Type -> QueryR [(Int, Norm)]
processResults i ty@(ListT t1) = do
                                v <- getResults i
                                mapM (\(it, vals) -> do
                                                        v1 <- processResults' i 0 vals t1
                                                        return (it, ListN v1 ty)) v
processResults i t = do
                        v <- getResults i
                        mapM (\(it, vals) -> do
                                              v1 <- processResults' i 0 vals t
                                              return (it, head v1)) v

-- | Reconstruct the values for column c of query q out of the rawData vals with type t.
processResults' :: Int -> Int -> [[SqlValue]] -> Type -> QueryR [Norm]
processResults' _ _ vals UnitT = return $ map (\_ -> UnitN UnitT) vals
processResults' q c vals t@(TupleT t1 t2) = do
                                            v1s <- processResults' q c vals t1
                                            v2s <- processResults' q (c + 1) vals t2
                                            return $ [TupleN v1 v2 t | v1 <- v1s | v2 <- v2s]
processResults' q c vals t@(ListT _) = do
                                        nestQ <- findQuery (q, c)
                                        list <- processResults nestQ t
                                        let maxI = fst $ L.maximumBy (\x y -> fst x `compare` fst y) list
                                        let lA = (A.accumArray ($impossible) Nothing (1,maxI) []) A.// map (\(x,y) -> (x, Just y)) list
                                        i <- getColResPos q c
                                        return $ map (\val -> case lA A.! ((convert $ val !! i)::Int) of
                                                                Just x -> x
                                                                Nothing -> ListN [] t) vals
processResults' _ _ _ (TimeT) = error "Results processing for time has not been implemented."
processResults' _ _ _ (ArrowT _ _) = $impossible -- The result cannot be a function
processResults' q c vals t = do
                                    i <- getColResPos q c
                                    return $ map (\val -> convert $ (val !! i, t)) vals


-- | Partition by iter column
-- The first argument is the position of the iter column.
-- The second argument the raw data
-- It returns a list of pairs (iterVal, rawdata within iter) 
partByIter :: Int -> [[SqlValue]] -> [(Int, [[SqlValue]])]
partByIter n (v:vs) = let i = getIter n v
                          (vi, vr) = span (\v' -> i == getIter n v') vs
                       in (i, v:vi) : partByIter n vr
       where
           getIter :: Int -> [SqlValue] -> Int
           getIter n' vals = ((fromSql (vals !! n'))::Int)
partByIter _ [] = []


-- | Execute the given query plan bundle, over the provided connection.
-- It returns the raw data for each query along with a description on how to reconstruct 
-- ordinary haskell data
runQuery :: IConnection conn => conn -> (Int, (String, SchemaInfo, Maybe (Int, Int))) -> IO (Int, ([(Int, [[SqlValue]])], ResultInfo, Maybe (Int, Int)))
runQuery c (qId, (query, schema, ref)) = do
                                                sth <- prepare c query
                                                _ <- execute sth []
                                                res <- dshFetchAllRowsStrict sth
                                                resDescr <- describeResult sth
                                                let ri = schemeToResult schema resDescr
                                                let res' = partByIter (iterR ri) res 
                                                return (qId, (res', ri, ref))

dshFetchAllRowsStrict :: Statement -> IO [[SqlValue]]
dshFetchAllRowsStrict stmt = go []
  where
  go :: [[SqlValue]] -> IO [[SqlValue]]
  go acc = do  mRow <- fetchRow stmt
               case mRow of
                 Nothing   -> return (reverse acc)
                 Just row  -> do mapM_ evaluate row
                                 go (row : acc)

-- | Transform algebraic plan scheme info into resultinfo
schemeToResult :: SchemaInfo -> [(String, SqlColDesc)] -> ResultInfo
schemeToResult (SchemaInfo itN cols) resDescr = let ordCols = sortBy (\(_, c1) (_, c2) -> compare c1 c2) cols
                                                    resColumns = flip zip [0..] $ map (\(c, _) -> takeWhile (\a -> a /= '_') c) resDescr
                                                    itC = fromJust $ lookup itN resColumns
                                                 in ResultInfo itC $ map (\(n, _) -> (n, fromJust $ lookup n resColumns)) ordCols

-- | 
buildRefMap :: (Int, ([(Int, [[SqlValue]])], ResultInfo, Maybe (Int, Int))) -> ([((Int, Int), Int)] ,[(Int, ([(Int, [[SqlValue]])], ResultInfo))]) -> ([((Int, Int), Int)] ,[(Int, ([(Int, [[SqlValue]])], ResultInfo))])
buildRefMap (q, (r, ri, (Just (t, c)))) (qm, rm) = (((t, c), q):qm, (q, (r, ri)):rm)
buildRefMap (q, (r, ri, _)) (qm, rm) = (qm, (q, (r, ri)):rm)