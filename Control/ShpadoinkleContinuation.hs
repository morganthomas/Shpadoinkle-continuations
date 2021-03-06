{-# LANGUAGE InstanceSigs          #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}


module Control.ShpadoinkleContinuation
  ( Continuation (..), contIso
  , ContinuationT (..), voidRunContinuationT, kleisliT, commit
  , done, pur, impur, kleisli, causes
  , runContinuation
  , MapContinuations (..)
  , convertC
  , voidC, voidMC, forgetMC, forgetMC'
  , liftC, liftMC
  , leftC, leftMC, rightC, rightMC
  , maybeC, maybeMC, comaybe, comaybeC, comaybeMC
  , eitherC, eitherMC
  , writeUpdate, shouldUpdate
  ) where


import           Control.Arrow                 (first)
import qualified Control.Categorical.Functor   as F
import           Control.Monad                 (liftM2, void)
import           Control.Monad.Trans.Class
import           Control.PseudoInverseCategory
import           GHC.Conc                      (retry)
import           UnliftIO
import           UnliftIO.Concurrent


-- | The type of a state update in Shpadoinkle. A Continuation builds up an
--   atomic state update incrementally in a series of stages. For each stage we perform
--   a monadic IO computation and we may get a pure state updating function. When
--   all of the stages have been executed we are left with a composition of the resulting
--   pure state updating functions, and this composition is applied atomically to the state.
--
--   Additionally, a Continuation stage may feature a Rollback action which cancels all state
--   updates generated so far but allows for further state updates to be generated based on
--   further monadic IO computation.
--
--   The functions generating each stage of the Continuation
--   are called with states which reflect the current state of the app, with all
--   the pure state updating functions generated so far having been
--   applied to it, so that each stage "sees" both the current state
--   (even if it changed since the start of computing the continuation), and the updates made
--   so far, although those updates are not committed to the real state until the continuation
--   finishes and they are all done atomically together.
data Continuation m a = Continuation (a -> a, a -> m (Continuation m a))
                      | Rollback (Continuation m a)
                      | Pure (a -> a)



-- | A pure state updating function can be turned into a Continuation. This function
--   is here so that users of the Continuation API can do basic things without needing
--   to depend on the internal structure of the type.
pur :: (a -> a) -> Continuation m a
pur = Pure


-- | A continuation which doesn't touch the state and doesn't have any side effects.
done :: Continuation m a
done = pur id


-- | A monadic computation of a pure state updating function can be turned into a Continuation.
impur :: Monad m => m (a -> a) -> Continuation m a
impur m = Continuation . (id,) . const $ do
  f <- m
  return $ Continuation (f, const (return done))


kleisli :: (a -> m (Continuation m a)) -> Continuation m a
kleisli = Continuation . (id,)


-- | A monadic computation can be turned into a Continuation which does not touch the state.
causes :: Monad m => m () -> Continuation m a
causes m = impur (m >> return id)


-- | runContinuation takes a Continuation and a state value and runs the whole continuation
--   as if the real state was frozen at the value given to runContinuation. It performs all the
--   IO actions in the stages of the continuation and returns a pure state updating function
--   which is the composition of all the pure state updating functions generated by the
--   non-rolled-back stages of the continuation. If you are trying to update a Continuous
--   territory, then you should probably be using writeUpdate instead of runContinuation,
--   because writeUpdate will allow each stage of the continuation to see any extant updates
--   made to the territory after the continuation started running.
runContinuation :: Monad m => Continuation m a -> a -> m (a -> a)
runContinuation = runContinuation' id


runContinuation' :: Monad m => (a -> a) -> Continuation m a -> a -> m (a -> a)
runContinuation' f (Continuation (g, h)) x = do
  i <- h (f x)
  runContinuation' (g.f) i x
runContinuation' _ (Rollback f) x = runContinuation' id f x
runContinuation' f (Pure g) _ = return (g.f)


-- | f is a Functor to Hask from the category where the objects are
--   Continuation types and the morphisms are functions.
class MapContinuations f where
  mapMC :: Functor m => Functor n => (Continuation m a -> Continuation n b) -> f m a -> f n b


instance MapContinuations Continuation where
  mapMC = id


-- | Given a natural transformation, change a continuation's underlying functor.
convertC :: Functor m => (forall b. m b -> n b) -> Continuation m a -> Continuation n a
convertC _ (Pure f) = Pure f
convertC f (Rollback r) = Rollback (convertC f r)
convertC f (Continuation (g, h)) = Continuation . (g,) $ \x -> f $ convertC f <$> h x


-- | Apply a lens inside a continuation to change the continuation's type.
liftC :: Functor m => (a -> b -> b) -> (b -> a) -> Continuation m a -> Continuation m b
liftC f g (Pure h) = Pure (\x -> f (h (g x)) x)
liftC f g (Rollback r) = Rollback (liftC f g r)
liftC f g (Continuation (h, i)) = Continuation (\x -> f (h (g x)) x, \x -> liftC f g <$> i (g x))


-- | Given a lens, change the value type of f by applying the lens in the continuations inside f.
liftMC :: Functor m => MapContinuations f => (a -> b -> b) -> (b -> a) -> f m a -> f m b
liftMC f g = mapMC (liftC f g)


-- | Change a void continuation into any other type of continuation.
voidC :: Monad m => Continuation m () -> Continuation m a
voidC f = Continuation . (id,) $ \_ -> do
  _ <- runContinuation f ()
  return done


-- | Change the type of the f-embedded void continuations into any other type of continuation.
voidMC :: Monad m => MapContinuations f => f m () -> f m a
voidMC = mapMC voidC


-- | Forget about the continuations.
forgetMC :: Monad m => Monad n => MapContinuations f => f m a -> f n b
forgetMC = mapMC (const done)


-- | Forget about the continuations without changing the monad. This can be easier on type inference compared to forgetMC.
forgetMC' :: Monad m => MapContinuations f => f m a -> f m b
forgetMC' = forgetMC


--- | Change the type of a continuation by applying it to the left coordinate of a tuple.
leftC :: Functor m => Continuation m a -> Continuation m (a,b)
leftC = liftC (\x (_,y) -> (x,y)) fst


-- | Change the type of f by applying the continuations inside f to the left coordinate of a tuple.
leftMC :: Functor m => MapContinuations f => f m a -> f m (a,b)
leftMC = mapMC leftC


-- | Change the type of a continuation by applying it to the right coordinate of a tuple.
rightC :: Functor m => Continuation m b -> Continuation m (a,b)
rightC = liftC (\y (x,_) -> (x,y)) snd


-- | Change the value type of f by applying the continuations inside f to the right coordinate of a tuple.
rightMC :: Functor m => MapContinuations f => f m b -> f m (a,b)
rightMC = mapMC rightC


-- | Transform a continuation to work on Maybes. If it encounters Nothing, then it cancels itself.
maybeC :: Applicative m => Continuation m a -> Continuation m (Maybe a)
maybeC (Pure f) = (Pure (fmap f))
maybeC (Rollback r) = Rollback (maybeC r)
maybeC (Continuation (f, g)) = Continuation . (fmap f,) $
  \case
    Just x -> maybeC <$> g x
    Nothing -> pure (Rollback done)


-- | Change the value type of f by transforming the continuations inside f to work on Maybes using maybeC.
maybeMC :: Applicative m => MapContinuations f => f m a -> f m (Maybe a)
maybeMC = mapMC maybeC


-- | Turn a 'Maybe a' updating function into an 'a' updating function which acts as
--   the identity function when the input function outputs Nothing.
comaybe :: (Maybe a -> Maybe a) -> (a -> a)
comaybe f x = case f (Just x) of
  Nothing -> x
  Just y  -> y


-- | Change the type of a Maybe-valued continuation into the Maybe-wrapped type.
--   The resulting continuation acts like the input continuation except that
--   when the input continuation would replace the current value with Nothing,
--   instead the current value is retained.
comaybeC :: Functor m => Continuation m (Maybe a) -> Continuation m a
comaybeC (Pure f) = Pure (comaybe f)
comaybeC (Rollback r) = Rollback (comaybeC r)
comaybeC (Continuation (f,g)) = Continuation (comaybe f, fmap comaybeC . g . Just)


-- | Transform the continuations inside f using comaybeC.
comaybeMC :: Functor m => MapContinuations f => f m (Maybe a) -> f m a
comaybeMC = mapMC comaybeC


-- Just define these rather than introducing another dependency even though they are in either
mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f (Left x)  = Left (f x)
mapLeft _ (Right x) = Right x


mapRight :: (b -> c) -> Either a b -> Either a c
mapRight _ (Left x)  = Left x
mapRight f (Right x) = Right (f x)


-- | Combine continuations heterogeneously into coproduct continuations.
--   The first value the continuation sees determines which of the
--   two input continuation branches it follows. If the coproduct continuation
--   sees the state change to a different Either-branch, then it cancels itself.
--   If the state is in a different Either-branch when the continuation
--   completes than it was when the continuation started, then the
--   coproduct continuation will have no effect on the state.
eitherC :: Monad m => Continuation m a -> Continuation m b -> Continuation m (Either a b)
eitherC f g = Continuation . (id,) $ \case
  Left x -> case f of
    Pure h -> return (Pure (mapLeft h))
    Rollback r -> return . Rollback $ eitherC r done
    Continuation (h, i) -> do
      j <- i x
      return $ Continuation (mapLeft h, const . return $ eitherC j (Rollback done))
  Right x -> case g of
    Pure h -> return (Pure (mapRight h))
    Rollback r -> return . Rollback $ eitherC done r
    Continuation (h, i) -> do
      j <- i x
      return $ Continuation (mapRight h, const . return $ eitherC (Rollback done) j)


-- | Create a structure containing coproduct continuations using two case
--   alternatives which generate structures containing continuations of
--   the types inside the coproduct. The continuations in the resulting
--   structure will only have effect on the state while it is in the branch
--   of the coproduct selected by the input value used to create the structure.
eitherMC :: Monad m => MapContinuations f => (a -> f m a) -> (b -> f m b) -> Either a b -> f m (Either a b)
eitherMC l _ (Left x)  = mapMC (\c -> eitherC c (pur id)) (l x)
eitherMC _ r (Right x) = mapMC (\c -> eitherC (pur id) c) (r x)


-- | Transform the type of a continuation using an isomorphism.
contIso :: Functor m => (a -> b) -> (b -> a) -> Continuation m a -> Continuation m b
contIso f g (Continuation (h, i)) = Continuation (f.h.g, fmap (contIso f g) . i . g)
contIso f g (Rollback h) = Rollback (contIso f g h)
contIso f g (Pure h) = Pure (f.h.g)


-- | Continuation m is a functor in the EndoIso category (where the objects
--   are types and the morphisms are EndoIsos).
instance Applicative m => F.Functor EndoIso EndoIso (Continuation m) where
  map (EndoIso f g h) =
    EndoIso (Continuation . (f,) . const . pure) (contIso g h) (contIso h g)


-- | You can combine multiple continuations homogeneously using the Monoid typeclass
--   instance. The resulting continuation will execute all the subcontinuations in parallel,
--   allowing them to see each other's state updates and roll back each other's updates,
--   applying all of the updates generated by all the subcontinuations atomically once
--   all of them are done.
instance Monad m => Semigroup (Continuation m a) where
  (Continuation (f, g)) <> (Continuation (h, i)) =
    Continuation (f.h, \x -> liftM2 (<>) (g x) (i x))
  (Continuation (f, g)) <> (Rollback h) =
    Rollback (Continuation (f, (\x -> liftM2 (<>) (g x) (return h))))
  (Rollback h) <> (Continuation (_, g)) =
    Rollback (Continuation (id, \x -> liftM2 (<>) (return h) (g x)))
  (Rollback f) <> (Rollback g) = Rollback (f <> g)
  (Pure f) <> (Pure g) = Pure (f.g)
  (Pure f) <> (Continuation (g,h)) = Continuation (f.g,h)
  (Continuation (f,g)) <> (Pure h) = Continuation (f.h,g)
  (Pure f) <> (Rollback g) = Continuation (f, const (return (Rollback g)))
  (Rollback f) <> (Pure _) = Rollback f


-- | Since combining continuations homogeneously is an associative operation,
--   and this operation has a unit element (done), continuations are a Monoid.
instance Monad m => Monoid (Continuation m a) where
  mempty = done


writeUpdate' :: MonadUnliftIO m => (a -> a) -> TVar a -> (a -> m (Continuation m a)) -> m ()
writeUpdate' h model f = do
  i <- readTVarIO model
  m <- f (h i)
  case m of
    Continuation (g,gs) -> writeUpdate' (g.h) model gs
    Pure g -> atomically $ writeTVar model =<< g.h <$> readTVar model
    Rollback gs -> writeUpdate' id model (const (return gs))


-- | Run a continuation on a state variable. This may update the state.
--   This is a synchronous, non-blocking operation for pure updates,
--   and an asynchronous, non-blocking operation for impure updates.
writeUpdate :: MonadUnliftIO m => TVar a -> Continuation m a -> m ()
writeUpdate model = \case
  Continuation (f,g) -> void . forkIO $ writeUpdate' f model g
  Pure f -> atomically $ writeTVar model =<< f <$> readTVar model
  Rollback f -> writeUpdate model f


-- | Execute a fold by watching a state variable and executing the next
--   step of the fold each time it changes.
shouldUpdate :: MonadUnliftIO m => Eq a => (b -> a -> m b) -> b -> TVar a -> m ()
shouldUpdate sun prev model = do
  i' <- readTVarIO model
  p  <- newTVarIO i'
  () <$ forkIO (go prev p)
  where
    go x p = do
      a <- atomically $ do
        new' <- readTVar model
        old  <- readTVar p
        if new' == old then retry else new' <$ writeTVar p new'
      y <- sun x a
      go y p

newtype ContinuationT model m a = ContinuationT
  { runContinuationT :: m (a, Continuation m model) }


commit :: Monad m => Continuation m model -> ContinuationT model m ()
commit = ContinuationT . return . ((),)


voidRunContinuationT :: Monad m => ContinuationT model m a -> Continuation m model
voidRunContinuationT m = Continuation . (id,) . const $ snd <$> runContinuationT m


kleisliT :: Monad m => (model -> ContinuationT model m a) -> Continuation m model
kleisliT f = kleisli $ \x -> return . voidRunContinuationT $ f x


instance Functor m => Functor (ContinuationT model m) where
  fmap f = ContinuationT . fmap (first f) . runContinuationT


instance Monad m => Applicative (ContinuationT model m) where
  pure = ContinuationT . pure . (, done)

  ft <*> xt = ContinuationT $ do
    (f, fc) <- runContinuationT ft
    (x, xc) <- runContinuationT xt
    return (f x, fc <> xc)


instance Monad m => Monad (ContinuationT model m) where
  return = ContinuationT . return . (, done)

  m >>= f = ContinuationT $ do
    (x, g) <- runContinuationT m
    (y, h) <- runContinuationT (f x)
    return (y, g <> h)


instance MonadTrans (ContinuationT model) where
  lift = ContinuationT . fmap (, done)
