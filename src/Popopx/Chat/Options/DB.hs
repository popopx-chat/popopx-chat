{-# LANGUAGE CPP #-}

module Popopx.Chat.Options.DB

#if defined(dbPostgres)
  ( module Popopx.Chat.Options.Postgres,
    FromField (..),
    ToField (..),
  )
  where
import Popopx.Chat.Options.Postgres
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.ToField (ToField (..))

#else
  ( module Popopx.Chat.Options.SQLite,
    FromField (..),
    ToField (..),
  )
  where
import Popopx.Chat.Options.SQLite
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))

#endif
