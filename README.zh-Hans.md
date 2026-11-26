[English](./README.md) | 简体中文

# POPOPX

### **Connect Everything.**

**自由连接 · 私密沟通 · 智能协作**

*隐私优先的智能连接平台*

> POPOPX 不只是提供连接工具，而是建立一个让人、AI、Agent、设备和服务能够安全连接、自由协作的开放生态。

**POPOPX Chat** 是这个平台的通讯客户端：一个 AGPL-3.0-only、无需许可的 messenger，**没有全局用户身份**
——没有手机号、没有邮箱、没有需要注册的账号，也没有任何东西把你的联系人绑定到某方运营的目录上。
消息经由单向队列传输，中继服务器被配置为不存储任何资料、也看不到任何会话内容。

## 四项核心能力

- **没有全局用户身份。** 你的 POPOPX 地址是指向某个中继上某个队列的链接，不是数据表里的一行——无需注册，
  也不存在任何人运营的目录。参见 [Identity model](./README.md#identity-model)。
- **默认启用后量子混合加密。** 每一次棘轮推进都把 `sntrup761` 与 X25519 组合使用。参见
  [Core technology](./README.md#core-technology)。
- **可完全自托管、本地优先。** 应用预设的每一台服务器都能在设置中替换，而你可以运行的二进制，就是这个
  集群此刻正在运行的那几个。参见 [Self-hosting](./README.md#self-hosting)。
- **同一个开放生态。** Chat、Bot Studio、Service Suite 与 Mac Node——下面的四个门户就是人、AI、Agent、
  设备与服务彼此安全连接、自由协作的方式。

## 四个官方门户

| 门户 | 地址 | 角色 |
|---|---|---|
| POPOPX | `https://popopx.chat/` | 项目主页：本平台、本仓库、各项政策 |
| Bot Studio | `https://bot.popopx.chat/` | 在你自己控制的服务器上运行你自己的 bot |
| Service Suite | `https://mp.popopx.chat/` | 服务账号与频道生态 |
| Mac Node | `https://node.popopx.chat/` | 在你自己的 Mac 上自托管服务器集群 |

这张表只划分角色。这四个地址背后的可达性与 DNS 测量才是要反复重测的那份记录，见
[Public sites](./README.md#public-sites)。

## 与上游的关系

本项目**派生自 [SimpleX Chat](https://github.com/simplex-chat/simplex-chat)**，并由 **POPOPX 独立运营**
——不同的分发方、自己的基础设施、自己的发布与支持渠道。协议、密码学与核心实现是上游的工作；
[NOTICE](./NOTICE) 列出任何构建都必须保留的署名，[FORK.md](./FORK.md) 记录本 fork 在其之上做的每一处改动。

本仓库发布的版本：iOS 客户端为 **1.2.0 (build 100)**（`apps/ios/POPOPX.xcodeproj/project.pbxproj` 中的
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`），Haskell 核心为 **7.1.2.0**（`popopx-chat.cabal:8`）。

---

## 「独立运营」在实践中改变了什么

应用只预设 **POPOPX 自己的 `popopx.im` 集群**。上游与第三方中继地址已从预设列表中移除——
`src/Popopx/Chat/Operators/Presets.hs` 里既不含 `simplex.im`，也不含 `simplexonflux.com` 主机，
而应用展示给你的运营方条目就是 POPOPX 自己的：

```haskell
tradeName = "POPOPX Chat", legalName = Just "POPOPX",
serverDomains = ["popopx.im"], conditionsAcceptance = CARequired Nothing
```

这是一个刻意的取舍，说清楚：在这个构建上，**针对被移除的中继创建的短链接不再可解析**。你换来的是
一次全新安装只与一个运营方通信——同意页面上写名的那一个，此外没有别的。

## 身份模型

- **没有全局 ID。** 你的 POPOPX 地址是指向某个中继上某个队列的链接，不是数据表里的一行。整个代码库里
  没有任何注册请求——没有 `createAccount`，没有短信或邮箱验证。
- **不绑定手机号或邮箱。** 应用中没有任何东西采集二者；在 iOS 上通讯录从不被读取
  （`CNContactStore` 与 `NSContactsUsageDescription` 都不出现在 target 中）。
- **每个会话一个新地址**是设计本身，不是一个选项：同一个 profile 可以持有多个地址，而对方永远只看得见
  某个会话最初使用的那一个。
- **服务器上没有联系人图谱。** 持有队列 A 的中继不会知道队列 A 与队列 B 属于同一个用户。

## 核心技术

### 端到端加密的单向队列

传输层是 SMP：你创建的队列由发送方写入、只由你读取，因此建立连接既不需要发现地址，也不需要同步握手。
中继持有的全部内容都是密文，而保护它的棘轮是你自己的：一个 double ratchet，其 DH 步骤
**默认就是后量子混合**——`sntrup761` 在每一次棘轮推进中与 X25519 组合使用
（`PQSupportOn` 是 `src/Popopx/Chat/Library/Internal.hs:993` 与
`src/Popopx/Chat/Library/Commands.hs:2160,3975,3997` 中的默认值；该原语从被固定版本的 `popopxmq`
依赖中无条件编译进来，因此不依赖任何构建开关）。这类后量子加密是上游的协议设计，本 fork 继承它；
上面引用的证据是我们自己的。

### 不依赖推送服务的离线投递

消息会存储在中继队列上直到应用取走它，因此投递不依赖推送服务是否成功。Apple 与 Google 的通知通道只用于
*唤醒*应用，而唤醒包携带的是加密元数据——见 [Privacy](./PRIVACY.md)。

### 一个联系人的两条通道，包含蓝牙直连

当对端可以经多条路径到达时，`PopopxMessageRouter` 会发布 `.dualChannel` 状态
（`apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Router/PopopxMessageRouter.swift:271,1473`），
其背后的 central 与 peripheral GATT 角色由 `PopopxBLETransport.swift` 实现，并在
`apps/ios/POPOPX--iOS--Info.plist:61-62,92-100` 中声明了 `bluetooth-central` /
`bluetooth-peripheral` 后台模式。这让一次会话在两部 iPhone 之间、完全没有任何网络的情况下继续下去。

这一段不该被夸大的两点：

- 它**只有 iOS**——`apps/multiplatform` 中没有对应的路由器。
- 它**是可选开启、且默认关闭**：还没有人做过决定时，kill-switch 持久化的值就是 `false`
  （`PopopxMeshKit/Sources/PopopxMeshUI/PopopxMeshKillSwitch.swift:245`），所以一个构建不会在你启用之前
  就开始广播。
- mesh 自己的握手是 `Noise_XX_25519`
  （`PopopxMeshKit/Sources/PopopxMeshKit/Crypto/PopopxNoiseXX.swift:8`）。那是 *mesh* 的传输层；
  SMP 连接使用协议自身的握手，不是 Noise。

### 媒体文件剥离元数据后才离开设备

在 iOS 上，图片、视频和 PDF 在附加之前会在本机重新编码，元数据字典被丢弃（图片见
`apps/ios/Shared/Features/MediaCompression/PopopxMediaEngine.swift:385`，视频对应 `:440` 的
`writer.metadata = []`，PDF 逐页重绘且不带页面信息）。文档则改用 LZFSE 容器封装——它只缩小文件，
不改动文件内容，所以预览里这种情况标注为「已压缩」，绝不写成「已清除元数据」。重新编码后的文件即便
比原文件更大也照样发出：那条「产物变大就丢弃」的保险丝已拆除，它过去丢弃的是清洗过的副本，把仍带
位置信息的原件发了出去。

拦截器在每一项被选取时就运行一次（`Shared/Views/Chat/ComposeMessage/ComposeView.swift:778`、`:830`），
发送时复用这次结果，不会再处理一遍（`:2047`、`:2407`、`:2445`）。每个附件因此都带一枚徽标，说明它自己
的实际处理结果；选词规则在 `PopopxMediaStatusResolver`
（`apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Media/PopopxMediaStatus.swift`），由
`apps/ios/PopopxMeshKit/Tests/PopopxMeshKitTests/PopopxMediaStatusTests.swift` 覆盖。

语音消息仍然绕开它（`:2442`），动图 GIF 被分类器排除，在「文件」里选取的文档按原样复制——这三类都显示
「按原样发送」。关闭媒体压缩后引擎不改写任何文件，但静态图片在发出时仍会经过应用自身的图片编码，所以
它的徽标写「发送前已重新编码」，不署引擎名。Android 与桌面端没有等价实现。

### 在应用内购买的 node badge

支持者 badge 是一笔 StoreKit 2 购买
（`Shared/Features/BadgeCredits/PopopxStoreKitManager.swift:197-272`，13 个 SKU `com.popopx.badge.node.*`）。
账本**在本地、在设备的 Keychain 里**（`PopopxBadgeManager.swift:69,136,215`），不存在任何能够撤销它的
POPOPX 商店服务：代码自己就这么写——*"要把一项 entitlement 跨设备收回需要一个服务器，而这个功能没有"*
（`PopopxCreditsManager.swift:285`）。后果记录在 [PRIVACY.md](./PRIVACY.md)：购买不能在设备之间迁移，
而持有支付记录的是 Apple，不是 POPOPX。

### 静默应用的签名服务器配置

两个 POPOPX 官方订阅会在 profile 首次启动时不经弹窗地种下
（`Shared/Features/ServerConfigSync/PopopxServerConfigSignalHandler.swift:814-820`，由每个用户持久化的
标记守卫，因此是幂等的），而沿签名通道下发的配置会被校验、合并并静默应用，附带一次回滚快照，以及当应用后
的 generation 未通过探测时的还原路径（`:10-30`）。它由应用生命周期中的三个触发点发起
（`Shared/Navigation/MainTabView.swift:233,244,253,262`）。某个已应用 generation 的凭证只从 direct chat
上行发送——从不从广播频道发送。

### 胁迫抹除

这是两个互不相同的功能，因为它们摧毁的东西不同：

- **胁迫口令**（`Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift:831-905`）关闭会话、清除
  mesh 身份、删除数据库、备份、导出、壁纸与存储的数据库口令
  （`apps/ios/POPOPXChat/FileUtils.swift:143-163`），移除 app/胁迫/助记词三类 Keychain 条目，然后重建一个
  全新的 profile。另一种策略（`:998-1053`）保留你选定的一个 profile，删除其余的**包括它们的服务器队列**。
- **恐慌擦除**（`PopopxMeView.swift:514-538` 中的红色行，或三连点品牌标记）是 mesh 的两遍覆写。在 iOS 应用
  里它以 `applicationDatabaseURL: nil` 构造（`Shared/Model/POPOPXAPI.swift:3808-3821`），因此它清除的是
  mesh 密钥、无线电状态与 mesh 记录；又因为宿主给了它 `PopopxMediaWipeRecorder`，容器临时目录下的两份
  媒体明文缓存也会一并清掉，最后结束进程。它**不会**删除聊天数据库，也没有“下次启动再擦”这种延后分支：
  确认后立即执行，否则就不发生。请启用与你真正需要消失的东西相匹配的那一个。

### 通话

语音与视频通话跑在 WebRTC 上，本地渲染与信令都在本仓库。随包发布的 ICE 配置是纯 STUN：
`stun:stun1.popopx.im:5349`（`apps/ios/Shared/Views/Call/WebRTCClient.swift:93`，
`packages/popopx-chat-webrtc/src/call.ts:355`）。POPOPX 另外运营一个 TURN 中继
`turn1.popopx.im:5349`，但它的凭据不在本仓库里：iOS 从 `Info.plist` 读取
`POPOPX_TURN_USERNAME` / `POPOPX_TURN_CREDENTIAL`，这两个值来自被 git 忽略的 `apps/ios/Local.xcconfig`；
缺少该文件时应用宁可退回纯 STUN，也不会挂出一个无法认证的中继
（`apps/ios/Shared/Views/Call/WebRTCClient.swift:113-130`）。iOS 优先走直连路径，只有在配置了中继且直连
失败时才用它；解析器一直都接受 `turn:` / `turns:` 条目，所以你在设置里自己添加的服务器——或者自建
TURN——会以同样的方式生效（`Shared/Views/Call/WebRTC.swift:469-487`）。

## 基础设施

十五个中继端点，每一个都在同一条记录里写成公网主机**加**配对的 V3 onion 地址，另加一个 STUN 主机和一个
TURN 主机：

| 角色 | 主机 | 端口 | 来源 |
|---|---|---|---|
| SMP 消息队列 | `smp1..8.popopx.im` | 5223（不带端口的地址） | `Operators/Presets.hs:69-76` |
| 聊天中继 | `relay1.popopx.im` | 5227 | `Operators/Presets.hs:105,115` |
| XFTP 文件传输 | `xftp1`、`xftp6`、`xftp8.popopx.im` | 8443 | `Operators/Presets.hs:91-93` |
| NTF 推送通知 | `ntf1..3.popopx.im` | 5226 | `Library/Commands.hs:164-169` |
| STUN | `stun1.popopx.im` | 5349 | `Shared/Views/Call/WebRTC.swift:469` |

这些端口是承重结构，不是装饰：不带端口的 SMP 地址拨向原生端口（5223），而不带端口的 XFTP 地址会被拨向
443——而这个集群上的 443 是 web 服务器，不是文件传输服务。`.popopx.im` 不出现在 `presetDomains` 里正是
同一个原因。

**关于双栈：**上面每个端点都同时带有公网 DNS 主机与 V3 `.onion` 主机，测量于 2026-11-25。它们其中没有一个
带有 IPv6 `AAAA` 记录——对本项目的每个主机执行 `dig +short AAAA popopx.chat smp1.popopx.im` 结果都是空的。
第二条通道是 Tor，不是 IPv6。

### 公开站点

2026-11-25 用 `dig` 与 HTTP 状态探测测量。四个站点都解析到 `43.129.40.33`，并在站点根路径返回 `200`：

| 站点 | 地址 | 它是什么 |
|---|---|---|
| 项目站点 | `https://popopx.chat/` | 本 fork 自己的主页 |
| Mac Node | `https://node.popopx.chat/` | 在你自己的 Mac 上自托管服务器集群；`/badge` 返回 200 |
| Portal | `https://mp.popopx.chat/` | 服务账号与频道生态 |
| Bot Studio | `https://bot.popopx.chat/` | 在你自己控制的服务器上运行你自己的 bot |

该站点不托管政策页面；自 2026-11-25 起它把这些页面**重定向**进本仓库（用
`curl -o /dev/null -w '%{http_code} -> %{redirect_url}' https://popopx.chat<path>` 测量，走直连出口
——`curl --noproxy '*'`——因为本地代理会丢弃其中一些主机）：`/privacy`、`/privacy/`、`/security` 与
`/security/` 全部返回 **301 →
`https://github.com/popopx-chat/popopx-chat/blob/master/PRIVACY.md`**。`/terms` 与 `/terms/` 返回
**301 → `https://github.com/`**，而那里不提供任何条款文本：许可证就是本仓库自己的
[`LICENSE`](./LICENSE)，政策就是本目录树里的这些文件，而不是网页。`/node`、
`/docs/upstream-disclaimer.html` 以及其余每个 `/docs/…` 路径仍返回 **404**，并且 `popopx.chat` **不发布 MX 记录**（同日测量）。

### POPOPX 官方地址

以下是应用静默加入的两个官方预设订阅，其取值与客户端读到的完全一致
（`apps/ios/Shared/Features/ServerConfigSync/PopopxServerConfigSignalHandler.swift:919-929`）。
两者都以完整 SMP 地址发布在这里，因为没有密钥和路径的主机是拨不通的：

- **配置频道**（只读；服务器把成员固定为 `observer`）：
  `https://smp2.popopx.im/g#AbX7ZWizYxULjL-QpOGJLJm7C33BcXIsLc61IVOa8zM?c=4bJjC-wqSpviWwuDnkhSKTD4V8mYxpLqj4aiCUSfGfA`
- **POPOPX 服务账号**（1:1、静默投递，更新凭证发往此处）：
  `https://smp6.popopx.im/a#ZwDniscH42Q2di4Ti-2MJns_ow7OasGL1BwoDoVBnis?c=2bIUdRa7VJeB2tx9W3gwaOJ2Sv72fH8Pc_uM9l9r4hM`

## Tor 与代理

任何客户端都不随带 Tor。上面每个地址的 `.onion` 那一半意味着应用*可以*指向隐藏服务端点而不是公网主机，
而在 iOS 上 `Shared/Views/UserSettings/NetworkAndServers/AdvancedNetworkSettings.swift:112,142,182-187,365-378`
暴露了一个 SOCKS5 开关加一个 `.onion` 偏好开关，以 `socksProxy` 形式接通
（`apps/ios/POPOPXChat/AppGroup.swift:362,392`）。**那个开关需要你自己提供的代理**（设置项自己写着
"Requires compatible VPN"），而且默认关闭——所以在移动端，针对被攻破的中继保护 IP 是一件你需要自己配置的
事，不是一个构建替你做好的事。CLI 有对应的选项（`src/Popopx/Chat/Options.hs:127-150`）。

## 从源码构建

### iOS：原生 Haskell 核心

Xcode 工程链接的静态库是用 Nix 交叉编译的。flake 属性是品牌化过的，所以目标是
`…:lib:popopx-chat`，绝不是上游仓库 `simplex-chat/simplex-chat` 里的 `…simplex-chat` 写法。下面两种写法都能实例化
（2026-11-25 用 `--dry-run` 验证）：

```bash
nix build '.#hydraJobs.aarch64-darwin."aarch64-darwin-ios:lib:popopx-chat"' \
  --extra-experimental-features "nix-command flakes" -o ./ios-core
# equivalent short form:
nix build '.#"aarch64-darwin-ios:lib:popopx-chat"' \
  --extra-experimental-features "nix-command flakes" -o ./ios-core
```

`flake.nix` 从一棵 `cleanGit` 树构建，所以**未提交的 Haskell 改动不会出现在产物里**——先提交再重建。
结果是 `pkg-ios-aarch64-swift-json.zip`；把五个 `.a` 文件解到 `apps/ios/Libraries/ios/`。

然后对齐归档文件的最低 OS 与应用的地板值。`scripts/ios/set-minos.py` 接受一个位置参数而非开关，并就地
修补每一个 `LC_BUILD_VERSION`：

```bash
python3 scripts/ios/set-minos.py 17.0 apps/ios/Libraries/ios/*.a
```

第二次运行它会报告 `written=0`，这就是该字段已经持有 17.0 的证明。跳过这一步会让 RTS 构建的成员保留
SDK 版本的戳记，链接器随之输出成千上万条 "built for newer iOS" 警告。

用一次不需要签名的构建来把关结果：

```bash
xcodebuild build -project apps/ios/POPOPX.xcodeproj -scheme "POPOPX (iOS)" \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

模拟器构建请显式传入 `ARCHS=arm64`。libraries 目录被 gitignore：让一次构建可复现的是这个 flake 加上这条
命令，不是磁盘上的产物。

### 其他平台

Android、桌面与 CLI 都由本仓库中 `.github/workflows/` 里的工作流构建；`docs/CLI.md` 覆盖命令行客户端，
桌面 DMG 的配方在上游留下的位置，即 `apps/multiplatform/README.md`。

## 自托管

应用预设的每一台服务器都能在设置中替换而无需重新构建，而为 `popopx.im` 提供服务的同一批二进制就是你可以
自己运行的那批：`node.popopx.chat/` 记录的是在你自己的 Mac 上做这件事。中继密钥是地址的一部分，因此切换
中继意味着已有联系人要换新地址——迁移一个活跃联系人之前，应该先读应用里的切换服务器流程。

## 隐私

**[PRIVACY.md](./PRIVACY.md)** 是 POPOPX 针对本应用与上述集群的策略：应用不采集什么、中继持有什么、
iOS 在磁盘上保护什么，以及这条 fork 无法超出 Apple 或一个自托管用户本身已经蕴含的边界在哪里。
**[PRIVACY-POPOPX.md](./PRIVACY-POPOPX.md)** 是配套记录——谁运营什么、哪段文本是上游的，以及每个论断
所依据的测量或文件。

## 安全漏洞联系

请把 POPOPX Chat 构建中的漏洞报告给 **chat@popopx.chat**。投递到该地址**未经验证**：`popopx.chat` 不发布
MX 记录（2026-11-25 测量），POPOPX 也没有为它发布 OpenPGP 公钥，因此除非你从别处提供一把密钥，一份报告会
以明文传输。补齐这个缺口——一条可用的邮件路由与一把公开密钥——是未完成的工作，不是已记录的能力。
请**不要**把漏洞作为 GitHub issue 提交。

## 许可证

**代码、美术作品、名称。** 本软件的源代码以 GNU Affero General Public License 第 3 版（AGPLv3）授权——
见 [LICENSE](./LICENSE) 文件。本 fork 创作的美术作品自 2026-11-16 起携带同一份授权，或由接收方选择
CC0-1.0。名称不随这里任何东西而来：商标位于版权许可证之外。上游那一边两者又是另一回事：

- **上游（SimpleX Chat Ltd）**：SimpleX 与 SimpleX Chat 的名称、logo、相关品牌素材，以及应用与网站的图形
  资产（插画、图片、视觉设计等）不在本许可证覆盖范围内，其条款分别见
  [TRADEMARK](https://github.com/simplex-chat/simplex-chat/blob/stable/docs/TRADEMARK.md) 与
  [ASSETS_LICENSE](./assets/ASSETS_LICENSE.md) 两个文件。
- **POPOPX（本 fork）**：POPOPX 与 POPOPX Chat 的名称、字标、logo 以及由此衍生的图标，和 `popopx.chat`
  域名，都不因本文档而被授权给任何人，其条款见 [TRADEMARK-POPOPX](./TRADEMARK-POPOPX.md)。本 fork 创作的
  美术作品是授权而非保留的：[ASSETS_LICENSE](./ASSETS_LICENSE.md)。它只授权本 fork 自己画的那些——
  它不能、也不会释放该文件中列出的与上游一致的文件。

**如果你 fork 本仓库并分发它，请重新建立品牌。** 你保留 AGPLv3 赋予你的对代码的一切权利，并且自 2026-11-16
起对这条 fork 自己创作的美术作品享有同样的权利；你不能带走的是任一项目的名称，或上游的美术作品。所以你的
构建必须携带一个不同的名称以及它自己的字标、图标与标记——我们的其他图画你可以保留，但永远不能当作你自己
产品的身份。[NOTICE](./NOTICE) 列出必须保留的上游署名。
