-- | Utilities for integrational testing.
-- Example tests can be found in the 'morley-test' test suite.

module Michelson.Test.Integrational
  (
    -- * Re-exports
    TxData (..)
  , genesisAddress

  -- * Testing engine
  , IntegrationalValidator
  , SuccessValidator
  , IntegrationalScenarioM
  , IntegrationalScenario
  , integrationalTestExpectation
  , integrationalTestProperty
  , originate
  , transfer
  , validate
  , setMaxSteps
  , setNow

  -- * Validators
  , composeValidators
  , composeValidatorsList
  , expectAnySuccess
  , expectStorageUpdate
  , expectStorageUpdateConst
  , expectBalance
  , expectStorageConst
  , expectGasExhaustion
  , expectMichelsonFailed
  ) where

import Control.Lens (assign, at, makeLenses, (.=), (<>=))
import Control.Monad.Except (Except, runExcept, throwError)
import qualified Data.List as List
import Fmt (Buildable(..), blockListF, pretty, (+|), (|+))
import Test.Hspec (Expectation, expectationFailure)
import Test.QuickCheck (Property)

import Michelson.Interpret (InterpretUntypedError(..), MichelsonFailed(..), RemainingSteps)
import Michelson.Runtime
  (InterpreterError(..), InterpreterOp(..), InterpreterRes(..), interpreterPure)
import Michelson.Runtime.GState
import Michelson.Runtime.TxData
import Michelson.Test.Dummy
import Michelson.Test.Util (failedProp, succeededProp)
import Michelson.Untyped (Contract, OriginationOperation(..), Value, mkContractAddress)
import Tezos.Address (Address)
import Tezos.Core (Mutez, Timestamp)

----------------------------------------------------------------------------
-- Some internals (they are here because TH makes our very existence much harder)
----------------------------------------------------------------------------

data InternalState = InternalState
  { _isMaxSteps :: !RemainingSteps
  , _isNow :: !Timestamp
  , _isGState :: !GState
  , _isOperations :: ![InterpreterOp]
  -- ^ Operations to be interpreted when 'TOValidate' is encountered.
  }

makeLenses ''InternalState

----------------------------------------------------------------------------
-- Interface
----------------------------------------------------------------------------

-- | Validator for integrational testing.
-- If an error is expected, it should be 'Left' with validator for errors.
-- Otherwise it should check final global state and its updates.
type IntegrationalValidator = Either (InterpreterError -> Bool) SuccessValidator

-- | Validator for integrational testing that expects successful execution.
type SuccessValidator = (GState -> [GStateUpdate] -> Either ValidationError ())

-- | A monad inside which integrational tests can be described using
-- do-notation.
type IntegrationalScenarioM = StateT InternalState (Except ValidationError)

-- | A dummy data type that ensures that `validate` is called in the
-- end of each scenario. It is intentionally not exported.
data Validated = Validated

type IntegrationalScenario = IntegrationalScenarioM Validated

newtype ExpectedStorage = ExpectedStorage Value deriving (Show)
newtype ExpectedBalance = ExpectedBalance Mutez deriving (Show)

data ValidationError
  = UnexpectedInterpreterError InterpreterError
  | ExpectingInterpreterToFail
  | IncorrectUpdates ValidationError [GStateUpdate]
  | IncorrectStorageUpdate Address Text
  | InvalidStorage Address ExpectedStorage Text
  | InvalidBalance Address ExpectedBalance Text
  | CustomError Text
  deriving (Show)

instance Buildable ValidationError where
  build (UnexpectedInterpreterError iErr) =
    "Unexpected interpreter error. Reason: " +| iErr |+ ""
  build ExpectingInterpreterToFail =
    "Interpreter unexpectedly didn't fail"
  build (IncorrectUpdates vErr updates) =
    "Updates are incorrect: " +| vErr |+ " . Updates are:"
    +| blockListF updates |+ ""
  build (IncorrectStorageUpdate addr msg) =
    "Storage of " +| addr |+ "is updated incorrectly: " +| msg |+ ""
  build (InvalidStorage addr (ExpectedStorage expected) msg) =
    "Expected " +| addr |+ " to have storage " +| expected |+ ", but " +| msg |+ ""
  build (InvalidBalance addr (ExpectedBalance expected) msg) =
    "Expected " +| addr |+ " to have balance " +| expected |+ ", but " +| msg |+ ""
  build (CustomError msg) = pretty msg

