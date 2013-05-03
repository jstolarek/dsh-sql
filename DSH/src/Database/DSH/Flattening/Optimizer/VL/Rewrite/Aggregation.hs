{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Flattening.Optimizer.VL.Rewrite.Aggregation(groupingToAggregation) where

import Control.Monad

import Database.Algebra.VL.Data
import Database.Algebra.Dag.Common

import Database.DSH.Impossible

import Database.DSH.Flattening.Optimizer.Common.Rewrite
import Database.DSH.Flattening.Optimizer.VL.Properties.Types
import Database.DSH.Flattening.Optimizer.VL.Rewrite.Common

aggregationRules :: VLRuleSet ()
aggregationRules = [ groupingToAggr ]

aggregationRulesBottomUp :: VLRuleSet BottomUpProps
aggregationRulesBottomUp = [ pushExprThroughGroupBy ]

groupingToAggregation :: VLRewrite Bool
groupingToAggregation = iteratively $ applyToAll inferBottomUp aggregationRulesBottomUp

-- If an expression operator is applied to the R2 output of GroupBy, push
-- the expression below the GroupBy operator. This rewrite assists in turning
-- combinations of GroupBy and Vec* into a form that is suitable for rewriting
-- into a VecAggr form. Even if this is not possible, the rewrite should not do 
-- any harm
pushExprThroughGroupBy :: VLRule BottomUpProps
pushExprThroughGroupBy q =
  $(pattern 'q "CompExpr1L e (R2 (qg=(qc) GroupBy (qp)))"
    [| do
        -- get vector type of right grouping input to determine the
        -- width of the vector
        vt <- liftM vectorTypeProp $ properties $(v "qp")
        let width = case vt of
                      VProp (ValueVector w) -> w
                      _                     -> $impossible
        
        return $ do
          logRewrite "Aggregation.PushExprThroughGroupBy" q
          -- Introduce a new column below the GroupBy operator which contains
          -- the expression result
          let projection = (map PLCol [1 .. width]) ++ [PLExpr $(v "e")]
          projectNode <- insert $ UnOp (ProjectPayload projection) $(v "qp")
          
          -- Link the GroupBy operator to the new projection
          groupNode   <- replaceWithNew $(v "qg") $ BinOp GroupBy $(v "qc") projectNode
          
          -- Replace the CompExpr1L operator with a projection on the new column
          void $ replaceWithNew q $ UnOp (ProjectL [width + 1]) groupNode |])
          
-- | Turn an aggregate operator into the corrresponding aggregate function for VecAggr
aggrOpToFun :: DBCol -> VL -> VLMatch () AggrFun
aggrOpToFun c (UnOp VecMaxL _)    = return $ Max c
aggrOpToFun c (UnOp VecMinL _)    = return $ Min c
aggrOpToFun c (BinOp VecAvgL _ _) = return $ Avg c
aggrOpToFun c (BinOp VecSumL _ _) = return $ Sum c
aggrOpToFun _ _                   = fail "no match"

-- | Check if we have an operator combination which is eligible for moving to a
-- VecAggr operator.
matchAggr :: AlgNode -> VLMatch () (AggrFun, AlgNode)
matchAggr q = do
  op1 <- getOperator q
  
  -- To change an aggregate operator into an aggregate function, we expect
  case op1 of
    -- either a VecMaxL (ProjectL (R2 GroupBy)) combinaton
    UnOp (ProjectL [c]) _ -> do
      ps <- getParents q
      case ps of
        [p] -> do
          o <- getOperator p
          f <- aggrOpToFun c o
          return (f, p)
        _   -> fail "no match"
    -- or LengthSeg (ToDescr (R2 GroupBy))
    UnOp ToDescr _ -> do
      ps <- getParents q
      case ps of
        [p] -> do
          o <- getOperator p
          case o of
            BinOp LengthSeg _ _ -> return (Count, p)
            _                   -> fail "no match"
        _ -> fail "no match"
    _                   -> fail "no match"
    
projectionCol :: PayloadProj -> VLMatch () DBCol
projectionCol (PLCol c) = return c
projectionCol _         = fail "no match"

-- FIXME combine with r2Parents in Specialized and move to Rewrite.Common
r1Parents :: AlgNode -> VLRewrite [AlgNode]
r1Parents n = do
  let isR1 (UnOp R1 _) = True
      isR1 _           = False
      
  ps  <- parents n
  ops <- mapM operator ps
  return $ map fst $ filter (\(_, o) -> isR1 o) $ zip ps ops
          
-- We rewrite a combination of GroupBy and aggregation operators into a single
-- VecAggr operator if the following conditions hold: 
--
-- 1. The R2 output of GroupBy is only consumed by aggregation operators (VecMaxL, 
--    VecMinL, VecSumL, LengthSeg)
-- 2. The grouping criteria is a simple column projection from the input vector
groupingToAggr :: VLRule ()
groupingToAggr q =
  $(pattern 'q "R2 (qg=(ProjectPayload ps (_)) GroupBy (q2))"
    [| do
       -- FIXME ensure that both GroupBy inputs have the same origin.
       
        groupByParents <- getParents q
        
        -- We ensure that all parents of the groupBy are operators which we can
        -- turn into aggregate functions
        funs <- mapM matchAggr groupByParents
        
        -- Check if the grouping criteria are simple columns. Extract the
        -- grouping cols from the left GroupBy input
        groupingCols <- mapM projectionCol $(v "ps")
        
        return $ do
          -- The output format of the new VecAggr operator is 
          -- [p1, ..., pn, a1, ..., am] where p1, ..., pn are the 
          -- grouping columns and a1, ..., am are the aggregates 
          -- themselves.
        
          -- We obviously assume that the grouping columns are still present in
          -- the right input of GroupBy at the same position. In combination
          -- with rewrite pushExprThroughGroupBy, this is true since we only
          -- *add* columns at the end.
          aggrNode <- insert $ UnOp (VecAggr groupingCols (map fst funs)) $(v "q2")

          -- For every aggregate function, generate a projection which only
          -- leaves the aggregate column. Function receives the node of the
          -- original aggregate operator and the column in which the respective 
          -- aggregation result resides.
          let insertAggrProject :: AlgNode -> DBCol -> VLRewrite ()
              insertAggrProject oldAggrNode aggrCol = 
                void $ replaceWithNew oldAggrNode $ UnOp (ProjectL [aggrCol]) aggrNode

          zipWithM_ insertAggrProject (map snd funs) [1 .. length funs]
          
          -- If the R1 output (that is, the vector which contains the grouping
          -- columns and desribes the group shape) of GroupBy is referenced, we
          -- replace it with a projection on the new VecAggr node.
          r1s <- r1Parents $(v "qg")
          if length r1s > 0
            then do
              r1ProjectNode <- insert $ UnOp (ProjectL [1 .. length groupingCols]) aggrNode
              mapM_ (\r1 -> replace r1 r1ProjectNode) r1s
            else return () |])

