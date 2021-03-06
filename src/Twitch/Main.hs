{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Twitch.Main where
import Data.Monoid
import Options.Applicative
import Data.Default
import qualified System.FSNotify as FS
import Twitch.Path
import qualified Twitch.InternalRule as IR
import System.IO
import Data.Foldable (for_)
import Twitch.Run
import Twitch.Internal
import System.Directory
import Data.Maybe
import Prelude hiding (log)
import qualified Filesystem.Path as F
import qualified Filesystem.Path.CurrentOS as F
import Data.Time.Clock
import Control.Concurrent.STM.TBMQueue
import Control.Concurrent
-- parse the command line
--

concatMapM f = fmap concat . mapM f

data LoggerType
  = LogToStdout
  | LogToFile
  | NoLogger
  deriving (Eq, Show, Read, Ord)

toLogger :: FilePath
         -> LoggerType
         -> IO (IR.Issue -> IO (), Maybe Handle)
toLogger filePath = \case
  LogToStdout -> return (print, Nothing)
  LogToFile -> do
    handle <- openFile filePath AppendMode
    return (hPrint handle, Just handle)
  NoLogger -> return (const $ return (), Nothing)

data Options = Options
  { log          :: LoggerType
  -- ^ The logger type.
  --   This cooresponds to the --log or -l argument. The valid options
  --   are "LogToStdout", "LogToFile", and "NoLogger"
  --   If "LogToFile" a file can provide with the 'logFile' field.
  , logFile      :: Maybe FilePath
  -- ^ The file to log to
  --   This is only used if the 'log' field is set to "LogToFile".
  --   This cooresponds to the --log-file or -f argument
  , dirsToWatch  :: [FilePath]
  -- ^ The directories to watch.
  --   This cooresponds to the --directories and -d argument
  , recurseThroughDirectories :: Bool
  -- ^ If true, main will recurse throug all subdirectories of the 'dirsToWatch'
  --   field. Otherwise the 'dirsToWatch' will be used literally.
  --   By default this is empty and the currentDirectory is used.
  , debounce     :: DebounceType
  -- ^ This corresponds to the debounce type used in the fsnotify library
  --   The argument for default main is --debounce or -b .
  --   Valid options are "DebounceDefault", "Debounce", "NoDebounce"
  --   If "Debounce" is used then a debounce amount must be specified with the
  --   'debounceAmount'
  , debounceAmount :: Double
  -- ^ The amount to debounce. This is only meaningful when 'debounce' is set
  --   to 'Debounce'.
  --   It cooresponds to the --debounce-amount or -a argument
  , pollInterval :: Int
  -- ^ poll interval if polling is used.
  --   This cooresponds to the --poll-interval or -i argument
  , usePolling   :: Bool
  -- ^ If true polling is used instead of events.
  --   This cooresponds to the --poll or -p argument
  , currentDir   :: Maybe FilePath
  -- ^ The current directory to append to the glob patterns. If Nothing then
  --   the value is whatever is returned by 'getCurrentDirectory'
  --   This cooresponds to the --current-dir or -c arguments
  }

data DebounceType
  = DebounceDefault
  | Debounce
  | NoDebounce
  deriving (Eq, Show, Read, Ord)

instance Default Options where
  def = Options
    { log                       = NoLogger
    , logFile                   = Nothing
    , dirsToWatch               = []
    , recurseThroughDirectories = True
    , debounce                  = DebounceDefault
    , debounceAmount            = 0
    , pollInterval              = 10^(6 :: Int) -- 1 second
    , usePolling                = False
    , currentDir                = Nothing
    }

pOptions :: Parser Options
pOptions
   =  Options
  <$> option auto
        ( long "log"
       <> short 'l'
       <> metavar "LOG_TYPE"
       <> help "Type of logger. Valid options are LogToStdout | LogToFile | NoLogger"
       <> value (log def)
        )
  <*> option auto
        ( long "log-file"
       <> short 'f'
       <> metavar "LOG_FILE"
       <> help "Log file"
       <> value (logFile def)
        )
  <*> option auto
        ( long "directories"
       <> short 'd'
       <> metavar "DIRECTORIES"
       <> help "Directories to watch"
       <> value (dirsToWatch def)
        )
  <*> option auto
        ( long "recurse"
       <> short 'r'
       <> metavar "RECURSE"
       <> help "Boolean to recurse or directories or not"
       <> value (recurseThroughDirectories def)
        )
  <*> option auto
        ( long "debounce"
       <> short 'b'
       <> metavar "DEBOUNCE"
       <> help "Target for the greeting"
       <> value (debounce def)
        )
  <*> option auto
        ( long "debounce-amount"
       <> short 'a'
       <> metavar "DEBOUNCE_AMOUNT"
       <> help "Target for the greeting"
       <> value (debounceAmount def)
        )
  <*> option auto
        ( long "poll-interval"
       <> short 'i'
       <> metavar "POLL_INTERVAL"
       <> help "Poll interval if polling is used"
       <> value (pollInterval def)
        )
  <*> option auto
        ( long "poll"
       <> short 'p'
       <> metavar "POLL"
       <> help "Whether to use polling or not"
       <> value (usePolling def)
        )
  <*> option auto
        ( long "current-dir"
       <> short 'c'
       <> metavar "CURRENT_DIR"
       <> help "Directory to append to the glob patterns"
       <> value (currentDir def)
        )

-- This is like run, but the config params can be over written from the defaults

toDB amount = \case
  DebounceDefault -> FS.DebounceDefault
  Debounce        -> FS.Debounce $ fromRational $ toRational amount
  NoDebounce      -> FS.NoDebounce

optionsToConfig :: Options -> IO (FilePath, IR.Config, Maybe Handle)
optionsToConfig Options {..} = do
  actualCurrentDir <- getCurrentDirectory
  let currentDir' = fromMaybe actualCurrentDir currentDir
      dirsToWatch' = if null dirsToWatch then
                       [currentDir']
                     else
                       dirsToWatch

  (logger, mhandle) <- toLogger (fromMaybe "log.txt" logFile) log
  let encodedDirs = map F.decodeString dirsToWatch'
  dirsToWatch'' <- if recurseThroughDirectories then
                   (encodedDirs ++) <$> concatMapM findAllDirs encodedDirs
                 else
                   return encodedDirs

  let watchConfig = FS.WatchConfig
        { FS.confDebounce     = toDB debounceAmount debounce
        , FS.confPollInterval = pollInterval
        , FS.confUsePolling   = usePolling
        }

  let config = IR.Config
        { logger      = logger
        , dirs        = dirsToWatch''
        , watchConfig = watchConfig
        }
  return (currentDir', config, mhandle)

-- | Simplest way to create a file watcher app. Set your main equal to defaultMain
--   and you are good to go. See the module documentation for examples.
--
--   The command line is parsed to make 'Options' value. For more information on
--   the arguments that can be passed see the doc for 'Options' and the run the
--   executable made with defaultMain with the --help argument.
defaultMain :: Dep -> IO ()
defaultMain dep = do
  let opts = info (helper <*> pOptions)
        ( fullDesc
       <> progDesc "twitch"
       <> header "a file watcher"
        )
  options <- execParser opts
  defaultMainWithOptions options dep

-- | A main file that uses manually supplied options instead of parsing the passed in arguments.
defaultMainWithOptions :: Options -> Dep -> IO ()
defaultMainWithOptions options dep = do
  (currentDir, config, mhandle) <- optionsToConfig options
  let currentDir' = F.decodeString currentDir
  manager <- runWithConfig currentDir' config dep
  putStrLn "Type anything to quit"
  _ <- getLine
  for_ mhandle hClose
  FS.stopManager manager



