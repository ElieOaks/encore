module Optimizer.TypedDesugarer(desugarTypedProgram) where


import Debug.Trace

import Control.Monad.Reader
import Control.Monad.Except
import Control.Monad.State
import Data.Maybe
import Data.List
import Data.Map.Strict(Map)
import qualified Data.Map.Strict as Map
import SystemUtils
import Typechecker.TypeError

-- Modular dependancies
import Identifiers
import AST.AST
import AST.Util
import Identifiers
import qualified AST.Meta as Meta
import Types
import Typechecker.Environment
import Typechecker.TypeError
import AST.PrettyPrinter

desugarTypedProgram :: Program -> Program
desugarTypedProgram p@(Program{classes, traits, functions}) =
    p{classes = map desugarClass classes
     ,traits = map desugarTrait traits
     ,functions = map desugarFunction functions}
    where
      desugarFunction f@(Function{funbody}) =
          f{funbody = desugarExpr funbody}

      desugarTrait t@(Trait{tmethods}) =
          t{tmethods = map desugarMethod tmethods}

      desugarClass c@(Class{cname, cmethods})=
          c{cmethods = map desugarMethod cmethods}

      desugarMethod m =
          m{mbody = desugarExpr (mbody m)}

      desugarExpr ast =
          foldl (\ast opt -> opt ast) ast desugarPasses

-- | The functions in this list will be performed in order during desugaring
desugarPasses :: [Expr -> Expr]
desugarPasses = [boxRemainingFor]

boxRemainingFor = extend boxRemainingFor'
  where
    boxRemainingFor' e
      | isFor e = desugarAndBoxForR' e
      | otherwise = e

-- into listA.flatMap(listB.flatMap(listC.map(fun)))
forDesugared :: Expr -> Expr
forDesugared e@For{emeta, sources, body} =
  let closureRetType = getType e
      collectionType = getType $ collection $ head sources
      callNameList = getCallName e collectionType $ length sources
      revSources = reverse sources
      elemType = getType body
      noBreakBody = changeBreak e
      desugaredFor = nestCalls emeta callNameList revSources noBreakBody elemType closureRetType
  in  desugaredFor
  where
    nestCalls :: Meta.Meta Expr -> [Name] -> [ForSource] -> Expr -> Type -> Type -> Expr
    nestCalls meta (name:_) (fs:[]) body elemType closureRetType  = intoCall meta name fs body elemType closureRetType
    nestCalls meta (name:restOfNames) (fs:restFS) body elemType closureRetType =
      let nestedCall = intoCall meta name fs body elemType closureRetType
      in nestCalls meta restOfNames restFS nestedCall elemType closureRetType

    intoCall :: Meta.Meta Expr -> Name -> ForSource -> Expr -> Type -> Type ->Expr
    intoCall met callName ForSource{fsName, fsTy, collection} bodyOrMethodCall elemType closureRetType =
      if isRefType (getType collection)
      then let param = [intoParam met Val fsName fsTy]
               retType = getRetType callName elemType closureRetType
               elemT= if callName == Name "foreach" || callName == Name "maybeForeach"
                      then []
                      else [elemType]
               arguments = [intoClosure met param retType bodyOrMethodCall]
           in  intoMethodCall met elemT collection callName arguments
       else let param = [intoParam met Val fsName fsTy]
                retType = getRetType callName elemType closureRetType
                elemT=  if callName == Name "foreach" || callName == Name "maybeForeach"
                        then [fromMaybe intType fsTy]
                        else [(fromMaybe intType fsTy), elemType]
                arguments = [intoClosure met param retType bodyOrMethodCall] ++ [collection]
                name = intoQName callName
            in  intoFunctionCall met elemT name arguments

    getCallName For{body} collectionType leng
      | containsBreak body = replicate leng (Name "maybeForeach")
      | (unitType == getType body) || (isRangeObjectType collectionType) = replicate leng (Name "foreach")
      | otherwise = [Name "map"] ++ replicate (leng-1) (Name "flatMap")

    containsBreak exp = not $ null $ AST.Util.filter isBreak exp
    changeBreak For{emeta, body}
      | not (containsBreak body) = body
      | otherwise = let newBody = extend changeBreak' body
                        retUnit = JustData{ e = intoSkip emeta}
                        maybeRetUnit = intoMaybeValue emeta retUnit
                        retMaybeRetUnit = intoReturn emeta maybeRetUnit
                    in intoSeq emeta [newBody, retMaybeRetUnit]
                      where
                        changeBreak' Break{emeta} =
                          let maybeData = intoMaybeValue emeta NothingData
                          in intoReturn emeta maybeData
                        changeBreak' m = m

    getRetType callName elemType closureRetType
      | callName == Name "foreach" = Nothing
      | callName == Name "maybeForeach" = Just $ maybeType unitType
      | callName == Name "map" = Just elemType
      | callName == Name "flatMap" = Just closureRetType
