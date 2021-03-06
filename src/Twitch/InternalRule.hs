{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Twitch.InternalRule where
import Filesystem.Path
import Data.Time.Clock
import System.FSNotify ( Event (..)
                       , WatchConfig
                       , watchDir
                       , startManagerConf
                       , WatchManager
                       , defaultConfig
                       )
import Data.Default
import Control.Monad
import Data.Monoid
import qualified Data.Text as T
import Data.Text (Text)
import Prelude hiding (FilePath)
import Twitch.Rule (Rule, RuleIssue)
import qualified Twitch.Rule as Rule

-- | The actions that are run when file events are triggered
type Action   = FilePath -> UTCTime -> IO ()
-- | The test function to determine if a event 'Action' should get fired
type FileTest = FilePath -> UTCTime -> Bool

data InternalRule = InternalRule 
  { name     :: Text
  -- ^ A name for debugging mostly
  , fileTest :: FileTest
  -- ^ The test to determine if the rule actions should fire
  , modify   :: Action 
  -- ^ The action to run on Modify events
  , add      :: Action 
  -- ^ The action to run on Add events
  , delete   :: Action 
  -- ^ The action to run on Delete events
  }
  
instance Default InternalRule where
  def = InternalRule 
    { name     = mempty
    , fileTest = \_ _ -> False
    , modify   = def
    , add      = def
    , delete   = def
    }

instance Show InternalRule where
  show InternalRule {..} 
    =  T.unpack $ "Rule { name = " 
    <> name 
    <> " }"

toInternalRule :: FilePath -> Rule -> Either RuleIssue InternalRule
toInternalRule currentDir rule = do
  test <- Rule.compilePattern currentDir $ Rule.pattern rule
  return $ InternalRule 
    { name     = Rule.name rule
    , fileTest = \x _ -> test x
    , add      = \x _ -> Rule.add    rule x
    , modify   = \x _ -> Rule.modify rule x
    , delete   = \x _ -> Rule.delete rule x
    }

-- | Configuration to run the file watcher
data Config = Config 
  { logger      :: Issue -> IO ()
  -- ^ A logger for the issues 
  , dirs        :: [FilePath]
  -- ^ The directories to watch
  , watchConfig :: WatchConfig
  -- ^ config for the file watcher
  } 
  
instance Show Config where
  show Config {..} 
    =  "Config { dirsToWatch = " 
    ++ show dirs
    ++ "}"

instance Default Config where
  def = Config
    { logger      = def
    , dirs        = def
    , watchConfig = defaultConfig
    }
    
-- | A sum type for the various issues that can be logged
data Issue 
  = IEvent     Event
  -- ^ logged every time an event is fired
  | IRuleFired Event InternalRule
  -- ^ logged every time an rule is fired
  deriving Show

-- | Retrieve the filePath of an Event
filePath :: Event -> FilePath
filePath = \case
  Added    x _ -> x
  Modified x _ -> x
  Removed  x _ -> x

-- | Retrieve the time of an Event
time :: Event -> UTCTime
time = \case
  Added    _ x -> x
  Modified _ x -> x
  Removed  _ x -> x

-- | Run the Rule action associated with the an event 
fireRule :: Event -> InternalRule -> IO ()
fireRule event rule = case event of
  Added    file time -> modify rule file time
  Modified file time -> add    rule file time
  Removed  file time -> delete rule file time

-- | Test to see if the rule should fire and fire it
testAndFireRule :: Config -> Event -> InternalRule -> IO ()
testAndFireRule Config {..} event rule = do
  let shouldFire = fileTest rule (filePath event) (time event)
  when shouldFire $ do 
    logger $ IRuleFired event rule
    fireRule event rule 

-- TODO in the future this should use the recursive directory functions
--      when appropiate
-- | Start watching a directory, and run the rules on it.
setupRuleForDir :: Config -> WatchManager -> [InternalRule] -> FilePath -> IO ()
setupRuleForDir config@(Config {..}) man rules dirPath = do
  -- TODO Instead of const True, this should use the rule's fileTests
  void $ watchDir man dirPath (const True) $ \event -> do 
    logger $ IEvent event
    forM_ rules $ testAndFireRule config event

-- | Setup all of the directory watches using the rules
setupRules :: Config -> [InternalRule] -> IO WatchManager
setupRules config@(Config {..}) rules = do 
  man <- startManagerConf watchConfig
  forM_ dirs $ setupRuleForDir config man rules
  return man
