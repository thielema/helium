module Helium.CodeGeneration.LLVM.CompileType (compileType, typeSize, toOperand, globalFunctionToOperand, taggedThunkPointer, splitValueFlag, cast, copy, compileCallingConvention) where

import qualified Helium.CodeGeneration.Core.TypeEnvironment as Core
import qualified Helium.CodeGeneration.Iridium.Data as Iridium
import qualified Helium.CodeGeneration.Iridium.Type as Iridium
import qualified Helium.CodeGeneration.Iridium.TypeEnvironment as Iridium
import Helium.CodeGeneration.LLVM.ConstructorLayout
import Helium.CodeGeneration.LLVM.Env (Env (..))
import Helium.CodeGeneration.LLVM.Target
import Helium.CodeGeneration.LLVM.Utils
import LLVM.AST as AST
import LLVM.AST.AddrSpace
import qualified LLVM.AST.CallingConvention as CallingConvention
import LLVM.AST.Constant as Constant
import LLVM.AST.Operand
import LLVM.AST.Type as Type
import Lvm.Common.Id (Id, NameSupply, freshId, idFromString, stringFromId)
import qualified Lvm.Core.Type as Core

compileType :: Env -> Core.Type -> Type
compileType env tp
  | not $ Core.typeIsStrict tp = taggedThunkPointer
compileType env tp = case skipApp $ skipForallAndAnn $ Core.typeNormalizeHead (envTypeEnv env) tp of
  Core.TCon (Core.TConDataType name)
    | name == idFromString "Float" -> FloatingPointType DoubleFP
    | name == idFromString "Int" -> envValueType env
    | name == idFromString "Int16" -> IntegerType 16
    | name == idFromString "Char" -> envValueType env
    | name == idFromString "$UnsafePtr" -> voidPointer
    | name == idFromString "$Trampoline" -> pointer $ FunctionType voidPointer [thunkType, pointer taggedThunkPointer, IntegerType 16] False
    | otherwise -> voidPointer -- NamedTypeReference $ toNamePrefixed "$data_" name
  _ -> voidPointer

typeSize :: Target -> Core.Type -> Int
typeSize target tp
  | tp == Iridium.typeInt16 = 16
  | Core.typeIsStrict tp = targetWordSize target
  | otherwise = 8 + targetWordSize target

skipApp :: Core.Type -> Core.Type
skipApp (Core.TAp t _) = skipApp t
skipApp t = t

skipForallAndAnn :: Core.Type -> Core.Type
skipForallAndAnn (Core.TForall _ t) = skipForallAndAnn t
skipForallAndAnn (Core.TAp (Core.TAnn _ _) t) = skipForallAndAnn t
skipForallAndAnn tp = tp

compileFunctionType :: Env -> Core.FunctionType -> Type
compileFunctionType env (Core.FunctionType args returnType) = pointer $ FunctionType (compileType env $ Core.typeToStrict returnType) argTypes False
  where
    argTypes = [compileType env tp | Right tp <- args]

toOperand :: Env -> Iridium.Variable -> Operand
toOperand env (Iridium.VarLocal (Iridium.Local name t)) = LocalReference (compileType env t) (toName name)
toOperand env (Iridium.VarGlobal (Iridium.GlobalVariable name t))
  | Core.typeIsStrict t = ConstantOperand $ Constant.BitCast (GlobalReference thunkType (toNamePrefixed "thunk$" name)) voidPointer
  | otherwise =
    ConstantOperand $
      Constant.Struct
        Nothing
        True
        [ Constant.BitCast (GlobalReference thunkType (toNamePrefixed "thunk$" name)) voidPointer,
          Constant.Int 1 0 -- false, as the value is not in WHNF
        ]

globalFunctionToOperand :: Env -> Iridium.GlobalFunction -> Operand
globalFunctionToOperand env (Iridium.GlobalFunction name arity tp) = ConstantOperand $ GlobalReference (compileFunctionType env fntype) (toName name)
  where
    fntype = Core.extractFunctionTypeWithArity (envTypeEnv env) arity tp

