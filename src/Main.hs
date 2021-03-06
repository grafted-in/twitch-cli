{-# LANGUAGE BangPatterns   #-}
{-# LANGUAGE NamedFieldPuns #-}

module Main (main) where

import           Control.Concurrent       (MVar, modifyMVar_, newMVar, threadDelay)
import           Control.Concurrent.Async (Async, async, cancel)
import           Control.Exception        (finally)
import           Control.Monad            (forM_, forever, when)
import           Data.Char                (toLower)
import           Data.Foldable            (sequenceA_)
import           Data.List                (elemIndex, splitAt)
import qualified Data.Map                 as Map
import           Data.Map.Strict          (Map)
import           Data.Maybe               (isJust)
import           Data.Monoid              (mempty, (<>))
import qualified Options.Applicative      as O
import           System.Environment       (getEnvironment)
import qualified System.Environment       as Sys
import qualified System.FilePath.Glob     as Glob
import           System.FSNotify          (Event(..), watchTree, withManager)
import           System.Process.Typed     (ProcessConfig, setEnv, shell, startProcess, stopProcess, waitExitCode)

main :: IO ()
main = mainWithArgs =<< parseArgs =<< Sys.getArgs

parseArgs :: [String] -> IO Options
parseArgs args = O.handleParseResult $ O.execParserPure O.defaultPrefs opts args
  where
    opts = O.info (O.helper <*> cmdOpts)
      (  O.fullDesc
      <> O.progDesc "Watch for file patterns and run commands when they change"
      )

mainWithArgs :: Options -> IO ()
mainWithArgs Options{_patterns, _debounceKey, _debounceSecs} =
  if null _patterns then
    putStrLn "No patterns given"
  else do
    let
      !debounceKeyParsed = parseDebounceKey _debounceKey
      patternsByDir = groupCommonDirs _patterns

    runningProcs <- newMVar mempty
    withManager $ \mgr -> do
      forM_ (Map.toList patternsByDir) $ \(baseDir, pats) ->
        watchTree mgr baseDir (isJust . fromAddOrModifyEvent) $ \event -> case fromAddOrModifyEvent event of
          Nothing -> pure ()
          Just file -> let
            key pat command = case debounceKeyParsed of
              DebouncePerAny     -> ""
              DebouncePerFile    -> file
              DebouncePerPattern -> baseDir ++ "/" ++ Glob.decompile pat
              DebouncePerCommand -> command
            in sequenceA_
                [ startCommand _debounceSecs (key pat command) file command runningProcs
                | (pat, command) <- pats, Glob.match pat file
                ]

      forever $ threadDelay maxBound
  where
    fromAddOrModifyEvent event = case event of
      Added file    _ -> Just file
      Modified file _ -> Just file
      _               -> Nothing

runCommand :: FilePath -> String -> Double -> IO (Async ())
runCommand file command delaySecs = async $ do
  when (delaySecs > 0) (threadDelay $ secondsToMicroseconds delaySecs)
  env <- getEnvironment
  let newEnv = Map.toList $ Map.insert "FILE" file $ Map.fromList env
  runProcessUntilCancel (setEnv newEnv $ shell command)

startCommand :: Double -> String -> FilePath -> String -> MVar (Map String (Async ())) -> IO ()
startCommand delaySecs key file command procsMapMvar = modifyMVar_ procsMapMvar $ \procsMap -> do
  let existingAsync' = Map.lookup key procsMap
  case existingAsync' of
    Nothing            -> pure ()
    Just existingAsync -> cancel existingAsync
  newAsync <- runCommand file command delaySecs
  pure $ Map.insert key newAsync procsMap

runProcessUntilCancel :: ProcessConfig () () () -> IO ()
runProcessUntilCancel c = do
  p <- startProcess c
  _ <- waitExitCode p `finally` stopProcess p
  pure ()


data DebounceKey = DebouncePerAny | DebouncePerFile | DebouncePerPattern | DebouncePerCommand
  deriving (Bounded, Enum, Eq, Ord, Show)

parseDebounceKey :: String -> DebounceKey
parseDebounceKey str = case map toLower str of
  "all"     -> DebouncePerAny
  "file"    -> DebouncePerFile
  "pattern" -> DebouncePerPattern
  "command" -> DebouncePerCommand
  _         -> error "Unrecognized debounce key: must be one of 'all', 'file', 'pattern', 'command'"

groupCommonDirs :: [Pattern] -> Map FilePath [(Glob.Pattern, String)]
groupCommonDirs patterns = Map.fromListWith (++)
  [ (baseDir, [(Glob.simplify pat, cmd)])
  | Pattern globStr cmd <- patterns
  , let (baseDir, pat) = Glob.commonDirectory $ Glob.compile globStr
  ]

data Options = Options{
    _debounceKey  :: String,
    _debounceSecs :: Double,
    _patterns     :: [Pattern]
  } deriving Show

data Pattern = Pattern{ _pattern :: String, _command :: String } deriving Show

cmdOpts :: O.Parser Options
cmdOpts = Options
  <$> O.strOption
    ( O.long "key"
    <> O.short 'k'
    <> O.metavar "DEBOUNCE-KEY"
    <> O.help "Key to use for debouncing. May be one of 'all', 'pattern', 'command', or 'file'."
    <> O.value "pattern"
    <> O.showDefault
    )
  <*> O.option O.auto
    (  O.long "debounce"
    <> O.metavar "SECONDS"
    <> O.help "Number of floating-point seconds to use for debouncing changes per DEBOUNCE-KEY"
    <> O.value 1
    <> O.showDefault
    )
  <*> O.many (O.option (readWith parsePattern)
    (  O.long "pattern"
    <> O.short 'p'
    <> O.metavar "PATTERN:COMMAND"
    <> O.help
      "A glob pattern that matches files paired with a command to run \
      \when any matching file changes. Separate the pattern and the \
      \command with ':'. The command will have access to an environment \
      \variable named $FILE which will contain the path to the file that \
      \changed. Note that if many files change quickly, the debounce \
      \setting may cause only one or some of the files to trigger the \
      \command to run. If you need per-file commands, disable debounce. \
      \For Glob pattern rules, refer to https://goo.gl/PgdTqF \
      \Examples: '**/*.pyo:rm $FILE', '*.cabal:cabal configure', \
      \'**/**:git status'"
    ))

parsePattern :: String -> Either String Pattern
parsePattern str
  | null pat || null cmd = Left "Invalid pattern"
  | otherwise = Right (Pattern pat cmd)
  where
    (pat, cmd) = case elemIndex ':' str of
      Just idx -> let (pat', cmd') = splitAt idx str
                   in if null cmd'
                        then (pat', "")
                        else (pat', tail cmd')  -- drop leading ':'
      Nothing  -> ("", "")

readWith :: Show err => (String -> Either err b) -> O.ReadM b
readWith f = O.eitherReader (either (Left . show) Right . f)

secondsToMicroseconds :: Double -> Int
secondsToMicroseconds = round . (*1000000)