forDesugared m = m

desugarAndBoxFor' :: Expr -> Expr
desugarAndBoxFor' for@For{emeta} =
  let listOfVar = getVariables for
      newExpr
        | null listOfVar = forDesugared for
        | otherwise =
          let listOfVarNames = map (\VarAccess{qname} -> qnlocal qname) listOfVar
              unBoxing = unBox listOfVar
              desugaredForWithFieldAccBody = forDesugared $ varBodyToFieldBody for [] listOfVarNames
              letBod = intoSeq emeta (desugaredForWithFieldAccBody:unBoxing)
          in boxVar emeta listOfVar letBod
  in newExpr

desugarAndBoxForR' :: Expr -> Expr
desugarAndBoxForR' for@For{emeta} =
  let retVarDecl = [([intoVarDecl (Name "__for_return_variable")], intoTypedExpr emeta Null{emeta = Meta.meta (Meta.getPos emeta)} (getType for))]
      retVarAcc = intoVarAccess emeta $ intoQName $ Name "__for_return_variable"
      outerLet = intoLet emeta Var retVarDecl $ intoSeq emeta [newExpr, retVarAcc]
      listOfVar = getVariables for
      newExpr
        | null listOfVar = if unitType == (getType for) || (unitType == getType (body for)) || isMaybeType (getType (body for))
                           then forDesugared for
                           else intoAssignment emeta retVarAcc $ forDesugared for
        | otherwise =
          let listOfVarNames = map (\VarAccess{qname} -> qnlocal qname) listOfVar
              unBoxing = unBox listOfVar
              desugaredFor = if unitType == (getType for) || (unitType == getType (body for)) || isMaybeType (getType (body for))
                             then forDesugared $ varBodyToFieldBody for [] listOfVarNames
                             else intoAssignment emeta retVarAcc (forDesugared $ varBodyToFieldBody for [] listOfVarNames)
              letBod = intoSeq emeta (desugaredFor:unBoxing)
          in boxVar emeta listOfVar letBod
      output
        | unitType == (getType for) || (unitType == getType (body for)) || isMaybeType (getType (body for)) = newExpr
        | otherwise = outerLet
  in output

getVariables :: Expr -> [Expr]
getVariables For{body} = removeDuplicates (fst (filterVar body)) [] []
  where
    removeDuplicates :: [Expr] -> [Name] -> [Expr] -> [Expr]
    removeDuplicates [] _ finalList = finalList
    removeDuplicates (e@VarAccess{qname}:expr) listOfNames finalList
      | (qnlocal qname) `elem` listOfNames = removeDuplicates expr listOfNames finalList
      | otherwise = removeDuplicates expr ((qnlocal qname):listOfNames) (e:finalList)
    removeDuplicates (_:expr) listOfNames finalList = undefined

    filterVar :: Expr -> ([Expr], [Name])
    filterVar = foldrExp (\e (acc, declAcc) -> if isNotLocalVar e declAcc
                                               then ((getVar e):acc, declAcc)
                                               else if isLet e
                                                    then (acc, (getDecls e) ++ declAcc)
                                                    else (acc, declAcc)) ([], [])
                     where
                       isNotLocalVar Assign{lhs = VarAccess{qname}} decl = not $ (Name (show (qnlocal qname))) `elem` decl
                       isNotLocalVar _ decl = False
                       isLet Let{} = True
                       isLet _ = False
                       getVar Assign{lhs} = lhs
                       getDecls Let{decls} = concatMap getDecls' $ fst $ unzip decls
                       getDecls' declList = map getDecl declList
                       getDecl VarNoType{varName} = varName
                       getDecl VarType{varName}= varName