instance Exception ValidationError where
  displayException = pretty

-- | Integrational test that executes given operations and validates
-- them using given validator. It can fail using 'Expectation'
-- capability.
-- It starts with 'initGState' and some reasonable dummy values for
-- gas limit and current timestamp. You can update blockchain state
-- by performing some operations.
integrationalTestExpectation :: IntegrationalScenario -> Expectation
integrationalTestExpectation =
  integrationalTest (maybe pass (expectationFailure . pretty))

-- | Integrational test similar to 'integrationalTestExpectation'.
-- It can fail using 'Property' capability.
-- It can be used with QuickCheck's @forAll@ to make a
-- property-based test with arbitrary data.
integrationalTestProperty :: IntegrationalScenario -> Property
integrationalTestProperty =
  integrationalTest (maybe succeededProp (failedProp . pretty))

-- | Originate a contract with given initial storage and balance. Its
-- address is returned.
originate :: Contract -> Value -> Mutez -> IntegrationalScenarioM Address
originate contract value balance = do
  mkContractAddress origination <$ putOperation originateOp
  where
    origination = (dummyOrigination value contract) {ooBalance = balance}
    originateOp = OriginateOp origination

-- | Transfer tokens to given address.
transfer :: TxData -> Address -> IntegrationalScenarioM ()
transfer txData destination =
  putOperation (TransferOp destination txData)

-- | Execute all operations that were added to the scenarion since
-- last 'validate' call. If validator fails, the execution will be aborted.
validate :: IntegrationalValidator -> IntegrationalScenario
validate validator = Validated <$ do
  now <- use isNow
  maxSteps <- use isMaxSteps
  gState <- use isGState
  ops <- use isOperations
  mUpdatedGState <-
    lift $ validateResult validator (interpreterPure now maxSteps gState ops)
  isOperations .= mempty
  whenJust mUpdatedGState $ \newGState -> isGState .= newGState

-- | Make all further interpreter calls (which are triggered by the
-- 'validate' function) use given timestamp as the current one.
setNow :: Timestamp -> IntegrationalScenarioM ()
setNow = assign isNow

-- | Make all further interpreter calls (which are triggered by the
-- 'validate' function) use given gas limit.
setMaxSteps :: RemainingSteps -> IntegrationalScenarioM ()
setMaxSteps = assign isMaxSteps

putOperation :: InterpreterOp -> IntegrationalScenarioM ()
putOperation op = isOperations <>= one op

----------------------------------------------------------------------------
-- Validators to be used within 'IntegrationalValidator'
----------------------------------------------------------------------------

-- | 'SuccessValidator' that always passes.
expectAnySuccess :: SuccessValidator
expectAnySuccess _ _ = pass

-- | Check that storage value is updated for given address. Takes a
-- predicate that is used to check the value.
--
-- It works even if updates are not filtered (i. e. a value can be
-- updated more than once).
expectStorageUpdate ::
     Address
  -> (Value -> Either ValidationError ())
  -> SuccessValidator
