{-#LANGUAGE NoImplicitPrelude, FlexibleInstances#-}

module LibMu.Builder (
  BuilderState,
  Builder,
  Block,
  Function,
  Error,

  runBuilder,
  flatten,
  emptyBuilderState,

  getTypedef,
  getTypedefs,
  containsType,
  getVarID,
  
  getConstant,
  getConstants,
  containsConst,

  getFuncSig,
  containsFuncSig,

  getFuncDecl,
  containsFuncDecl,

  getGlobal,
  containsGlobal,

  getFuncDef,
  containsFuncDef,

  putFuncSig,
  putFunction,
  putTypeDef,
  putGlobal,
  putExpose,
  putConstant,
  putFuncDecl,

  createVariable,
  createVariables,
  
  createExecClause,
  putBasicBlock,
  withBasicBlock,
  updateBasicBlock,
  putParams,
  
  putBinOp,
  putConvOp,
  putCmpOp,
  putAtomicRMW,
  putCmpXchg,
  putFence,
  putNew,
  putNewHybrid,
  putAlloca,
  putAllocaHybrid,
  setTermInstRet,
  setTermInstThrow,
  putCall,
  putCCall,
  setTermInstTailCall,
  setTermInstBranch,
  setTermInstBranch2,
  putWatchPoint,
  setTermInstWatchPoint,
  putTrap,
  setTermInstTrap,
  setTermInstWPBranch,
  setTermInstSwitch,
  setTermInstSwapStack,
  putNewThread,
  putComminst,
  putLoad,
  putStore,
  putExtractValueS,
  putInsertValueS,
  putExtractValue,
  putInsertValue,
  putShuffleVector,
  putGetIRef,
  putGetFieldIRef,
  putGetElemIRef,
  putShiftIRef,
  putGetVarPartIRef,
  
  putComment,

  putIf,
  putIfElse,
  putIfTrue,
  putWhile,
  
  lift,
  gets,
  get,
  
  Log,
  retType,
  checkExpression,
  checkAssign,
  checkAst,
  checkBuilder,

  PrettyPrint (..),

  Scope(..),
  CallConvention(..),
  UvmType(..),
  SSAVariable(..),
  UvmTypeDef(..),
  FuncSig(..),
  ExceptionClause(..),
  BinaryOp(..),
  CompareOp(..),
  ConvertOp(..),
  AtomicRMWOp(..),
  MemoryOrder(..),
  CurStackClause(..),
  NewStackClause(..),
  Program(..),

  loadStdPrelude,
  loadPrelude
                     ) where

import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Except (ExceptT, throwE, runExceptT)
import           Control.Monad.Trans.State.Strict (State, get, gets, modify, evalState)
import           Control.Monad.Trans.Writer.Strict (WriterT, runWriterT, tell)
import qualified Data.Map.Strict as M
import           LibMu.MuPrelude
import           LibMu.MuSyntax
import           LibMu.PrettyPrint (PrettyPrint (..))
import           LibMu.TypeCheck                  (Log, checkAssign, checkAst,
                                                   checkExpression, retType)
import           Prelude hiding (EQ)
import           Text.Printf (printf)


-- |BuilderState is the state in which the Builder holds all the information to generate a Mu Bundle
-- |Included in this state is the information to generate Variable IDs
data BuilderState = BuilderState {
  builderVarID   :: Int, -- ^Used to generate Variable Id's
  constants      :: M.Map String Declaration, -- ^Holds all constants, Indexed by constant name
  typedefs       :: M.Map String Declaration, -- ^Holds all typedefs, Indexed by type alias
  funcsigs       :: M.Map String Declaration, -- ^Holds all function signatures, indexed by function name ++ version
  funcdecls      :: M.Map String Declaration, -- ^Holds all function declarations, Indexed by function name ++ version
  globals        :: M.Map String Declaration, -- ^Holds all globals, Indexed by variable name
  exposes        :: M.Map String Declaration, -- ^Holds all exposes, Indexed by name
  functionDefs   :: M.Map String Declaration  -- ^Holds all Function Defs, Indexed by function name ++ version
  }

-- |Function Data structure holds (Function Name, Function Verrsion)
-- |This datatype is used to give the programmer some type security when writting code, it ensures that they are using a fucntion instead of a block or variable
-- |Each Function can be uniquly referenced by this datatype 
data Function = Function String  String

-- |Block Data structure holds (Block Name, Parent Function)
data Block = Block String Function

-- |This Pretty Print specification is given to allow debugging of code
instance PrettyPrint (Either Error BuilderState) where
  ppFormat e = case e of
    Left err -> return err
    Right bs -> ppFormat bs

instance PrettyPrint BuilderState where
  ppFormat = ppFormat . flatten

-- |Transform a BuilderState into a Program
flatten :: BuilderState -> Program
flatten (BuilderState _ cons tds fs fdecl gl ex fdefs) = Program $ concat [
        M.elems tds,
        M.elems gl,
        M.elems cons,
        M.elems fdecl,
        M.elems fs,
        M.elems ex,
        M.elems fdefs
        ]

-- |Type Check a BuilderState and return it's log
checkBuilder :: BuilderState -> Log
checkBuilder = checkAst . flatten

-- |an empty BuilderState, an initial seed value for building programs
emptyBuilderState :: BuilderState
emptyBuilderState = BuilderState 0 M.empty M.empty M.empty M.empty M.empty M.empty M.empty

-- |Errors are encoded as error messages
type Error = String
type Builder = ExceptT Error (State BuilderState)

runBuilder :: Builder a -> BuilderState -> Either Error a
runBuilder b s = evalState (runExceptT b) s

loadStdPrelude :: Builder ([UvmTypeDef], [SSAVariable], [FuncSig])
loadStdPrelude = loadPrelude preludeContents
                   
loadPrelude :: MuPrelude -> Builder ([UvmTypeDef], [SSAVariable], [FuncSig])
loadPrelude (types, consts, sigs) = do
  lift $ modify (\pState ->
                  pState {
                    typedefs = M.union (typedefs pState) (M.fromList tPrelude),
                    constants = M.union (constants pState) (M.fromList cPrelude),
                    funcsigs = M.union (funcsigs pState) (M.fromList sPrelude)
                    }
                )
  return (types, map constVariable consts, sigs)
                 where
                   tNames = map uvmTypeDefName types
                   cNames = map (varID . constVariable) consts
                   sNames = map funcSigName sigs
                   tPrelude = zip tNames (map Typedef types)
                   cPrelude = zip cNames consts
                   sPrelude = zip sNames (map FunctionSignature sigs)

getVarID :: Builder Int
getVarID = lift $ gets builderVarID

getTypedef :: String -> Builder UvmTypeDef
getTypedef name = do
  pState <- lift $ gets typedefs
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find typedef: %s" name
    Just (Typedef tDef) -> return tDef
    _ -> throwE $ printf "Found non typedef with specified id: %s" name

getTypedefs :: [String] -> Builder [UvmTypeDef]
getTypedefs = mapM getTypedef

containsType :: String -> Builder Bool
containsType name = do
  pState <- lift $ gets typedefs
  case M.lookup name pState of
    Nothing -> return False
    Just (Typedef _) -> return True
    Just _ -> throwE $ printf "Found non typedef with specified id: %s" name

getConstant :: String -> Builder SSAVariable
getConstant name = do
  pState <- lift $ gets constants
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find constant: %s" name
    Just (ConstDecl var _) -> return var
    _ -> throwE $ printf "Found non constant with specified id: %s" name

getConstants :: [String] -> Builder [SSAVariable]
getConstants = mapM getConstant

containsConst :: String -> Builder Bool
containsConst name = do
  pState <- lift $ gets constants
  case M.lookup name pState of
    Nothing -> return False
    Just (ConstDecl _ _) -> return True
    Just _ -> throwE $ printf "Found non constant with specified id: %s" name

getFuncSig :: String -> Builder FuncSig
getFuncSig name = do
  pState <- lift $ gets funcsigs
  case M.lookup name pState of
   Nothing -> throwE $ printf "Failed to find constant: %s" name
   Just (FunctionSignature sig) -> return sig
   _ -> throwE $ printf "Found non function signature with specified id: %s" name

containsFuncSig :: String -> Builder Bool
containsFuncSig name = do
  pState <- lift $ gets funcsigs
  case M.lookup name pState of
    Nothing -> return False
    Just (FunctionSignature _) -> return True
    Just _ -> throwE $ printf "Found non function signature with specified id: %s" name


getGlobal :: String -> Builder SSAVariable
getGlobal name = do
  pState <- lift $ gets globals
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find global definition: %s" name
    Just (GlobalDef var _) -> return var
    _ -> throwE $ printf "Found non global with specified id: %s" name

containsGlobal :: String -> Builder Bool
containsGlobal name = do
  pState <- lift $ gets globals
  case M.lookup name pState of
    Nothing -> return False
    Just (GlobalDef _ _) -> return True
    Just _ -> return False

getFuncDecl :: String -> Builder FuncSig
getFuncDecl name = do
  pState <- lift $ gets funcdecls
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find funcdecl: %s" name
    Just (FunctionDecl _ sig) -> return sig
    Just _ -> throwE $ printf "Found non funcdecl with specified id: %s" name

containsFuncDecl :: String ->  Builder Bool
containsFuncDecl name = do
  pState <- lift $ gets funcdecls
  case M.lookup name pState of
    Nothing -> return False
    Just (FunctionDecl _ _) -> return True
    Just _ -> return False

getFuncDef :: String -> String -> Builder Declaration
getFuncDef name ver = do
  pState <- lift $ gets functionDefs
  case M.lookup (name ++ ver) pState of
    Nothing -> throwE $ printf "Failed to find global definition: %s" (name ++ ver)
    Just func@(FunctionDef _ _ _ _) -> return func
    Just _ -> throwE $ printf "Found non function def with specified id: %s" (name ++ ver)

containsFuncDef :: String -> String -> Builder Bool
containsFuncDef name ver = do
  pState <- lift $ gets functionDefs
  case M.lookup (name ++ ver) pState of
    Nothing -> return False
    Just (FunctionDef _ _ _ _) -> return True
    Just _ -> return False

putFuncSig :: String -> [UvmTypeDef] -> [UvmTypeDef] -> Builder FuncSig
putFuncSig name args ret = do
  let functionSig = FuncSig name args ret
  lift $ modify (\pState ->
                  pState {
                    funcsigs = M.insert name (FunctionSignature functionSig) (funcsigs pState)
                    })
  return functionSig

putFunction :: String -> String -> FuncSig -> Builder (Function, SSAVariable)
putFunction name ver sig = do
  lift $ modify $ (\pState ->
                    pState {
                      functionDefs = M.insert (name ++ ver) (FunctionDef name ver sig []) (functionDefs pState)
                           })
  fSig <- putTypeDef (show (FuncRef sig)) (FuncRef sig)
  let funcRef = SSAVariable Global name fSig
  return $ (Function name ver, funcRef)

putConstant :: String -> UvmTypeDef -> String -> Builder SSAVariable
putConstant name constType val = do
  let constVar = SSAVariable Global name constType
  lift $ modify (\pState ->
                  pState {
                    constants = M.insert name (ConstDecl constVar val) (constants pState)
                    })
  return constVar

putTypeDef :: String -> UvmType -> Builder UvmTypeDef
putTypeDef name uvmType = do
  let tDef = UvmTypeDef name uvmType
  lift $ modify (\pState ->
                  pState {
                    typedefs = M.insert name (Typedef tDef) (typedefs pState)                    
                    })
  return tDef

putFuncDecl :: String -> FuncSig -> Builder ()
putFuncDecl name fSig =
  lift $ modify (\pState -> pState {funcdecls = M.insert name (FunctionDecl name fSig) (funcdecls pState)
                                   })

putGlobal :: String -> UvmTypeDef -> Builder (SSAVariable, UvmTypeDef)
putGlobal name dType = do
  let refType' = IRef dType
  varType' <- putTypeDef (show refType') refType'
  let var = SSAVariable Global name varType'
  lift $ modify (\pState ->
                  pState {
                    globals = M.insert name (GlobalDef var dType) (globals pState)
                    })
  return (var, varType')

putExpose :: String -> String -> CallConvention -> SSAVariable -> Builder ()
putExpose name funcName cconv cookie = do
  let e = ExposeDef name funcName cconv cookie
  lift $ modify (\pState ->
                  pState {
                    exposes = M.insert name e (exposes pState)
                         })

createVariable :: String -> UvmTypeDef -> Builder SSAVariable
createVariable name typeVal = do
  n <- getVarID
  lift $ modify $ \pState -> pState {builderVarID = succ n}
  return $ SSAVariable Local (printf "%s%d" name n) typeVal

createVariables :: UvmTypeDef -> [String] -> Builder [SSAVariable]
createVariables t lst = mapM (flip createVariable t) lst

createExecClause :: Block -> [SSAVariable] -> Block -> [SSAVariable] -> ExceptionClause
createExecClause (Block name1 _) v1 (Block name2 _) v2 = ExceptionClause (DestinationClause name1 v1) (DestinationClause name2 v2)


putBasicBlock :: String -> Maybe SSAVariable -> Function -> Builder Block
putBasicBlock name exec fn@(Function func ver) = do
  FunctionDef fName fVer fSig fBody <- getFuncDef func ver
  let block = BasicBlock name [] exec [] (Return [])
  lift $ modify $ (\pState ->
                    pState {
                      functionDefs = M.insert (fName ++ fVer) (FunctionDef fName fVer fSig (block:fBody)) (functionDefs pState)
                           })
  return $ Block name fn

newtype BlockState = BlockState ([Assign], [SSAVariable], Maybe Expression)

instance Monoid BlockState where
  mempty = BlockState ([], [], Nothing)
  mappend (BlockState (b1, p1, t1)) (BlockState (b2, p2, t2)) = case t2 of
    Nothing -> BlockState (b2 `mappend` b1, p1 `mappend` p2, t1)
    _ -> BlockState (b2 `mappend` b1, p1 `mappend` p2, t2)


withBasicBlock :: String -> Maybe SSAVariable -> Function -> WriterT BlockState Builder a -> Builder (Block, a)
withBasicBlock name exec func prog = do
  --let block = BasicBlock name [] exec [] (Return [])
  block <- putBasicBlock name exec func
  res <- updateBasicBlock block prog
  return (block, res)
  
      
updateBasicBlock :: Block ->  WriterT BlockState Builder a -> Builder a
updateBasicBlock block@(Block name (Function func ver)) prog = do
  FunctionDef fName fVer fSig fBody <- getFuncDef func ver
  bb@(BasicBlock _ params _ body term) <- getBlock block fBody
  (ctx, BlockState (body', params', Just term')) <- runWriterT $ do
    tell $ BlockState (body, params, Just term)
    prog
  let block' = bb {basicBlockInstructions=body', basicBlockTerminst=term', basicBlockParams=params'}
  newBody <- editBlock block' fBody
  lift $ modify (\pState ->
                  pState {
                    functionDefs = M.insert (fName ++ fVer) (FunctionDef fName fVer fSig newBody) (functionDefs pState)
                         })
  return ctx
  where
    editBlock :: BasicBlock -> [BasicBlock] -> Builder [BasicBlock]
    editBlock blk lst = case lst of
      x:xs
        | basicBlockName x == name -> return $ blk:xs
        | otherwise -> (x:) <$> (editBlock blk xs)
      [] -> throwE $ printf "could not find block %s" name
    getBlock :: Block -> [BasicBlock] -> Builder BasicBlock
    getBlock blk lst = case lst of
      x:xs
        | name == basicBlockName x -> return x
        | otherwise -> getBlock blk xs
      [] -> throwE $ printf "could not find block %s" name
      

putParams :: [UvmTypeDef] -> WriterT BlockState Builder [SSAVariable]
putParams types = do
  let vars = genVars 0 types
  tell $ BlockState ([], vars, Nothing) 
  return vars
  where
    genVars :: Int -> [UvmTypeDef] -> [SSAVariable]
    genVars count lst = case lst of
      t:ts -> SSAVariable Local (printf "p%d" count) t:genVars (succ count) ts
      [] -> []
  

putBinOp :: BinaryOp -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putBinOp op v1@(SSAVariable _ _ opType) v2 exec = do
  assignee <- lift $ createVariable "v" opType
  tell $ BlockState ([Assign [assignee] (BinaryOperation op opType v1 v2 exec)], [], Nothing)
  return assignee

putConvOp :: ConvertOp -> UvmTypeDef -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putConvOp op dest var exec = do
  assignee <- lift $ createVariable "v" dest
  tell $ BlockState  ([Assign [assignee] (ConvertOperation op (varType var) dest var exec)], [], Nothing)
  return assignee


putCmpOp :: CompareOp -> SSAVariable -> SSAVariable -> WriterT BlockState Builder SSAVariable
putCmpOp op  v1@(SSAVariable _ _ opType) v2 = do
  assignee <- lift $ createVariable "v" i1
  tell $ BlockState ([Assign [assignee] (CompareOperation op opType v1 v2)], [], Nothing)
  return assignee


putAtomicRMW :: AtomicRMWOp -> Bool -> MemoryOrder -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putAtomicRMW op ptr memOrd loc opnd exec = do
  assignee <- lift $ createVariable "v" (varType opnd)
  tell $ BlockState ([Assign [assignee] (AtomicRMWOperation ptr memOrd op (varType opnd) loc opnd exec)], [], Nothing)
  return assignee


putCmpXchg :: Bool -> Bool -> MemoryOrder -> MemoryOrder -> SSAVariable -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder (SSAVariable, SSAVariable)
putCmpXchg ptr weak mem1 mem2 loc expec desir exec = do
  ass1 <- lift $ createVariable "v" opndType
  ass2 <- lift $ createVariable "v" i1
  tell $ BlockState ([Assign [ass1, ass2] (CmpXchg ptr weak mem1 mem2 opndType loc expec desir exec)], [], Nothing)
  return (ass1, ass2)
  where
    opndType = case uvmTypeDefType $ varType loc of
      UPtr t -> t
      IRef t -> t
      _ -> varType loc
  

putFence :: MemoryOrder -> WriterT BlockState Builder ()
putFence memOrd = tell $ BlockState ([Assign [] (Fence memOrd)], [], Nothing)


putNew :: UvmTypeDef -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putNew t exec  = do
  let operation = New t exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee


putNewHybrid :: UvmTypeDef -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putNewHybrid t len exec = do
  let operation = NewHybrid t (varType len) len exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee

                                               
putAlloca :: UvmTypeDef -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putAlloca t exec = do
  let operation = Alloca t exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee


putAllocaHybrid :: UvmTypeDef -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putAllocaHybrid t len exec = do
  let operation = AllocaHybrid t (varType len) len exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee
  

setTermInstRet :: [SSAVariable] -> WriterT BlockState Builder ()
setTermInstRet rets = 
  tell $ BlockState ([], [], Just $ Return rets)


setTermInstThrow :: SSAVariable -> WriterT BlockState Builder ()
setTermInstThrow var = 
  tell $ BlockState ([], [], Just $ Throw var)


putCall :: [SSAVariable] -> SSAVariable -> FuncSig -> [SSAVariable] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
putCall assignee func sig args exec alive =
  tell $ BlockState ([Assign assignee (Call sig func args exec (KeepAlive <$> alive))], [], Nothing)
  

putCCall :: [SSAVariable] ->  CallConvention -> UvmTypeDef -> FuncSig -> SSAVariable -> [SSAVariable] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
putCCall assignee callConv t sig callee args exec alive = 
  tell $ BlockState ([Assign assignee (CCall callConv t sig callee args exec (KeepAlive <$> alive))], [], Nothing)
  

setTermInstTailCall :: FuncSig -> SSAVariable -> [SSAVariable] -> WriterT BlockState Builder ()
setTermInstTailCall sig callee args = 
  tell $ BlockState ([], [], Just $ TailCall sig callee args)
  

setTermInstBranch :: Block -> [SSAVariable] -> WriterT BlockState Builder ()
setTermInstBranch (Block dest _) vars =
  tell $ BlockState ([], [], Just $ Branch1 $ DestinationClause dest vars)
  

setTermInstBranch2 :: SSAVariable -> Block -> [SSAVariable] -> Block -> [SSAVariable] -> WriterT BlockState Builder ()
setTermInstBranch2 cond (Block trueBlock _) trueVars (Block falseBlock _) falseVars =
  tell $ BlockState ([], [], Just $  Branch2 cond (DestinationClause trueBlock trueVars) (DestinationClause falseBlock falseVars))
  

putWatchPoint :: [SSAVariable] -> SSAVariable -> Int -> [UvmTypeDef] -> BasicBlock -> [SSAVariable] -> BasicBlock -> [SSAVariable] -> Maybe (BasicBlock, [SSAVariable]) -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
putWatchPoint assignee name wpid ts (BasicBlock dis _ _ _ _) disArgs (BasicBlock ena _ _ _ _) enaArgs wpexec alive =
  tell $ BlockState ([Assign assignee (WatchPoint name wpid ts (DestinationClause dis disArgs) (DestinationClause ena enaArgs) wp (KeepAlive <$> alive))], [], Nothing)
  where
    wp = case wpexec of
      Nothing -> Nothing
      Just (BasicBlock wpBlock _ _ _ _, wpVars) -> Just $ WPExceptionClause $ DestinationClause wpBlock wpVars


putTrap :: [SSAVariable] -> SSAVariable -> [UvmTypeDef] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
putTrap assignee name ts exec alive =
  tell $ BlockState  ([Assign assignee (Trap name ts exec (KeepAlive <$> alive))], [], Nothing)


setTermInstWatchPoint :: SSAVariable -> Int -> [UvmTypeDef] -> BasicBlock -> [SSAVariable] -> BasicBlock -> [SSAVariable] -> Maybe (BasicBlock, [SSAVariable]) -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
setTermInstWatchPoint name wpid ts (BasicBlock dis _ _ _ _) disArgs (BasicBlock ena _ _ _ _) enaArgs wpexec alive =
  tell $ BlockState ([], [], Just $ WatchPoint name wpid ts (DestinationClause dis disArgs) (DestinationClause ena enaArgs) wp (KeepAlive <$> alive))
  where
    wp = case wpexec of
      Nothing -> Nothing
      Just (BasicBlock wpBlock _ _ _ _, wpVars) -> Just $ WPExceptionClause $ DestinationClause wpBlock wpVars


setTermInstTrap :: SSAVariable -> [UvmTypeDef] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
setTermInstTrap name ts exec alive = 
  tell $ BlockState ([], [], Just $ Trap name ts exec (KeepAlive <$> alive))
  

setTermInstWPBranch :: Int -> BasicBlock -> [SSAVariable] -> BasicBlock -> [SSAVariable] -> WriterT BlockState Builder ()
setTermInstWPBranch wpid (BasicBlock disBlock _ _ _ _) disArgs (BasicBlock enaBlock _ _ _ _) enaArgs =
  tell $ BlockState ([], [], Just $ WPBranch wpid (DestinationClause disBlock disArgs) (DestinationClause enaBlock enaArgs))
  

setTermInstSwitch :: SSAVariable -> BasicBlock -> [SSAVariable] -> [(SSAVariable, BasicBlock, [SSAVariable])] -> WriterT BlockState Builder ()
setTermInstSwitch cond (BasicBlock defBlock _ _ _ _) defArgs blocks = 
  tell $ BlockState ([], [], Just $ Switch (varType cond) cond (DestinationClause defBlock defArgs) (map toBlocks blocks))
  where
    toBlocks :: (SSAVariable, BasicBlock, [SSAVariable]) -> (SSAVariable, DestinationClause)
    toBlocks (condition, (BasicBlock block _ _ _ _), args) = (condition, DestinationClause block args)


setTermInstSwapStack :: SSAVariable -> CurStackClause -> NewStackClause -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
setTermInstSwapStack swappee csClause nsClause exec alive = 
  tell $ BlockState $ ([], [], Just $  SwapStack swappee csClause nsClause exec (KeepAlive <$> alive))


putNewThread :: SSAVariable -> NewStackClause -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putNewThread stack nsClause exec = do
  
  assignee <- lift $ createVariable "v" threadref
  tell $ BlockState ([Assign [assignee] (NewThread stack nsClause exec)], [], Nothing)
  
  return assignee


putComminst :: [SSAVariable] -> String -> [String] -> [UvmTypeDef] -> [FuncSig] -> [SSAVariable] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
putComminst assignee name flags types sigs args exec alive =
  tell $ BlockState ([Assign assignee (Comminst name (toMaybe $ map Flag flags) (toMaybe types) (toMaybe sigs) (toMaybe args) exec (KeepAlive <$> alive))], [], Nothing)
  where
    toMaybe :: [a] -> Maybe [a]
    toMaybe lst = case lst of
      [] -> Nothing
      _  -> Just lst


putLoad :: Bool -> Maybe MemoryOrder -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putLoad ptr memOrd var exec = do
  
  assignee <- lift $ createVariable "v" vType
  tell $ BlockState ([Assign [assignee] (Load ptr memOrd vType var  exec)], [], Nothing)
  
  return assignee
  where
    vType :: UvmTypeDef
    vType = case uvmTypeDefType $ varType var of
      IRef t -> t
      UPtr t -> t
      _ -> undefined --varType var --errorful type, but let it fail elsewhere


putStore :: Bool -> Maybe MemoryOrder -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder ()
putStore ptr memOrd loc newVal exec = 
  tell $ BlockState ([Assign [] (Store ptr memOrd locType loc newVal exec)], [], Nothing)
  where
    locType :: UvmTypeDef
    locType = case uvmTypeDefType $ varType loc of
      IRef t -> t
      UPtr t -> t
      _ -> varType loc --errorful type, but let it fail elsewhere


putExtractValueS :: Int -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putExtractValueS index opnd exec = do
  
  let operation  = ExtractValueS (varType opnd) index opnd exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] (ExtractValueS (varType opnd) index opnd exec)], [], Nothing)
  
  return assignee


