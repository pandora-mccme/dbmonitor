{-# LANGUAGE RecordWildCards #-}
module Monitor.Entry where

import Control.Concurrent
import Control.Exception
import Control.Monad.Reader

import System.Directory
import System.FilePath
import System.INotify

import qualified Data.ByteString.Char8 as BSC
import Data.List

import Monitor.Options (Options(..))
import Monitor.Config
import Monitor.Queue
import Monitor.DataModel

configName :: FilePath
configName = "conf.dhall"

updateEventVariety :: [EventVariety]
updateEventVariety = [Modify, MoveIn, MoveOut, Create, Delete, DeleteSelf]

changeConfigAction :: INotify -> String -> FilePath -> FilePath -> IO ()
changeConfigAction watcher dir tgvar path = if path == configName
  then tryToEnter ConfigWatched watcher dir tgvar
  else pure ()

-- watches only config changes.
configWatch :: INotify -> String -> FilePath -> Event -> IO ()
-- Looks like we do not need any data about event.
configWatch watcher dir tgvar (Modified False (Just path)) =
  changeConfigAction watcher dir tgvar $ BSC.unpack path
configWatch watcher dir tgvar (MovedIn False path _) =
  changeConfigAction watcher dir tgvar $ BSC.unpack path
configWatch watcher dir tgvar (Created False path) =
  changeConfigAction watcher dir tgvar $ BSC.unpack path
configWatch _ _ _ _ = pure ()

jobAction :: JobAction -> FilePath -> ReaderT Settings IO ()
jobAction action path = if notHidden path
  then case action of
    Start -> startJob path
    Restart -> restartJob path
    Remove -> removeJob path
  else pure ()

-- watches check changes.
{-
  Expected behavior:
  On config changes -- drop all jobs, execute tryToEnter. On success inotify process is kept alive.
  On file changes -- actions for each type of event.
  Problem -- connection between job and filename, seems easy to handle.
  Also note behavior on file renames -- two successive alerts comes, one deletes the job, one starts the same with another id.
  DeleteSelf event must trigger suicide alert and immediate exit.
-}
watchTower :: Settings -> Event -> IO ()
watchTower cfg DeletedSelf = runReaderT destroyEvent cfg
watchTower cfg (Modified False (Just path)) = runReaderT (jobAction Restart $ BSC.unpack path) cfg
watchTower cfg (Deleted False path) = runReaderT (jobAction Remove $ BSC.unpack path) cfg
watchTower cfg (MovedOut False path _) = runReaderT (jobAction Remove $ BSC.unpack path) cfg
watchTower cfg (MovedIn False path _) = runReaderT (jobAction Start $ BSC.unpack path) cfg
watchTower cfg (Created False path) = runReaderT (jobAction Start $ BSC.unpack path) cfg
-- Other events must not be watched, warning bypass
watchTower _ _ = pure ()


missingConfigCase :: INotify -> FilePath -> String -> IO ()
missingConfigCase watcher dir tgvar = do
  putStrLn $ "Configuration file is missing or invalid in " <> dir <> ", ignoring. You do not need to restart after config fix."
  void $ addWatch watcher [MoveIn, Create, Modify] (BSC.pack dir) (configWatch watcher tgvar dir)

notHidden :: FilePath -> Bool
notHidden ('.':_) = False
notHidden _ = True

enter :: INotify -> FilePath -> [FilePath] -> Settings -> IO ()
enter watcher dir checks cfg = do
  {-
    After successful start behavior changes: config now must be watched by process taking care about job queue,
    we don't want old settings to be applied so far.
    Hence on successful start we have to close watch descriptor. But we cannot pass it to it's own event handler.
    So we must restart whole inotify.
    First inotify process watches only config, second -- only queue.
    When config breaks, it turns into loop of starting process and dies as soon as queue is successfully restarted,
  -}
  killINotify watcher
  newWatcher <- initINotify
  _ <- addWatch newWatcher updateEventVariety (BSC.pack dir) (watchTower cfg)
  -- In directories there may be any content.
  checkFiles <- filter notHidden <$> filterM doesFileExist checks
  runReaderT (buildQueue checkFiles) cfg

maybeAddConfigWatch :: INotify -> ConfigWatchFlag -> FilePath -> String -> IO ()
maybeAddConfigWatch watcher isWatched dir tgvar = case isWatched of
  ConfigWatched -> return ()
  ConfigNonWatched -> missingConfigCase watcher dir tgvar

tryToEnter :: ConfigWatchFlag -> INotify -> FilePath -> String -> IO ()
tryToEnter isWatched watcher dir tgvar = do
  (mConfigPath, checks) <- partition (== configName) <$> listDirectory dir
  case mConfigPath of
    [] -> maybeAddConfigWatch watcher isWatched dir tgvar
    (configPath:_) -> do
      mSettings <- readSettings dir tgvar configPath
      case mSettings of
        Nothing -> maybeAddConfigWatch watcher isWatched dir tgvar
        Just cfg -> enter watcher dir checks cfg

finalizer :: FilePath -> Either SomeException () -> IO ()
finalizer dir (Right ()) =
  putStrLn $ "monitor for " <> dir <> " suddenly decided to be mortal with no exception or command received"
finalizer dir (Left e) =
  putStrLn $ "monitor for " <> dir <> " is dead by following reason: " <> show e

trackDatabase :: FilePath -> String -> FilePath -> IO ()
trackDatabase baseDir tgvar dbDir = void . flip forkFinally (finalizer dbDir) $
  do
    let dir = baseDir </> dbDir
    watcher <- initINotify
    tryToEnter ConfigNonWatched watcher dir tgvar

runApp :: Options -> IO ()
runApp Options{..} = do
  databaseDirs <- listDirectory optionsDir
  mapM_ (trackDatabase optionsDir optionsToken) databaseDirs