expectStorageUpdate addr predicate _ updates =
  case List.find checkAddr (reverse updates) of
    Nothing -> Left $ IncorrectStorageUpdate addr "storage wasn't updated"
    Just (GSSetStorageValue _ val) ->
      first (IncorrectStorageUpdate addr . pretty) $
      predicate val
    -- 'checkAddr' ensures that only 'GSSetStorageValue' can be found
    Just _ -> error "expectStorageUpdate: internal error"
  where
    checkAddr (GSSetStorageValue addr' _) = addr' == addr
    checkAddr _ = False

-- | Like 'expectStorageUpdate', but expects a constant.
expectStorageUpdateConst ::
     Address
  -> Value
  -> SuccessValidator
expectStorageUpdateConst addr expected =
  expectStorageUpdate addr predicate
  where
    predicate val
      | val == expected = pass
      | otherwise = Left $ IncorrectStorageUpdate addr $ pretty expected

-- | Check that eventually address has some particular storage value.
expectStorageConst :: Address -> Value -> SuccessValidator
expectStorageConst addr expected gs _ =
  case gsAddresses gs ^. at addr of
    Just (ASContract cs)
      | csStorage cs == expected -> pass
      | otherwise ->
        Left $ intro $ "its actual storage is: " <> (pretty $ csStorage cs)
    Just (ASSimple {}) ->
      Left $ intro $ "it's a simple address"
    Nothing -> Left $ intro $ "it's unknown"
  where
    intro = InvalidStorage addr (ExpectedStorage expected)

-- | Check that eventually address has some particular balance.
expectBalance :: Address -> Mutez -> SuccessValidator
expectBalance addr balance gs _ =
  case gsAddresses gs ^. at addr of
    Nothing ->
      Left $
      InvalidBalance addr (ExpectedBalance balance) "it's unknown"
    Just (asBalance -> realBalance)
      | realBalance == balance -> pass
      | otherwise ->
        Left $
        InvalidBalance addr (ExpectedBalance balance) $
        "its actual balance is: " <> pretty realBalance
-- | Compose two success validators.
--
-- For example:
--
-- expectBalance bal addr `composeValidators`
-- expectStorageUpdateConst addr2 ValueUnit
composeValidators ::
     SuccessValidator
  -> SuccessValidator
  -> SuccessValidator
composeValidators val1 val2 gState updates =
  val1 gState updates >> val2 gState updates

-- | Compose a list of success validators.
composeValidatorsList :: [SuccessValidator] -> SuccessValidator
composeValidatorsList = foldl' composeValidators expectAnySuccess

-- | Check that interpreter failed due to gas exhaustion.
expectGasExhaustion :: InterpreterError -> Bool
expectGasExhaustion =
  \case
    IEInterpreterFailed _ (RuntimeFailure (MichelsonGasExhaustion, _)) -> True
    _ -> False

-- | Expect that interpretation of contract with given address ended
-- with [FAILED].
expectMichelsonFailed :: (MichelsonFailed -> Bool) -> Address -> InterpreterError -> Bool
expectMichelsonFailed predicate addr =
  \case
    IEInterpreterFailed failedAddr (RuntimeFailure (mf, _)) ->
      addr == failedAddr && predicate mf
    _ -> False

----------------------------------------------------------------------------
-- Implementation of the testing engine
----------------------------------------------------------------------------

initIS :: InternalState
initIS = InternalState
  { _isNow = dummyNow
  , _isMaxSteps = dummyMaxSteps
  , _isGState = initGState
  , _isOperations = mempty
  }

integrationalTest ::
     (Maybe ValidationError -> res)
  -> IntegrationalScenario
  -> res
integrationalTest howToFail scenario =
  howToFail $ leftToMaybe $ runExcept (runStateT scenario initIS)

validateResult ::
     IntegrationalValidator
  -> Either InterpreterError InterpreterRes
  -> Except ValidationError (Maybe GState)
validateResult validator result =
  case (validator, result) of
    (Left validateError, Left err)
      | validateError err -> pure Nothing
    (_, Left err) -> doFail $ UnexpectedInterpreterError err
    (Left _, Right _) ->
      doFail $ ExpectingInterpreterToFail
    (Right validateUpdates, Right ir)
      | Left bad <- validateUpdates (_irGState ir) (_irUpdates ir) ->
        doFail $ IncorrectUpdates bad (_irUpdates ir)
      | otherwise -> pure $ Just $ _irGState ir
  where
    doFail = throwError
