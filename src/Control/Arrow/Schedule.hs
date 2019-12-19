{-# LANGUAGE Arrows        #-}
{-# LANGUAGE RankNTypes    #-}
{-# LANGUAGE TupleSections #-}

{-| Run scheduled computations in any (stateful) arrow, using an adapter. -}
module Control.Arrow.Schedule
  ( RunSchedA
  , runTick
  , runTicksTo
  , getInput
  , mkOutput
  , tickTask
  , module Data.Schedule
  )
where

-- external
import           Control.Arrow
import           Data.Functor.Identity  (Identity (..))
import           Data.Maybe             (fromMaybe)

-- internal
import           Data.Schedule
import           Data.Schedule.Internal


-- TODO: export to upstream arrows or extra
whileJustA :: (ArrowChoice a, Monoid o) => a i (Maybe o) -> a i o
whileJustA act = (, mempty) ^>> go
 where
  go = proc (i, rr) -> do
    r' <- act -< i
    case r' of
      Nothing -> returnA -< rr
      Just r  -> go -< (i, rr <> r)


-- | Something that can run @Schedule@ state arrows.
--
-- This could be pure (e.g. @StateArrow@) or impure (e.g. ref to a @PrimST@).
type RunSchedA t a = forall i o . ((i, Schedule t) -> (o, Schedule t)) -> a i o

runTick
  :: (ArrowChoice a, Monoid o) => RunSchedA t a -> a (Tick, t) o -> a Tick o
runTick runS runTickTask = whileJustA $ proc tick -> do
  r' <- runS (stA popOrTick) -< ()
  case r' of
    Nothing     -> returnA -< Nothing
    Just (t, p) -> do
      () <- runS (imodA acquireTask) -< (t, p)
      r  <- runTickTask -< (tick, p) -- TODO: catch Haskell exceptions here
      () <- runS (imodA releaseTask) -< t
      returnA -< Just r

runTicksTo
  :: (ArrowChoice a, Monoid o) => RunSchedA t a -> a (Tick, t) o -> a Tick o
runTicksTo runS runTask = whileJustA $ proc tick -> do
  tick' <- runS (getA tickNow) -< ()
  if tick' >= tick
    then returnA -< Nothing
    else Just ^<< runTick runS runTask -< tick

getInput
  :: (Arrow a)
  => RunSchedA t a
  -> a TickDelta (Either Tick i)
  -> a i' (Either Tick i)
getInput runS getTimedInput =
  runS (getA ticksToIdle) >>> arr (fromMaybe maxBound) >>> getTimedInput

mkOutput
  :: (ArrowChoice a, Monoid o)
  => RunSchedA t a
  -> a (Tick, t) o
  -> a i o
  -> a (Either Tick i) o
mkOutput runS runTask runInput = runTicksTo runS runTask ||| runInput

-- | A more general version of mkOutput that uses a prism-like optic.
--
-- Given an input executor @a it o@ where one branch of the @it@ type has
-- a @(Tick, t)@ tuple that represents individual input tasks, return a
-- convenience wrapper executor of type @a i o@ where the @i@ type only
-- has a @Tick@. When the wrapper executor receives these @Tick@ inputs, it
-- automatically resolves the relevant tasks of type @t@ that are active for
-- that @Tick@, and passes each tuple in sequence to the wrapped executor.
tickTask
  :: (ArrowChoice a, ArrowApply a, Monoid o)
  => RunSchedA t a
  -> (forall f . Applicative f => (Tick -> f (Tick, t)) -> i -> f it)
  -> a it o
  -> a i o
tickTask runS prism runTaskOr = proc input -> case prism Left input of
  Right it   -> runTaskOr -< it
  Left  tick -> runTicksTo runS (runTaskOr <<^ inputWithTask) -<< tick
    where inputWithTask tk = runIdentity (prism (const (pure tk)) input)