putInsertValueS :: Int -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putInsertValueS index opnd newVal exec = do
  
  let operation = InsertValueS (varType opnd) index newVal opnd exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  
  return assignee
  

putExtractValue :: SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putExtractValue opnd index exec = do
  
  let operation = ExtractValue (varType opnd) (varType index) opnd index exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  
  return assignee
  

putInsertValue :: SSAVariable -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putInsertValue opnd index newVal exec = do
  
  let operation = InsertValue (varType opnd) (varType index) opnd index newVal exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState([Assign [assignee] operation], [], Nothing)
  
  return assignee


putShuffleVector :: SSAVariable -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putShuffleVector v1 v2 mask exec = do
  let operation = ShuffleVector (varType v1) (varType mask) v1 v2 mask exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee


putGetIRef :: SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putGetIRef opnd exec = do
  let operation = GetIRef opndType opnd exec
  assT <- let retT = IRef opndType in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      Ref t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere


putGetFieldIRef :: Bool -> Int -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putGetFieldIRef ptr index opnd exec = do
  let operation = GetFieldIRef ptr opndType index opnd exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere


putGetElemIRef :: Bool -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putGetElemIRef ptr opnd index exec = do
  let operation = GetElemIRef ptr opndType (varType index) opnd index exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere


