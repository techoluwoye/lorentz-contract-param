-- | Module, containing data types for Michelson value.

module Michelson.Typed.Value
  ( Value' (..)
  , ContractInp
  , ContractOut
  , CreateAccount (..)
  , CreateContract (..)
  , CValue (..)
  , Operation (..)
  , SetDelegate (..)
  , TransferTokens (..)
  , ToVal
  , FromVal
  , toVal
  , fromVal
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Singletons (SingI)
import Fmt (Buildable(build), (+|), (|+))

import Michelson.EqParam
import Michelson.Typed.CValue (CValue(..), FromCVal, ToCVal, fromCVal, toCVal)
import Michelson.Typed.Scope (HasNoOp)
import Michelson.Typed.T (T(..), ToT)
import Tezos.Address (Address)
import Tezos.Core (Mutez, Timestamp)
import Tezos.Crypto (KeyHash, PublicKey, Signature)

-- | Data type, representing operation, list of which is returned
-- by Michelson contract (according to calling convention).
--
-- These operations are to be further executed against system state
-- after the contract execution.
data Operation instr where
  OpTransferTokens
    :: (Typeable p, SingI p, HasNoOp p)
    => TransferTokens instr p -> Operation instr
  OpSetDelegate :: SetDelegate -> Operation instr
  OpCreateAccount :: CreateAccount -> Operation instr
  OpCreateContract
    :: ( Show (instr (ContractInp cp st) (ContractOut st)), SingI cp, SingI st
       , Typeable instr, Typeable cp, Typeable st, HasNoOp cp, HasNoOp st)
    => CreateContract instr cp st
    -> Operation instr

instance Buildable (Operation instr) where
  build =
    \case
      OpTransferTokens tt -> build tt
      OpSetDelegate sd -> build sd
      OpCreateAccount ca -> build ca
      OpCreateContract cc -> build cc

deriving instance Show (Operation instr)
instance Eq (Operation instr) where
  op1 == op2 = case (op1, op2) of
    (OpTransferTokens tt1, OpTransferTokens tt2) -> eqParam1 tt1 tt2
    (OpTransferTokens _, _) -> False
    (OpSetDelegate sd1, OpSetDelegate sd2) -> sd1 == sd2
    (OpSetDelegate _, _) -> False
    (OpCreateAccount ca1, OpCreateAccount ca2) -> ca1 == ca2
    (OpCreateAccount _, _) -> False
    (OpCreateContract cc1, OpCreateContract cc2) -> eqParam3 cc1 cc2
    (OpCreateContract _, _) -> False

data TransferTokens instr p = TransferTokens
  { ttContractParameter :: !(Value' instr p)
  , ttAmount :: !Mutez
  , ttContract :: !(Value' instr ('TContract p))
  } deriving (Show, Eq)

instance Buildable (TransferTokens instr p) where
  build TransferTokens {..} =
    "Transfer " +| ttAmount |+ " tokens to " +| destAddr |+ ""
    where
      destAddr = case ttContract of VContract addr -> addr

data SetDelegate = SetDelegate
  { sdMbKeyHash :: !(Maybe KeyHash)
  } deriving (Show, Eq)

instance Buildable SetDelegate where
  build (SetDelegate mbDelegate) =
    "Set delegate to " <> maybe "<nobody>" build mbDelegate

data CreateAccount = CreateAccount
  { caManager :: !KeyHash
  , caDelegate :: !(Maybe KeyHash)
  , caSpendable :: !Bool
  , caBalance :: !Mutez
  } deriving (Show, Eq)

instance Buildable CreateAccount where
  build CreateAccount {..} =
    "Create a new account with manager " +| caManager |+
    " and delegate " +| maybe "<nobody>" build caDelegate |+
    ", spendable: " +| caSpendable |+
    " and balance = " +| caBalance |+ ""

data CreateContract instr cp st
  = ( Show (instr (ContractInp cp st) (ContractOut st))
    , Eq (instr (ContractInp cp st) (ContractOut st))
    )
  => CreateContract
  { ccManager :: !KeyHash
  , ccDelegate :: !(Maybe KeyHash)
  , ccSpendable :: !Bool
  , ccDelegatable :: !Bool
  , ccBalance :: !Mutez
  , ccStorageVal :: !(Value' instr st)
  , ccContractCode :: !(instr (ContractInp cp st) (ContractOut st))
  }

instance Buildable (CreateContract instr cp st) where
  build CreateContract {..} =
    "Create a new contract with manager " +| ccManager |+
    " and delegate " +| maybe "<nobody>" build ccDelegate |+
    ", spendable: " +| ccSpendable |+
    ", delegatable: " +| ccDelegatable |+
    " and balance = " +| ccBalance |+ ""

deriving instance Show (CreateContract instr cp st)
deriving instance Eq (CreateContract instr cp st)

type ContractInp param st = '[ 'TPair param st ]
type ContractOut st = '[ 'TPair ('TList 'TOperation) st ]

-- | Representation of Michelson value.
--
-- Type parameter @instr@ stands for Michelson instruction
-- type, i.e. data type to represent an instruction of language.

