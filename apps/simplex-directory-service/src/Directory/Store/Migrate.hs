{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Directory.Store.Migrate where

import Control.Monad
import Control.Monad.Except
import qualified Data.ByteString.Char8 as B
import Data.List (find)
import qualified Data.Text as T
import Directory.Options
import Directory.Store
import Popopx.Chat (createChatDatabase)
import Popopx.Chat.Controller (ChatConfig (..), ChatDatabase (..))
import Popopx.Chat.Options (CoreChatOpts (..))
import Popopx.Chat.Options.DB
import Popopx.Chat.Store.Groups (getHostMember)
import Popopx.Chat.Store.Profiles (getUsers)
import Popopx.Chat.Store.Shared (getGroupInfo)
import Popopx.Chat.Types
import Popopx.Messaging.Agent.Store.Common
import qualified Popopx.Messaging.Agent.Store.DB as DB
import Popopx.Messaging.Agent.Store.Interface (closeDBStore, migrateDBSchema)
import Popopx.Messaging.Agent.Store.Shared (MigrationConfig (..), MigrationConfirmation (..))
import Popopx.Messaging.Encoding.String
import System.Exit (exitFailure)

#if defined(dbPostgres)
import Directory.Store.Postgres.Migrations
#else
import Directory.Store.SQLite.Migrations
#endif

runDirectoryMigrations :: DirectoryOpts -> ChatConfig -> DBStore -> IO ()
runDirectoryMigrations opts ChatConfig {confirmMigrations} chatStore =
  migrateDBSchema
    chatStore
    (toDBOpts dbOptions chatSuffix False [])
    (Just "sx_directory_migrations")
    directorySchemaMigrations
    MigrationConfig {confirm, backupPath = Nothing}
    >>= either (exit . ("directory migrations " <>) . show) pure
  where
    DirectoryOpts {coreOptions = CoreChatOpts {dbOptions, yesToUpMigrations}} = opts
    confirm = if confirmMigrations == MCConsole && yesToUpMigrations then MCYesUp else confirmMigrations

exit :: String -> IO a
exit err = putStrLn ("Error: " <> err) >> exitFailure

verifyGroupRegistration :: StoreCxt -> DB.Connection -> User -> GroupReg -> IO Bool
verifyGroupRegistration cxt db user GroupReg {dbGroupId = gId, dbContactId = ctId, dbOwnerMemberId, groupRegStatus} =
  runExceptT (getGroupInfo db cxt user gId) >>= \case
    Left e -> False <$ putStrLn ("Error: loading group " <> show gId <> " (skipping): " <> show e)
    Right GroupInfo {localDisplayName} -> do
      let groupRef = show gId <> " " <> T.unpack localDisplayName
      runExceptT (getHostMember db cxt user gId) >>= \case
        Left e -> False <$ putStrLn ("Error: loading host member of group " <> groupRef <> " (skipping): " <> show e)
        Right GroupMember {groupMemberId = mId', memberContactId = ctId'} -> case dbOwnerMemberId of
          Nothing -> True <$ putStrLn ("Warning: group " <> groupRef <> " has no owner member ID, host member ID is " <> show mId' <> ", registration status: " <> B.unpack (strEncode groupRegStatus))
          Just mId
            | mId /= mId' -> False <$ putStrLn ("Error: different host member ID of " <> groupRef <> " (skipping): " <> show mId')
            | otherwise -> True <$ unless (Just ctId == ctId') (putStrLn $ "Warning: bad group " <> groupRef <> " contact ID: " <> show ctId')

withChatStore :: DirectoryOpts -> (DBStore -> IO ()) -> IO ()
withChatStore DirectoryOpts {coreOptions = CoreChatOpts {dbOptions, yesToUpMigrations, migrationBackupPath}} action =
  createChatDatabase dbOptions migrationConfig >>= \case
    Left e -> exit $ show e
    Right ChatDatabase {chatStore, agentStore} -> do
      action chatStore
      closeDBStore chatStore
      closeDBStore agentStore
  where
    migrationConfig = MigrationConfig (if yesToUpMigrations then MCYesUp else MCConsole) migrationBackupPath

withActiveUser :: DBStore -> (User -> IO ()) -> IO ()
withActiveUser st action = withTransaction st getUsers >>= maybe (exit "no active user") action . find activeUser
