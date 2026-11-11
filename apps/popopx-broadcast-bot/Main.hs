module Main where

import Broadcast.Bot
import Broadcast.Options
import Popopx.Chat.Core
import Popopx.Chat.Terminal (terminalChatConfig)

main :: IO ()
main = do
  opts <- welcomeGetOpts
  simplexChatCore terminalChatConfig (mkChatOpts opts) $ broadcastBot opts
