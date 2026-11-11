module Main where

import Server (simplexChatServer)
import Popopx.Chat.Badges.CLI (runBadgeCommand)
import Popopx.Chat.Terminal (terminalChatConfig)
import Popopx.Chat.Terminal.Main (simplexChatCLI)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("badge" : _) -> runBadgeCommand args
    _ -> simplexChatCLI terminalChatConfig (Just simplexChatServer)
