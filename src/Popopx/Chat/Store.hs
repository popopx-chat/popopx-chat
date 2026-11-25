{-# LANGUAGE CPP #-}

module Popopx.Chat.Store
  ( DBStore,
    StoreError (..),
    ChatLockEntity (..),
    UserMsgReceiptSettings (..),
    UserContactLink (..),
    GroupLinkInfo (..),
    AddressSettings (..),
    AutoAccept (..),
    createChatStore,
    migrations, -- used in tests
    withTransaction,
  )
where

import Popopx.Chat.Store.Profiles
import Popopx.Chat.Store.Shared
import Popopx.Messaging.Agent.Store.Common (DBStore (..), withTransaction)
import Popopx.Messaging.Agent.Store.Interface (DBOpts, createDBStore)
import Popopx.Messaging.Agent.Store.Shared (MigrationConfig, MigrationError)
#if defined(dbPostgres)
import Popopx.Chat.Store.Postgres.Migrations
#else
import Popopx.Chat.Store.SQLite.Migrations
#endif

createChatStore :: DBOpts -> MigrationConfig -> IO (Either MigrationError DBStore)
createChatStore dbCreateOpts = createDBStore dbCreateOpts migrations