putShiftIRef :: Bool -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putShiftIRef ptr opnd offset exec = do
  let operation = ShiftIRef ptr opndType (varType offset) opnd offset exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere

putGetVarPartIRef :: Bool -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putGetVarPartIRef ptr opnd exec = do
  let operation = GetVarPartIRef ptr opndType opnd exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  assignee <- lift $ createVariable "v" assT
  tell $ BlockState ([Assign [assignee] operation], [], Nothing)
  return assignee
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere
    

putComment :: String -> WriterT BlockState Builder ()
putComment str = 
  tell $ BlockState ([Assign [] (Comment str)], [], Nothing)

type Context = [SSAVariable]


putIf :: Context -> Context -> SSAVariable -> Block -> Function -> (Block -> WriterT BlockState Builder a) ->  Builder (Block, Block, a)
putIf progCtx contCtx cond entry func prog = do
  n <- lift $ gets builderVarID
  progBlock <- putBasicBlock (printf "progBlock%d" n) Nothing func
  contBlock <- putBasicBlock (printf "contBlock%d" n) Nothing func

  lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}

  _ <-  updateBasicBlock entry $ do
    setTermInstBranch2 cond progBlock progCtx contBlock contCtx

  ret <- updateBasicBlock progBlock $ prog contBlock
  
  return (progBlock, contBlock, ret)