-- Splits a variable into its value and its tag. Casts to a less-precise type.
splitValueFlag :: Env -> NameSupply -> (Iridium.Variable, Core.Type) -> ([Named Instruction], (Operand, Operand))
splitValueFlag env supply (var, toType)
  | not (Core.typeIsStrict t) =
    ( [ nameValue := AST.ExtractValue operand [0] [],
        nameIsWHNF := AST.ExtractValue operand [1] []
      ],
      -- toType should be non-strict, as it is only allowed to cast to a less-precise type
      ( LocalReference voidPointer nameValue,
        LocalReference boolType nameIsWHNF
      )
    )
  | t == toType' =
    ( [],
      ( operand,
        ConstantOperand $ Int 1 1 -- true
      )
    )
  | otherwise =
    ( cast supply' env operand nameValue t toType',
      ( LocalReference (compileType env toType') nameValue,
        ConstantOperand $ Int 1 1
      )
    )
  where
    t = Iridium.variableType var
    toType' = Core.typeToStrict toType
    operand = toOperand env var
    (nameValue, supply') = freshName supply
    (nameIsWHNF, _) = freshName supply'

copy :: Env -> Operand -> Name -> Core.Type -> [Named Instruction]
copy env operand name tp =
  {- [name := Call
    { tailCallKind = Nothing
    , callingConvention = CallingConvention.C
    , returnAttributes = []
    , function = Right $ ConstantOperand $ GlobalReference (pointer $ FunctionType compiledType [compiledType] False) $ mkName "llvm.ssa_copy"
    , arguments = [(operand, [])]
    , functionAttributes = []
    , metadata = []
    }
  ] -}
  [name := AST.Select (ConstantOperand $ Constant.Int 1 1) operand operand []]
  where
    compiledType = compileType env tp

cast :: NameSupply -> Env -> Operand -> Name -> Core.Type -> Core.Type -> [Named Instruction]
cast supply env fromOperand toName fromType' toType'
  -- Thunks to thunk - all thunks have the same type in LLVM, so this cast is a no-op
  | not fromStrict && not toStrict =
    copy env fromOperand toName toType
  -- Thunk to WHNF - not allowed in a Cast instruction. This should be done with an Eval statement
  | not fromStrict && toStrict =
    error ("cast: Cannot cast from thunk to WHNF: " ++ show fromOperand ++ ", " ++ show toName ++ " " ++ Core.showType fromType ++ " to " ++ Core.showType toType)
  -- Strict to thunk - perform bitcast from fromType to the strict variant of toType,
  -- then wrap the value in a thunk
  | fromStrict && not toStrict =
    let (name, supply') = freshName supply
     in cast supply env fromOperand name fromType (Core.typeToStrict $ Core.TVar 0) -- Cast to voidPointer
          ++ [ toName
                 := AST.InsertValue
                   (ConstantOperand $ Struct Nothing True [Constant.Undef voidPointer, Constant.Int 1 1])
                   (LocalReference voidPointer name)
                   [0]
                   []
             ]
  -- Strict to strict - perform bitcast
  | fromStrict && toStrict =
    cast' supply toName toType
  where
    fromType = Core.typeNormalizeHead (envTypeEnv env) fromType'
    toType = Core.typeNormalizeHead (envTypeEnv env) toType'
    fromStrict = Core.typeIsStrict fromType
    toStrict = Core.typeIsStrict toType
    fromBase = skipApp $ skipForallAndAnn fromType
    toBase = skipApp $ skipForallAndAnn toType
    -- Checks whether a type is represented in LLVM as a pointer type
    isPointer (Core.TCon (Core.TConDataType name)) =
      name /= idFromString "Int"
        && name /= idFromString "Char"
        && name /= idFromString "Float"
    isPointer _ = True
    fromPointer = isPointer fromBase
    toPointer = isPointer toBase
    cast' supply name to
      | fromPointer == toPointer =
        [name := AST.BitCast fromOperand (compileType env $ Core.typeToStrict toType) []]
      | fromPointer =
        if toBase == Core.TCon (Core.TConDataType $ idFromString "Float")
          then
            let (nameInt, _) = freshName supply
             in [ nameInt := AST.PtrToInt fromOperand (envValueType env) [],
                  name := AST.BitCast (LocalReference (envValueType env) nameInt) (compileType env toType) []
                ]
          else [name := AST.PtrToInt fromOperand (envValueType env) []]
      | toPointer =
        if fromBase == Core.TCon (Core.TConDataType $ idFromString "Float")
          then
            let (nameInt, _) = freshName supply
             in [ nameInt := AST.BitCast fromOperand (envValueType env) [],
                  name := AST.IntToPtr (LocalReference (envValueType env) nameInt) (compileType env toType) []
                ]
          else [name := AST.IntToPtr fromOperand (compileType env toType) []]

compileCallingConvention :: Iridium.CallingConvention -> CallingConvention.CallingConvention
compileCallingConvention Iridium.CCC = CallingConvention.C
compileCallingConvention Iridium.CCFast = CallingConvention.Fast
compileCallingConvention Iridium.CCPreserveMost = CallingConvention.PreserveMost
