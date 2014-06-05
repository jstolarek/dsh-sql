module Database.DSH.Optimizer.TA.OptimizeTA where

import qualified Data.IntMap as M

import qualified Database.Algebra.Dag                                             as Dag

import           Database.Algebra.Table.Lang

import           Database.DSH.Common.QueryPlan
import           Database.DSH.VL.Vector

import           Database.DSH.Optimizer.Common.Rewrite

import           Database.DSH.Optimizer.TA.Rewrite.Basic

{-

rough plan/first goals:

merge projections: no properties, leads to basic infrastructure

prune unreferenced rownums: icols prop

simplify rownums, e.g. key-based: key prop, maybe fd (not sure if necessary)

merge sorting criteria into rownums:  track sorting criteria

remove rownums if concrete values not required: use prop, key prop, ?

-}

type RewriteClass = Rewrite TableAlgebra (TopShape DVec) Bool

defaultPipeline :: [RewriteClass]
defaultPipeline = [cleanup]

runPipeline :: Dag.AlgebraDag TableAlgebra 
            -> (TopShape DVec)
            -> [RewriteClass] 
            -> Bool 
            -> (Dag.AlgebraDag TableAlgebra, Log, TopShape DVec)
runPipeline d sh pipeline debug = (d', rewriteLog, sh')
  where (d', sh', _, rewriteLog) = runRewrite (sequence_ pipeline) d sh debug

optimizeTA :: QueryPlan TableAlgebra -> QueryPlan TableAlgebra
optimizeTA plan =
#ifdef DEBUGGRAPH
  let (d, _rewriteLog, shape) = runPipeline (queryDag plan) (queryShape plan) defaultPipeline True
#else
  let (d, _rewriteLog, shape) = runPipeline (queryDag plan) (queryShape plan) defaultPipeline False
#endif
  in QueryPlan { queryDag = d, queryShape = shape, queryTags = M.empty }