data Value' instr t where
  VC :: CValue t -> Value' instr ('Tc t)
  VKey :: PublicKey -> Value' instr 'TKey
  VUnit :: Value' instr 'TUnit
  VSignature :: Signature -> Value' instr 'TSignature
  VOption :: forall t instr. Maybe (Value' instr t) -> Value' instr ('TOption t)
  VList :: forall t instr. [Value' instr t] -> Value' instr ('TList t)
  VSet :: forall t instr. Set (CValue t) -> Value' instr ('TSet t)
  VOp :: Operation instr -> Value' instr 'TOperation
  VContract :: forall p instr. Address -> Value' instr ('TContract p)
  VPair :: forall l r instr. (Value' instr l, Value' instr r) -> Value' instr ('TPair l r)
  VOr :: forall l r instr. Either (Value' instr l) (Value' instr r) -> Value' instr ('TOr l r)
  VLam
    :: forall inp out instr.
       ( Show (instr '[inp] '[out])
       , Eq (instr '[inp] '[out])
       )
    => instr (inp ': '[]) (out ': '[]) -> Value' instr ('TLambda inp out)
  VMap :: forall k v instr. Map (CValue k) (Value' instr v) -> Value' instr ('TMap k v)
  VBigMap :: forall k v instr. Map (CValue k) (Value' instr v) -> Value' instr ('TBigMap k v)

deriving instance Show (Value' instr t)
deriving instance Eq (Value' instr t)

-- TODO: actually we should handle big maps with something close
-- to following:
--
--  VBigMap :: BigMap op ref k v -> Value' cp ('TBigMap k v)
--
-- data Value'Op v
--     = New v
--     | Upd v
--     | Rem
--     | NotExisted
--
-- data BigMap op ref k v = BigMap
--  { bmRef :: ref k v, bmChanges :: Map (CValue k) (Value'Op (Value' cp v)) }


-- | Converts a complex Haskell structure into @Value@ representation.
class ToVal a where
  toVal :: a -> Value' instr (ToT a)

-- | Converts a @Val@ value into complex Haskell type.
class FromVal t where
  fromVal :: Value' instr (ToT t) -> t

-- ToVal / FromVal instances

-- @gromak: we can write the following code instead of these
-- instances below, but I am not sure whether it's a good idea.
-- Note: if it breaks compilation for you, try to clean and
-- rebuild from scratch. It seems to compile fine.
-- instance {-# OVERLAPPABLE #-} ('Tc (ToCT t) ~ ToT t, FromCVal t) => FromVal t where
--   fromVal (VC cval) = fromCVal cval

instance FromVal Integer where
  fromVal (VC cval) = fromCVal cval

instance FromVal Natural where
  fromVal (VC cval) = fromCVal cval

instance FromVal Text where
  fromVal (VC cval) = fromCVal cval

instance FromVal Bool where
  fromVal (VC cval) = fromCVal cval

instance FromVal ByteString where
  fromVal (VC cval) = fromCVal cval

instance FromVal Mutez where
  fromVal (VC cval) = fromCVal cval

instance FromVal KeyHash where
  fromVal (VC cval) = fromCVal cval

instance FromVal Timestamp where
  fromVal (VC cval) = fromCVal cval

instance FromVal Address where
  fromVal (VC cval) = fromCVal cval

instance FromVal () where
  fromVal VUnit = ()

instance FromVal a => FromVal [a] where
  fromVal (VList lVals) = map fromVal lVals

instance FromVal a => FromVal (Maybe a) where
  fromVal (VOption Nothing) = Nothing
  fromVal (VOption (Just val)) = Just $ fromVal val

instance (FromVal a, FromVal b) => FromVal (Either a b) where
  fromVal (VOr (Left l)) = Left $ fromVal l
  fromVal (VOr (Right r)) = Right $ fromVal r

instance (FromVal a, FromVal b) => FromVal (a, b) where
  fromVal (VPair (a, b)) = (fromVal a, fromVal b)

instance (Ord k, FromCVal k) => FromVal (Set k) where
  fromVal (VSet s) = Set.map fromCVal s

instance (Ord k, FromCVal k, FromVal a) => FromVal (Map k a) where
  fromVal (VMap m) = Map.map fromVal $ Map.mapKeys fromCVal m

instance ToVal () where
  toVal _ = VUnit

instance ToVal Integer where
  toVal = VC . toCVal

instance ToVal Int where
  toVal = VC . toCVal

instance ToVal Word64 where
  toVal = VC . toCVal

instance ToVal Natural where
  toVal = VC . toCVal

instance ToVal Text where
  toVal = VC . toCVal

instance ToVal ByteString where
  toVal = VC . toCVal

instance ToVal Bool where
  toVal = VC . toCVal

instance ToVal Mutez where
  toVal = VC . toCVal

instance ToVal KeyHash where
  toVal = VC . toCVal

instance ToVal Timestamp where
  toVal = VC . toCVal

instance ToVal Address where
  toVal = VC . toCVal

instance ToVal a => ToVal (Maybe a) where
  toVal Nothing = VOption Nothing
  toVal (Just a) = VOption (Just $ toVal a)

instance (ToVal a, ToVal b) => ToVal (Either a b) where
  toVal (Left l) = VOr $ Left $ toVal l
  toVal (Right r) = VOr $ Right $ toVal r

instance (ToVal a, ToVal b) => ToVal (a, b) where
  toVal (l, r) = VPair (toVal l, toVal r)

instance ToVal x => ToVal [x] where
  toVal = VList . map toVal

instance ToCVal k => ToVal (Set k) where
  toVal = VSet . Set.map toCVal

-- Note: the instance produces Map not BigMap
instance (ToCVal k, ToVal a) => ToVal (Map k a) where
  toVal = VMap . Map.mapKeys toCVal . Map.map toVal
