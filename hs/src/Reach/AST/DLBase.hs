{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Reach.AST.DLBase where

import Control.Monad.Identity
import Control.Monad.Reader
import Data.Aeson
import qualified Data.ByteString.Char8 as B
import Data.Functor ((<&>))
import qualified Data.List as List
import Data.List.Extra
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Monoid
import qualified Data.Sequence as Seq
import qualified Data.Set as S
import qualified Data.Text as T
import GHC.Stack (HasCallStack)
import GHC.Generics
import Reach.AST.Base
import Reach.Counter
import Reach.Pretty
import Reach.Texty
import Reach.Util
import Data.Bifunctor
import Data.Bool (bool)

type ConnectorName = T.Text

type PrettySubstEnv = M.Map DLVar Doc

type PrettySubstApp = ReaderT PrettySubstEnv Identity

class PrettySubst a where
  prettySubst :: a -> PrettySubstApp Doc

instance {-# OVERLAPPABLE #-} PrettySubst a => Pretty a where
  pretty = runIdentity . flip runReaderT mempty . prettySubst

instance (PrettySubst a, PrettySubst b) => PrettySubst (Either a b) where
  prettySubst = \case
    Left x -> f "Left" x
    Right x -> f "Right" x
    where
      f l x = (l <+>) <$> prettySubst x

-- DL types only describe data, and explicitly do not describe functions
data DLType
  = T_Null
  | T_Bool
  | T_UInt UIntTy
  | T_Bytes Integer
  | T_BytesDyn
  | T_StringDyn
  | T_Digest
  | T_Address
  | T_Contract
  | T_Token
  | T_Array DLType Integer
  | T_Tuple [DLType]
  | T_Object (M.Map SLVar DLType)
  | T_Data (M.Map SLVar DLType)
  | T_Struct [(SLVar, DLType)]
  deriving (Eq, Generic, Ord)

instance FromJSON DLType

instance ToJSON DLType

uintTyOf :: DLType -> UIntTy
uintTyOf = \case
  T_UInt t -> t
  _ -> UI_Word

tokenInfoElemTy :: DLType
tokenInfoElemTy = T_Tuple [balance, supply, destroyed]
  where
    balance = T_UInt UI_Word
    supply = T_UInt UI_Word
    destroyed = T_Bool

maybeT :: DLType -> DLType
maybeT t = T_Data $ M.fromList $ [("None", T_Null), ("Some", t)]

eitherT :: DLType -> DLType -> DLType
eitherT lt rt = T_Data $ M.fromList $ [("Left", lt), ("Right", rt)]

dataTypeMap :: DLType -> M.Map SLVar DLType
dataTypeMap = \case
  T_Data m -> m
  _ -> impossible "no data"

dataTagMap :: DLType -> M.Map SLVar Integer
dataTagMap d = M.fromAscList $ zip (map fst $ M.toAscList m) ints
  where
    m = dataTypeMap d
    ints = ([0 ..] :: [Integer])

arrTypeLen :: DLType -> (DLType, Integer)
arrTypeLen = \case
  T_Array d l -> (d, l)
  _ -> impossible "no array"

arrType :: DLType -> DLType
arrType = fst . arrTypeLen

tupleTypes :: HasCallStack => DLType -> [DLType]
tupleTypes = \case
  T_Tuple ts -> ts
  _ -> impossible $ "should be tuple"

bytesTypeLen :: DLType -> Integer
bytesTypeLen = \case
  T_Bytes l -> l
  _ -> impossible "no bytes"

objstrTypes :: DLType -> [(SLVar, DLType)]
objstrTypes = \case
  T_Object m -> M.toAscList m
  T_Struct ts -> ts
  _ -> impossible $ "should be obj"

objstrFieldIndex :: DLType -> SLVar -> Integer
objstrFieldIndex t f = fromIntegral $ fromJust' $ List.elemIndex f $ map fst $ objstrTypes t
  where
    fromJust' = fromMaybe $ impossible "field not in type"

showTys :: Show a => [a] -> String
showTys = List.intercalate ", " . map show

showTyMap :: Show a => M.Map SLVar a -> String
showTyMap = List.intercalate ", " . map showPair . M.toList
  where
    showPair (name, ty) = show name <> ": " <> show ty

showTyList :: Show a => [(SLVar, a)] -> String
showTyList = List.intercalate ", " . map showPair
  where
    showPair (name, ty) = "['" <> show name <> "', " <> show ty <> "]"

instance Show DLType where
  show = \case
    T_Null -> "Null"
    T_Bool -> "Bool"
    T_UInt UI_Word -> "UInt"
    T_UInt UI_256 -> "UInt256"
    T_Bytes sz -> "Bytes(" <> show sz <> ")"
    T_BytesDyn -> "BytesDyn"
    T_StringDyn -> "StringDyn"
    T_Digest -> "Digest"
    T_Address -> "Address"
    T_Contract -> "Contract"
    T_Token -> "Token"
    T_Array ty i -> "Array(" <> show ty <> ", " <> show i <> ")"
    T_Tuple tys -> "Tuple(" <> showTys tys <> ")"
    T_Object tyMap -> "Object({" <> showTyMap tyMap <> "})"
    T_Data tyMap -> "Data({" <> showTyMap tyMap <> "})"
    T_Struct tys -> "Struct([" <> showTyList tys <> "])"

instance Pretty DLType where
  pretty = viaShow

-- Interact types can only be value types or first-order function types
data IType
  = IT_Val DLType
  | IT_Fun [DLType] DLType
  | IT_UDFun DLType
  deriving (Eq, Ord, Generic, Show)

instance ToJSON IType

itype2arr :: IType -> ([DLType], DLType)
itype2arr = \case
  IT_Val t -> ([], t)
  IT_Fun dom rng -> (dom, rng)
  IT_UDFun rng -> ([], rng)

instance Pretty IType where
  pretty = viaShow

newtype InteractEnv
  = InteractEnv (M.Map SLVar IType)
  deriving (Eq, Generic, Show)
  deriving newtype (Monoid, Semigroup)

instance ToJSON InteractEnv

instance Pretty InteractEnv where
  pretty (InteractEnv m) = "interact" <+> render_obj m

data SLParts = SLParts
  { sps_ies :: M.Map SLPart InteractEnv
  , sps_apis :: S.Set SLPart
  }
  deriving (Eq, Generic, Show)

instance Semigroup SLParts where
  (SLParts xi xa) <> (SLParts yi ya) = SLParts (xi <> yi) (xa <> ya)

instance Monoid SLParts where
  mempty = SLParts mempty mempty

instance Pretty SLParts where
  pretty (SLParts {..}) = "parts" <+> render_obj sps_ies <> semi

type DLMapInfos = M.Map DLMVar DLMapInfo

data DLInit = DLInit
  { dli_maps :: DLMapInfos
  }
  deriving (Eq, Generic)

instance Pretty DLInit where
  pretty (DLInit {..}) =
    "// maps" <> hardline
      <> render_obj dli_maps
      <> hardline
      <> "// initialization"
      <> hardline

data DLConstant
  = DLC_UInt_max
  | DLC_Token_zero
  deriving (Bounded, Enum, Eq, Generic, Show, Ord)

allConstants :: [DLConstant]
allConstants = enumFrom minBound

instance ToJSON DLConstant

instance FromJSON DLConstant

instance Pretty DLConstant where
  pretty = \case
    DLC_UInt_max  -> "UInt.max"
    DLC_Token_zero -> "Token.zero"

conTypeOf :: DLConstant -> DLType
conTypeOf = \case
  DLC_UInt_max  -> T_UInt UI_Word
  DLC_Token_zero -> T_Token

data DLLiteral
  = DLL_Null
  | DLL_Bool Bool
  | DLL_Int SrcLoc UIntTy Integer
  | DLL_TokenZero
  deriving (Eq, Generic, Show, Ord)

instance ToJSON DLLiteral

instance FromJSON DLLiteral

instance Pretty DLLiteral where
  pretty = \case
    DLL_Null -> "null"
    DLL_Bool b -> if b then "true" else "false"
    DLL_Int _ _ i -> viaShow i
    DLL_TokenZero -> "Token.zero"

litTypeOf :: DLLiteral -> DLType
litTypeOf = \case
  DLL_Null -> T_Null
  DLL_Bool _ -> T_Bool
  DLL_Int _ t _ -> T_UInt t
  DLL_TokenZero -> T_Token

data DLVar = DLVar SrcLoc (Maybe (SrcLoc, SLVar)) DLType Int
  deriving (Generic)

instance ToJSONKey DLVar

instance ToJSON DLVar where
  toJSON v = toJSON $ show v

instance FromJSON DLVar

instance SrcLocOf DLVar where
  srclocOf (DLVar a _ _ _) = a

instance Eq DLVar where
  (DLVar _ _ _ x) == (DLVar _ _ _ y) = x == y

instance Ord DLVar where
  (DLVar _ _ _ x) <= (DLVar _ _ _ y) = x <= y

instance Pretty DLVar where
  pretty v = viaShow v <+> ":" <+> viaShow (varType v)

instance Show DLVar where
  show (DLVar _ b _ i) =
    case b of
      Nothing -> "v" <> show i
      Just (_, v) -> v <> "/" <> show i

showErr :: DLVar -> String
showErr v@(DLVar a b _ _) = show v <> " from " <> show at
  where
    at = case b of
      Nothing -> a
      Just (c, _) -> c

dvdelete :: DLVar -> [DLVar] -> [DLVar]
dvdelete x = filter (x /=)

dvdeletem :: Maybe DLVar -> [DLVar] -> [DLVar]
dvdeletem = \case
  Nothing -> id
  Just x -> dvdelete x

dvdeletep :: DLVar -> [(DLVar, a)] -> [(DLVar, a)]
dvdeletep x = filter ((x /=) . fst)

varType :: DLVar -> DLType
varType (DLVar _ _ t _) = t

newtype DLMVar = DLMVar Int
  deriving (Show, Eq, Ord, Generic)

instance ToJSONKey DLMVar

instance ToJSON DLMVar

instance Pretty DLMVar where
  pretty (DLMVar i) = "map" <> pretty i

data DLMapInfo = DLMapInfo
  { dlmi_kt :: DLType
  , dlmi_ty :: DLType
  , dlmi_at :: SrcLoc
  }
  deriving (Eq, Generic)

instance Pretty DLMapInfo where
  pretty (DLMapInfo {..}) = pretty dlmi_ty

dlmi_tym :: DLMapInfo -> DLType
dlmi_tym = maybeT . dlmi_ty

data DLArg
  = DLA_Var DLVar
  | DLA_Constant DLConstant
  | DLA_Literal DLLiteral
  | DLA_Interact SLPart String DLType
  deriving (Eq, Ord, Generic, Show)

instance PrettySubst DLArg where
  prettySubst = \case
    DLA_Var v -> do
      env <- ask
      return $ fromMaybe (viaShow v) (M.lookup v env)
    DLA_Interact who m _ ->
      return $ pretty who <> ".interact." <> pretty m
    DLA_Constant x -> return $ pretty x
    DLA_Literal x -> return $ pretty x

argLitZero :: DLArg
argLitZero = DLA_Literal $ DLL_Int sb UI_Word 0

argLitNull :: DLArg
argLitNull = DLA_Literal DLL_Null

staticZero :: DLArg -> Bool
staticZero = \case
  DLA_Literal (DLL_Int _ _ 0) -> True
  _ -> False

uintTyMax :: UIntTy -> DLArg
uintTyMax = \case
  UI_256 -> DLA_Literal $ DLL_Int sb UI_256 $ uint256_Max
  UI_Word -> DLA_Constant DLC_UInt_max

asnLike :: [DLVar] -> [(DLVar, DLArg)]
asnLike = map (\x -> (x, DLA_Var x))

class CanDupe a where
  canDupe :: a -> Bool

instance CanDupe DLArg where
  canDupe = \case
    DLA_Var {} -> True
    DLA_Constant {} -> True
    DLA_Literal {} -> True
    DLA_Interact {} -> False

argTypeOf :: DLArg -> DLType
argTypeOf = \case
  DLA_Var (DLVar _ _ t _) -> t
  DLA_Constant c -> conTypeOf c
  DLA_Literal c -> litTypeOf c
  DLA_Interact _ _ t -> t

argArrTypeLen :: DLArg -> (DLType, Integer)
argArrTypeLen = arrTypeLen . argTypeOf

argObjstrTypes :: DLArg -> [(SLVar, DLType)]
argObjstrTypes = objstrTypes . argTypeOf

data DLLargeArg
  = DLLA_Array DLType [DLArg]
  | DLLA_Tuple [DLArg]
  | DLLA_Obj (M.Map String DLArg)
  | DLLA_Data (M.Map SLVar DLType) String DLArg
  | DLLA_Struct [(SLVar, DLArg)]
  | DLLA_Bytes B.ByteString
  | DLLA_BytesDyn B.ByteString
  | DLLA_StringDyn T.Text
  deriving (Eq, Ord, Generic, Show)

bytesZero :: Integer -> B.ByteString
bytesZero k = B.replicate (fromIntegral k) '\0'

bytesZeroLit :: Integer -> DLLargeArg
bytesZeroLit = DLLA_Bytes . bytesZero

instance CanDupe a => CanDupe [a] where
  canDupe = getAll . mconcatMap (All . canDupe)

instance CanDupe DLLargeArg where
  canDupe = \case
    DLLA_Array _ as -> canDupe as
    DLLA_Tuple as -> canDupe as
    DLLA_Obj am -> canDupe $ M.elems am
    DLLA_Data _ _ x -> canDupe x
    DLLA_Struct m -> canDupe $ map snd m
    DLLA_Bytes _ -> False
    DLLA_BytesDyn _ -> False
    DLLA_StringDyn _ -> False

render_dasM :: PrettySubst a => [a] -> PrettySubstApp Doc
render_dasM as = do
  as' <- mapM prettySubst as
  return $ hsep $ punctuate comma as'

render_objM :: Pretty k => PrettySubst v => M.Map k v -> PrettySubstApp Doc
render_objM env = do
  ps <- mapM render_p $ M.toAscList env
  return $ braces $ nest $ hardline <> (concatWith (surround (comma <> hardline)) ps)
  where
    render_p (k, oa) = do
      o' <- prettySubst oa
      return $ pretty k <+> "=" <+> o'

instance PrettySubst String where
  prettySubst = return . pretty

instance (PrettySubst a, PrettySubst b) => PrettySubst (a, b) where
  prettySubst (x, y) = do
    x' <- prettySubst x
    y' <- prettySubst y
    return $ parens $ hsep $ punctuate comma [x', y']

instance PrettySubst DLLargeArg where
  prettySubst = \case
    DLLA_Array t as -> do
      t' <- prettySubst (DLLA_Tuple as)
      return $ "array" <> parens (pretty t <> comma <+> t')
    DLLA_Tuple as -> render_dasM as <&> brackets
    DLLA_Obj env -> render_objM env
    DLLA_Data _ vn vv -> do
      v' <- prettySubst vv
      return $ "<" <> pretty vn <> " " <> v' <> ">"
    DLLA_Struct kvs -> do
      kvs' <- render_dasM kvs
      return $ "struct" <> brackets kvs'
    DLLA_Bytes bs -> return $ pretty bs
    DLLA_BytesDyn bs -> return $ pretty bs
    DLLA_StringDyn t -> return $ dquotes (pretty t)

mdaToMaybeLA :: DLType -> Maybe DLArg -> DLLargeArg
mdaToMaybeLA t = \case
  Nothing -> f "None" $ DLA_Literal $ DLL_Null
  Just a -> f "Some" a
  where
    f = DLLA_Data (dataTypeMap $ maybeT t)

data DLArgExpr
  = DLAE_Arg DLArg
  | DLAE_Array DLType [DLArgExpr]
  | DLAE_Tuple [DLArgExpr]
  | DLAE_Obj (M.Map SLVar DLArgExpr)
  | DLAE_Data (M.Map SLVar DLType) String DLArgExpr
  | DLAE_Struct [(SLVar, DLArgExpr)]
  | DLAE_Bytes B.ByteString
  | DLAE_BytesDyn B.ByteString
  | DLAE_StringDyn T.Text
  deriving (Show)

argExprToArgs :: DLArgExpr -> [DLArg]
argExprToArgs = \case
  DLAE_Arg a -> [a]
  DLAE_Array _ aes -> many aes
  DLAE_Tuple aes -> many aes
  DLAE_Obj m -> many $ M.elems m
  DLAE_Data _ _ ae -> one ae
  DLAE_Struct aes -> many $ map snd aes
  DLAE_Bytes _ -> []
  DLAE_BytesDyn _ -> []
  DLAE_StringDyn _ -> []
  where
    one = argExprToArgs
    many = concatMap one

largeArgToArgExpr :: DLLargeArg -> DLArgExpr
largeArgToArgExpr = \case
  DLLA_Array sz as -> DLAE_Array sz $ map DLAE_Arg as
  DLLA_Tuple as -> DLAE_Tuple $ map DLAE_Arg as
  DLLA_Obj m -> DLAE_Obj $ M.map DLAE_Arg m
  DLLA_Data m v a -> DLAE_Data m v $ DLAE_Arg a
  DLLA_Struct kvs -> DLAE_Struct $ map (\(k, v) -> (,) k $ DLAE_Arg v) kvs
  DLLA_Bytes b -> DLAE_Bytes b
  DLLA_BytesDyn b -> DLAE_BytesDyn b
  DLLA_StringDyn t -> DLAE_StringDyn t

largeArgTypeOf :: DLLargeArg -> DLType
largeArgTypeOf = argExprTypeOf mempty . largeArgToArgExpr

argExprTypeOf :: M.Map SLVar SecurityLevel -> DLArgExpr -> DLType
argExprTypeOf menv = \case
  DLAE_Arg a -> argTypeOf a
  DLAE_Array t as -> T_Array t $ fromIntegral (length as)
  DLAE_Tuple as -> T_Tuple $ map rec as
  DLAE_Obj senv -> T_Object $ M.map rec senv
  DLAE_Data t _ _ -> T_Data t
  DLAE_Struct kvs -> T_Struct $ map (second rec) kvs
  DLAE_Bytes bs -> T_Bytes $ fromIntegral $ B.length bs
  DLAE_BytesDyn _ -> T_BytesDyn
  DLAE_StringDyn _ -> T_StringDyn
  where
    rec = argExprTypeOf menv

data ClaimType
  = --- Verified on all paths
    CT_Assert
  | --- Checked at runtime
    CT_Enforce
  | --- Assume true in verification, but check at runtime
    CT_Assume
  | --- Verified in honest, assumed in dishonest. (This may sound
    --- backwards, but by verifying it in honest mode, then we are
    --- checking that the other participants fulfill the promise when
    --- acting honestly.)
    CT_Require
  | --- Check if an assignment of variables exists to make
    --- this true.
    CT_Possible
  | --- Check if one part can't know what another party does know
    CT_Unknowable SLPart [DLArg]
  deriving (Eq, Ord, Generic, Show)

instance Pretty ClaimType where
  pretty = \case
    CT_Assert -> "assert"
    CT_Enforce -> "enforce"
    CT_Assume -> "assume"
    CT_Require -> "require"
    CT_Possible -> "possible"
    CT_Unknowable p as -> "unknowable" <> parens (pretty p <> render_das as)

class IsPure a where
  isPure :: a -> Bool

instance IsPure a => IsPure [a] where
  isPure = all isPure

class IsLocal a where
  isLocal :: a -> Bool

instance IsLocal a => IsLocal (Seq.Seq a) where
  isLocal = all isLocal

data DLWithBill = DLWithBill
  { dwb_net_billed :: Bool
  , dwb_tok_billed :: [DLArg]
  , dwb_tok_not_billed :: [DLArg]
  }
  deriving (Eq, Ord, Show)

instance PrettySubst DLWithBill where
  prettySubst (DLWithBill x y z) = do
    y' <- render_dasM y
    z' <- render_dasM z
    return $
      render_obj $
        M.fromList $
          [ ("net", pretty x)
          , ("billed" :: String, parens y')
          , ("notBilled", parens z')
          ]

tokenNameLen :: Integer
tokenNameLen = 32

tokenSymLen :: Integer
tokenSymLen = 8

tokenURLLen :: Integer
tokenURLLen = 96

tokenMetadataLen :: Integer
tokenMetadataLen = 32

data DLTokenNew = DLTokenNew
  { dtn_name :: DLArg
  , dtn_sym :: DLArg
  , dtn_url :: DLArg
  , dtn_metadata :: DLArg
  , dtn_supply :: DLArg
  , dtn_decimals :: Maybe DLArg
  }
  deriving (Eq, Ord, Show)

instance PrettySubst DLTokenNew where
  prettySubst (DLTokenNew {..}) =
    render_objM $
      M.fromList $
        [ (("name" :: String), dtn_name)
        , ("sym", dtn_sym)
        , ("url", dtn_url)
        , ("metadata", dtn_metadata)
        , ("supply", dtn_supply)
        , ("decimals", fromMaybe (DLA_Literal DLL_Null) dtn_decimals)
        ]

type DLTimeArg = Either DLArg DLArg

-- What additional work needs to be done when compiling the definition
-- for a lifted API call
data ApiInfoCompilation
  = AIC_Case
  | AIC_SpreadArg
  deriving (Eq, Ord, Show)

instance Pretty ApiInfoCompilation where
  pretty = viaShow

data ApiInfo = ApiInfo
  { ai_at :: SrcLoc
  , ai_msg_tys :: [DLType]
  , ai_mcase_id :: Maybe String
  , ai_which :: Int
  , ai_compile :: ApiInfoCompilation
  , ai_ret_ty :: DLType
  , ai_alias :: Maybe B.ByteString
  }
  deriving (Eq)

instance Pretty ApiInfo where
  pretty (ApiInfo {..}) =
    render_obj $
      M.fromList
        [ ("msg_tys" :: String, pretty ai_msg_tys)
        , ("mcase_id", pretty ai_mcase_id)
        , ("which", pretty ai_which)
        , ("compile", pretty ai_compile)
        , ("ret", pretty ai_ret_ty)
        ]

type ApiInfos = M.Map SLPart (M.Map Int ApiInfo)

data PrimVM -- Primitive Verification Mode
  = PV_Safe -- No static assertion, yes dynamic check
  | PV_Veri -- Yes static assertion, no dynamic check
  | PV_None
  deriving (Eq, Generic, Ord, Show)

data PrimOp
  = ADD UIntTy PrimVM
  | SUB UIntTy PrimVM
  | MUL UIntTy PrimVM
  | DIV UIntTy PrimVM
  | MOD UIntTy PrimVM
  | PLT UIntTy
  | PLE UIntTy
  | PEQ UIntTy
  | PGE UIntTy
  | PGT UIntTy
  | SQRT UIntTy
  | UCAST UIntTy UIntTy Bool PrimVM
  | IF_THEN_ELSE
  | DIGEST_EQ
  | ADDRESS_EQ
  | TOKEN_EQ
  | SELF_ADDRESS SLPart Bool Int
  | LSH
  | RSH
  | BAND UIntTy
  | BIOR UIntTy
  | BXOR UIntTy
  | BYTES_ZPAD Integer
  | STRINGDYN_CONCAT
  | UINT_TO_STRINGDYN UIntTy
  | MUL_DIV PrimVM
  | DIGEST_XOR
  | BYTES_XOR
  | BTOI_LAST8 Bool
  | CTC_ADDR_EQ
  | GET_CONTRACT
  | GET_ADDRESS
  | GET_COMPANION
  deriving (Eq, Generic, Ord, Show)

instance Pretty PrimVM where
  pretty = viaShow

instance Pretty PrimOp where
  pretty = \case
    ADD t _ -> uitp t <> "+"
    SUB t _ -> uitp t <> "-"
    MUL t _ -> uitp t <> "*"
    DIV t _ -> uitp t <> "/"
    MOD t _ -> uitp t <> "%"
    PLT t -> uitp t <> "<"
    PLE t -> uitp t <> "<="
    PEQ t -> uitp t <> "=="
    PGE t -> uitp t <> ">="
    PGT t -> uitp t <> ">"
    SQRT t -> uitp t <> "sqrt"
    UCAST dom rng trunc pv ->
      let mTruncMsg = if trunc then ",Truncate" else "" in
      let mVeriMsg = ", " <> pretty pv in
      "cast" <> parens (uitp dom <> "," <> uitp rng <> mTruncMsg <> mVeriMsg)
    IF_THEN_ELSE -> "ite"
    DIGEST_EQ -> "=="
    ADDRESS_EQ -> "=="
    TOKEN_EQ -> "=="
    SELF_ADDRESS x y z -> "selfAddress" <> parens (render_das [pretty x, pretty y, pretty z])
    LSH -> "<<"
    RSH -> ">>"
    BAND t -> uitp t <> "&"
    BIOR t -> uitp t <> "|"
    BXOR t -> uitp t <> "^"
    BYTES_ZPAD x -> "zpad" <> parens (pretty x)
    MUL_DIV _ -> "muldiv"
    DIGEST_XOR -> "digest_xor"
    BYTES_XOR -> "bytes_xor"
    BTOI_LAST8 isDigest -> "btoiLast8(" <> bool "Bytes" "Digest" isDigest <> ")"
    STRINGDYN_CONCAT -> "StringDyn.concat"
    UINT_TO_STRINGDYN t -> "UInt" <> uitp t <> ".toStringDyn"
    CTC_ADDR_EQ -> "Contract.addressEq"
    GET_CONTRACT -> "getContract()"
    GET_ADDRESS -> "getAddress()"
    GET_COMPANION -> "getCompanion()"
    where
      uitp = \case
        UI_256 -> "b"
        UI_Word -> ""

data DLRemoteALGOOC
  = RA_NoOp
  | RA_OptIn
  | RA_CloseOut
  | RA_ClearState
  | RA_UpdateApplication --- XXX need the fields
  | RA_DeleteApplication
  deriving (Eq, Ord)

data DLRemoteALGOSTR -- simTokensRecv in `remote().ALGO({ simTokensRecv: [1, 2, 3] })`
  = RA_Unset               -- User never gave simTokensRecv
  | RA_List SrcLoc [DLArg] -- List of UInts given by user
  | RA_Tuple DLArg         -- Tuple of UInts compiled from list given by user
  deriving (Eq, Ord, Show)

data DLRemoteALGO = DLRemoteALGO
  { ralgo_fees :: DLArg
  , ralgo_accounts :: [DLArg]
  , ralgo_assets :: [DLArg]
  , ralgo_addr2acc :: Bool
  , ralgo_apps :: [DLArg]
  , ralgo_onCompletion :: DLRemoteALGOOC
  , ralgo_strictPay :: Bool
  , ralgo_rawCall :: Bool
  , ralgo_simNetRecv :: DLArg
  , ralgo_simTokensRecv :: DLRemoteALGOSTR
  , ralgo_simReturnVal :: Maybe DLArg
  }
  deriving (Eq, Ord)

zDLRemoteALGO :: DLRemoteALGO
zDLRemoteALGO = DLRemoteALGO argLitZero mempty mempty False mempty RA_NoOp False False argLitZero RA_Unset Nothing

instance PrettySubst DLRemoteALGO where
  prettySubst (DLRemoteALGO {..}) = do
    f' <- prettySubst ralgo_fees
    a' <- mapM prettySubst ralgo_assets
    p' <- mapM prettySubst ralgo_apps
    let a2a' = pretty ralgo_addr2acc
    let sp = pretty ralgo_strictPay
    return $
      render_obj $
        M.fromList
          [ ("fees" :: String, f')
          , ("assets", render_das a')
          , ("addr2acc", pretty a2a')
          , ("apps", render_das p')
          , ("strictPay", pretty sp)
          , ("rawCall", pretty ralgo_rawCall)
          ]

data DLContractNew = DLContractNew
  { dcn_code :: Value
  , dcn_opts :: Value
  }
  deriving (Eq, Ord, Generic)

instance PrettySubst Value where
  prettySubst = return . pretty . show

instance PrettySubst DLContractNew where
  prettySubst (DLContractNew {..}) = do
    c' <- prettySubst dcn_code
    o' <- prettySubst dcn_opts
    return $
      render_obj $
        M.fromList
        [ ("code" :: String, c')
        , ("mopts", o')
        ]

type DLContractNews = M.Map ConnectorName DLContractNew

data DLRemote = DLRemote
  { dr_mfun :: Maybe String
  , dr_pay :: DLPayAmt
  , dr_args :: [DLArg]
  , dr_bills :: DLWithBill
  , dr_ralgo :: DLRemoteALGO
  }
  deriving (Eq, Ord, Generic)

data DLExpr
  = DLE_Arg SrcLoc DLArg
  | DLE_LArg SrcLoc DLLargeArg
  | DLE_Impossible SrcLoc Int ImpossibleError
  | DLE_VerifyMuldiv SrcLoc [SLCtxtFrame] ClaimType [DLArg] ImpossibleError
  | DLE_PrimOp SrcLoc PrimOp [DLArg]
  | DLE_ArrayRef SrcLoc DLArg DLArg
  | DLE_ArraySet SrcLoc DLArg DLArg DLArg
  | DLE_ArrayConcat SrcLoc DLArg DLArg
  | DLE_BytesDynCast SrcLoc DLArg
  | DLE_TupleRef SrcLoc DLArg Integer
  | DLE_TupleSet SrcLoc DLArg Integer DLArg
  | DLE_ObjectRef SrcLoc DLArg String
  | DLE_ObjectSet SrcLoc DLArg SLVar DLArg
  | DLE_Interact SrcLoc [SLCtxtFrame] SLPart String DLType [DLArg]
  | DLE_Digest SrcLoc [DLArg]
  | DLE_Claim SrcLoc [SLCtxtFrame] ClaimType DLArg (Maybe B.ByteString)
  | DLE_Transfer SrcLoc DLArg DLArg (Maybe DLArg)
  | DLE_TokenInit SrcLoc DLArg
  | DLE_TokenAccepted SrcLoc DLArg DLArg
  | DLE_CheckPay SrcLoc [SLCtxtFrame] DLArg (Maybe DLArg)
  | DLE_Wait SrcLoc DLTimeArg
  | DLE_PartSet SrcLoc SLPart DLArg
  | DLE_MapRef SrcLoc DLMVar DLArg
  | DLE_MapSet SrcLoc DLMVar DLArg (Maybe DLArg)
  | DLE_Remote SrcLoc [SLCtxtFrame] DLArg DLType DLRemote
  | DLE_TokenNew SrcLoc DLTokenNew
  | DLE_TokenBurn SrcLoc DLArg DLArg
  | DLE_TokenDestroy SrcLoc DLArg
  | DLE_TimeOrder SrcLoc PrimOp (Maybe DLArg) DLVar
  | -- | DLE_EmitLog SrcLoc LogKind [DLVar]
    -- * the LogKind specifies whether the log generated from an API, Events, or is internal
    -- * the [DLVar] are the values to log
    DLE_EmitLog SrcLoc LogKind [DLVar]
  | DLE_setApiDetails
      { sad_at :: SrcLoc
      , sad_who :: SLPart
      , sad_dom :: [DLType]
      , sad_mcase_id :: Maybe String
      , sad_compile :: ApiInfoCompilation
      }
  | DLE_GetUntrackedFunds SrcLoc (Maybe DLArg) DLArg
  | DLE_DataTag SrcLoc DLArg
  | DLE_FromSome SrcLoc DLArg DLArg
  -- Maybe try to generalize FromSome into a Match
  | DLE_ContractNew SrcLoc DLContractNews DLRemote
  | DLE_ContractFromAddress SrcLoc DLArg
  deriving (Eq, Ord, Generic)

data LogKind
  = L_Api SLPart
  | L_Event (Maybe SLPart) String
  | L_Internal
  deriving (Eq, Ord, Show)

prettyClaim :: (PrettySubst a1, Show a2, Show a3) => a2 -> a1 -> a3 -> PrettySubstApp Doc
prettyClaim ct a m = do
  a' <- prettySubst a
  return $ "claim" <> parens (viaShow ct) <> parens (a' <> comma <+> viaShow m)

-- prettyTransfer :: Pretty a => a -> a -> Maybe a -> PrettySubstApp Doc
prettyTransfer :: (PrettySubst a1, PrettySubst a2, PrettySubst a3) => a1 -> a2 -> a3 -> PrettySubstApp Doc
prettyTransfer who da mta = do
  who' <- prettySubst who
  da' <- prettySubst da
  mta' <- prettySubst mta
  return $ "transfer." <> parens (da' <> ", " <> mta') <> ".to" <> parens who'

instance PrettySubst a => PrettySubst (Maybe a) where
  prettySubst = \case
    Just a -> do
      a' <- prettySubst a
      return $ "Some" <+> a'
    Nothing -> return "None"

instance (Pretty k, PrettySubst a) => PrettySubst (M.Map k a) where
  prettySubst x = render_obj <$> mapM prettySubst x

instance PrettySubst DLRemote where
  prettySubst (DLRemote ma amta as wb ra) = do
      amta' <- prettySubst amta
      as' <- render_dasM as
      wb' <- prettySubst wb
      ra' <- prettySubst ra
      return $ viaShow ma <> ".pay" <> parens amta'
        <> parens as'
        <> ".withBill"
        <> parens wb'
        <> ".ALGO"
        <> parens ra'

instance PrettySubst DLExpr where
  prettySubst = \case
    DLE_Arg _ a -> prettySubst a
    DLE_LArg _ a -> prettySubst a
    DLE_Impossible _ _ err -> return $ "impossible" <> parens (pretty err)
    DLE_VerifyMuldiv _ _ cl as _ -> do
      as' <- render_dasM as
      return $ "verifyMuldiv" <> parens (viaShow cl) <> parens as'
    DLE_PrimOp _ IF_THEN_ELSE [c, t, el] -> do
      c' <- prettySubst c
      t' <- prettySubst t
      e' <- prettySubst el
      return $ parens $ c' <> " ? " <> t' <> " : " <> e'
    DLE_PrimOp _ o [a] -> do
      a' <- prettySubst a
      return $ pretty o <> a'
    DLE_PrimOp _ o [a, b] -> do
      a' <- prettySubst a
      b' <- prettySubst b
      return $ a' <+> pretty o <+> b'
    DLE_PrimOp _ o as -> do
      as' <- render_dasM as
      return $ pretty o <> parens as'
    DLE_ArrayRef _ a o -> do
      a' <- prettySubst a
      o' <- prettySubst o
      return $ a' <> brackets o'
    DLE_ArraySet _ a i v -> do
      as' <- render_dasM [a, i, v]
      return $ "Array.set" <> parens as'
    DLE_ArrayConcat _ x y -> do
      as' <- render_dasM [x, y]
      return $ "Array.concat" <> parens as'
    DLE_BytesDynCast _ x -> do
      x' <- prettySubst x
      return $ "BytesDyn" <> parens x'
    DLE_TupleRef _ a i -> do
      a' <- prettySubst a
      return $ a' <> brackets (pretty i)
    DLE_ObjectRef _ a f -> do
      a' <- prettySubst a
      return $ a' <> "." <> pretty f
    DLE_Interact _ _ who m t as -> do
      as' <- render_dasM as
      return $ "protect" <> angles (pretty t) <> parens (pretty who <> ".interact." <> pretty m <> parens as')
    DLE_Digest _ as -> do
      as' <- render_dasM as
      return $ "digest" <> parens as'
    DLE_Claim _ _ ct a m -> prettyClaim ct a m
    DLE_Transfer _ who da mtok -> prettyTransfer who da mtok
    DLE_TokenInit _ tok -> do
      tok' <- prettySubst tok
      return $ "tokenInit" <> parens tok'
    DLE_TokenAccepted _ addr tok -> do
      addr' <- prettySubst addr
      tok' <- prettySubst tok
      return $ "canReceive" <> parens (addr' <> ", " <> tok')
    DLE_CheckPay _ _ da mtok -> do
      da' <- prettySubst da
      mtok' <- prettySubst mtok
      return $ "checkPay" <> parens (da' <> ", " <> mtok')
    DLE_Wait _ a -> do
      a' <- prettySubst a
      return $ "wait" <> parens a'
    DLE_PartSet _ who a -> do
      a' <- prettySubst a
      return $ render_sp who <> ".set" <> parens a'
    DLE_MapRef _ mv i -> do
      i' <- prettySubst i
      return $ pretty mv <> brackets i'
    DLE_MapSet _ mv kv (Just nv) -> do
      kv' <- prettySubst kv
      nv' <- prettySubst nv
      return $ pretty mv <> "[" <> kv' <> "]" <+> "=" <+> nv'
    DLE_MapSet _ mv i Nothing -> do
      i' <- prettySubst i
      return $ "delete" <+> pretty mv <> brackets i'
    DLE_Remote _ _ av _ dr -> do
      av' <- prettySubst av
      dr' <- prettySubst dr
      return $ "remote(" <> av' <> ")." <> dr'
    DLE_TokenNew _ tns -> do
      tns' <- prettySubst tns
      return $ "new Token" <> parens tns'
    DLE_TokenBurn _ tok amt -> do
      tok' <- prettySubst tok
      amt' <- prettySubst amt
      return $ "Token(" <> tok' <> ").burn(" <> amt' <> ")"
    DLE_TokenDestroy _ tok -> do
      tok' <- prettySubst tok
      return $ "Token(" <> tok' <> ").destroy()"
    DLE_TimeOrder _ op mx y -> do
      return $ "timeOrder" <> parens (pretty op <> ", " <> pretty mx <> ", " <> pretty y)
    DLE_EmitLog _ lk vs -> do
      lk' <- prettySubst lk
      vs' <- render_dasM $ map DLA_Var vs
      return $ "emitLog" <> parens lk' <> parens vs'
    DLE_setApiDetails _ p d mc f -> do
      let p' = pretty p
      let d' = pretty d
      mc' <- prettySubst mc
      let f' = pretty f
      return $ "setApiDetails" <> parens (render_das [p', d', mc', f'])
    DLE_GetUntrackedFunds _ mtok tb -> do
      mtok' <- prettySubst mtok
      tb' <- prettySubst tb
      return $ "getActualBalance" <> parens (mtok' <> ", " <> tb')
    DLE_DataTag _ d -> do
      d' <- prettySubst d
      return $ "dataTag" <> parens d'
    DLE_FromSome _ mo da -> do
      mo' <- prettySubst mo
      da' <- prettySubst da
      return $ "fromSome" <> parens (render_das [mo', da'])
    DLE_ContractFromAddress _ addr -> do
      addr' <- prettySubst addr
      return $ "ContractFromAddress" <> parens (render_das [addr'])
    DLE_ContractNew _ cns dr -> do
      cns' <- prettySubst cns
      dr' <- prettySubst dr
      return $ "new Contract" <> parens cns' <> "." <> dr'
    DLE_ObjectSet _ o k v -> do
      o' <- prettySubst o
      v' <- prettySubst v
      return $ "Object.set" <> parens (render_das [o', pretty k, v'])
    DLE_TupleSet _ t i v -> do
      t' <- prettySubst t
      v' <- prettySubst v
      return $ "Tuple.set" <> parens (render_das [t', pretty i, v'])

instance PrettySubst LogKind where
  prettySubst = \case
    L_Internal ->
      return $ "internal"
    L_Event ml s -> do
      return $ "event" <> parens (pretty ml <> ", " <> pretty s)
    L_Api s -> do
      return $ "api" <> parens (pretty s)

pretty_subst :: PrettySubst a => PrettySubstEnv -> a -> Doc
pretty_subst e x =
  runIdentity $ flip runReaderT e $ prettySubst x

instance IsPure PrimOp where
  isPure = \case
    ADD _ PV_Safe -> False
    SUB _ PV_Safe -> False
    MUL _ PV_Safe -> False
    DIV _ PV_Safe -> False
    MOD _ PV_Safe -> False
    UCAST _ _ _ PV_Safe -> False
    MUL_DIV PV_Safe     -> False
    _ -> True

instance IsPure DLExpr where
  isPure = \case
    DLE_Arg {} -> True
    DLE_LArg {} -> True
    DLE_Impossible {} -> True
    DLE_VerifyMuldiv {} -> False
    DLE_PrimOp _ op _ -> isPure op
    DLE_ArrayRef {} -> True
    DLE_ArraySet {} -> True
    DLE_ArrayConcat {} -> True
    DLE_BytesDynCast {} -> True
    DLE_TupleRef {} -> True
    DLE_ObjectRef {} -> True
    DLE_Interact {} -> False
    DLE_Digest {} -> True
    DLE_Claim {} ->
      -- These are all false, because we use purity to determine if we can
      -- reorder things and an assert can not be ordered outside of an IF to
      -- turn it into an ITE
      False
    DLE_Transfer {} -> False
    DLE_TokenInit {} -> False
    DLE_TokenAccepted {} -> False
    DLE_CheckPay {} -> False
    DLE_Wait {} -> False
    DLE_PartSet {} -> False
    DLE_MapRef {} -> True
    DLE_MapSet {} -> False
    DLE_Remote {} -> False
    DLE_TokenNew {} -> False
    DLE_TokenBurn {} -> False
    DLE_TokenDestroy {} -> False
    DLE_TimeOrder {} -> False
    DLE_EmitLog {} -> False
    DLE_setApiDetails {} -> False
    DLE_GetUntrackedFunds {} -> False
    DLE_DataTag {} -> True
    DLE_FromSome {} -> True
    DLE_ContractNew {} -> False
    DLE_ObjectSet {} -> True
    DLE_TupleSet {} -> True
    DLE_ContractFromAddress {} -> False

instance IsLocal DLExpr where
  isLocal = \case
    DLE_Arg {} -> True
    DLE_LArg {} -> True
    DLE_Impossible {} -> True
    DLE_VerifyMuldiv {} -> True
    DLE_PrimOp {} -> True
    DLE_ArrayRef {} -> True
    DLE_ArraySet {} -> True
    DLE_ArrayConcat {} -> True
    DLE_BytesDynCast {} -> True
    DLE_TupleRef {} -> True
    DLE_ObjectRef {} -> True
    DLE_Interact {} -> True
    DLE_Digest {} -> True
    DLE_Claim {} -> True
    DLE_Transfer {} -> False
    DLE_TokenInit {} -> False
    DLE_TokenAccepted {} -> False
    DLE_CheckPay {} -> False
    DLE_Wait {} -> False
    DLE_PartSet {} -> True
    DLE_MapRef {} -> True
    DLE_MapSet {} -> False
    DLE_Remote {} -> False
    DLE_TokenNew {} -> False
    DLE_TokenBurn {} -> False
    DLE_TokenDestroy {} -> False
    DLE_TimeOrder {} -> True
    DLE_EmitLog {} -> False
    DLE_setApiDetails {} -> False
    DLE_GetUntrackedFunds {} -> True
    DLE_DataTag {} -> True
    DLE_FromSome {} -> True
    DLE_ContractNew {} -> False
    DLE_ObjectSet {} -> True
    DLE_TupleSet {} -> True
    DLE_ContractFromAddress {} -> False

instance CanDupe DLExpr where
  canDupe = \case
    DLE_Arg {} -> True
    DLE_LArg {} -> True
    DLE_Impossible {} -> True
    DLE_VerifyMuldiv {} -> False
    DLE_PrimOp {} -> True
    DLE_ArrayRef {} -> True
    DLE_ArraySet {} -> True
    DLE_ArrayConcat {} -> True
    DLE_BytesDynCast {} -> True
    DLE_TupleRef {} -> True
    DLE_TupleSet {} -> True
    DLE_ObjectRef {} -> True
    DLE_ObjectSet {} -> True
    DLE_Interact {} -> False
    DLE_Digest {} -> True
    DLE_Claim {} -> False
    DLE_Transfer {} -> False
    DLE_TokenInit {} -> False
    DLE_TokenAccepted {} -> False
    DLE_CheckPay {} -> False
    DLE_Wait {} -> False
    DLE_PartSet {} -> False
    DLE_MapRef {} -> True
    DLE_MapSet {} -> False
    DLE_setApiDetails {} -> False
    DLE_GetUntrackedFunds {} -> False
    DLE_DataTag {} -> True
    DLE_FromSome {} -> True
    DLE_Remote {} -> False
    DLE_TokenNew {} -> False
    DLE_TokenBurn {} -> False
    DLE_TokenDestroy {} -> False
    DLE_TimeOrder {} -> False
    DLE_EmitLog {} -> False
    DLE_ContractNew {} -> False
    DLE_ContractFromAddress {} -> True

newtype DLAssignment
  = DLAssignment (M.Map DLVar DLArg)
  deriving (Eq, Generic, Show)
  deriving newtype (Monoid, Semigroup)

instance Pretty DLAssignment where
  pretty (DLAssignment m) = render_obj m

assignment_vars :: DLAssignment -> [DLVar]
assignment_vars (DLAssignment m) = M.keys m

data DLVarCat
  = DVC_Once
  | DVC_Many
  deriving (Eq, Show)

instance Semigroup DLVarCat where
  _ <> _ = DVC_Many

instance Pretty DLVarCat where
  pretty = \case
    DVC_Many -> "*"
    DVC_Once -> "!"

data DLLetVar
  = DLV_Eff
  | DLV_Let DLVarCat DLVar
  deriving (Eq, Show)

instance Pretty DLLetVar where
  pretty = \case
    DLV_Eff -> "eff"
    DLV_Let lc x -> pretty x <> pretty lc

lv2mdv :: DLLetVar -> Maybe DLVar
lv2mdv = \case
  DLV_Eff -> Nothing
  DLV_Let _ v -> Just v

data DLVarLet = DLVarLet (Maybe DLVarCat) DLVar
  deriving (Eq, Show)

instance Pretty DLVarLet where
  pretty (DLVarLet mvc x) = pretty x <> mvc'
    where
      mvc' = case mvc of
               Nothing -> "#"
               Just vc -> pretty vc

varLetVar :: DLVarLet -> DLVar
varLetVar (DLVarLet _ v) = v
varLetType :: DLVarLet -> DLType
varLetType = varType . varLetVar
v2vl :: DLVar -> DLVarLet
v2vl = DLVarLet (Just DVC_Many)

type SwitchCases a = M.Map SLVar (DLVar, Bool, a)

instance IsPure a => IsPure (SwitchCases a) where
  isPure = isPure . map (\(_,_,z)->z) . M.elems

data DLInvariant a = DLInvariant
  { dl_inv :: a
  , dl_inv_lab :: Maybe B.ByteString
  } deriving (Eq, Show)

instance Pretty a => Pretty (DLInvariant a) where
  pretty (DLInvariant {..}) =
    "invariant" <> parens (pretty dl_inv <> ", " <> pretty dl_inv_lab)

data DLStmt
  = DL_Nop SrcLoc
  | DL_Let SrcLoc DLLetVar DLExpr
  | DL_ArrayMap SrcLoc DLVar [DLArg] [DLVar] DLVar DLBlock
  | DL_ArrayReduce SrcLoc DLVar [DLArg] DLArg DLVar [DLVar] DLVar DLBlock
  | DL_Var SrcLoc DLVar
  | DL_Set SrcLoc DLVar DLArg
  | DL_LocalDo SrcLoc (Maybe DLVar) DLTail
  | DL_LocalIf SrcLoc (Maybe DLVar) DLArg DLTail DLTail
  | DL_LocalSwitch SrcLoc DLVar (SwitchCases DLTail)
  | DL_Only SrcLoc (Either SLPart Bool) DLTail
  | DL_MapReduce SrcLoc Int DLVar DLMVar DLArg DLVar DLVar DLBlock
  deriving (Eq)

instance SrcLocOf DLStmt where
  srclocOf = \case
    DL_Nop a -> a
    DL_Let a _ _ -> a
    DL_ArrayMap a _ _ _ _ _ -> a
    DL_ArrayReduce a _ _ _ _ _ _ _ -> a
    DL_Var a _ -> a
    DL_Set a _ _ -> a
    DL_LocalDo a _ _ -> a
    DL_LocalIf a _ _ _ _ -> a
    DL_LocalSwitch a _ _ -> a
    DL_Only a _ _ -> a
    DL_MapReduce a _ _ _ _ _ _ _ -> a

instance Pretty DLStmt where
  pretty = \case
    DL_Nop _ -> mempty
    DL_Let _ DLV_Eff de -> pretty de <> semi
    DL_Let _ x de -> "const" <+> pretty x <+> "=" <+> pretty de <> semi
    DL_ArrayMap _ ans xs as i f -> prettyMap ans xs as i f
    DL_ArrayReduce _ ans xs z b as i f -> prettyReduce ans xs z b as i f
    DL_Var _at dv -> "let" <+> pretty dv <> semi
    DL_Set _at dv da -> pretty dv <+> "=" <+> pretty da <> semi
    DL_LocalDo _at ans k -> "do"  <> parens (pretty ans) <+> braces (pretty k) <> semi
    DL_LocalIf _at ans ca t f -> "local" <> parens (pretty ans) <+> prettyIfp ca t f
    DL_LocalSwitch _at ov csm -> "local" <+> prettySwitch ov csm
    DL_Only _at who b -> prettyOnly who b
    DL_MapReduce _ _mri ans x z b a f -> prettyReduce ans x z b a () f

instance IsPure DLStmt where
  isPure = \case
    DL_Nop _ -> True
    DL_Let _ _ de -> isPure de
    DL_ArrayMap _ _ _ _ _ f -> isPure f
    DL_ArrayReduce _ _ _ _ _ _ _ f -> isPure f
    DL_Var {} -> True
    DL_Set {} -> True -- XXX This might be bad
    DL_LocalDo _ _ k -> isPure k
    DL_LocalIf _ _ _ t f -> isPure t && isPure f
    DL_LocalSwitch _ _ csm -> isPure csm
    DL_Only _ _ b -> isPure b
    DL_MapReduce _ _ _ _ _ _ _ f -> isPure f

mkCom :: (DLStmt -> k -> k) -> DLStmt -> k -> k
mkCom mk m k =
  case m of
    DL_Nop _ -> k
    DL_LocalDo _ _ k' ->
      dtReplace mk k k'
    _ -> mk m k

data DLTail
  = DT_Return SrcLoc
  | DT_Com DLStmt DLTail
  deriving (Eq)

instance Pretty DLTail where
  pretty = \case
    DT_Return _at -> mempty
    DT_Com x k -> prettyCom x k

instance IsPure DLTail where
  isPure = \case
    DT_Return {} -> True
    DT_Com s t -> isPure s && isPure t

dtReplace :: (DLStmt -> b -> b) -> b -> DLTail -> b
dtReplace mkk nk = \case
  DT_Return _ -> nk
  DT_Com m k -> (mkCom mkk) m $ dtReplace mkk nk k

dtList :: SrcLoc -> [DLStmt] -> DLTail
dtList at = \case
  [] -> DT_Return at
  m : ms -> DT_Com m $ dtList at ms
data DLBlock
  = DLBlock SrcLoc [SLCtxtFrame] DLTail DLArg
  deriving (Eq)

instance Pretty DLBlock where
  pretty (DLBlock _ _ ts ta) = prettyBlockP ts ta

instance IsPure DLBlock where
  isPure (DLBlock _ _ t _) = isPure t

data DLinExportBlock a
  = DLinExportBlock SrcLoc (Maybe [DLVarLet]) a
  deriving (Eq)

instance SrcLocOf (DLinExportBlock a) where
  srclocOf = \case
    DLinExportBlock a _ _ -> a

instance Pretty a => Pretty (DLinExportBlock a) where
  pretty = \case
    DLinExportBlock _ args b ->
      "export" <+> parens (pretty args) <+> "=>" <+> braces (pretty b)

dlebEnsureFun :: DLinExportBlock a -> DLinExportBlock a
dlebEnsureFun (DLinExportBlock at mvs a) =
  DLinExportBlock at (Just $ fromMaybe [] mvs) a

type DLExportBlock = DLinExportBlock DLBlock

instance ToJSON DLExportBlock where
  toJSON _ = "DLinExportBlock DLBlock"

type DLExports = M.Map SLVar DLExportBlock

data DLPayAmt = DLPayAmt
  { pa_net :: DLArg
  , pa_ks :: [(DLArg, DLArg)]
  }
  deriving (Eq, Generic, Ord, Show)

instance PrettySubst DLPayAmt where
  prettySubst (DLPayAmt {..}) = do
    pa_net' <- prettySubst pa_net
    pa_ks' <- render_dasM pa_ks
    return $ brackets $ pa_net' <> ", " <> pa_ks'

data DLSend = DLSend
  { ds_isClass :: Bool
  , ds_msg :: [DLArg]
  , ds_pay :: DLPayAmt
  , ds_when :: DLArg
  }
  deriving (Eq, Generic)

instance Pretty DLSend where
  pretty (DLSend {..}) =
    ".send"
      <> parens
        (render_obj $
           M.fromList $
             [ ("isClass" :: String, pretty ds_isClass)
             , ("msg", pretty ds_msg)
             , ("pay", pretty ds_pay)
             , ("when", pretty ds_when)
             ])

data DLRecv a = DLRecv
  { dr_from :: DLVar
  , dr_msg :: [DLVar]
  , dr_time :: DLVar
  , dr_secs :: DLVar
  , dr_didSend :: DLVar
  , dr_k :: a
  }
  deriving (Eq, Generic)

instance Pretty a => Pretty (DLRecv a) where
  pretty (DLRecv {..}) =
    ".recv"
      <> parens
        (render_obj $
           M.fromList $
             [ ("from" :: String, pretty dr_from)
             , ("msg", pretty dr_msg)
             , ("time", pretty dr_time)
             , ("secs", pretty dr_secs)
             , ("didSend", pretty dr_didSend)
             ])
      <> render_nest (pretty dr_k)

data FluidVar
  = FV_tokenInfos
  | FV_tokens
  | FV_netBalance
  | FV_thisConsensusTime
  | FV_lastConsensusTime
  | FV_baseWaitTime
  | FV_thisConsensusSecs
  | FV_lastConsensusSecs
  | FV_baseWaitSecs
  | FV_didSend
  deriving (Eq, Generic, Ord, Show)

instance Pretty FluidVar where
  pretty = \case
    FV_tokenInfos -> "tokenInfos"
    FV_tokens -> "tokens"
    FV_netBalance -> "netBalance"
    FV_thisConsensusTime -> "thisConsensusTime"
    FV_lastConsensusTime -> "lastConsensusTime"
    FV_baseWaitTime -> "baseWaitTime"
    FV_thisConsensusSecs -> "thisConsensusSecs"
    FV_lastConsensusSecs -> "lastConsensusSecs"
    FV_baseWaitSecs -> "baseWaitSecs"
    FV_didSend -> "didPublish"

fluidVarType :: FluidVar -> DLType
fluidVarType = \case
  FV_tokenInfos -> impossible "fluidVarType: FV_tokenInfos"
  FV_tokens -> impossible "fluidVarType: FV_tokens"
  FV_netBalance -> T_UInt UI_Word
  FV_thisConsensusTime -> T_UInt UI_Word
  FV_lastConsensusTime -> T_UInt UI_Word
  FV_baseWaitTime -> T_UInt UI_Word
  FV_thisConsensusSecs -> T_UInt UI_Word
  FV_lastConsensusSecs -> T_UInt UI_Word
  FV_baseWaitSecs -> T_UInt UI_Word
  FV_didSend -> T_Bool

allFluidVars :: [FluidVar]
allFluidVars =
  [ FV_thisConsensusTime
  , FV_lastConsensusTime
  , FV_baseWaitTime
  , FV_thisConsensusSecs
  , FV_lastConsensusSecs
  , FV_baseWaitSecs
  , FV_tokenInfos
  , FV_tokens
  , FV_netBalance
  -- This function is not really to get all of them, but just to
  -- get the ones that must be saved for a loop. didSend is only used locally,
  -- so it doesn't need to be saved.
  --, FV_didSend
  ]

class HasCounter a where
  getCounter :: a -> Counter

class HasUntrustworthyMaps a where
  getUntrustworthyMaps :: a -> Bool

type InterfaceLikeMap a = M.Map (Maybe SLPart) (M.Map SLVar a)

flattenInterfaceLikeMap :: forall a . InterfaceLikeMap a -> M.Map SLPart a
flattenInterfaceLikeMap = M.fromList . concatMap go . M.toList
  where
    go :: (Maybe SLPart, (M.Map SLVar a)) -> [(SLPart, a)]
    go (mp, m) = map (go' mp) $ M.toList m
    go' :: Maybe SLPart -> (SLVar, a) -> (SLPart, a)
    go' mp (v, x) = (fromMaybe "" (fmap (flip (<>) "_") mp) <> bpack v, x)

type DLView = (IType, [B.ByteString])

type DLViews = InterfaceLikeMap DLView

type ViewsInfo = InterfaceLikeMap DLExportBlock

data ViewInfo = ViewInfo [DLVar] ViewsInfo
  deriving (Eq)

instance Pretty ViewInfo where
  pretty (ViewInfo vs vi) =
    pform "view" (pretty vs <+> pretty vi)

type ViewInfos = M.Map Int ViewInfo

data DLViewsX = DLViewsX DLViews ViewInfos
  deriving (Eq)

instance Pretty DLViewsX where
  pretty (DLViewsX vs vis) = render_obj $ M.fromList
    [ ("vs"::String, pretty vs)
    , ("vis", pretty vis)
    ]

type Aliases = M.Map SLVar (Maybe B.ByteString)

type DLAPIs = InterfaceLikeMap (SLPart, IType)

type DLEvents = InterfaceLikeMap [DLType]

type ApiCalls = M.Map SLPart Int

arraysLength :: [DLArg] -> Integer
arraysLength arrays = do
  let sizes = map (snd . argArrTypeLen) arrays
  case allEqual sizes of
    Right s -> s
    _ -> impossible "Inconsistent array sizes."

adjustApiName :: Show a => String -> a -> Bool -> String
adjustApiName who which qualify = prefix <> who <> suffix
  where (prefix, suffix) = bool ("", "") ("_", show which) qualify

-- NOTE switch to Maybe DLAssignment and make sure we have a consistent order,
-- like with M.toAscList
data FromInfo
  = FI_Continue [(DLVar, DLArg)]
  | FI_Halt [DLArg]
  deriving (Eq)

instance Pretty FromInfo where
  pretty = \case
    FI_Continue svs -> pform "continue" (pretty svs)
    FI_Halt toks -> pform "halt" (pretty toks)
