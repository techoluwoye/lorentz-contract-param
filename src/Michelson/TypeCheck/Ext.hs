-- | Type-checking of Morley extension.
module Michelson.TypeCheck.Ext
  ( typeCheckExt
  ) where

import Control.Lens ((%=))
import Control.Monad.Except (liftEither, throwError)
import Data.Map.Lazy (Map, insert, lookup)
import qualified Data.Map.Lazy as Map
import Data.Singletons (Sing)
import Data.Typeable ((:~:)(..))

import Michelson.TypeCheck.Error
import Michelson.TypeCheck.Helpers
import Michelson.TypeCheck.TypeCheck
import Michelson.TypeCheck.Types
import Michelson.Typed (converge, extractNotes, mkUType)
import qualified Michelson.Typed as T
import Michelson.Types
import Michelson.Untyped (CT(..))
import qualified Michelson.Untyped as U
import Util.Peano (Sing(SS, SZ))

type TypeCheckListHandler inp =
     [U.ExpandedOp]
  -> HST inp
  -> TypeCheckT (SomeInstr inp)

typeCheckExt
  :: forall s.
     (Typeable s)
  => TypeCheckListHandler s
  -> U.ExpandedExtInstr
  -> HST s
  -> TypeCheckT (SomeInstr s)
typeCheckExt typeCheckListH ext hst =
  case ext of
    U.STACKTYPE s -> liftExtError hst $ nopSomeInstr <$ checkStackType noBoundVars s hst
    U.FN t sf op  -> checkFn typeCheckListH t sf op hst
    U.UPRINT pc   -> verifyPrint pc <&> \tpc -> toSomeInstr (T.PRINT tpc)
    U.UTEST_ASSERT U.TestAssert{..} -> do
      verifyPrint tassComment
      _ :/ si <- typeCheckListH tassInstrs hst
      case si of
        AnyOutInstr _ -> throwError $ TCExtError (SomeHST hst) $ TestAssertError
                         "TEST_ASSERT has to return Bool, but it always fails"
        instr ::: (((_ :: (Sing b, T.Notes b, VarAnn)) ::& (_ :: HST out1))) -> do
          Refl <- liftEither $
                    first (const $ TCExtError (SomeHST hst) $
                           TestAssertError "TEST_ASSERT has to return Bool, but returned something else") $
                      eqType @b @('T.Tc 'CBool)
          tcom <- verifyPrint tassComment
          pure . toSomeInstr $ T.TEST_ASSERT $ T.TestAssert tassName tcom instr
        _ -> throwError $ TCExtError (SomeHST hst) $ TestAssertError "TEST_ASSERT has to return Bool, but the stack is empty"
  where
    verifyPrint :: U.PrintComment -> TypeCheckT (T.PrintComment s)
    verifyPrint (U.PrintComment pc) = do
      let checkStRef (Left txt) = pure (Left txt)
          checkStRef (Right (U.StackRef i)) = Right <$> do
            liftEither $ createStackRef i hst
      T.PrintComment <$> traverse checkStRef pc

    toSomeInstr ext' = hst :/ T.Ext ext' ::: hst
    nopSomeInstr = hst :/ T.Nop ::: hst

liftExtError :: Typeable s => HST s -> Either ExtError a -> TypeCheckT a
liftExtError hst = liftEither . first (TCExtError (SomeHST hst))

-- | Check that the optional "forall" variables are consistent if present
checkVars :: Text -> StackFn -> Either ExtError ()
checkVars t sf = case quantifiedVars sf of
  Just qs
    | varSet (inPattern sf) /= qs -> Left $ VarError t sf
  _ -> pure ()

-- | Executes function body, pushing @ExtFrame@ onto the state and checks
-- the pattern in @FN@.
checkFn
  :: Typeable inp
  => TypeCheckListHandler inp
  -> Text
  -> StackFn
  -> [ExpandedOp]
  -> HST inp
  -> TypeCheckT (SomeInstr inp)