putIfElse :: Context -> Context -> SSAVariable -> Block -> (Block -> WriterT BlockState Builder a) -> (Block -> WriterT BlockState Builder b) -> Builder (Block, Block, Block, a, b)
putIfElse trueCtx falseCtx cond entry@(Block _ func) trueProg falseProg = do
  n <- lift $ gets builderVarID
  trueBlock <- putBasicBlock (printf "trueBlock%d" n) Nothing func
  falseBlock <- putBasicBlock (printf "falseBlock%d" n) Nothing func
  contBlock <- putBasicBlock (printf "contBlock%d" n) Nothing func

  lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}

  _ <- updateBasicBlock entry $ do
    setTermInstBranch2 cond trueBlock trueCtx falseBlock falseCtx

  tRet <- updateBasicBlock trueBlock $ trueProg contBlock
  fRet <- updateBasicBlock falseBlock $ falseProg contBlock
  
  return (trueBlock, falseBlock, contBlock, tRet, fRet)

putIfTrue :: Context -> Context -> SSAVariable -> Block -> (Block -> WriterT BlockState Builder a) -> Builder (Block, Block, a)
putIfTrue progCtx contCtx cond entry@(Block _ func) prog = do
  n <- getVarID
  progBlock <- putBasicBlock (printf "progBlock%d" n) Nothing func
  contBlock <- putBasicBlock (printf "contBlock%d" n) Nothing func

  lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}

  _ <- updateBasicBlock entry $ do
    setTermInstBranch2 cond progBlock progCtx contBlock contCtx

  pRet <- updateBasicBlock progBlock $ prog contBlock
  
  return (progBlock, contBlock, pRet)
  
putWhile :: Context -> Block -> (Block -> Block -> WriterT BlockState Builder a) -> (Block -> WriterT BlockState Builder b) -> Builder (Block, Block, Block, a, b)
putWhile condCtx entry@(Block _ func) condProg loopProg = do
  n <- getVarID
  condBlock <- putBasicBlock (printf "condBlock%d" n) Nothing func
  loopBlock <- putBasicBlock (printf "loopBlock%d" n) Nothing func
  contBlock <- putBasicBlock (printf "contBlock%d" n) Nothing func

  lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}

  _ <- updateBasicBlock entry $ do
    setTermInstBranch condBlock condCtx

  cRet <- updateBasicBlock condBlock $ condProg loopBlock contBlock
  
  lRet <- updateBasicBlock loopBlock $ loopProg condBlock
  
  return (condBlock, loopBlock, contBlock, cRet, lRet)
