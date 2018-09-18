{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE ScopedTypeVariables #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Test
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- Module containing testing helpers shared across all broadcast-chan packages.
-------------------------------------------------------------------------------
module BroadcastChan.Test
    ( (@?)
    , expect
    , doNothing
    , doPrint
    , genStreamTests
    , runTests
    , MonadIO(..)
    , mapHandler
    -- * Re-exports of @tasty@ and @tasty-hunit@
    , module Test.Tasty
    , module Test.Tasty.HUnit
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>),(<*>))
#endif
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Exception (Exception, throwIO, try)
import Data.Bifunctor (second)
import Data.List (sort)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Monoid ((<>), mconcat)
import Data.Proxy (Proxy(Proxy))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Tagged (Tagged, untag)
import Data.Typeable (Typeable)
import Options.Applicative (switch, long, help)
import System.Clock
    (Clock(Monotonic), TimeSpec, diffTimeSpec, getTime, toNanoSecs)
#if !MIN_VERSION_base(4,7,0)
import System.Posix.Env (setEnv)
#else
import System.Environment (setEnv)
#endif
import System.IO (Handle, SeekMode(AbsoluteSeek), hPrint, hSeek)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty
import Test.Tasty.Golden.Advanced (goldenTest)
import Test.Tasty.HUnit hiding ((@?))
import qualified Test.Tasty.HUnit as HUnit
import Test.Tasty.Options
import Test.Tasty.Travis

import BroadcastChan.Extra (Action(..), Handler(..), mapHandler)
import ParamTree

infix 0 @?
-- | Monomorphised version of 'Test.Tasty.HUnit.@?' to avoid ambiguous type
-- errors when combined with predicates that are @MonadIO m => m Bool@.
(@?) :: IO Bool -> String -> Assertion
(@?) = (HUnit.@?)

-- | Test which fails if the expected exception is not thrown by the 'IO'
-- action.
expect :: (Eq e, Exception e) => e -> IO () -> Assertion
expect err act = do
    result <- try act
    case result of
        Left e | e == err -> return ()
               | otherwise -> assertFailure $
                                "Expected: " ++ show err ++ "\nGot: " ++ show e
        Right _ -> assertFailure $ "Expected exception, got success."

-- | Pauses a number of microseconds before returning its input.
doNothing :: Int -> a -> IO a
doNothing threadPause x = do
    threadDelay threadPause
    return x

-- | Print a value, then return it.
doPrint :: Show a => Handle -> a -> IO a
doPrint hnd x = do
    hPrint hnd x
    return x

fromTimeSpec :: Fractional n => TimeSpec -> n
fromTimeSpec = fromIntegral . toNanoSecs

speedupTest
    :: forall r . (Eq r, Show r)
    => IO (TVar (Map ([Int], Int) (MVar (r, Double))))
    -> ([Int] -> (Int -> IO Int) -> IO r)
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r)
    -> Int
    -> [Int]
    -> Int
    -> String
    -> TestTree
speedupTest getCache seqSink parSink n inputs pause name = testCase name $ do
    withAsync cachedSequential $ \seqAsync ->
      withAsync (timed $ parSink inputs testFun n) $ \parAsync -> do
        (seqResult, seqTime) <- wait seqAsync
        (parResult, parTime) <- wait parAsync
        seqResult @=? parResult
        let lowerBound :: Double
            lowerBound = seqTime / (fromIntegral n + 1)

            upperBound :: Double
            upperBound = seqTime / (fromIntegral n - 1)

            errorMsg :: String
            errorMsg = mconcat
                [ "Parallel time should be 1/"
                , show n
                , "th of sequential time!\n"
                , "Actual time was 1/"
                , show (round $ seqTime / parTime :: Int)
                , "th (", show (seqTime/parTime), ")"
                ]
        assertBool errorMsg $ lowerBound < parTime && parTime < upperBound
  where
    testFun :: Int -> IO Int
    testFun = doNothing pause

    timed :: IO a -> IO (a, Double)
    timed = fmap (\(x, t) -> (x, fromTimeSpec t)) . withTime

    cachedSequential :: IO (r, Double)
    cachedSequential = do
        mvar <- newEmptyMVar
        cacheTVar <- getCache
        result <- atomically $ do
            cacheMap <- readTVar cacheTVar
            let (oldVal, newMap) = M.insertLookupWithKey
                    (\_ _ v -> v)
                    (inputs, pause)
                    mvar
                    cacheMap
            writeTVar cacheTVar newMap
            return oldVal

        case result of
            Just var -> readMVar var
            Nothing -> do
                timed (seqSink inputs testFun) >>= putMVar mvar
                readMVar mvar

nonDeterministicGolden
    :: forall r
     . (Eq r, Show r)
    => String
    -> (Handle -> IO r)
    -> (Handle -> IO r)
    -> TestTree