checkFn typeCheckListH t sf body inp = do
  checkStart inp
  res@(_ :/ instr) <- typeCheckListH body inp
  case instr of
    _ ::: out -> checkEnd out
    AnyOutInstr _ -> pass
  return res
  where
    checkStart hst = do
      liftExtError hst $ checkVars t sf
      void . liftExtError hst $ checkStackType noBoundVars (inPattern sf) hst
      tcExtFramesL %= (SomeHST hst :)

    checkEnd :: Typeable out => HST out -> TypeCheckT ()
    checkEnd out = liftExtError out $ do
      checkVars t sf
      m <- checkStackType noBoundVars (inPattern sf) inp
      void $ checkStackType m (outPattern sf) out

data BoundVars = BoundVars (Map Var Type) (Maybe SomeHST)

noBoundVars :: BoundVars
noBoundVars = BoundVars Map.empty Nothing

-- | Check that a @StackTypePattern@ matches the type of the current stack
checkStackType :: Typeable xs => BoundVars -> U.StackTypePattern -> HST xs
               -> Either ExtError BoundVars
checkStackType (BoundVars vars boundStkRest) s hst = go vars 0 s hst
  where
    go :: Typeable xs => Map Var Type -> Int -> U.StackTypePattern -> HST xs
       -> Either ExtError BoundVars
    go m _ U.StkRest sr = case boundStkRest of
      Nothing -> pure $ BoundVars m (Just $ SomeHST sr)
      Just si@(SomeHST sr') ->
        bimap (StkRestMismatch s (SomeHST sr) si)
              (const $ BoundVars m (Just si))
              (eqHST sr sr')
    go m _ U.StkEmpty SNil = pure $ BoundVars m Nothing
    go _ _ U.StkEmpty _    = Left $ LengthMismatch s
    go _ _ _ SNil        = Left $ LengthMismatch s
    go m n (U.StkCons (TyCon t) ts) ((xt, xann, _) ::& xs) = do
      tann <- first (TypeMismatch s n . ExtractionTypeMismatch) (extractNotes t xt)
      void $ first (TypeMismatch s n . AnnError) (converge tann xann)
      go m (n + 1) ts xs
    go m n (U.StkCons (VarID v) ts) ((xt, xann, _) ::& xs) =
      case lookup v m of
        Nothing -> let t = mkUType xt xann in go (insert v t m) (n + 1) ts xs
        Just t -> do
          tann <- first (TyVarMismatch v t s n . ExtractionTypeMismatch) (extractNotes t xt)
          void $ first (TyVarMismatch v t s n . AnnError) (converge tann xann)
          go m (n + 1) ts xs

eqHST :: (Typeable as, Typeable bs) => HST as -> HST bs -> Either TCTypeError (as :~: bs)
eqHST (hst :: HST xs) (hst' :: HST ys) = do
  Refl <- (eqType @xs @ys)
  void $ convergeHST hst hst' `onLeft` AnnError
  return Refl

lengthHST :: HST xs -> Natural
lengthHST (_ ::& xs) = 1 + lengthHST xs
lengthHST SNil = 0

-- | Create stack reference accessing element with a given index.
--
-- Fails when index is too large for the given stack.
createStackRef :: Typeable s => Natural -> HST s -> Either TCError (T.StackRef s)
createStackRef idx hst =
  case doCreate (hst, idx) of
    Just sr -> Right sr
    Nothing -> Left $
      TCExtError (SomeHST hst) $
      InvalidStackReference (U.StackRef idx) (StackSize $ lengthHST hst)
  where
    doCreate :: forall s. (HST s, Natural) -> Maybe (T.StackRef s)
    doCreate = \case
      (SNil, _) -> Nothing
      ((_ ::& _), 0) -> Just (T.StackRef SZ)
      ((_ ::& st), i) -> do
        T.StackRef ns <- doCreate (st, i - 1)
        return $ T.StackRef (SS ns)
