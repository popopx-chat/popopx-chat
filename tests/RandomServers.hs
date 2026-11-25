{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module RandomServers where

import Control.Monad (replicateM)
import Data.Foldable (foldMap')
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Monoid (Sum (..))
import Popopx.Chat (defaultChatConfig, chooseRandomServers)
import Popopx.Chat.Controller (ChatConfig (..), PresetServers (..))
import Popopx.Chat.Operators
import Popopx.Messaging.Agent.Env.SQLite (ServerRoles (..))
import Popopx.Messaging.Protocol (ProtoServerWithAuth (..), SProtocolType (..), UserProtocol)
import Test.Hspec

randomServersTests :: Spec
randomServersTests = describe "choosig random servers" $ do
  it "should choose 4 random SMP servers and keep the rest disabled" testRandomSMPServers
  it "should keep every preset XFTP server enabled, because the roster is exactly useXFTP" testRandomXFTPServers

deriving instance Eq ServerRoles

deriving instance Eq (UserServer' s p)

-- 4 and 3 are useSMP and useXFTP of the one preset operator this fork ships (src/Popopx/Chat.hs).
testRandomSMPServers :: IO ()
testRandomSMPServers = do
  [srvs1, srvs2, srvs3] <-
    replicateM 3 $
      checkEnabled SPSMP 4 False =<< chooseRandomServers (presetServers defaultChatConfig)
  (srvs1 == srvs2 && srvs2 == srvs3) `shouldBe` False -- && to avoid rare failures

-- This fork presets exactly as many XFTP servers as useXFTP (3), so chooseRandomServers takes its
-- `toUse >= length enbldSrvs` branch (src/Popopx/Chat.hs) and hands the roster back untouched instead of
-- picking a subset: no row is ever disabled, and the result is deterministic. Disabling would also be
-- wrong here — with three file servers, dropping one removes a third of the upload capacity.
testRandomXFTPServers :: IO ()
testRandomXFTPServers = do
  [srvs1, srvs2, srvs3] <-
    replicateM 3 $
      checkEnabled SPXFTP 3 True =<< chooseRandomServers (presetServers defaultChatConfig)
  (srvs1 == srvs2 && srvs2 == srvs3) `shouldBe` True

checkEnabled :: UserProtocol p => SProtocolType p -> Int -> Bool -> NonEmpty (PresetOperator) -> IO [NewUserServer p]
checkEnabled p n allUsed presetOps' = do
  let PresetServers {operators = presetOps} = presetServers defaultChatConfig
      presetSrvs = sortOn server' $ concatMap (pServers p) presetOps
      srvs' = sortOn server' $ concatMap (pServers p) presetOps'
      Sum toUse = foldMap' (Sum . operatorServersToUse p) presetOps
      Sum toUse' = foldMap' (Sum . operatorServersToUse p) presetOps'
  length presetOps `shouldBe` length presetOps'
  toUse `shouldBe` toUse'
  srvs' == presetSrvs `shouldBe` allUsed
  map enable srvs' `shouldBe` map enable presetSrvs
  let enbldSrvs = filter (\UserServer {enabled} -> enabled) srvs'
  toUse `shouldBe` n
  length enbldSrvs `shouldBe` n
  pure enbldSrvs
  where
    server' UserServer {server = ProtoServerWithAuth srv _} = srv
    enable :: forall p. NewUserServer p -> NewUserServer p
    enable srv = (srv :: NewUserServer p) {enabled = False}
