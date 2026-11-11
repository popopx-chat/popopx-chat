{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Main where

import Directory.Options
import Directory.Service
import Popopx.Chat.Terminal (terminalChatConfig)

main :: IO ()
main = do
  opts@DirectoryOpts {runCLI} <- welcomeGetOpts
  if runCLI
    then directoryServiceCLI opts
    else newServiceState opts >>= directoryService opts terminalChatConfig
