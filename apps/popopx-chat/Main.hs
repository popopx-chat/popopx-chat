module Main where

import Server (popopxChatServer)
import Popopx.Chat.Badges.CLI (runBadgeCommand)
import Popopx.Chat.Terminal (terminalChatConfig)
import Popopx.Chat.Terminal.Main (popopxChatCLI)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("badge" : _) -> runBadgeCommand args
    _ -> popopxChatCLI terminalChatConfig (Just popopxChatServer)
