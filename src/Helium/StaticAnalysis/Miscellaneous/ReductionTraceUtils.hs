{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
module Helium.StaticAnalysis.Miscellaneous.ReductionTraceUtils where

import Rhodium.TypeGraphs.GraphProperties (CompareTypes, HasTypeGraph, HasGraph (getGraph))
import Helium.StaticAnalysis.Inferencers.OutsideInX.Rhodium.RhodiumTypes (RType (MType), Axiom, TyVar, Constraint (Constraint_Unify), MonoType (MonoType_Fam, MonoType_App, MonoType_Con, MonoType_Var), ReductionTrace, ReductionStep (Step), ReductionType (LeftToRight, CanonReduction, ArgInjection), getMaybeReductionStep, insertReductionStepMaybe)
import Helium.StaticAnalysis.Miscellaneous.ConstraintInfoOU (ConstraintInfo)
import Unbound.Generics.LocallyNameless (Fresh, Subst (subst))
import Rhodium.TypeGraphs.Graph (TGEdge, getGroupFromEdge, getEdgeFromId)
import Helium.StaticAnalysis.Messages.Messages (MessageBlock (MessageString, MessageCompose))
import Rhodium.TypeGraphs.GraphUtils (getSubstTypeFull, getConstraintFromEdge)
import Data.List (groupBy)
import Helium.StaticAnalysis.StaticChecks.TypeFamilyInfos
import Helium.Syntax.UHA_Range (showRange)
import Data.Maybe (fromMaybe)
import Helium.StaticAnalysis.HeuristicsOU.HeuristicsInfo (WithHints(addReduction))
import Rhodium.Blamer.Path (Path, edgeIdFromPath)
import Helium.StaticAnalysis.Miscellaneous.Diagnostics (Diagnostic)
import Data.Bifunctor (second)


buildReductionTrace :: (CompareTypes m (RType ConstraintInfo), Fresh m, HasTypeGraph m (Axiom ConstraintInfo) TyVar (RType ConstraintInfo) (Constraint ConstraintInfo) ConstraintInfo Diagnostic)
                    => TGEdge (Constraint ConstraintInfo) -> MonoType -> m ReductionTrace
buildReductionTrace e mt = case getMaybeReductionStep mt of
      -- If no own reductions, check args of type family for reductions
      Nothing -> case mt of
          MonoType_Fam{} -> buildNestedSteps e mt
          _                    -> return []
      -- else, we build substituted step components from the step we obtain.
      Just (Step after before mconstr rt) -> do
          (MType after') <- if not (isArgInjection rt) then getSubstTypeFull (getGroupFromEdge e) (MType after) else return (MType after)
          (MType before') <- if not (isArgInjection rt) then  getSubstTypeFull (getGroupFromEdge e) (MType before) else return (MType before)
          ih <- buildReductionTrace e before'
          return $ (Step after' before' mconstr rt, 1) : ih

buildNestedSteps :: (CompareTypes m (RType ConstraintInfo), Fresh m, HasTypeGraph m (Axiom ConstraintInfo) TyVar (RType ConstraintInfo) (Constraint ConstraintInfo) ConstraintInfo Diagnostic)
                   => TGEdge (Constraint ConstraintInfo) -> MonoType -> m ReductionTrace
buildNestedSteps e mt  = snd <$> buildNestedSteps' 0 [] e mt
    where
        buildNestedSteps' :: (CompareTypes m (RType ConstraintInfo), Fresh m, HasTypeGraph m (Axiom ConstraintInfo) TyVar (RType ConstraintInfo) (Constraint ConstraintInfo) ConstraintInfo Diagnostic)
                          => Int -> [MonoType] -> TGEdge (Constraint ConstraintInfo) -> MonoType -> m (Int, ReductionTrace)
        buildNestedSteps' i seen e' mt'
          | i > 50 = return (i, [])
          | otherwise =
            case mt' of
                mf@(MonoType_Fam f (m:mts) _) -> do
                  step <- getOneStep e' m
                  case step of
                    Nothing -> do
                        -- diveDeeper dives into the type itself (and recurses)
                        (i', diveDeeper) <- buildNestedSteps' (i+1) [] e' m
                        let resArg = fromMaybe m (getLastTypeInTrace diveDeeper)
                        -- next obtains the next argument of the original type family
                        (i'', next) <- buildNestedSteps' (i'+1) (resArg:seen) e' (MonoType_Fam f mts Nothing)
                        -- setInsideFam takes the recurses in diveDeeper and deposits them back in the original type family.
                        returnLoopSafe i'' $ setInsideFam seen mf diveDeeper ++ next
                    Just (Step after before mconstr rt)
                      | not (isCanonReduction rt) -> do
                          (i', ih) <- buildNestedSteps' (i+1) seen e' (MonoType_Fam f (before:mts) Nothing)
                          returnLoopSafe i' ((Step (MonoType_Fam f (seen++(after:mts)) Nothing) (MonoType_Fam f (seen++(before:mts)) Nothing) mconstr rt, 1) : ih)
                      | otherwise -> buildNestedSteps' (i+1) (m:seen) e' (MonoType_Fam f mts Nothing)
                -- Case for application type
                ma@(MonoType_App mt1 mt2 _) -> do
                  step <- getOneStep e' ma
                  case step of
                    -- No step of its own means we dive into the arguments
                    Nothing -> (\(i', r1) (i'', r2) -> (max i' i'', setInsideApp ma r1 r2)) <$> buildNestedSteps' (i+1) [] e' mt1 <*> buildNestedSteps' (i+1) [] e' mt2
                    -- With a step we continue toplevel
                    Just st@(Step _ before _ rt)
                      | not (isCanonReduction rt) -> second ((st, 1) : ) <$> buildNestedSteps' (i+1) [] e' before
                      | otherwise -> (\(i', r1) (i'', r2) -> (max i' i'', setInsideApp ma r1 r2)) <$> buildNestedSteps' (i+1) [] e' mt1 <*> buildNestedSteps' (i+1) [] e' mt2
                -- Case for constant types
                mc@(MonoType_Con _ _) -> do
                  step <- getOneStep e' mc
                  case step of
                    -- No step means we are done (no recursion options)
                    Nothing -> returnLoopSafe i []
                    -- Otherwise we continue top level
                    Just st@(Step _ before _ rt)
                      | not (isCanonReduction rt) -> second ((st, 1) : ) <$> buildNestedSteps' (i+1) [] e' before
                      | otherwise -> returnLoopSafe i []
                mv@MonoType_Var{} -> do
                  step <- getOneStep e' mv
                  case step of
                    Nothing -> do
                      (MType mv') <- getSubstTypeFull (getGroupFromEdge e') (MType mv)
                      -- If there is no step and we dive deeper, we only do so if the substitution results in a new type.
                      if mv' == mv
                        then returnLoopSafe i []
                        else buildNestedSteps' (i + 1) [] e' mv'
                    -- Otherwise, we continue toplevel
                    Just st@(Step _ before _ rt)
                      | not (isCanonReduction rt) -> second ((st, 1) : ) <$> buildNestedSteps' (i+1) [] e' before
                      | otherwise -> returnLoopSafe i []
                _ -> returnLoopSafe i []

        -- Sets an obtained trace of a type fam argument back in the original type fam trace
        setInsideFam :: [MonoType] -> MonoType -> ReductionTrace -> ReductionTrace
        setInsideFam seen mf@(MonoType_Fam f (_:mts) _) ((Step after before constr rt, _):ss) = let
          afterFam = MonoType_Fam f (seen++(after:mts)) Nothing
          beforeFam = MonoType_Fam f (seen++(before:mts)) Nothing
          famStep = Step afterFam beforeFam constr rt
          in (famStep, 1) : setInsideFam seen mf ss
        setInsideFam _ _ [] = []

        -- Sets an obtained trace of a type app argument back in the original app trace.
        setInsideApp :: MonoType -> ReductionTrace -> ReductionTrace -> ReductionTrace
        setInsideApp (MonoType_App _ mt2 _) ((Step after before constr rt, _):ss1) ss2 = let
          afterApp = MonoType_App after mt2 Nothing
          beforeApp = MonoType_App before mt2 Nothing
          appStep = Step afterApp beforeApp constr rt
          in (appStep, 1) : setInsideApp beforeApp ss1 ss2
        setInsideApp (MonoType_App mt1 _ _) [] ((Step after before constr rt, _):ss1) = let
          afterApp = MonoType_App mt1 after Nothing
          beforeApp = MonoType_App mt1 before Nothing
          appStep = Step afterApp beforeApp constr rt
          in (appStep, 1) : setInsideApp beforeApp [] ss1
        setInsideApp _ [] [] = []

        returnLoopSafe :: (Fresh m, CompareTypes m (RType ConstraintInfo)) => Int -> ReductionTrace ->  m (Int, ReductionTrace)
        returnLoopSafe i rt = if i > 50
          then return (i, [])
          else return (i, rt)



isCanonReduction :: ReductionType -> Bool
isCanonReduction (CanonReduction _) = True
isCanonReduction _                  = False

isArgInjection :: ReductionType -> Bool
isArgInjection (ArgInjection _) = True
isArgInjection _                = False

-- Gets one step.
getOneStep :: (CompareTypes m (RType ConstraintInfo), Fresh m, HasTypeGraph m (Axiom ConstraintInfo) TyVar (RType ConstraintInfo) (Constraint ConstraintInfo) ConstraintInfo Diagnostic)
                  => TGEdge (Constraint ConstraintInfo) -> MonoType -> m (Maybe ReductionStep)
getOneStep _ mt = case getMaybeReductionStep mt of
    Nothing -> return Nothing
    Just (Step after before mconstr rt) -> return $ Just $ Step after before mconstr rt

-- Squashes the trace when similar reduction steps are found.
squashTrace :: ReductionTrace -> ReductionTrace
squashTrace rts = let

    groupedRts = groupBy (\(Step _ _ _ rt1, _) (Step _ _ _ rt2, _) -> rt1 == rt2) rts
    in map buildNewStep groupedRts
    where
        buildNewStep [s] = s
        buildNewStep (s@(Step after _ c rt, _):groupedRt) = let
            (Step _ before _ _, _) = last groupedRt
            in (Step after before c rt, length (s:groupedRt))

-- Gets last type in the trace
getLastTypeInTrace :: ReductionTrace -> Maybe MonoType
getLastTypeInTrace rt = case rt of
  [] -> Nothing
  xs -> let (Step _ before _ _, _) = last xs in Just before

-- Gets first type in the trace
getFirstTypeInTrace :: ReductionTrace -> Maybe MonoType
getFirstTypeInTrace [] = Nothing
getFirstTypeInTrace ((Step after _ _ _, _):_) = Just after

getMaybeStepFromType :: MonoType -> Maybe ReductionStep
getMaybeStepFromType (MonoType_Var _ _ trc) = trc
getMaybeStepFromType (MonoType_App _ _ trc) = trc
getMaybeStepFromType (MonoType_Fam _ _ trc) = trc
getMaybeStepFromType (MonoType_Con _ trc) = trc

substTraceInMt :: (TyVar, MonoType) -> Maybe ReductionStep -> Maybe ReductionStep
substTraceInMt (tv, mt) (Just s) = let
  (Step after before c rt) = s
  recStep = getMaybeStepFromType before
  before' = subst tv mt before
  before'' = insertReductionStepMaybe before' $ substTraceInMt (tv, mt) recStep
  after' = subst tv mt after
  rt' = substRTInTrace (tv, mt) rt
  c' = subst tv mt c
  in Just (Step after' before'' c' rt')
substTraceInMt _ Nothing = Nothing

substRTInTrace :: (TyVar, MonoType) -> ReductionType -> ReductionType
substRTInTrace (tv, mt) (ArgInjection (t1, t2)) = ArgInjection (subst tv mt t1, subst tv mt t2)
substRTInTrace _ rt = rt

hasTrace :: MonoType -> Bool
hasTrace mt = case getMaybeStepFromType mt of
  Nothing -> False
  Just _ -> True

-- Name not entirely fitting, gets the "full" trace among two traces.
getFullTrace :: ReductionTrace -> ReductionTrace -> Maybe (Int, ReductionTrace)
getFullTrace [] [] = Nothing
getFullTrace [] xs = Just (1, xs)
getFullTrace xs [] = Just (0, xs)
getFullTrace [(Step (MonoType_App (MonoType_Con "[]" _) (MonoType_Con "Char" _) _) _ _ _, _)] xs = Just (1, xs)
getFullTrace xs [(Step (MonoType_App (MonoType_Con "[]" _) (MonoType_Con "Char" _) _) _ _ _, _)] = Just (0, xs)
getFullTrace _ _ = Nothing

-- Maps trace to a message block for type error messages.
traceToMessageBlock :: ReductionTrace -> MessageBlock
traceToMessageBlock rts = MessageCompose $ mapToBlock (1 :: Int) rts
    where
        mapToBlock idx ((Step after before _ rt@(LeftToRight (lhs, rhs) tfi), times):rts')
            = MessageCompose
                [
                  MessageString (show idx ++ ". " ++ "Applied\t: " ++ show lhs ++ " = " ++ show rhs)
                , MessageString ("\n   From\t: " ++ showMaybeRange tfi)
                , MessageString ("\n   Step\t: " ++ show after ++ " <- " ++ show before)
                , MessageString ("\n   Reason\t: " ++ showReason rt)
                , MessageString ("\n   Amount\t: " ++ timesToString times)
                , MessageString "\n"
                ]
                : mapToBlock (idx + 1) rts'
        mapToBlock idx ((Step after before (Just constr) rt@(CanonReduction (oa, ob)), times):rts')
            = MessageCompose
                [
                  MessageString (show idx ++ ". " ++ "Old\t: " ++ show constr)
                , MessageString ("\n   Step 1\t: " ++ show oa ++ " <- " ++ show ob)
                , MessageString ("\n   Step 2\t: " ++ show after ++ " <- " ++ show before)
                , MessageString ("\n   New\t: " ++ show oa ++ " ~ " ++ show after)
                , MessageString ("\n   Reason\t: " ++ showReason rt)
                , MessageString ("\n   Amount\t: " ++ timesToString times)
                , MessageString "\n"
                ]
                : mapToBlock (idx + 1) rts'
        mapToBlock idx ((Step after before (Just constr) rt@(ArgInjection (apBef, apAft)), times):rts')
          = MessageCompose
              [
                MessageString (show idx ++ ". " ++ "Applied\t: " ++ show apBef ++ " ~ " ++ show apAft)
              , MessageString ("\n   On\t: " ++ show constr)
              , MessageString ("\n   Step:\t: " ++ show after ++ " <- " ++ show before)
              , MessageString ("\n   Reason\t: " ++ showReason rt)
              , MessageString ("\n   Amount\t: " ++ timesToString times)
              , MessageString "\n"
              ]
              : mapToBlock (idx + 1) rts'
        mapToBlock _ [] = []

        timesToString t = show t ++ " time" ++ if t == 1 then "" else "s"

        showMaybeRange tfi = case tfi of
            Nothing -> "unknown position"
            Just t -> showRange $ tfiRange t

        showReason rt = case rt of
            LeftToRight _ _ -> "left to right application"
            CanonReduction _ -> "injectivity"
            ArgInjection _ -> "argument injection"

getTraceFromTwoTypes :: (CompareTypes m (RType ConstraintInfo), Fresh m, HasTypeGraph m (Axiom ConstraintInfo) TyVar (RType ConstraintInfo) (Constraint ConstraintInfo) ConstraintInfo Diagnostic)
                     => TGEdge (Constraint ConstraintInfo) -> MonoType -> MonoType -> m (Maybe ReductionTrace)
getTraceFromTwoTypes cedge m1 m2 = do
  trc1 <- buildReductionTrace cedge m1
  trc2 <- buildReductionTrace cedge m2

  case getFullTrace trc1 trc2 of
    Just (_, trc) -> return $ Just trc
    Nothing -> return Nothing

buildReductionFromPath :: (CompareTypes m (RType ConstraintInfo), Fresh m, HasTypeGraph m (Axiom ConstraintInfo) TyVar (RType ConstraintInfo) (Constraint ConstraintInfo) ConstraintInfo Diagnostic)
                   => Path m (Axiom ConstraintInfo) TyVar (RType ConstraintInfo) (Constraint ConstraintInfo) ConstraintInfo -> m (ConstraintInfo -> ConstraintInfo)
buildReductionFromPath path = do
  graph <- getGraph
  let ceid = edgeIdFromPath path
  let cedge = getEdgeFromId graph ceid
  --let Constraint_Unify pt1 pt2 _ = getConstraintFromEdge cedge
  case getConstraintFromEdge cedge of
    c@(Constraint_Unify pt1 pt2 _) -> do
      trc <- getTraceFromTwoTypes cedge pt1 pt2
      return $ addReduction trc
    _ -> return id

buildSimpleTraceHint :: ReductionTrace -> (String, MessageBlock)
buildSimpleTraceHint xs = let
  Just firstType = getFirstTypeInTrace xs
  Just lastType = getLastTypeInTrace xs
  in ("reduction", MessageString ((show . show) lastType ++ " reduced to " ++ (show . show) firstType))

buildFullTraceHint :: ReductionTrace -> (String, MessageBlock)
buildFullTraceHint xs = ("full reduction", traceToMessageBlock xs)