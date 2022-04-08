{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Helium.StaticAnalysis.Inferencers.OutsideInX.TopConversion(
        monoTypeToTp
    ,   tpSchemeListDifference
    ,   bindVariables
    ,   typeToPolytype
    ,   typeToMonoType
    ,   getTypeVariablesFromMonoType
    ,   tpSchemeToMonoType
    ,   tpSchemeToPolyType
    ,   tpSchemeToPolyType'
    ,   polyTypeToTypeScheme
    ,   classEnvironmentToAxioms
    ,   typeSynonymsToAxioms
    ,   getTypeVariablesFromPolyType
    ,   getTypeVariablesFromPolyType'
    ,   getTypeVariablesFromConstraints
    ,   getConstraintFromPoly
    ,   polytypeToMonoType
    ,   unbindPolyType
    ,   importEnvironmentToTypeFamilies
    ,   tpToMonoType
    ,   TypeFamilies
    ,   tfInstanceInfoToAxiom
    ,   tfInstanceInfoToMonoTypes
    ,   typeSynonymsToTypeFamilies
    ,   typeFamiliesToAxioms
    ,   unbindPolyTypeSep
) where

import Unbound.Generics.LocallyNameless hiding (Name, freshen)
import qualified Unbound.Generics.LocallyNameless as UGL
--import Unbound.Generics.LocallyNameless.Types (GenBind(..))
import Unbound.Generics.LocallyNameless.Bind
import Top.Types.Classes
import Top.Types.Primitive
import Top.Types.Quantification
import Top.Types.Qualification
import Top.Types.Substitution
import Top.Types.Schemes
import Helium.Syntax.UHA_Syntax
import Helium.Syntax.UHA_Utils
import Helium.Utils.Utils
import Helium.StaticAnalysis.Miscellaneous.TypeConversion
import Helium.StaticAnalysis.Miscellaneous.ConstraintInfoOU
import Helium.StaticAnalysis.Inferencers.OutsideInX.Rhodium.RhodiumTypes
import Helium.StaticAnalysis.Inferencers.OutsideInX.Rhodium.RhodiumGenerics
import Helium.ModuleSystem.ImportEnvironment
import qualified Data.Map as M
import Control.Monad.State
import Control.Arrow
import Data.Maybe 
import Data.List
import Debug.Trace
import Data.Functor.Identity

import Unbound.Generics.LocallyNameless.Fresh
import Unbound.Generics.LocallyNameless.Operations hiding (freshen)
import Rhodium.TypeGraphs.GraphInstances()
import Helium.StaticAnalysis.StaticChecks.TypeFamilyInfos (TFInstanceInfo (tfiName, argTypes, defType, tfiType, preCompat), splitBy, TFType (Closed), TFInstanceInfos, ordPrio, buildInjectiveEnv, TFDeclInfo (argNames), insertVarNameMap)

type TypeFamilies = [(String, Int)]

bindVariables :: [(String, TyVar)] -> PolyType ConstraintInfo -> PolyType ConstraintInfo
bindVariables = flip (foldr (\(s, t) p -> PolyType_Bind s (bind t p)))

integer2Name :: Integer -> UGL.Name a
integer2Name = makeName ""

monoTypeToTp :: MonoType -> Tp
monoTypeToTp (MonoType_App (MonoType_Con "[]" _) (MonoType_Con "Char" _) _) = TCon "String"
monoTypeToTp (MonoType_Var _ n _) = TVar (fromInteger (name2Integer n))
monoTypeToTp (MonoType_Con n _)   = TCon n
monoTypeToTp (MonoType_App f a _) = TApp (monoTypeToTp f) (monoTypeToTp a)
monoTypeToTp (MonoType_Fam s a _) = foldl TApp (TCon s) (map monoTypeToTp a)

polyTypeToTypeScheme :: PolyType ConstraintInfo -> TpScheme
polyTypeToTypeScheme p = let
        (quant, preds, tp) = runFreshM (ptHelper p)
        qualifiedType = preds .=>. tp
        in bindTypeVariables quant qualifiedType
    where
        constraintToPredicate :: Constraint ConstraintInfo -> [Predicate]
        constraintToPredicate (Constraint_Class c mts _) = map (\m -> Predicate c $ monoTypeToTp m) mts
        ptHelper :: PolyType ConstraintInfo -> FreshM ([Int], [Predicate], Tp)
        ptHelper (PolyType_Bind s b) = do
            (t, p) <- unbind b
            (qs, ps, tp) <- ptHelper p
            return (fromInteger (name2Integer t) : qs, ps, tp)
        ptHelper (PolyType_Mono cs m) = do
            return ([], concatMap constraintToPredicate cs, monoTypeToTp m)

typeSynonymsToTypeFamilies :: TypeSynonymEnvironment -> TypeFamilies
typeSynonymsToTypeFamilies = map (\(n, (i, _)) -> (show n, i)) . M.assocs

importEnvironmentToTypeFamilies :: ImportEnvironment -> TypeFamilies
importEnvironmentToTypeFamilies = map (\(n, (i, _)) -> (show n, i)) . M.assocs . typeSynonyms

tpSchemeListDifference :: M.Map Name TpScheme -> M.Map Name TpScheme -> M.Map Name  ((Tp, String), (Tp, String))
tpSchemeListDifference m1 m2 = M.map fromJust $ M.filter isJust $ M.intersectionWith eqTpScheme m1 m2

eqTpScheme :: TpScheme -> TpScheme -> Maybe ((Tp, String), (Tp, String))
eqTpScheme t1@(Quantification (is1, qmap1, tp1)) t2@(Quantification (is2, qmap2, tp2)) = let
    subs = M.fromList $ zipWith (\orig rep -> (orig, TVar rep)) is2 is1
    tp2r = subs |-> unqualify tp2
    tp1r = unqualify tp1
    in if freshen (0 :: Int) tp1r == freshen 0 tp2r  then Nothing else Just ((tp1r, "Orig"), (tp2r, "OutsideIn(X)"))

typeToPolytype :: TypeFamilies -> Integer -> Type -> (PolyType ConstraintInfo, Integer, [(String, TyVar)])
typeToPolytype fams bu t = let
    (cs, tv, mt) = typeToMonoType fams t
    (mapping, (mt', bu')) = freshenWithMapping [] bu mt
    mappingSub :: [(TyVar, MonoType)]
    mappingSub = map (\(i, v) -> (integer2Name i, var (integer2Name v))) mapping
    cs' = map (substs mappingSub) cs 
    qmap = getQuantorMap (makeTpSchemeFromType t)
    mapping' :: [(String, TyVar)]
    mapping' =  map (\(o, s) -> (fromMaybe (internalError "TopConversion.hs" "typeToPolytype" "Type variable not found") $ lookup (fromInteger o) qmap, integer2Name s)) mapping
    vars = getTypeVariablesFromMonoType mt'
    in (foldr (\(s, b) p -> PolyType_Bind s (bind b p)) (PolyType_Mono cs' mt') mapping', bu', mapping')

typeToMonoType :: TypeFamilies -> Type -> ([Constraint ConstraintInfo], [(String, TyVar)], MonoType)
typeToMonoType fams = tpSchemeToMonoType fams . makeTpSchemeFromType

tpSchemeToPolyType :: TypeFamilies -> TpScheme -> PolyType ConstraintInfo
tpSchemeToPolyType fams = fst . tpSchemeToPolyType' fams []

tpSchemeToPolyType' :: TypeFamilies -> [String] -> TpScheme -> (PolyType ConstraintInfo, [(String, TyVar)])
tpSchemeToPolyType' fams restricted tps = let 
        (cs, tv, mt) = tpSchemeToMonoType fams tps
        pt' = PolyType_Mono cs mt
        pt = bindVariables tv pt'
        --pt = bindVariables (map snd tv) pt'
    in (pt, tv) 

tpSchemeToMonoType :: TypeFamilies -> TpScheme -> ([Constraint ConstraintInfo], [(String, TyVar)], MonoType)
tpSchemeToMonoType fams tps = 
    let 
        qmap = map (\(v, n) -> (n, integer2Name (toInteger v))) $ getQuantorMap tps
        tyvars = map (\x -> (TVar x, integer2Name (toInteger x))) $ quantifiers tps
        qs :: [Predicate]
        (qs, tp) = split $ unquantify tps
        monoType = tpToMonoType fams (getQuantorMap tps) tp
        convertPred (Predicate c v) = case lookup v tyvars of
            Nothing -> internalError "TopConversion" "tpSchemeToMonoType" "Type variable not found"
            Just tv -> Constraint_Class c [var tv] (Just emptyConstraintInfo)
        in (map convertPred qs , qmap, monoType)

tpToMonoType :: TypeFamilies -> [(Int, String)] -> Tp -> MonoType
tpToMonoType fams qm (TVar v) = case lookup v qm of 
                                    Just s -> MonoType_Var (Just s) (integer2Name $ toInteger v) Nothing
                                    Nothing -> var (integer2Name $ toInteger v)
tpToMonoType fams qm (TCon n) | isTypeFamily fams (TCon n) = MonoType_Fam n [] Nothing
                              | otherwise = MonoType_Con n Nothing
tpToMonoType fams qm ta@(TApp f a)  | isTypeFamily fams ta = let 
                                                m1 = tpToMonoType fams qm f
                                                m2 = tpToMonoType fams qm a
                                                (MonoType_Con famName _, params) = separateMt (MonoType_App m1 m2 Nothing)
                                                in MonoType_Fam famName params Nothing
                                    | otherwise = MonoType_App (tpToMonoType fams qm f) (tpToMonoType fams qm a) Nothing

tpDepth :: Tp -> Int
tpDepth (TVar _) = 0
tpDepth (TCon _) = 0
tpDepth (TApp f _) = 1 + tpDepth f

tpCons :: Tp -> Maybe String
tpCons (TVar _) = Nothing
tpCons (TCon n) = Just n
tpCons (TApp f _) = tpCons f

isTypeFamily :: TypeFamilies -> Tp -> Bool
isTypeFamily fams tp = let
    depth = tpDepth tp
    fFams = filter (\x -> snd x == depth) fams
    cons = tpCons tp
    in any (\(x, _) -> Just x == cons) fFams

getTypeVariablesFromPolyType :: PolyType ConstraintInfo -> [TyVar]
getTypeVariablesFromPolyType (PolyType_Bind _ (B p t)) = p : getTypeVariablesFromPolyType t
getTypeVariablesFromPolyType _ = []

getTypeVariablesFromPolyType' :: PolyType ConstraintInfo -> [TyVar]
getTypeVariablesFromPolyType' (PolyType_Mono _ m) = fvToList m
getTypeVariablesFromPolyType' _ = []

getTypeVariablesFromMonoType :: MonoType -> [TyVar]
getTypeVariablesFromMonoType (MonoType_Var _ v _) = [v]
getTypeVariablesFromMonoType (MonoType_Fam _ ms _) = nub $ concatMap getTypeVariablesFromMonoType ms
getTypeVariablesFromMonoType (MonoType_Con _ _) = []
getTypeVariablesFromMonoType (MonoType_App f a _) = nub $ getTypeVariablesFromMonoType f ++ getTypeVariablesFromMonoType a

getTypeVariablesFromConstraints :: Constraint ConstraintInfo -> [TyVar]
getTypeVariablesFromConstraints (Constraint_Unify v1 v2 _) = nub $ getTypeVariablesFromMonoType v1 ++ getTypeVariablesFromMonoType v2
getTypeVariablesFromConstraints (Constraint_Class _ vs _) = nub $ concatMap getTypeVariablesFromMonoType vs

getConstraintFromPoly :: PolyType ConstraintInfo -> [Constraint ConstraintInfo]
getConstraintFromPoly (PolyType_Bind _ (B _ t)) = getConstraintFromPoly t
getConstraintFromPoly (PolyType_Mono cs _) = cs

polytypeToMonoType :: [(Integer, Integer)] -> Integer -> PolyType ConstraintInfo -> ([(Integer, Integer)], ((MonoType, [Constraint ConstraintInfo]), Integer))
polytypeToMonoType mapping bu (PolyType_Bind s b) = let
    ((_, x), bu') = contFreshMRes (unbind b) (trace ("S: " ++ show s) bu)
    in polytypeToMonoType mapping bu' x
polytypeToMonoType mapping bu (PolyType_Mono cs m) = freshenWithMapping mapping bu (m, cs)
    
classEnvironmentToAxioms :: TypeFamilies -> ClassEnvironment -> [Axiom ConstraintInfo] 
classEnvironmentToAxioms fams env = concatMap (uncurry classToAxioms) (M.toList env)
    where
        classToAxioms :: String -> Class -> [Axiom ConstraintInfo]
        classToAxioms s (superclasses, instances) = map instanceToAxiom instances
        instanceToAxiom :: Instance -> Axiom ConstraintInfo
        instanceToAxiom (Predicate cn v, supers) = let
                vars = map (integer2Name  . toInteger) (ftv v ++ concatMap (\(Predicate _ v) -> ftv v) supers)
                superCons = map (\(Predicate c v) -> Constraint_Class c [tpToMonoType fams [] v] Nothing) supers
            in Axiom_Class (bind vars (superCons, cn, [tpToMonoType fams [] v]))

           -- type TypeSynonymEnvironment      = M.Map Name (Int, Tps -> Tp)

typeSynonymsToAxioms :: TypeSynonymEnvironment -> [Axiom ConstraintInfo]
typeSynonymsToAxioms env = concatMap tsToAxioms $ M.toList env
            where
                tsToAxioms (name, (size, f)) = let
                        fams = map (\(n, (i, _)) -> (show n, i)) $ M.assocs env
                        vars = take size [0..]
                        tpVars = map TVar vars
                        tp = f tpVars
                        mt = tpToMonoType fams [] tp
                        mtVars = map (integer2Name . toInteger) vars
                        
                        unifyAxiom = Axiom_Unify (bind mtVars (MonoType_Fam (show name) (map var mtVars) Nothing, mt)) Nothing
                    in [Axiom_Injective (show name) vars, unifyAxiom]

-- For use during static checks
tfInstanceInfoToAxiom :: TypeFamilies -> Maybe TFDeclInfo -> TFInstanceInfo -> Axiom ConstraintInfo
tfInstanceInfoToAxiom fams dInfo iInfo = let
    famType = buildUHATf (tfiName iInfo) (argTypes iInfo)
    (_, lhsenv, lhsMonoType) = typeToMonoType fams famType
    (_, _, rhsMonoType) = typeToMonoType fams $ defType iInfo
    rhsMonoType' = updateRhs lhsenv rhsMonoType

    axVars = fvToList lhsMonoType
    iInfo' = insertVarNameMap (M.fromList $ zip [0..] (maybe [] argNames dInfo)) iInfo

    in Axiom_Unify (bind axVars (lhsMonoType, rhsMonoType')) $ Just iInfo'

closedTFInstanceInfoToAxiom :: TypeFamilies -> Maybe TFDeclInfo ->  TFInstanceInfo -> Axiom ConstraintInfo
closedTFInstanceInfoToAxiom fams dInfo iInfo = let
    famType = buildUHATf (tfiName iInfo) (argTypes iInfo)
    (_, lhsenv, lhsMonoType) = typeToMonoType fams famType
    (_, _, rhsMonoType) = typeToMonoType fams $ defType iInfo
    rhsMonoType' = updateRhs lhsenv rhsMonoType

    axVars = fvToList lhsMonoType
    iInfo' = insertVarNameMap (M.fromList $ zip [0..] (maybe [] argNames dInfo)) iInfo

    in Axiom_Unify (bind axVars (lhsMonoType, rhsMonoType')) $ Just iInfo'


-- For use during static checks
tfInstanceInfoToMonoTypes :: TypeFamilies -> TFInstanceInfo -> (MonoType, MonoType)
tfInstanceInfoToMonoTypes fams iInfo = let
    
    (_, lhsenv, lhsMonoType) = typeToMonoType fams $ buildUHATf (tfiName iInfo) (argTypes iInfo)
    (_, _, rhsMonoType) = typeToMonoType fams (defType iInfo)
    rhsMonoType' = updateRhs lhsenv rhsMonoType

    in (lhsMonoType, rhsMonoType')

-- Main families to axiom conversion function
typeFamiliesToAxioms :: TypeFamilies -> ImportEnvironment -> [Axiom ConstraintInfo]
typeFamiliesToAxioms fams env = let
    injEnv = buildInjectiveEnv $ M.elems $ typeFamDeclEnvironment env
    declEnv = typeFamDeclEnvironment (trace ("INJENV: " ++ show injEnv) env)
    tfInstances = M.assocs $ typeFamInstanceEnvironment env
    (closed, other) = splitBy (\(_,i:_) -> tfiType i == Closed) tfInstances

    closedAxs = map (createClosedGroup declEnv) closed
    injAxioms = map (uncurry Axiom_Injective) $ filter (\(_, idx) -> not (null idx)) $ M.assocs injEnv
    openAxs = concatMap (\(n, insts) -> map (tfInstanceInfoToAxiom fams (Just $ declEnv M.! n)) insts) other
    in closedAxs ++ injAxioms ++ openAxs
    where
        createClosedGroup :: TypeFamDeclEnvironment -> (Name, TFInstanceInfos) -> Axiom ConstraintInfo
        createClosedGroup declEnv (n, infos) = let
            axs = map (closedTFInstanceInfoToAxiom fams (Just $ declEnv M.! n)) (sortBy ordPrio infos)
            in Axiom_ClosedGroup (show n) axs

-- Ensures that the right hand side vars are updated to coincide with the vars in the left hand side
-- (For type families that is)
updateRhs :: [(String, TyVar)] -> MonoType -> MonoType
updateRhs env v@(MonoType_Var (Just s) _ ri) = case lookup s env of
    Nothing -> v
    Just tv -> MonoType_Var (Just s) tv ri
updateRhs _   c@(MonoType_Con _ _)           = c
updateRhs env (MonoType_Fam n mts rs)        = MonoType_Fam n (map (updateRhs env) mts) rs
updateRhs env (MonoType_App mt1 mt2 ri)      = MonoType_App (updateRhs env mt1) (updateRhs env mt2) ri
updateRhs _   mtv                            = mtv

-- typeFamilyToMonoType :: TypeFamilies -> Name -> Types -> Type -> (MonoTypes, MonoType)
-- typeFamilyToMonoType fams n args def = let
--     (mtArgs, _) = runState (stateArgsToMonoType fams args) (0 :: Integer)

--     in undefined

-- stateArgsToMonoType :: TypeFamilies -> [(Int, String)] -> Types -> State Integer [(MonoType, [(String, TyVar)])]
-- stateArgsToMonoType fams qmap (arg:args) = do
--     i <- get
--     let (_, tv, mt) = typeToMonoType fams arg
    
--     put newI
--     mts <- stateArgsToMonoType fams args
--     return $ (fmt,tv):mts
-- stateArgsToMonoType _ _ [] = return []


instance Freshen MonoType Integer where
    freshenWithMapping mapping n mt = (\(mt', (n', m'))->(map (name2Integer *** name2Integer) m', (mt', n'))) $ 
        runState (freshenHelperMT mt) (n, map (integer2Name *** integer2Name) mapping) 
        
freshenHelperMT :: MonoType -> State (Integer, [(TyVar, TyVar)]) MonoType
freshenHelperMT (MonoType_Var s v' ri) =  
    do
        (uniq, mapping) <- get
        case lookup v' mapping of
            Just v -> return (MonoType_Var s v ri)
            Nothing -> put (uniq + 1, (v', integer2Name uniq) : mapping) >> return (MonoType_Var s (integer2Name uniq) ri)
freshenHelperMT c@(MonoType_Con _ _) = return c
freshenHelperMT  (MonoType_App f a ri) = do
    f' <- freshenHelperMT f
    a' <- freshenHelperMT a
    return (MonoType_App f' a' ri)
freshenHelperMT (MonoType_Fam s xs ri) = do
    (n, mapping) <- get
    let (mapping', (xs', n')) = freshenWithMapping (map (name2Integer *** name2Integer) mapping) n xs
    put (n', map (integer2Name *** integer2Name) mapping')
    return (MonoType_Fam s xs' ri)

instance Freshen (PolyType ConstraintInfo) Integer where
    freshenWithMapping mapping n mt = (\(mt', (n', m'))->(map (name2Integer *** name2Integer) m', (mt', n'))) $ 
        runState (freshenHelper mt) (n, map (integer2Name *** integer2Name) mapping) 
        where
            freshenHelper :: PolyType ConstraintInfo -> State (Integer, [(TyVar, TyVar)]) (PolyType ConstraintInfo)
            freshenHelper (PolyType_Mono cs m) = do
                m' <- freshenHelperMT m
                (uniq, mapping) <- get
                let cs' = map (substs (map (\(t, v) -> (t, var v)) mapping)) cs
                return (PolyType_Mono cs' m')
            freshenHelper (PolyType_Bind s b) = do
                (uniq, mapping) <- get
                let ((p, t), uniq') = contFreshMRes (unbind b) uniq
                let p' = integer2Name $ uniq' + 1
                put (uniq' + 2, (p, p') : mapping)
                t' <- freshenHelper t
                return (PolyType_Bind s (bind p' t'))

instance Freshen TyVar Integer where
    freshenWithMapping mapping n v = let 
        vi = name2Integer v
        in case lookup vi mapping of
                Nothing -> ((vi, n) : mapping, (integer2Name n, n + 1))
                Just v' -> (mapping, (integer2Name v', n))

instance Freshen Char Integer where
    freshenWithMapping mapping n c = (mapping, (c, n))

instance (Freshen a c, Freshen b c) => Freshen (a, b) c where
    freshenWithMapping mapping n (x, y) = let
        (mapping', (x', b)) = freshenWithMapping mapping n x
        (mapping'', (y', b')) = freshenWithMapping mapping' b y
        in (mapping'', ((x', y'), b')) 

instance (Freshen a d, Freshen b d, Freshen c d) => Freshen (a, b, c) d where
    freshenWithMapping mapping n (x, y, z) = let
        (mapping', (x', b)) = freshenWithMapping mapping n x
        (mapping'', (y', b')) = freshenWithMapping mapping' b y
        (mapping''', (z', b'')) = freshenWithMapping mapping'' b' z
        in (mapping'', ((x', y', z'), b''))         


instance Freshen (Constraint ConstraintInfo) Integer where
    freshenWithMapping mapping n (Constraint_Class cn vs ci) = let 
        (mapping', (vs', n')) = freshenWithMapping mapping n vs
        in (mapping', (Constraint_Class cn vs' ci, n'))
    freshenWithMapping mapping n (Constraint_Unify v1 v2 ci) = let
        (mapping', (v1', n')) = freshenWithMapping mapping n v1
        (mapping'', (v2', n'')) = freshenWithMapping mapping' n' v2
        in (mapping'', (Constraint_Unify v1' v2' ci, n''))


contFreshMRes :: FreshM a -> Integer -> (a, Integer)
contFreshMRes i = runIdentity . contFreshMTRes i

contFreshMTRes :: Monad m => FreshMT m a -> Integer -> m (a, Integer)
contFreshMTRes (FreshMT m) = runStateT m

unbindPolyType :: PolyType ConstraintInfo -> PolyType ConstraintInfo
unbindPolyType x = runFreshM $ unbindPolyType' x

unbindPolyType' :: PolyType ConstraintInfo -> FreshM (PolyType ConstraintInfo)
unbindPolyType' (PolyType_Bind s b) = do
    (t, p) <- unbind b
    PolyType_Mono cs p' <- unbindPolyType' p
    return (PolyType_Mono (map (assureRepresentationC t s) cs) (assureRepresentation t s p'))
unbindPolyType' pt = return pt

unbindPolyTypeSep :: PolyType ConstraintInfo -> ([Constraint ConstraintInfo], PolyType ConstraintInfo)
unbindPolyTypeSep = runFreshM . unbindPolyTypeSep'

unbindPolyTypeSep' :: PolyType ConstraintInfo -> FreshM ([Constraint ConstraintInfo], PolyType ConstraintInfo)
unbindPolyTypeSep' (PolyType_Bind s b) = do
    (t, p) <- unbind b
    (cs, PolyType_Mono _ p') <- unbindPolyTypeSep' p
    return (map (assureRepresentationC t s) cs, PolyType_Mono [] p')
unbindPolyTypeSep' (PolyType_Mono cs pt) = return (cs, PolyType_Mono [] pt)

assureRepresentation :: TyVar -> String -> MonoType -> MonoType
assureRepresentation t s (MonoType_Var ms v rs) | v == t = MonoType_Var (Just s) v rs
                                                | otherwise = MonoType_Var ms v rs
assureRepresentation _ _ (MonoType_Con s rs)    = MonoType_Con s rs
assureRepresentation t s (MonoType_App f a rs)  = MonoType_App (assureRepresentation t s f) (assureRepresentation t s a) rs
assureRepresentation t s (MonoType_Fam f ms rs) = MonoType_Fam f (map (assureRepresentation t s) ms) rs

assureRepresentationC :: TyVar -> String -> Constraint ci -> Constraint ci
assureRepresentationC t s (Constraint_Class cn ms ci) = Constraint_Class cn (map (assureRepresentation t s) ms) ci