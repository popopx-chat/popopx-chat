{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Popopx.Chat.Terminal where

import Control.Monad
import qualified Data.List.NonEmpty as L
import Popopx.Chat (defaultChatConfig)
import Popopx.Chat.Controller
import Popopx.Chat.Core
import Popopx.Chat.Help (chatWelcome)
import Popopx.Chat.Library.Commands (_defaultNtfServers)
import Popopx.Chat.Operators
import Popopx.Chat.Operators.Presets (operatorPopopxChat, popopxXFTPServers, popopxChatRelays)
import Popopx.Chat.Options
import Popopx.Chat.Terminal.Input
import Popopx.Chat.Terminal.Output
import Popopx.Messaging.Client (NetworkConfig (..), SMPProxyFallback (..), SMPProxyMode (..), defaultNetworkConfig)
import Popopx.Messaging.Util (raceAny_)
#if !defined(dbPostgres)
import Control.Exception (handle, throwIO)
import qualified Data.ByteArray as BA
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple (SQLError (..))
import qualified Database.SQLite.Simple as DB
import Popopx.Chat.Options.DB
import System.IO (hFlush, hSetEcho, stdin, stdout)
#endif

terminalChatConfig :: ChatConfig
terminalChatConfig =
  defaultChatConfig
    { presetServers =
        PresetServers
          { operators =
              [ PresetOperator
                  { operator = Just operatorPopopxChat,
                    smp =
                      map
                        (presetServer True)
                        [ "smp://f2X5hAgHZW9-SVkhMou0sUFg3AHUi2pE3kSw46AiGjY=@smp1.popopx.im,quheabd5hdghpztkw53fho6fki722npoytgvkutnbh3gtpgrlna5ukad.onion",
                          "smp://4bJjC-wqSpviWwuDnkhSKTD4V8mYxpLqj4aiCUSfGfA=@smp2.popopx.im,e2ox73tvq54iv6z46c2rsxo7qc3ngrb26rx54qctuxoornn6w4l2uxyd.onion",
                          "smp://_djpBHNn7-6BqzY2mv2kbU6dKOp9PX451wX12Q2DQbE=@smp3.popopx.im,7vlsoq342gvphpdpb74vhqtb5ohe25ymvck2uhta4sxo6nvyowu3fuad.onion"
                        ],
                    useSMP = 3,
                    xftp = map (presetServer True) $ L.toList popopxXFTPServers,
                    useXFTP = 3,
                    chatRelays = popopxChatRelays,
                    useChatRelays = 0
                  }
              ],
            ntf = _defaultNtfServers,
            netCfg =
              defaultNetworkConfig
                { smpProxyMode = SPMUnknown,
                  smpProxyFallback = SPFAllowProtected
                }
          },
      deviceNameForRemote = "POPOPX CLI"
    }

popopxChatTerminal :: WithTerminal t => ChatConfig -> ChatOpts -> t -> IO ()
popopxChatTerminal cfg options t = run options
  where
#if defined(dbPostgres)
    run opts =
      popopxChatCore cfg opts $ \u cc -> do
        ct <- newChatTerminal t opts
        when (firstTime cc) . printToTerminal ct $ chatWelcome u
        runChatTerminal ct cc opts
#else
    run opts@ChatOpts {coreOptions = coreOptions@CoreChatOpts {dbOptions}} =
      handle checkDBKeyError . popopxChatCore cfg opts $ \u cc -> do
        ct <- newChatTerminal t opts
        when (firstTime cc) . printToTerminal ct $ chatWelcome u
        runChatTerminal ct cc opts
      where
        checkDBKeyError :: SQLError -> IO ()
        checkDBKeyError e = case sqlError e of
          DB.ErrorNotADatabase -> do
            putStrLn $ "Database file is invalid or " <> if BA.null (dbKey dbOptions) then "encrypted." else "you passed an incorrect encryption key."
            run =<< getKeyOpts
          _ -> throwIO e
        getKeyOpts :: IO ChatOpts
        getKeyOpts = do
          putStr "Enter database encryption key (Ctrl-C to exit):"
          hFlush stdout
          hSetEcho stdin False
          key <- getLine
          hSetEcho stdin True
          putStrLn ""
          pure opts {coreOptions = coreOptions {dbOptions = dbOptions {dbKey = BA.convert $ encodeUtf8 $ T.pack key}}}
#endif

runChatTerminal :: ChatTerminal -> ChatController -> ChatOpts -> IO ()
runChatTerminal ct cc opts = raceAny_ [runTerminalInput ct cc, runTerminalOutput ct cc opts, runInputLoop ct cc]
