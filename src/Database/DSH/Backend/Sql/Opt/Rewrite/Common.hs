module Database.DSH.Backend.Sql.Opt.Rewrite.Common where

import qualified Data.IntMap                                   as M

import           Database.Algebra.Dag.Common
import           Database.Algebra.Table.Lang

import           Database.DSH.Backend.Sql.Vector
import           Database.DSH.Common.QueryPlan
import           Database.DSH.Common.Opt

import           Database.DSH.Backend.Sql.Opt.Properties.BottomUp
import           Database.DSH.Backend.Sql.Opt.Properties.TopDown
import           Database.DSH.Backend.Sql.Opt.Properties.Types

  -- Type abbreviations for convenience
type TARewrite p = Rewrite TableAlgebra (Shape TADVec) p
type TARule p = Rule TableAlgebra p (Shape TADVec)
type TARuleSet p = RuleSet TableAlgebra  p (Shape TADVec)
type TAMatch p = Match TableAlgebra p (Shape TADVec)

inferBottomUp :: TARewrite (NodeMap BottomUpProps)
inferBottomUp = infer inferBottomUpProperties

inferAll :: TARewrite (NodeMap AllProps)
inferAll = do
  to <- topsort
  buPropMap <- infer inferBottomUpProperties
  props <- infer (inferAllProperties buPropMap to)
  return props

noProps :: Monad m => m (M.IntMap a)
noProps = return M.empty
