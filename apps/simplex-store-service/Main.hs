{-# LANGUAGE NamedFieldPuns #-}

module Main where

import StoreService.Config (ServiceConfig (..), defaultLogLevel)
import StoreService.Options (RunMode (..), StoreServiceOpts (..))
import StoreService.Service
import StoreService.Store.Migrate (withInstanceLock)
import Control.Logger.Simple (LogConfig (..), setLogLevel, withGlobalLogging)
import GHC.IO.Encoding (setLocaleEncoding)
import Simplex.Chat.Terminal (terminalChatConfig)
import System.IO (hSetEncoding, stderr, stdout, utf8)

-- | withGlobalLogging installs the log sinks of the service and the SMP agent, which the chat core otherwise installs only under --log-agent.
main :: IO ()
main = do
  -- Without a UTF-8 locale GHC reads the ini and writes logs as ASCII, and throws on a non-ASCII group name.
  setLocaleEncoding utf8
  mapM_ (`hSetEncoding` utf8) [stdout, stderr]
  withGlobalLogging LogConfig {lc_file = Nothing, lc_stderr = True} $ do
    setLogLevel defaultLogLevel
    opts@StoreServiceOpts {runMode, serviceConfigFile} <- welcomeGetOpts
    serviceCfg <- traverse readConfigOrExit serviceConfigFile
    mapM_ (setLogLevel . serviceLogLevel) serviceCfg
    case runMode of
      RunService -> welcomeChat opts >> withInstanceLock opts (newServiceState >>= storeService opts serviceCfg terminalChatConfig)
      RunCLI -> welcomeChat opts >> withInstanceLock opts (storeServiceCLI opts serviceCfg)
      ExportWebapp -> storeServiceExport serviceCfg