nonDeterministicGolden label controlAction testAction =
  goldenTest label (normalise control) (normalise test) diff update
  where
    normalise :: MonadIO m => IO (a, Text) -> m (a, Text)
    normalise = liftIO . fmap (second (T.strip . T.unlines . sort . T.lines))

    rewindAndRead :: Handle -> IO Text
    rewindAndRead hnd = do
        hSeek hnd AbsoluteSeek 0
        T.hGetContents hnd

    control :: IO (r, Text)
    control = withSystemTempFile "control.out" $ \_ hndl ->
        (,) <$> controlAction hndl <*> rewindAndRead hndl

    test :: IO (r, Text)
    test = withSystemTempFile "test.out" $ \_ hndl ->
        (,) <$> testAction hndl <*> rewindAndRead hndl

    diff :: (r, Text) -> (r, Text) -> IO (Maybe String)
    diff (controlResult, controlOutput) (testResult, testOutput) =
        return $ resultDiff <> outputDiff
      where
        resultDiff :: Maybe String
        resultDiff
            | controlResult == testResult = Nothing
            | otherwise = Just "Results differ!\n"

        outputDiff :: Maybe String
        outputDiff
            | controlOutput == testOutput = Nothing
            | otherwise = Just . mconcat $
                [ "Outputs differ!\n"
                , "Expected:\n\"", T.unpack controlOutput, "\"\n\n"
                , "Got:\n\"", T.unpack testOutput, "\"\n"
                ]

    update :: (r, Text) -> IO ()
    update _ = return ()

outputTest
    :: forall r . (Eq r, Show r)
    => ([Int] -> (Int -> IO Int) -> IO r)
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r)
    -> Int
    -> [Int]
    -> String
    -> TestTree
outputTest seqSink parSink threads inputs label =
    nonDeterministicGolden label seqTest parTest
  where
    seqTest :: Handle -> IO r
    seqTest = seqSink inputs . doPrint

    parTest :: Handle -> IO r
    parTest hndl = parSink inputs (doPrint hndl) threads

data TestException = TestException deriving (Eq, Show, Typeable)
instance Exception TestException

exceptionTests
    :: (Eq r, Show r)
    => ([Int] -> (Int -> IO Int) -> IO r)
    -> (Handler IO Int -> [Int] -> (Int -> IO Int) -> Int -> IO r)
    -> TestTree
exceptionTests _seqImpl parImpl = testGroup "exceptions" $
    [ testCase "termination" . expect TestException . void $
        withSystemTempFile "terminate.out" $ \_ hndl ->
            parImpl (Simple Terminate) inputs (dropEven hndl) 4
    ]
  where
    inputs = [1..100]

    dropEven hnd n
      | even n = throwIO TestException
      | otherwise = doPrint hnd n

newtype SlowTests = SlowTests Bool
  deriving (Eq, Ord, Typeable)

instance IsOption SlowTests where
  defaultValue = SlowTests False
  parseValue = fmap SlowTests . safeRead
  optionName = return "slow-tests"
  optionHelp = return "Run slow tests."
  optionCLParser =
    fmap SlowTests $
    switch
      (  long (untag (optionName :: Tagged SlowTests String))
      <> help (untag (optionHelp :: Tagged SlowTests String))
      )

-- | Takes a name, a sequential sink, and a parallel sink and generates tasty
-- tests from these.
--
-- The parallel and sequential sink should perform the same tasks so their
-- results can be compared to check correctness.
--
-- The sinks should take a list of input data, a function processing the data,
-- and return a result that can be compared for equality.
--
-- Furthermore the parallel sink should take a number indicating how many
-- concurrent consumers should be used.
genStreamTests
    :: (Eq r, Show r)
    => String -- ^ Name to group tests under
    -> ([Int] -> (Int -> IO Int) -> IO r) -- ^ Sequential sink
    -> (Handler IO Int -> [Int] -> (Int -> IO Int) -> Int -> IO r)
    -- ^ Parallel sink
    -> TestTree
genStreamTests name f g = askOption $ \(SlowTests slow) ->
    withResource (newTVarIO M.empty) (const $ return ()) $ \getCache ->
    let
        testTree = growTree (Just ".") testGroup
        params
          | slow = simpleParam "threads" [1,2,5]
                 . derivedParam (enumFromTo 0) "inputs" [600]
          | otherwise = simpleParam "threads" [1,2,5]
                      . derivedParam (enumFromTo 0) "inputs" [300]
        pause = simpleParam "pause" [10^(5 :: Int)]

    in testGroup name
        [ testTree "output" (outputTest f (g term)) params
        , testTree "speedup" (speedupTest getCache f (g term)) $ params . pause
        , exceptionTests f g
        ]
  where
    term = Simple Terminate

-- | Run a list of 'TestTree''s and group them under the specified name.
runTests :: String -> [TestTree] -> IO ()
runTests name tests = do
    setEnv "TASTY_NUM_THREADS" "100"
#if !MIN_VERSION_base(4,7,0)
        True
#endif
    travisTestReporter travisConfig ingredients $ testGroup name tests
  where
    ingredients = [ includingOptions [Option (Proxy :: Proxy SlowTests)] ]

    travisConfig = defaultConfig
      { travisFoldGroup = FoldMoreThan 1
      , travisSummaryWhen = SummaryAlways
      , travisTestOptions = setOption (SlowTests True)
      }

withTime :: IO a -> IO (a, TimeSpec)
withTime act = do
    start <- getTime Monotonic
    r <- act
    end <- getTime Monotonic
    return $ (r, diffTimeSpec start end)
