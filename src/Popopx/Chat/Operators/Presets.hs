{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module Popopx.Chat.Operators.Presets where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Popopx.Chat.Operators
import Popopx.Chat.Protocol (mkRelayProfile)
import Popopx.Messaging.Agent.Env.SQLite (allRoles)
import Popopx.Messaging.Agent.Store.Entity
import Popopx.Messaging.Encoding.String (strDecode)
import Popopx.Messaging.Protocol (ProtocolType (..), SMPServer, XFTPServerWithAuth)

operatorPopopxChat :: NewServerOperator
operatorPopopxChat =
  ServerOperator
    { operatorId = DBNewEntity,
      operatorTag = Just OTSimplex,
      tradeName = "POPOPX Chat",
      legalName = Just "POPOPX",
      serverDomains = ["popopx.im"],
      conditionsAcceptance = CARequired Nothing,
      enabled = True,
      smpRoles = allRoles,
      xftpRoles = allRoles
    }

-- Please note: if any servers are removed from the lists below, they MUST be added here.
-- Otherwise previously created short links won't work.
--
-- !!! Also, if any servers need to be added, shortLinkPresetServers will need to be be split to two,
-- so that option used for restoring links is updated earlier, for backward/forward compatibility.
-- POPOPX only: upstream and third-party servers have been removed. Existing short links
-- to those servers will no longer resolve, but this is a deliberate cleanup to ship only
-- the popopx.im cluster by default.
allPresetServers :: NonEmpty SMPServer
allPresetServers =
  enabledPopopxChatSMPServers
    <> chatRelaySMPServers

-- A row listed here is re-compared against what the store already holds on EVERY app start
-- (Popopx.Chat `agentServers` -> `groupByOperator'` -> `updatedUserServers` -> `setUserServers'`), and
-- that comparison only sees the rows `serverDomains` routed into this operator's group. A preset row
-- whose hosts fall outside those domains is never found in the group, so it is re-emitted as DBNew and
-- `insertProtocolServer` INSERTs a second copy of a row that already exists:
-- `UNIQUE constraint failed: protocol_servers.user_id, protocol_servers.host, protocol_servers.port`,
-- an uncaught exception that escapes `newChatController` to the RTS, which prints it and exits - the app
-- dies on the launch after the one that stored the row, before the interface appears.
-- Every SMP host offered here must therefore be covered by `operatorPopopxChat.serverDomains`.
-- Upstream and third-party servers have been removed; POPOPX ships only its own cluster.
popopxChatSMPServers :: [NewUserServer 'PSMP]
popopxChatSMPServers = map (presetServer' True) (L.toList enabledPopopxChatSMPServers)

-- Please note: if any servers are removed from this list, they MUST be added to allPresetServers.
-- Otherwise previously created short links won't work.
--
-- !!! Also, if any servers need to be added, shortLinkPresetServers will need to be be split to two,
-- so that option used for restoring links is updated earlier, for backward/forward compatibility.
-- POPOPX's own dual-stack production cluster. The addresses carry no port on purpose: a port-less SMP
-- address is dialled on the native port (`defaultSMPPort` = 5223) over TLS, which is what this cluster
-- listens on. `presetDomains` deliberately does NOT list `.popopx.im` (Popopx.Chat): matching a host
-- there would rewrite the dial to 443 with the http/1.1 ALPN, and 443 on this cluster is the Caddy
-- web site, not SMP.
enabledPopopxChatSMPServers :: NonEmpty SMPServer
enabledPopopxChatSMPServers =
  [ "smp://f2X5hAgHZW9-SVkhMou0sUFg3AHUi2pE3kSw46AiGjY=@smp1.popopx.im,quheabd5hdghpztkw53fho6fki722npoytgvkutnbh3gtpgrlna5ukad.onion",
    "smp://4bJjC-wqSpviWwuDnkhSKTD4V8mYxpLqj4aiCUSfGfA=@smp2.popopx.im,e2ox73tvq54iv6z46c2rsxo7qc3ngrb26rx54qctuxoornn6w4l2uxyd.onion",
    "smp://_djpBHNn7-6BqzY2mv2kbU6dKOp9PX451wX12Q2DQbE=@smp3.popopx.im,7vlsoq342gvphpdpb74vhqtb5ohe25ymvck2uhta4sxo6nvyowu3fuad.onion",
    "smp://u2anmYvY5dhqHTdFsLGS0AvPqd9yZcmBWAcB4DIgI8U=@smp4.popopx.im,mwanxalavtfkr4536re33hax5yrifuewftqu3r6edn4c6ewonfqgcmad.onion",
    "smp://J8rBEqmx3aN9tdk1HVf1gQ3nBGogF_nEHKc2ZTKzf8s=@smp5.popopx.im,mmjxftmk36uzbmd3lfaw55cqr6fwxzzvdtedajpohfyicm32q3uosnqd.onion",
    "smp://2bIUdRa7VJeB2tx9W3gwaOJ2Sv72fH8Pc_uM9l9r4hM=@smp6.popopx.im,vby2g42jivku4xcd24z56tmwxm5uxfm3t56ou7itulps4lfhdnr3zwid.onion",
    "smp://9zMJeSEmrqWtPKet6gDy2dzc9WA_3Fr3XRKK67U5wC8=@smp7.popopx.im,yjk4l3ip5ky4nypzcusx6qeafk42nud6lcdpjbvzrtfjpfogncfo45id.onion",
    "smp://R5de8tqpXpo6RsfDTLJm6IQiK58r3bRdtbRL1YsQGo8=@smp8.popopx.im,xvzne6jxj7qza6yaptsyv5ffchdv7kikcnnhotfpjkgsm32xsxh6vzid.onion"
  ]

-- Upstream and third-party server lists have been removed. POPOPX ships only its own
-- popopx.im cluster by default.

-- POPOPX's own XFTP servers, defined here rather than taken from the dependency's
-- `Popopx.FileTransfer.Client.Presets.defaultXFTPServers`: that list is a wire value held outside
-- this repo. The pinned commit (0c9141f9) names these same three servers, so the two lists agree
-- today - this one stays so the servers the app ships are decided here even if the pin moves.
-- The port is load-bearing - a port-less XFTP address is always dialled on 443
-- (FileTransfer.Client: `usePort = if null port then "443" else port`), which on this cluster is the
-- Caddy web site.
popopxXFTPServers :: NonEmpty XFTPServerWithAuth
popopxXFTPServers =
  [ "xftp://OtONXJLyqB9g3QFSuOSfvBBoH5AdgccTbNbKCdaSWtw=@xftp1.popopx.im,im6alhiruuj3m2zhwnl3bzuujzpcg7hqgfljp3wmcgh3rrg3uysd7eqd.onion:8443",
    "xftp://B4WH5g5SRl7ioZx3gK9ruwkgv3lJGSQJ6QKIoV1JZMk=@xftp6.popopx.im,65fhxyz3yphhts4xy2vf2symvj2e4peb6zypry7ryg7qz7wbcxqyvxqd.onion:8443",
    "xftp://4GSglxXYIJswF-ysVo5RCycQ7vHF-85zTodA2wZCIQ8=@xftp8.popopx.im,wa47g3vf4xxfa246le62t6cwqjvww2eugecysqoznpgqt5we5kf2owyd.onion:8443"
  ]

-- relay1.popopx.im:5227 is this cluster's chat relay: the dependency NOTICE counts fifteen relays as
-- eight SMP (`smp1..8`, port-less), one chat relay (`relay1`, `:5227`), three file and three
-- notification relays. It is not offered to new users as an SMP server - a chat relay is a different
-- transport - so its address appears only in chatRelaySMPServers below.
-- Presetting the relay itself needs its short link contact `https://<host>/r#<LinkKey>`, and that key is
-- minted by the relay process when the link is created - it is in neither repository - so this stays
-- empty until the link is supplied.
popopxChatRelays :: [NewUserChatRelay]
popopxChatRelays =
  [ presetChatRelay True (mkRelayProfile "POPOPX Relay 1" Nothing) ["popopx.im"] (either error id $ strDecode "https://relay1.popopx.im/r#glhT18ZtqaIxY-IELvM79Vv0nMA7NKPrDisWzuDnOKE?p=5227&c=04Mm3i26SSyFmrSe6h8NSXZ7bIGsUAVyQ7o6abUJbLw")
  ]

-- The relay's SMP address belongs in allPresetServers even while popopxChatRelays above is empty,
-- because it is what makes a link already published on that host resolvable: a short link carries the
-- host and the contact key only, and `restoreShortLink` fills in the server key and port from this list
-- alone (popopxmq Agent/Protocol `findPresetServer` compares the FIRST host, so the public host is
-- written first). The port is load-bearing for the same reason: 5227 is this relay's role port, not the
-- SMP default, so an address completed without it is dialled to the wrong socket.
chatRelaySMPServers :: NonEmpty SMPServer
chatRelaySMPServers = ["smp://04Mm3i26SSyFmrSe6h8NSXZ7bIGsUAVyQ7o6abUJbLw=@relay1.popopx.im,5ui7syydfqzvyjy6vwuy726rwxdsa5ow4esnfln2lhevduyuamcdvqqd.onion:5227"]

-- Flux operator removed: POPOPX ships only its own popopx.im cluster.