varBodyToFieldBody body declList boxedVarList = extend (varBodyToFieldBody' declList boxedVarList) body
  where
    varBodyToFieldBody' declList boxedVarList v@VarAccess{qname}
      | isLocalVar v declList && isBoxedVar v boxedVarList = varAccToFieldAcc v
      | otherwise = v
    varBodyToFieldBody' declList boxedVarList l@Let{decls}  = varBodyToFieldBody l (getDecls l ++ declList) boxedVarList
    varBodyToFieldBody' declList boxedVarList m  = m
    isLocalVar VarAccess{qname} decl = not $ (Name (show (qnlocal qname))) `elem` decl
    isBoxedVar VarAccess{qname} boxedNameList = (qnlocal qname) `elem` boxedNameList
    getDecls Let{decls} = concatMap getDecls' $ fst $ unzip decls
    getDecls' declList = map getDecl declList
    getDecl VarNoType{varName} = varName
    getDecl VarType{varName}= varName

    varAccToFieldAcc VarAccess{emeta, qname} =
      let boxQname = intoQName (Name ("__box_mutable__" ++ show (qnlocal qname)))
          boxVarAcc = intoVarAccess emeta boxQname
      in intoFieldAccess emeta boxVarAcc (Name "value")


boxVar meta listOfVar body =
  intoLet meta Var (makeDecls meta listOfVar) body
  where
    makeDecls meta varAccess = map (makeDecl meta) varAccess
    makeDecl emeta v@VarAccess{qname} =
      let box = boxNewWithInit emeta [getType v] [v]
          variableDecl = intoVarDecl $ Name ("__box_mutable__" ++ show (qnlocal qname))
      in  ([variableDecl], box)

unBox varAccList = map (unBoxVar) varAccList
  where unBoxVar VarAccess{emeta, qname} = intoAssignment emeta (intoVarAccess emeta qname) (fieldAccessRhs emeta qname)
        boxQname qname = intoQName (Name ("__box_mutable__" ++ show (qnlocal qname)))
        boxVarAcc emeta qname = intoVarAccess emeta (boxQname qname)
        fieldAccessRhs emeta qname = intoFieldAccess emeta (boxVarAcc emeta qname) (Name "value")

intoSkip meta =
  Skip{emeta = Meta.meta (Meta.getPos meta)}

intoReturn meta value =
  Return{emeta = Meta.meta (Meta.getPos meta)
        ,val = value}

intoMaybeValue meta mValue =
  MaybeValue{emeta = Meta.meta (Meta.getPos meta)
            ,mdt = mValue}

intoVarAccess meta name =
  VarAccess{emeta = Meta.meta (Meta.getPos meta)
           ,qname = name}

intoClosure meta parameters mty body =
  Closure {emeta = Meta.meta (Meta.getPos meta)
          ,eparams = parameters
          ,mty = mty
          ,body = body}

intoParam emetaP mutP nameP maybeTyP =
  Param {pmeta = Meta.meta (Meta.getPos emetaP)
        ,pmut = mutP
        ,pname = nameP
        ,ptype = fromMaybe intType maybeTyP
        ,pdefault = Nothing}

intoFunctionCall meta typeArg name arguments =
  FunctionCall {emeta = meta
               ,typeArguments = typeArg
               ,qname = name
               ,args = arguments}

intoQName name =
  QName{qnspace = Nothing
       ,qnsource = Nothing
       ,qnlocal = name}

intoMethodCall meta typeArg object nam arguments =
  MethodCall {emeta = meta,
              typeArguments = typeArg,
              target = object,
              name = nam,
              args = arguments}

intoAssignment meta left right =
  Assign {emeta = Meta.meta (Meta.getPos meta),
          lhs = left,
          rhs = right}

intoFieldAccess meta object nam =
  FieldAccess{ emeta = Meta.meta (Meta.getPos meta),
               target = object,
               name = nam}

intoSeq meta listOfExpr =
  Seq {emeta = meta,
       eseq = listOfExpr}

boxNewWithInit meta parameters arguments =
  NewWithInit{emeta = Meta.meta (Meta.getPos meta),
              ty = boxObjectType parameters,
              args = arguments}

intoVarDecl name =
  VarNoType{varName = name}

intoVarDeclType name ty =
  VarType{varName = name, varType = ty}

intoLet meta mut varDecls body =
  Let {emeta = meta,
      mutability = mut,
      decls = varDecls,
      body = body}

intoTypedExpr meta body ty =
  TypedExpr {emeta = Meta.meta (Meta.getPos meta),
             body = body,
             ty   = ty}
