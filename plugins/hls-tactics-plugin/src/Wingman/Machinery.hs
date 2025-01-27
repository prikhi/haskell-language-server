{-# LANGUAGE RecordWildCards       #-}

module Wingman.Machinery where

import           Class (Class (classTyVars))
import           Control.Lens ((<>~))
import           Control.Monad.Error.Class
import           Control.Monad.Reader
import           Control.Monad.State.Class (gets, modify)
import           Control.Monad.State.Strict (StateT (..))
import           Data.Bool (bool)
import           Data.Coerce
import           Data.Either
import           Data.Foldable
import           Data.Functor ((<&>))
import           Data.Generics (everything, gcount, mkQ)
import           Data.Generics.Product (field')
import           Data.List (sortBy)
import qualified Data.Map as M
import           Data.Maybe (mapMaybe)
import           Data.Monoid (getSum)
import           Data.Ord (Down (..), comparing)
import           Data.Set (Set)
import qualified Data.Set as S
import           Development.IDE.GHC.Compat
import           OccName (HasOccName (occName))
import           Refinery.ProofState
import           Refinery.Tactic
import           Refinery.Tactic.Internal
import           TcType
import           Type
import           Unify
import           Wingman.Judgements
import           Wingman.Simplify (simplify)
import           Wingman.Types


substCTy :: TCvSubst -> CType -> CType
substCTy subst = coerce . substTy subst . coerce


------------------------------------------------------------------------------
-- | Produce a subgoal that must be solved before we can solve the original
-- goal.
newSubgoal
    :: Judgement
    -> Rule
newSubgoal j = do
    unifier <- gets ts_unifier
    subgoal
      $ substJdg unifier
      $ unsetIsTopHole j


------------------------------------------------------------------------------
-- | Attempt to generate a term of the right type using in-scope bindings, and
-- a given tactic.
runTactic
    :: Context
    -> Judgement
    -> TacticsM ()       -- ^ Tactic to use
    -> Either [TacticError] RunTacticResults
runTactic ctx jdg t =
    let skolems = S.fromList
                $ foldMap (tyCoVarsOfTypeWellScoped . unCType)
                $ (:) (jGoal jdg)
                $ fmap hi_type
                $ toList
                $ hyByName
                $ jHypothesis jdg
        tacticState =
          defaultTacticState
            { ts_skolems = skolems
            }
    in case partitionEithers
          . flip runReader ctx
          . unExtractM
          $ runTacticT t jdg tacticState of
      (errs, []) -> Left $ take 50 errs
      (_, fmap assoc23 -> solns) -> do
        let sorted =
              flip sortBy solns $ comparing $ \(ext, (_, holes)) ->
                Down $ scoreSolution ext jdg holes
        case sorted of
          ((syn, _) : _) ->
            Right $
              RunTacticResults
                { rtr_trace = syn_trace syn
                , rtr_extract = simplify $ syn_val syn
                , rtr_other_solns = reverse . fmap fst $ sorted
                , rtr_jdg = jdg
                , rtr_ctx = ctx
                }
          -- guaranteed to not be empty
          _ -> Left []

assoc23 :: (a, b, c) -> (a, (b, c))
assoc23 (a, b, c) = (a, (b, c))


tracePrim :: String -> Trace
tracePrim = flip rose []


------------------------------------------------------------------------------
-- | Mark that a tactic used the given string in its extract derivation. Mainly
-- used for debugging the search when things go terribly wrong.
tracing
    :: Functor m
    => String
    -> TacticT jdg (Synthesized ext) err s m a
    -> TacticT jdg (Synthesized ext) err s m a
tracing s = mappingExtract (mapTrace $ rose s . pure)


------------------------------------------------------------------------------
-- | Mark that a tactic performed recursion. Doing so incurs a small penalty in
-- the score.
markRecursion
    :: Functor m
    => TacticT jdg (Synthesized ext) err s m a
    -> TacticT jdg (Synthesized ext) err s m a
markRecursion = mappingExtract (field' @"syn_recursion_count" <>~ 1)


------------------------------------------------------------------------------
-- | Map a function over the extract created by a tactic.
mappingExtract
    :: Functor m
    => (ext -> ext)
    -> TacticT jdg ext err s m a
    -> TacticT jdg ext err s m a
mappingExtract f (TacticT m)
  = TacticT $ StateT $ \jdg ->
      mapExtract' f $ runStateT m jdg


------------------------------------------------------------------------------
-- | Given the results of running a tactic, score the solutions by
-- desirability.
--
-- NOTE: This function is completely unprincipled and was just hacked together
-- to produce the right test results.
scoreSolution
    :: Synthesized (LHsExpr GhcPs)
    -> Judgement
    -> [Judgement]
    -> ( Penalize Int  -- number of holes
       , Reward Bool   -- all bindings used
       , Penalize Int  -- unused top-level bindings
       , Penalize Int  -- number of introduced bindings
       , Reward Int    -- number used bindings
       , Penalize Int  -- number of recursive calls
       , Penalize Int  -- size of extract
       )
scoreSolution ext goal holes
  = ( Penalize $ length holes
    , Reward   $ S.null $ intro_vals S.\\ used_vals
    , Penalize $ S.size unused_top_vals
    , Penalize $ S.size intro_vals
    , Reward   $ S.size used_vals + length used_user_vals
    , Penalize $ getSum $ syn_recursion_count ext
    , Penalize $ solutionSize $ syn_val ext
    )
  where
    initial_scope = hyByName $ jEntireHypothesis goal
    intro_vals = M.keysSet $ hyByName $ syn_scoped ext
    used_vals = S.intersection intro_vals $ syn_used_vals ext
    used_user_vals = filter (isLocalHypothesis . hi_provenance)
                   $ mapMaybe (flip M.lookup initial_scope)
                   $ S.toList
                   $ syn_used_vals ext
    top_vals = S.fromList
             . fmap hi_name
             . filter (isTopLevel . hi_provenance)
             . unHypothesis
             $ syn_scoped ext
    unused_top_vals = top_vals S.\\ used_vals


------------------------------------------------------------------------------
-- | Compute the number of 'LHsExpr' nodes; used as a rough metric for code
-- size.
solutionSize :: LHsExpr GhcPs -> Int
solutionSize = everything (+) $ gcount $ mkQ False $ \case
  (_ :: LHsExpr GhcPs) -> True


newtype Penalize a = Penalize a
  deriving (Eq, Ord, Show) via (Down a)

newtype Reward a = Reward a
  deriving (Eq, Ord, Show) via a


------------------------------------------------------------------------------
-- | Like 'tcUnifyTy', but takes a list of skolems to prevent unification of.
tryUnifyUnivarsButNotSkolems :: Set TyVar -> CType -> CType -> Maybe TCvSubst
tryUnifyUnivarsButNotSkolems skolems goal inst =
  case tcUnifyTysFG
         (bool BindMe Skolem . flip S.member skolems)
         [unCType inst]
         [unCType goal] of
    Unifiable subst -> pure subst
    _               -> Nothing


updateSubst :: TCvSubst -> TacticState -> TacticState
updateSubst subst s = s { ts_unifier = unionTCvSubst subst (ts_unifier s) }



------------------------------------------------------------------------------
-- | Attempt to unify two types.
unify :: CType -- ^ The goal type
      -> CType -- ^ The type we are trying unify the goal type with
      -> RuleM ()
unify goal inst = do
  skolems <- gets ts_skolems
  case tryUnifyUnivarsButNotSkolems skolems goal inst of
    Just subst ->
      modify $ updateSubst subst
    Nothing -> throwError (UnificationError inst goal)


------------------------------------------------------------------------------
-- | Prefer the first tactic to the second, if the bool is true. Otherwise, just run the second tactic.
--
-- This is useful when you have a clever pruning solution that isn't always
-- applicable.
attemptWhen :: TacticsM a -> TacticsM a -> Bool -> TacticsM a
attemptWhen _  t2 False = t2
attemptWhen t1 t2 True  = commit t1 t2


------------------------------------------------------------------------------
-- | Get the class methods of a 'PredType', correctly dealing with
-- instantiation of quantified class types.
methodHypothesis :: PredType -> Maybe [HyInfo CType]
methodHypothesis ty = do
  (tc, apps) <- splitTyConApp_maybe ty
  cls <- tyConClass_maybe tc
  let methods = classMethods cls
      tvs     = classTyVars cls
      subst   = zipTvSubst tvs apps
  sc_methods <- fmap join
              $ traverse (methodHypothesis . substTy subst)
              $ classSCTheta cls
  pure $ mappend sc_methods $ methods <&> \method ->
    let (_, _, ty) = tcSplitSigmaTy $ idType method
    in ( HyInfo (occName method) (ClassMethodPrv $ Uniquely cls) $ CType $ substTy subst ty
       )


------------------------------------------------------------------------------
-- | Mystical time-traveling combinator for inspecting the extracts produced by
-- a tactic. We can use it to guard that extracts match certain predicates, for
-- example.
--
-- Note, that this thing is WEIRD. To illustrate:
--
-- @@
-- peek f
-- blah
-- @@
--
-- Here, @f@ can inspect the extract _produced by @blah@,_  which means the
-- causality appears to go backwards.
--
-- 'peek' should be exposed directly by @refinery@ in the next release.
peek :: (ext -> TacticT jdg ext err s m ()) -> TacticT jdg ext err s m ()
peek k = tactic $ \j -> Subgoal ((), j) $ \e -> proofState (k e) j


------------------------------------------------------------------------------
-- | Run the given tactic iff the current hole contains no univars. Skolems and
-- already decided univars are OK though.
requireConcreteHole :: TacticsM a -> TacticsM a
requireConcreteHole m = do
  jdg     <- goal
  skolems <- gets ts_skolems
  let vars = S.fromList $ tyCoVarsOfTypeWellScoped $ unCType $ jGoal jdg
  case S.size $ vars S.\\ skolems of
    0 -> m
    _ -> throwError TooPolymorphic


------------------------------------------------------------------------------
-- | The 'try' that comes in refinery 0.3 causes unnecessary backtracking and
-- balloons the search space. This thing just tries it, but doesn't backtrack
-- if it fails.
--
-- NOTE(sandy): But there's a bug! Or at least, something not understood here.
-- Using this everywhere breaks te tests, and neither I nor TOTBWF are sure
-- why.  Prefer 'try' if you can, and only try this as a last resort.
--
-- TODO(sandy): Remove this when we upgrade to 0.4
try'
    :: Functor m
    => TacticT jdg ext err s m ()
    -> TacticT jdg ext err s m ()
try' t = commit t $ pure ()

