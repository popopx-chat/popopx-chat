# POPOPX 动态隐私节点徽章 / 算力点生态 —— App Store 审核备注

# App Store Review Notes — Dynamic Privacy Node Badge & Compute Credits

> 本文件有两类内容，分得很清：
> **①【审核可粘贴】** 是英文、可直接填进 App Store Connect → App Review Information → Notes；
> **②【内部】** 是中文的实现事实、待办与风险，不给审核看。
>
> Every factual claim below is a measurement, not a memory: section 附录 lists the exact command that
> reproduces it. If the code moves, re-run the commands before re-submitting.

- 版本 / Version: 提交前基线 = `apps/ios/Shared/Features/BadgeCredits/`（17 个 Swift 文件、8 768 行，实测 `wc -l`；另有本文件与 `PopopxStoreKit.storekit`）
- 最后核对 / Last verified: 2026-11-19（本轮：口径收口 + `CHANNEL_SUB_ACK` 核销回执 + 频道卡片防冒充，门禁 `build/gate_bc5.log`（失败，见第 10 节）与 `gate_bc6.log`，读数见第 10 节）
- 商店配置文件 / StoreKit config: `apps/ios/Shared/Features/BadgeCredits/PopopxStoreKit.storekit`
  （9 个产品：5 个消耗型 + 2 个自动续订订阅（同属一个订阅组 `3020000001`）
  + 2 个**非续订**一次性通行证（`nonRenewingSubscriptions`：`pass.30d` / `pass.365d`）；配置 `version` = major 4）。
  工程引用的就是这一份，且**现在只有这一份**（`project.pbxproj:693` 的 fileRef 挂在 `path = BadgeCredits`
  的 group 下，:1880 进 `POPOPX (iOS)` 的 Resources 阶段）。
  根目录那份逐字节相同的重复副本 `apps/ios/PopopxStoreKit.storekit` 已按 2026-11-19 裁定删除；
  删除前实测它在 `project.pbxproj` 里 0 处可解析引用（那 4 条同名引用全部指向 BadgeCredits 那一份），
  且 `cmp` 两份 IDENTICAL。**改配置只改上面那一条路径。**

---

## 1. 这个功能是什么 / What the feature is

**【口径 · 2026-11-19 现行文本，全文件与商店文案以此为准】**

> 点亮"POPOPX 动态隐私节点徽章"用于支持去中心化加密中继基础设施的持续运行，解锁专属翡翠绿动态节点状态标识、
> 实时节点状态面板、点对点二维码礼品卡转赠特权，以及向好友发送与核销端到端加密算力点红包的生态身份认证。

> Activating the "POPOPX Dynamic Privacy Node Badge" supports the ongoing operation of decentralized
> encrypted relay infrastructure. It unlocks an exclusive emerald dynamic node status indicator, a
> real-time node status panel, peer-to-peer QR code gift card transfers, and ecosystem authentication
> for sending and claiming end-to-end encrypted Compute Credit red packets.

**【商店元数据短句 · 逐字采用】**
- zh-Hans：`解锁动态节点标识、节点状态面板与礼品卡转赠。`
- en：`Unlocks node badge, status & P2P gift cards.`

这四句里的每一项都对应一个**已落地、可在本机走到**的东西，逐条落点（命令见附录）：

| 口径里的说法 | 代码落点 |
|---|---|
| 翡翠绿动态节点状态标识 | 顶栏胶囊 `PopopxBadgeCapsuleView.swift`，点亮态取 `PopopxPalette.successInk`（翡翠绿墨，:11 解释它与提示词 #10B981 的对应关系） |
| 实时节点状态面板 | `PopopxBadgeDetailSheet.swift`（档位、到期、对账摘要、本机计数，只读本机） |
| 点对点二维码礼品卡转赠 | `PopopxGiftBadgeCardSheet.swift` 铸券 + `PopopxVoucherRedeemSheet.swift` 扫码核销 |
| 发送与核销算力点红包 | `PopopxCreditsManager.sendRedPacket(...)`（:303）与领取/退款路径（第 3 节①） |

同一裁定还有一条禁止项：任何位置都**不得**写成"购买后改变传输协议""绕过防火墙""提供 VPN 隧道"。
上面这句和下面所有可粘贴文本都服从这一条；**用户可见文本**里这些词是 0 处——模块内只剩 2 处代码注释提到
"VPN"这个字面词（计数与命令见第 5 节）。

**【审核可粘贴 · EN】**

POPOPX is an end-to-end encrypted messenger. This feature adds an optional, paid **Dynamic Privacy
Node Badge** and an in-app virtual currency, **Compute Credits**.

- The app is free and open source, and **every user — paying or not — uses the same standard
  end-to-end encryption protocol**. There is no "stronger encryption" tier.
- The badge is **support for the operating cost of the decentralized relay network** (SMP/XFTP
  servers) that the app's messages pass through. It is not a VPN, proxy, tunnel or anonymity
  network, and it cannot be configured as one: the feature contains no network-extension,
  `NEVPNManager` or proxy-configuration code (see the check in section 7).
- Compute Credits can only be purchased with in-app purchase (Apple's payment). They are spent inside
  the app on: badge exchange, peer-to-peer credit packets, channel subscriptions, encrypted profile
  unlocks, a longer secure-viewing window, and cosmetic items.
- There is **no server operated by us for this feature**: no ledger, no account, no redemption
  endpoint. Balances, badges and gift codes live in this device's Keychain. Peer-to-peer steps are
  exchanged as ordinary end-to-end encrypted SMP messages between the two users.

**【内部 · 原先那三个解锁项已整句撤下（裁定 B，2026-11-19 执行完毕）】**
上一版口径里的"高并发中继路由优先调度 / 节点池每日动态轮换防关联 / 单文件最大 1GB"三项，
按裁定 **B（实事求是，不虚标未实现功能）** 从**四件产物**里一起撤走，App 内不再出现完成时断言。
逐条证据（本轮复算，命令见附录）：

| 原先写进的收益点 | 代码现状（为什么不能写） | 撤走的位置 |
|---|---|---|
| 高并发中继路由优先调度 | **0 处实现**。全特性没有任何"按优先级选路/调度"的代码路径，客户端也不向中继声明优先级 | 本文件可粘贴块（本节上一版）；`grep -rln '调度\|priorit\|schedul' Shared/Features/BadgeCredits/ \| wc -l` = **0** |
| 节点池每日动态轮换防关联 | **只有本地计数**。`PopopxCommerceLimits.nodeRotationSeconds = 15`（`PopopxBadgeCreditsModels.swift:73`）只是胶囊转圈与本机计数的**最小间隔**，真正的判定每 30 秒心跳最多一次（`PopopxBadgeManager.swift:312`），不发任何请求、不改任何中继地址 | `PopopxTrialWelcomeModal.swift:201`（原句"…中继地址定期轮换"→ 现为"节点状态面板"那一句）、`PopopxBadgePaywallView.swift`（原 `benefitRotation` 那条 bullet **整条删除**，收益清单现为 5 条 :286-290）、`PopopxBadgeDetailSheet.swift`（"遥测"→"节点状态面板"、"间隔"格改为 `≥ 15 秒`） |
| 单文件最大 1GB 的加密传输配额 | **1GB 是无条件的既有上限，不是买来的**。`getMaxFileSize(.xftp:)` 无徽章时返回 `MAX_FILE_SIZE_XFTP = 1_073_741_824`；真正抬高上限的是既存的另一套 `LocalBadge`（supporter 2GB / legend 5GB），与本徽章无关 | 商店短句与本节可粘贴块都不提 1GB（`POPOPXChat/FileUtils.swift:31,365-375`） |

撤完之后，**用户可见文本**里 `轮换 / 优先调度 / 1GB` 三个词是 0 处（附录第一条命令实测：排除注释行后 grep 无命中）。
剩下的路径是：日后若把中继侧调度与轮换做实并上机验证（要核心/服务端配合），再把这些句子放回来，
放回来时必须四件产物同时改，并更新本节与第 8、9 节。

在实现接完之前，App 内那台"节点状态面板"自己带着免责声明
`PopopxBadgeDetailSheet.swift:289`："这一格只是本机计数……没有任何中继节点因为它而改变"——这句**不要删**，
它是目前唯一让 UI 与代码一致的说明。

---

## 2. 内购清单 / IAP inventory

`PopopxNodeBadgeSku`（`PopopxBadgeCreditsModels.swift:142`、`productId` 整表 :155-167、价格回退 :216-223）与
`PopopxStoreKit.storekit` 的 9 个 identifier 已交叉核对，双向一致、无多无少
（核对用的是**工程引用的那一份** = `Shared/Features/BadgeCredits/PopopxStoreKit.storekit`；
2026-11-19 裁定后根目录那份逐字节重复副本已删除，仓库里只剩这一份，见文件头）。

| # | Product ID | 类型 / Type | 回退价 / Fallback | 交付内容 / Delivers |
|---|---|---|---|---|
| 1 | `com.popopx.badge.node.monthly` | Auto-renewable subscription（P1M） | $6.99 | 徽章 30 天 / badge 30 days |
| 2 | `com.popopx.badge.node.annual` | Auto-renewable subscription（P1Y） | $49.99 | 徽章 365 天 / badge 365 days |
| 3 | `com.popopx.badge.node.pass.30d` | **Non-renewing** subscription（一次性通行证） | $6.99 | 购买起点亮 30 天，不自动续订 / 30-day pass, never renews |
| 4 | `com.popopx.badge.node.pass.365d` | **Non-renewing** subscription（一次性通行证） | $49.99 | 购买起点亮 365 天，不自动续订 / 365-day pass, never renews |
| 5 | `com.popopx.gift.node.monthly` | Consumable（礼品卡/一次性券） | $6.99 | 一张可转赠的 30 天徽章券 / transferable 30-day voucher |
| 6 | `com.popopx.gift.node.annual` | Consumable | $49.99 | 365 天徽章券 / 365-day voucher |
| 7 | `com.popopx.credits.100` | Consumable | $1.99 | **正好** 100 算力点 / exactly 100 credits |
| 8 | `com.popopx.credits.500` | Consumable | $8.99 | 正好 500 / exactly 500 |
| 9 | `com.popopx.credits.2000` | Consumable | $29.99 | 正好 2000 / exactly 2000 |

**【审核可粘贴 · EN】** Both subscriptions belong to a single subscription group
(`3020000001`, "POPOPX Dynamic Privacy Node Badge"). Only those two products auto-renew; the two
`pass` products are **non-renewing** subscriptions (bought once, never renewed, no further payment),
and everything else in the list is a consumable. Restore Purchases calls StoreKit's `AppStore.sync()`
(`PopopxStoreKitManager.swift:371`) — we do not implement our own restore or refund flow, and the
in-app UI sends users to App Store settings to manage or cancel.

**【内部 · 3.1.2(c) 披露】** 自动续订说明全文走 `NSLocalizedString("Payment will be charged to your Apple
Account at confirmation of purchase. …")`，已进全部 16 个翻译目录（见第 6 节）。付费墙在订阅档下方直接展示
该句；取消/管理入口不自建。

**【内部 · 纯净充值】** 三个点数包"到账 = 面额"，代码里没有"赠送/bonus"这条通路；
`PopopxCommerceCopy` 里那句 "Compute Credits are added at the exact amount shown. No bonus credits
are granted." 是审核读的证据句，全 16 语种都有。

---

## 3. 算力点 / Compute Credits

**【审核可粘贴 · EN】**

- Credits are purchasable **only** through Apple IAP inside this app. There is no external purchase
  path, no web store, and nothing in the app links out to buy credits.
- Credits are **not** transferable to another account or device, cannot be withdrawn, and cannot be
  converted back to money. They cannot be traded; the only peer-to-peer movement is an explicit
  sender→recipient gift, which is a spend, not a currency exchange.
- Non-refundable once spent. The one automatic return in the design: a credit packet that nobody
  opens is returned to the sender 30 days after it was sent (`PopopxCommerceLimits` :62), and the
  exact number is interpolated into the sentence from that constant, so the promise cannot drift.
- Balance cap: 100,000 credits (:40). A top-up that would exceed the cap is refused with an explicit
  message rather than silently truncating.

**【内部】六个花费场景与代码落点**（`PopopxCreditsManager.swift`）：

| 场景 | 判据 / 数值 | 落点 |
|---|---|---|
| ① 红包（点对点算力点） | 面额只能取 `[10, 50, 100, 500]`（:56），收件人上限 100（:58），**无自定义金额输入框**；**只出现在 1:1 单聊**（裁定 2026-11-19，群聊里这一格不渲染，见第 9 节第 8 条） | `sendRedPacket(amount:recipientCount:note:)` :303 |
| ② 频道订阅 | 门槛由**频道主自己**设定：1 到 100,000、最多 6 位数字（:51、:53；`make` :720 拒绝 0，`canPublish` 也要 `price >= 1`，所以"免费"的表达方式是**不发卡片**而不是发一张 0 价卡，`PopopxChannelSubscriptionSheet.swift:474`）；一 period 30 天（:65） | `subscribeToChannel(...)` :423 |
| ③ 加密资料卡解锁 | 价格来自 `popopx://profile` URI 的可选参数 `credits=`（`PersonalProfileModel.swift:445-458`，缺省即免费） | `unlockProfile(...)` :471 |
| ④ 防窥窗口延长 | 20 点 / +3600 秒（:67-68），只延长本机一侧的查看窗口 | `purchaseExtendedSecureWindow()` :502 |
| ⑤ 外观（头像框 / 暗金二维码皮肤） | 各 150 点（:70-71），一次性、仅本机生效 | `purchase(_:)` :508 / `owns(_:)` :516 |
| ⑥ 算力点兑徽章 | 600 点 / 30 天，4500 点 / 365 天（:98-99）；**先扣点后点亮，点亮失败原额退回** | `exchangeCreditsForBadge(period:)` :268 |

**② 的宿主入口（本轮裁定"必须接上、不得留孤立死代码"后的实测链，行号本轮重测）**：
频道页 `PopopxGroupChatInfoView.swift:270`（`subscriptionCard`，仅 `groupInfo.isChannel` 时出现）
→ 频道主/管理员那一格 `:276` 推进 `PopopxChannelThresholdView`（`PopopxChannelSubscriptionSheet.swift:341`；
   进不进这一格由 `popopxCanPublishChannelThreshold` 决定，见下）
→ `sendChannelAccess`（`PopopxSilentSignalingRouter.swift:412`）把**一条可见的**门槛卡片
（`popopx://channel?p=&t=&e=&s=`，载荷 `PopopxBadgeCreditsModels.swift:691`）发进频道会话
→ 成员在气泡上点订阅（`PopopxCommerceCards.swift:400` 的 `PopopxChannelAccessBubble`）才真正走
`subscribeToChannel` 扣点 → 票据写本机钥匙串，成员回到频道页那一格读到"有效至 …"（`:294`）
→ **票签成之后**成员这一侧再补发一条静默核销回执 `CHANNEL_SUB_ACK`（第 4 节第七种），
   它是尽力而为的：发不出去只留一行日志，绝不回滚那张已经成立的票据。
双向键都用 `ChatInfo.id`（群/频道即 `"#<groupId>"`），生产侧与消费侧同一个串，不会各算一次。
卡片是**看得见的消息**、不删不隐藏：它是成员那一侧唯一的价目来源（详见 `PopopxChannelAccessPayload`
顶部注释与本文件第 9 节第 7 条偏差）。

**发布端判据只有一份**（本轮裁定"防冒充必做"里可以落地的部分）：
`PopopxSilentSignalingRouter.swift:52` 的 `GroupInfo.popopxCanPublishChannelThreshold`
= `isChannel && membership.memberRole >= .admin && membership.memberCurrent`，
频道页那一格（`:274`）与 `sendChannelAccess` 的守卫（`:413`）读的是同一个计算属性，
所以"能不能发布"不会出现两个答案。接收端的两道闸见第 9 节第 7 条。

**②③④⑤ 都不经过 Apple**：它们花的是"此前已经通过 Apple 买过的余额"，不产生新的 IAP。
这是本特性最需要主动解释的一块，第 7 节给了口径。

---

## 4. 零 Bot、零中心账本 / No bot, no central ledger

**【审核可粘贴 · EN】** This feature contacts no server of ours. Every redemption or gift step is a
message between the two users over the existing end-to-end encrypted SMP connection. The whole
feature makes **five** API calls to the local messaging layer, all inside one file
(`PopopxSilentSignalingRouter.swift`, lines 278, 293, 325, 456, 487): create a temporary incognito
connection, send the control message, then delete the message rows and the temporary connection.
Nothing is persisted on our side because we run no side for this feature.

**【内部】** 七个静默信令种类（`PopopxCommerceSignalKind`，`PopopxBadgeCreditsModels.swift:806-820`）：
`EXT_REDEEM_REQ` / `EXT_REDEEM_ACK` / `CHAT_REDEEM_REQ` / `CHAT_REDEEM_ACK` / `REDPACKET_CLAIMED`
/ `PROFILE_UNLOCKED` / `CHANNEL_SUB_ACK`，线上格式 `::popopx_sys::` + 大写名 + `::` + 载荷（:831）。
前五种是需求点名的；**第六种是按需求补的**（资料卡解锁回执在需求里被写成"静默通知"却没有对应名字），
理由与"只进不出、收到即删行、绝不落库为可见记录"的语义记在 `PROFILE_UNLOCKED` 那一格的注释里，
本文件第 9 节把它列为 deviation。**第七种 `CHANNEL_SUB_ACK` 是 2026-11-19 裁定点名的**
（需求 :88"向频道同步已核销凭证回执"那一格，见第 8 节第 7 条的关闭记录）：成员扣点签票成功后，
本机把 `::popopx_sys::CHANNEL_SUB_ACK::<chatInfoId>::<expiresAtMs>` 发回那条频道会话，
载荷 `"chatInfoId::expiresAtMs"`（`PopopxSilentSignalingRouter.swift:426`）。
群/频道这一支的放行判据也从"只有 REDPACKET_CLAIMED"改成了 enum 上的计算属性
`acceptedInGroup`（:805），两种回执 kinds 共用它，避免"两处各写一份白名单"。
"用完即删"是裁定过的方案：Swift 层不渲染 + ACK 后删行 + 一次性连接整条删除（`.full(notify: false)`，:278）。
宿主侧三处闸（本轮重测行号，判据都只有 `PopopxSysMarker` 一份，`PopopxBadgeCreditsModels.swift:850`）：
渲染抑制在**行**这一层 `ChatView.swift:2318-2325`（命中即 `Color.clear.frame(height: 0)`，
挂在行而不是气泡，因为终端排版与群里的行会绕过气泡）；会话列表预览 `ChatPreviewView.swift:301-307`
（信令常常正是该会话的最后一条，预览会把它念出来）；通知横幅 `NtfManager.swift:254-262`
（横幅在删行的 `Task` 之前**同步**发出，只靠删行赶不上）。
收信旁路在 `POPOPXAPI.swift:2785-2796`。

防双花：券/红包状态机在 `actor PopopxP2PVoucherVault`（`PopopxP2PVoucherVault.swift:54`）里，
单写者、跨调用串行，兑换记录写在 `AfterFirstUnlockThisDeviceOnly` 的钥匙串条目上。

**频道门槛卡片仍然不是静默信令，第七种才是。** 卡片走同一个 `send(text:)`（`apiSendMessages`，:456），因此
"整特性只有五处网络调用"这句仍然成立；但它**不带** `::popopx_sys::` 前缀、不进 `PopopxSysMarker`
的判据、也不被 `deleteSignal` 删行（`send` 自己从不删，删除只在 ACK 路径上）。理由写在
`sendChannelAccess` 的注释里：成员唯一能看到价格的地方就是这条消息，把它藏起来等于让成员为一个
看不见的数字付点。效果是这条消息像普通文本一样留在双方的会话历史里（含对方的设备），
产品要接受这一点再提交——见第 9 节第 6、7 条。
`CHANNEL_SUB_ACK` 走的是**另一套**：带前缀、过三处闸、收到即 `deleteSignal`，所以频道主那一侧
既不会在时间线上看到它，也不会在横幅里读到它（后果与未覆盖的窗口见第 8 节第 5、7 条）。

---

## 5. 术语合规 / Terminology

**【内部 → 也可给审核】** 本特性**不使用**任何 VPN/代理/anonymizer 词汇。用户可见文本一律是
"动态 SMP 中继节点集群 / 加密中继路由 / dynamic SMP relay node cluster"，
术语本身是一条 `NSLocalizedString`（`PopopxCommerceCopy.nodeClusterTerm`），改一处即可全语种生效。
实测：`Shared/Features/BadgeCredits/` 下 17 个文件里，`VPN / 专网 / 代理 / proxy` 只出现在
两条**代码注释**（`PopopxBadgePaywallView.swift:381` 与源文注释 `comment: "never VPN"`，后者在
`PopopxBadgeCreditsModels.swift:1285`），
用户可见文本 0 处。16 个翻译目录里同样各有一行 `/* never VPN */`（那是给译者的说明，不是译文），
**译文值 0 处**含这些词；目录里其余的 "proxy/VPN" 命中全部在本特性之外的既存条目
（例如 onion 主机的连接设置）。这一点很重要：如果产品描述里出现"隐藏你的网络活动"，3.1.4（硬件/网络功能）
与 VPN 相关条款就会把 app 推到另一个审核类别。

**术语通俗化记录（2026-11-19 追加）**：产品要求把用户看得见的"遥测面板 / Telemetry"改成
"节点状态面板 / Node Status Panel"。落点四处，全部是功能内文案（`private enum Copy`，不走 `.lproj`）：
`PopopxBadgeDetailSheet.swift:288`（面板标题本身）、`:289`（脚注）、`PopopxTrialWelcomeModal.swift:209`、
`PopopxBadgePaywallView.swift:572`（收益条目那句，措辞红线注释在 `:381`）。复算与例外：
- `遥测` 这个词在**全部 Swift 与 `.strings` 里 = 0 处**（附录给命令）；17 个 `.lproj` 本来就没有它，
  所以"含 17 个 `.lproj`"那一条是**空操作**，不是漏做——那些目录只放涉钱/合规句子。
- `Docs/popopx-brand-spec.md` 原有 2 处（`:44` 小节标题、`:279` 字号表"顶栏遥测数字"）已按用户
  2026-11-19 的明确指示改为"节点状态"；**同一次指示覆盖了此前"不改 brand-spec"的裁定 4**，
  但只覆盖这两行——§2.4 那类条目仍然没有动（第 9 节第 4 条的例外仍由你定）。
- 类型与文件名 `Shared/Navigation/PopopxTelemetryHeader.swift` **保持原样**：改名要动 `.pbxproj`（红线），
  且 brand-spec `:249` 与 `:352` 引用的是这个真实路径，改了会让文档对不上代码。
- 用户自己的输入件 `apps/ios/prompt.md:64` 与 `apps/ios/ui-prompt.md:72` 仍写"遥测导航栏"，我没有改。

---

## 6. 本地化 / Localization evidence

**【审核可粘贴 · EN】** All purchase, renewal, refund and compliance sentences are localized. The
commerce copy set is **49 strings**, delivered into **all 16 translation catalogs** in the app
(bg, cs, de, es, fi, fr, hu, it, ja, nl, pl, ru, th, tr, uk, zh-Hans). English is the development
region, so it renders from the source key. Every entry passes the repository's own placeholder and
link validator (`scripts/ios/localizations.py`), and `plutil -lint` reports all 17 catalogs OK.

**【内部】** 三条刻意不复用已有 key 的说明：目录是 app 级共享的，`"History"`、`"For me"`、
`"Restore purchases"` 已被别的页面占用（zh-Hans 把 "For me" 译成"仅自己"、de 把 "History" 译成
"Nachrichtenverlauf"），所以本特性用 `"For myself"` / `"Restore badge purchases"` 独立成条，
并删掉了三条普查后无人引用的 key。分线判据写在 `PopopxCommerceCopy` 的文档注释里（`PopopxBadgeCreditsModels.swift:1269-1274`）：
**涉钱、涉退款、涉合规 → 目录；其余功能内文案 → 各文件私有 `enum Copy` 中文常量。**
据此，点数消费的确认弹窗（外观、解锁资料卡、频道订阅）保持中文功能文案：**2026-11-19 裁定"保持现状，
不扩写 16 个目录"**，第 8 节原第 4 条按这条关闭。若审核在别的语言环境下打开这些弹窗会看到中文——
这是裁定接受的后果，要翻的话是 3 句 × 16 目录的一次独立提交。

---

## 7. 审核最可能问的五个问题 / The five likely questions

1. **"Is the badge a VPN?" — No.** No VPN entitlement, no network extension, no packet tunnel,
   no proxy configuration API is used. Nothing about the transport changes when it is bought.
   *Check:* the feature contains no `NEVPNManager` / `NETunnelProvider*` / proxy symbols; it links
   no network-extension target.
2. **"Why do credits get spent without a new IAP?"** Because every credit was already bought through
   Apple. Spending is an in-app consumption of an existing balance (600/4500 credits → badge days,
   20 → one hour, 150 → a cosmetic, N → a 30-day channel subscription where N is a number the
   *channel owner* typed and the member sees on the card before tapping Subscribe).
   No external purchase, no sideload of value.
3. **"Is this a gambling / randomised mechanism?" — No.** All amounts are fixed and shown before the
   user commits: the credit packet offers exactly 10/50/100/500 with no amount field at all; every
   cosmetic, subscription and unlock price is displayed in the same view as the confirm control.
   There is no randomised reward anywhere in this feature.
4. **"Do you keep transaction records on your servers?" — We have no server for this feature.**
   StoreKit receipts are read on-device to resolve entitlements; the badge/balance/ledger state is
   written to the device Keychain only (`PopopxBadgeCreditsModels.swift:1099`,
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Consequence we disclose: a badge bought on
   one device is not carried to another by us — subscriptions are recovered through Apple's own
   restore, the credit balance is not a cloud balance.
5. **"What exactly does the paying user get?"** Today, verifiably: a lit badge and its top-bar
   indicator for the paid period, the ability to convert credits into badge days, and full use of the
   credit ecosystem (peer-to-peer credit packets, channel subscriptions, encrypted profile unlocks,
   an extended secure-viewing window, cosmetic items). All of it is on-device state plus ordinary
   end-to-end encrypted messages.
   *【内部】不要在这一问答里追加任何"更快/优先/轮换"的措辞* —— 那三项从未实现，且已按 2026-11-19 裁定
   从**四件产物**（代码、App 内文案、商店短句、本文件）里一起撤走，证据与落点见第 1 节。
   审核如果就"prioritised routing"追问，唯一的诚实回答是：这个版本没有任何一处这样写，
   客户端也没有改变传输调度路径的代码。

---

## 8. 提交前必须先处理 / Blocking items before submission

按严重度排。第 1 条（口径与实现不符）原本直接决定审核结果，本轮按裁定 B 关闭；
第 2、3、4、7 条也已按裁定关闭。剩下的开放项是第 5、6 条的**真机验证**（"只有编译证据"那一类）——
第 1 条撤下的那三项**不是**"待验证"，是"未实现且已停止宣称"，两者不要混。

1. ~~口径里的三个解锁项没有实现，而 App 内有两句话把它们说成"已经在做"~~ —— **本轮按裁定 B 收口，已关闭。**
   两处**用户可见中文**都改了（都是文件私有 `Copy`，不走 16 目录）：
   - `PopopxTrialWelcomeModal.swift:201`：原"流量走动态 SMP 中继节点集群，中继地址定期轮换。"
     → 现"徽章详情是一台只读本机的节点状态面板：档位、到期、对账摘要、本机计数。"
   - `PopopxBadgePaywallView.swift`：原 `Copy.benefitRotation` 那条 bullet **整条删除**，
     收益清单现为 5 条（:286-290），其中新增的 `benefitStatusPanel` 与上面同一套说法。
   商店短句与本文件的可粘贴块一起换成第 1 节那两句（中英各一），"1GB" 不再出现在任何付费语境里。
   复算：排除注释行后 `grep -rn '轮换\|优先调度\|1GB' Shared/Features/BadgeCredits/*.swift` **0 命中**（附录）。
   第 1 节表格里那三项的实现状态**没有变化**——这次改的是"App 说什么"，不是"App 能做什么"。
2. ~~**频道订阅面板还没有宿主入口**~~ —— **本轮已关闭（裁定 1：必须接上、不得留孤立死代码）。**
   挂载链见第 3 节末尾，实测锚点：`PopopxGroupChatInfoView.swift:271`（仅 `groupInfo.isChannel` 出现）、
   频道主发布页 `PopopxChannelSubscriptionSheet.swift:341`、成员卡片 `PopopxCommerceCards.swift:400`、
   扣点 `PopopxCreditsManager.subscribeToChannel` :423、本机凭证查询 `ticket(forChannelId:)` :464。
   审核现在**走得到**这个场景：频道页 →「订阅门槛」→ 填数发布 → 频道里出现卡片 → 成员点订阅扣点。
   剩下的不是入口问题，而是第 1 条那类"宣称与实现"问题，以及下面第 5 条的上机验证。
3. ~~DeviceCheck capability 尚未在工程里开启~~ —— **本轮裁定：维持现状，不加 entitlements/capability。**
   `DCDevice.current.generateToken()` 已带墙钟超时调用
   （`PopopxBadgeManager.swift:357-377`，超时 2 秒的常量在 :46，`isSupported` 先判 :336），
   且**任何失败（不支持 / capability 未开 / 超时 / 无网络）都合并成 nil**，改用本机安装指纹
   （:362，一个自铸 UUID 存在钥匙串 `installIdentity` 格）作防重放标识；取哪一种由 :325-329 决定。
   后果（裁定已接受，写在这里免得日后当成 bug）：体验徽章防的是"同一台设备卸载重装再来一次"，
   **不防跨设备转移**；capability 没开时 :336 直接返回 nil，走的就是本机指纹那条路，行为不变、不会崩。
4. ~~点数消费确认弹窗目前只有中文~~ —— **本轮裁定：保持现状中文 `Copy`，不扩写 16 个目录**（判据见第 6 节）。
   涉及的是外观购买、资料卡解锁、频道订阅三处确认文案；审核在别的语言环境下会看到中文，这是裁定的后果。
5. 静默信令的"隐身"现在有**三处闸**（见第 4 节：会话行 / 会话列表预览 / 通知横幅）。**对方是另一款
   客户端时三处闸都不存在**：桌面版 SimpleX 或不带本特性的版本会把这一行当普通文本显示、也照常通知。
   彻底消除要核心侧加专用消息类型（Haskell 层，本轮范围外）。
   另外：删行用的是 `.cidmInternal`，**只删本机这一份**，对方库里的这一行仍然在（只是本机不可见）。
   本轮新增的两处闸（预览、通知）只有代码证据，尚未上机验证：请在真机上开"显示内容"的通知，
   走一次红包领取与一次礼品卡兑换，确认横幅不出现。
   **本轮新加的频道门槛卡片不属于这三处闸的射程**：它是可见消息，横幅**应当**照常弹（弹了才是对的），
   它也必须留在双方的会话历史里不被删行。真机上确认这两点，别把它当信令去查。
6. **兑换码扫码改为本机自持的相机会话**（`PopopxVoucherRedeemSheet.swift` 的 `PopopxQRScannerView`），
   不再走 `CodeScanner` 包：包里的 `ScannerViewController` 只在 `viewDidDisappear` 异步 `stopRunning()`、
   从不放掉会话引用（包源码 :293-303，本轮实测），满足不了"识别成功与页面消失两处都必须
   stopRunning 且置 nil"这条要求。停止顺序抄 `PopopxCameraGuardEngine.swift:43`。
   **这一段是新写的相机代码，只过了类型检查**：真机上要验三件事——扫到即停、关掉即停、
   关掉之后指示灯不亮；失败重建已设上限 2 次，别指望它无限重试能救回一台坏相机。
   （~~两处扫码口径不一致是否统一~~ **本轮裁定：不统一**——加好友页 `Shared/Features/AddFriend/PopopxAddFriendView.swift`
   那份已上机验证过的 `CodeScanner` 页面**不动**，兑换页继续用本机自持、确定性销毁的 `AVCaptureSession`。
   这条差异是裁定，不是遗漏。）
   **但第 6 条剩下的部分仍然开放**：新写的相机会话只过了类型检查，真机三件事（扫到即停、关掉即停、
   关掉之后指示灯不亮）还没验。
7. ~~需求要求"向频道同步已核销凭证回执"，这一条没做~~ —— **本轮已做，信令名按裁定定为 `CHANNEL_SUB_ACK`。**
   现在的形状：成员扣点签票成功 → `sendChannelSubscriptionAck(chatInfoId:expiresAtMs:to:)`
   （`PopopxSilentSignalingRouter.swift:426`）把 `::popopx_sys::CHANNEL_SUB_ACK::<chatInfoId>::<expiresAtMs>`
   发回那条频道会话；频道主那一侧收到后走三处闸（不渲染、不进预览、不弹横幅）并 `deleteSignal` 删行，
   所以第 8 节第 5 条担心的"老客户端把这一行当普通文本显示"这一支**只对不带本特性的客户端仍然存在**。
   两个必须知道的边界：
   - **它是尽力而为的**：票据已经写进钥匙串，回执发不出去（订阅者在核心那一侧没有发言权，
     `ChatInfo.sendAsGroup` 只对 `memberRole >= .owner` 为真，`POPOPXChat/ChatTypes.swift:2405-2415`）
     只留一行日志，**不回滚点数、不报错**，否则一个已经成立的订阅看起来像失败。
   - **它不搬运任何价值**：频道主收到的是"某台设备在某个时刻核销了某张票"这一件事的**本机可见证据**，
     没有服务端账本，点数**不会**因此进频道主的账户。付费频道目前**不是给创作者的分成机制**，
     这一句仍然必须让产品知情（第 3 节②、第 9 节第 7 条）。
   做到的另一部分：成员点订阅 → 本机扣点 → 钥匙串里那张带到期时间的准入凭证
   （`PopopxChannelSubscriptionTicket`，需求里那个名字写作 `ChannelAccessToken`，实测它在**代码里 0 处**，
   只有需求 :88 与本文件的引用）。

---

## 9. 与产品需求的偏差 / Deviations from the product spec

需求文件是 `apps/ios/BadgeCredits_prompt.md`。以下每一条都是**实现与字面要求的差**，
不是漏做（漏做在第 8 节）。

1. **`popopx://redpacket` 多了一个签名字段 `n=`。** 需求 :85 写了四个字段
   （`id/amount/note/sig`），实现加入 `n=<收件人份数>`（`PopopxBadgeCreditsModels.swift:565`、wireString :600）
   并把 `n` 纳入签名原文，因此改份数与改金额一样导致验签失败。多收件人是"一个红包发给 100 人"这条
   需求语义的必要承载，删不掉；但它是**协议字段的增加**，请在提交前确认这套 URI 不与其他客户端互操作。
2. **`popopx://gift` 的字段集是实现自定的**（需求只写了 `popopx://gift?...`）：
   `v/p/n/t/s`（:441、:479），`n` 在礼品卡里是 base64url 的赠言，**与红包里的 `n` 不同义**。
   两个 host 不同、解析器不同，不会互相误读；但如果以后要做跨端解析，这条命名冲突要写进协议文档。
3. **第六种信令 `PROFILE_UNLOCKED` 与第七种 `CHANNEL_SUB_ACK`** 都在需求点名的五种之外：
   第一种是本实现自补的名字（理由见第 4 节），第二种由 2026-11-19 裁定点名定名（第 8 节第 7 条）。
4. **暗金二维码皮肤动到品牌规范 §2.4**（`Docs/popopx-brand-spec.md` 的"唯一允许渐变的地方"）。
   实现只换单一色相（品牌紫 → 暗金），三个 stop 位置、三个 alpha、`label` 底、`onBrand` 墨全部不动，
   二维码模块色另取深青铜以保持 ≥4.5:1 扫码对比度
   （`Shared/Features/AddFriend/PopopxQRCardSheet.swift:112-181`、:241-252）。
   **我没有改 brand-spec 文档**（红线之外还因为它是你的裁定件）；§2.4 要不要写这条例外，由你定。
5. **付费墙多了一个无条件入口。** 需求的进入路径是顶栏胶囊；实测胶囊按状态分发
   （`PopopxBadgeCapsuleView.swift:295-301`：`.activeLit → 徽章详情`），于是**已点亮徽章的人再也没有
   任何购买入口**（买不了点数，也就兑不了续期）。已在"我的"页加一条常驻"充值算力点"
   （`PopopxMeView.swift:130`）。这是修死路，不是加营销位。
6. **`popopx://channel` 这个 URI 整个是实现自定的**——需求只写了"订阅确认弹窗"（:86-88），没给任何线上传输形状。
   实现落在**一条可见消息**上：`?p=<点数>&t=<发布时间毫秒>&e=<发卡方 P-256 公钥 base64url>&s=<签名>`
   （`PopopxBadgeCreditsModels.swift:691`，字段名 :674，wireString :729），签名原文是
   `canonical(kind: "chan", parts: [price, publishedAtMs, pubkey])`。
   为什么必须走消息而不是走"频道元数据"：没有服务端，成员这一侧唯一能拿到价格的通道就是频道会话本身
   （这条推理写在 payload 顶部注释里）。代价是它像普通文本一样留在双方历史里，且**这是一套只有本客户端认识的 URI**，
   与礼品卡/红包那两条同属"实现自定义协议"，第 1、2 条已经声明过同一族风险。
7. **门槛不拦内容，且这张卡片不能证明发卡人是频道主。** 两件事都必须知道：
   - **不拦内容页。** 需求 :88 的原话是"成员**进入**付费频道时展示订阅确认弹窗"。真按字面做会死结：
     价格只存在于频道里那条卡片上，把频道内容挡住就等于把"要付多少、去哪儿付"一起挡住。
     所以实现改成"卡片上点订阅 → 本机扣点 → 本机凭证"，进入频道时**不弹任何窗**。
     这既是与字面要求的差，也是零服务端下唯一不自相矛盾的做法。产品若要"进入即弹"，
     需要先把价格放进可查询的频道元数据（核心侧，本轮范围外）。
   - **签名只防篡改，不防冒充；本轮把"能防的那半做了，做不到的那半写在这里。**
     验签用的是卡片自带的公钥 `e`，所以它能保证"价格发出后没被改过"，**不能保证发卡的人是频道主**
     （没有 PKI，谁都能签一张）。2026-11-19 裁定要求的三道闸，落地情况是：
     1. **发布端角色闸（已实现）**：`GroupInfo.popopxCanPublishChannelThreshold`
        （`PopopxSilentSignalingRouter.swift:52`）= `isChannel && memberRole >= .admin && memberCurrent`，
        `sendChannelAccess`（:412）与频道页那一格（`PopopxGroupChatInfoView.swift:274`）读同一份，
        所以本机不是频道主/管理员就发不出这张卡。
     2. **接收端"必须在频道里"闸（已实现）**：气泡按 `context.isChannel` 分档
        （`PopopxCommerceCards.swift:458`，判据 = `GroupInfo.isChannel`
        = `publicGroup?.groupType == .channel`，`POPOPXChat/ChatTypes.swift:3064`、`:3233`；
        **不是** `ChatInfo.isChannel` 那个 `useRelays` 版本，后者对大型私群也为真）。
        伪造一张 `popopx://channel` 粘进单聊，会显示"这一条不在频道里"而**走不到扣点**。
        信息页那一格用同一个 `isChannel`，两处不可能给出不同答案。
     3. **签发密钥钉扎（已实现，覆盖面有限）**：付过一次之后本机那张票记下发卡公钥
        （`PopopxChannelSubscriptionTicket.issuerPublicKeyBase64URL`，`PopopxBadgeCreditsModels.swift:983`），
        同一 `chatId` 上再出现另一把钥匙签的卡 → "签名密钥与本机上一次付费记下的发布者不一致"
        （`PopopxCreditsManager.channelIssuerConflict` :456 → 气泡 :462）。
        **它只保护已经在这个频道付过一次钱的设备**；首次付费前没有任何可比对的钉扎，
        这条窗口必须知道，别把它读成"防住了冒充"。
   - **裁定里"接收端校验发送者确为 owner/admin"这一句在 Swift 层做不到**，不是没做：
     频道消息的 `CIDirection.channelRcv`（`POPOPXChat/ChatTypes.swift:4421-4422`）**不带成员对象**，
     `groupMemberId` 在这一支是 nil（同文件 :4440-4442），只有 `.groupRcv(groupMember:)` 带；
     `GroupInfo.id = "#\(groupId)"`（:3059）是本机数据库行号，不是跨设备的绑定材料；
     而本模块的 P-256 商业密钥与 SMP 连接身份是两套互不认识的密钥体系。
     于是"这一条是谁发的"在收信侧根本没有可读的字段。上面 1+2+3 是该裁定可落地的等价物，
     剩下的可滥用面（任何成员都能签一张卡发进频道，别人点了就是烧自己的点换一张本机凭证）
     **仍然存在且无法在本层关闭**——没有服务端账本，这笔钱不进任何人的口袋，也退不回来。
     真机还需要验一件事：频道主的帖子在现网到底落到 `.channelRcv` 还是 `.groupRcv` 那一支
     （如果落到 `.groupRcv`，将来可以从那里读出 `memberRole`，闸 2 就能升级成真正的发送者身份闸）。
8. **红包的群聊入口按裁定关闭。** 需求要求点对点红包，未规定群聊；实现里 `PopopxSendRedPacketSheet`
   有 `.group` 那一档，但宿主侧 `ComposeView.swift:1393` 的 `popopxPacketDestination` **只认单聊联系人**，
   所以群聊里的"+"菜单不出现这一格（判据只有一份，`popopxPlusActions` 读同一个可选值，
   不存在第二处开关会把它放回来）。
   原因写在 `:1393` 的注释里：零服务端意味着群里并发拆包没有互斥，最坏情况是同一笔点数字面上被多记几次到账。
   保留 `.group` 那一档有两个真实用途，不是"将来再说"：解读对端发来的 `n>1` 来件、
   以及本文件唯一能显示"均分 N 份"排版的预览。
9. **`PopopxChannelSubscriptionSheet` 里的准入凭证命名与需求不同**：需求写 `ChannelAccessToken`（:88），
   实现叫 `PopopxChannelSubscriptionTicket`——那个名字在代码里 0 处（只有需求原文与本文件的引用），
   本模块所有类型一律带 `Popopx` 前缀，所以没有引入第二个命名风格。语义等价
   （本机钥匙串条目 `.channelTickets`，`PopopxCreditsManager.swift:189`）。

---

## 10. 怎么测 / How to test it

**【审核可粘贴 · EN】**

- Attach the StoreKit configuration `PopopxStoreKit.storekit` to the run scheme
  (Product → Scheme → Edit Scheme → Run → Options → StoreKit Configuration). It contains all 7
  products, so the app is fully testable with no App Store account and no network.
- Path to each surface: top bar badge capsule → paywall / detail / trial; Me → 算力点中心 (credits
  store, badge exchange, gift-code redeem, cosmetics) → the six spend scenarios; the message
  composer "+" menu → send a credit packet (1:1 chats only); an encrypted profile card in a chat →
  unlock prompt; a **channel** → channel info page → "订阅门槛" (owner sets a price and publishes a
  card into the channel) → a member taps Subscribe on that card.
- To exercise a gift: mint a card in 算力点中心 → 赠送徽章, copy the `PPX1-…` code, and redeem it
  from a second simulator/device (two installs of the app connected as contacts).

**【内部】** 已验证到哪一步（诚实口径，本轮实测数字）：

- **工程挂载**：`git status` 里本批改动的 Swift 文件共 **35** 个 = 17 个新特性文件 + 18 个既存宿主文件；
  附录那条循环逐个数 `project.pbxproj` 引用，实测 **34 个 = 4 条、`ChatView.swift` = 12 条**
  （同一个文件进多个 target，不是重复挂载）。`PopopxStoreKit.storekit` 也已进 Resources 阶段（:1880）。
  挂载前那次"BUILD SUCCEEDED 但一个新文件都没编译"的坑不会再犯。
  本轮（口径收口 + 核销回执 + 防冒充）**没有新增任何 Swift 文件**，所以不需要再手动拖入 Xcode；
  `project.pbxproj` 里属于本特性的那部分是你上次拖入的结果，我没有用脚本改过它（红线）。
- **arm64 整包门禁这一轮跑了五次**（`build/gate_bc2.log` … `build/gate_bc6.log`，命令与读数方法见附录）：
  - `gate_bc2.log`（6 182 行）= `** BUILD SUCCEEDED **`、`error:` **0** 条、
    按 target 计的真实编译文件 **265** 个、主二进制 `Ld` 1 次；`warning:` 共 3 条，全部是
    `appintentsmetadataprocessor … Metadata extraction skipped, no AppIntents.framework dependency found`
    （非 Swift 警告，本 target 没有 AppIntents 依赖，属既有噪音）。
    只有 bc5/bc6 两次把 `XCODEBUILD_EXIT=…` 写进了日志；bc2-bc4 的退出码当时是在日志外读的
    （"BUILD SUCCEEDED + 非 0 的真实编译文件数 + Ld" 是当时用来代替它的三重判据）。
  - `gate_bc3.log`（851 行）与 `gate_bc4.log`（787 行）：注释性改动后的两次增量，均 SUCCEEDED、
    0 error、**0 warning**、真实编译文件数分别 **4** 与 **1**、`Ld` 各 1 次。
  - `gate_bc5.log`（1 438 行）= **失败**，`XCODEBUILD_EXIT=65`、`succ=0`、无 `Ld`、`error:` 2 行
    （同一条错被 Swift 的 diagnose 块复读一次）：
    `PopopxSilentSignalingRouter.swift:417:9: error: missing return in instance method expected to return 'Bool'`
    —— 我加频道发布权限闸时把 `sendChannelAccess` 原来的 `return await send(...)` 换成了裸调用，
    同时带出一条 `result of call to 'send(text:to:)' is unused`。这是本轮唯一真实回归，已修。
    记录它是因为"绿过"的历史数字不能替当前树背书。
  - `gate_bc6.log`（2 092 行）= 修复后的最终门禁：`** BUILD SUCCEEDED **`、`XCODEBUILD_EXIT=0`、
    `error:` **0**、`warning:` **0**、真实编译文件 **256** 个（`builtin-SwiftPerFileCompile` 标记 258 行）、
    主二进制 `Ld` **1** 次；并且**本批 35 个改动的 Swift 文件全部出现在 bc6 的单文件编译行里，缺失 = 0**
    （附录给那段脚本）。
  - 时间戳对得上：主二进制 mtime `18:27:00` **晚于**本轮最后一个源文件改动 `18:25:12`
    （`PopopxSilentSignalingRouter.swift`），所以门禁覆盖的是当前工作区，不是旧的中间产物。
  - 读数方法（避免自己骗自己）：`grep -c 'SwiftCompile '` 数的是**日志行**，一次编译会同时打批次头
    (`… Compiling\ A.swift,\ B.swift /abs/A.swift /abs/B.swift`) 和每个文件的单独行；
    只有 `^SwiftCompile normal arm64 /…swift (in target 'POPOPX (iOS)'` 这种**每文件一行**的才算数。
    bc6 的那个"320"是行数、"256"才是文件数。
- **本地化**：49 条 key、16 个翻译目录再加 `en.lproj`（实测 `ls -d *.lproj` = **17**），用只喂源目录的
  等价命令复算 = `catalogs: 17 / problems: 0 / plutil: []`（本轮实测）。
- **`check-previews` 这一步**：本轮把 BadgeCredits 的 23 个 `*_Previews` 加进了
  `"POPOPX Snapshots"/check-previews.py` 的 `EXCLUDED`（**39 → 62** 项，`git diff` = 23 行纯新增）。
  对 **tracked 源**跑（附录给命令）= `listed: 131 / errors: 0`；
  在带构建产物的工作区里直跑会 `rc=1`，报的 4 行全是
  `build/**/SourcePackages/checkouts/CodeScanner/…: CodeScannerView_Previews`——
  那是 gitignore 掉的依赖检出，不是本特性的文件，不能当成回归。
- **仍未验证的部分（不要把上面任何一条当成运行时证据）**：StoreKit 真实交付、SMP 收发信令、
  DeviceCheck、扫码、Face ID、临时连接删除、**本轮新增的频道卡片发布/订阅与 `CHANNEL_SUB_ACK`
  核销回执整条链**、`GroupInfo.isChannel` 在真机频道会话里的实际取值、发卡公钥 pinning 的两台设备行为、
  以及第 8 节第 5 条那三处抑制闸在另一款客户端面前的表现。全部只有编译证据。
- `POPOPX (iOS)` target 之外没有新增任何 target；没有动 `project.pbxproj` 的脚本改动（红线）。

---

## 附录：每条声明的复算命令 / Re-derivation appendix

```sh
cd apps/ios
# 规模与文件数
ls Shared/Features/BadgeCredits/*.swift | wc -l && wc -l Shared/Features/BadgeCredits/*.swift | tail -1
# 9 个 SKU：identifier 与 .storekit 双向核对（用工程真正引用的那一份，不是根目录那份重复副本）
grep -n "com.popopx" Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift Shared/Features/BadgeCredits/PopopxStoreKit.storekit
# 本特性只有一份 storekit：根目录那份逐字节相同的重复副本已按 2026-11-19 裁定删除（它从未进 git，
# 所以 `git status` 里看不到删除痕迹——只能这样证明"现在只剩一份"）
ls PopopxStoreKit.storekit 2>&1 | tail -1                                                 # 期望 No such file or directory
find . -name "PopopxStoreKit.storekit" -not -path "./build/*"                             # 期望只有 BadgeCredits 那一条
grep -c 'PopopxStoreKit.storekit' POPOPX.xcodeproj/project.pbxproj                         # 4：那 4 条同名引用全指向 BadgeCredits
grep -n 'PopopxStoreKit.storekit' POPOPX.xcodeproj/project.pbxproj | sed 's/^ *//'         # fileRef 的 path = BadgeCredits
# 六个花费场景的判据数值（行号见第 3 节）
grep -n "static let redPacketAmounts\|packetClaimGraceSeconds\|channelTicketSeconds\|extendedSecureWindow\|avatarFrameCost\|qrCardSkinCost\|maximumCreditBalance" Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift
# 网络调用只有 5 处、全在一个文件里
# 注意：裸 grep 得到 **7** 行，其中 :14 与 :16 是文件头注释里提到这两个名字；去掉注释行才是 5。
grep -rn "apiConnect(\|apiAddContact(\|apiSendMessages(\|apiDeleteChatItems(\|apiDeleteContact(" Shared/Features/BadgeCredits/
grep -rn "apiConnect(\|apiAddContact(\|apiSendMessages(\|apiDeleteChatItems(\|apiDeleteContact(" Shared/Features/BadgeCredits/ | grep -v '//' | wc -l   # 期望 5；本轮实测 278 / 293 / 325 / 456 / 487
# 七种静默信令与线上前缀（本轮复算：enum 806-820、`marker` 在 851、`parse` 从 857 起）
sed -n '786,800p;830,851p' Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift
# 本轮新增的核销回执（发送侧一行 + 判据入组白名单一行）
grep -n 'channelSubscriptionAcknowledge\|CHANNEL_SUB_ACK' Shared/Features/BadgeCredits/*.swift
# 口径撤下的三项在**用户可见文本**里为 0（注释里保留一条撤回说明，那是裁定要求的记录）
grep -rn '轮换\|优先调度\|1GB' Shared/Features/BadgeCredits/*.swift | grep -v '^\S*:[0-9]*: *//' | wc -l   # 期望 0
grep -rln '调度\|priorit\|schedul' Shared/Features/BadgeCredits/                                          # 期望 1 个文件 = PopopxBadgePaywallView.swift 的撤回注释
# "1GB 是既有无条件上限"：无徽章分支返回 MAX_FILE_SIZE_XFTP，抬高上限的是另一套 LocalBadge
sed -n '30,35p;365,375p' POPOPXChat/FileUtils.swift
# 频道订阅挂载链（第 3 节末尾与第 9 节第 6、7 条的每一格）
grep -n 'subscriptionCard\|memberTicketValue' Shared/Features/ChatInfo/PopopxGroupChatInfoView.swift
grep -n 'struct PopopxChannelThresholdView\|private var canPublish' Shared/Features/BadgeCredits/PopopxChannelSubscriptionSheet.swift
grep -n 'struct PopopxChannelAccessBubble\|case channel(' Shared/Features/BadgeCredits/PopopxCommerceCards.swift
grep -n 'struct PopopxChannelAccessPayload\|static func make(price\|var wireString' Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift
grep -n 'func sendChannelAccess\|static func messageText(channel' Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift
grep -n 'func subscribeToChannel\|func ticket(forChannelId\|func saveTickets' Shared/Features/BadgeCredits/PopopxCreditsManager.swift
# 红包在群聊里没有入口：判据只有这一处，`.group` 那一档不会被别的开关放回来
grep -n 'popopxPacketDestination' Shared/Views/Chat/ComposeMessage/ComposeView.swift
# 工程挂载证据：每个"本批改动的 Swift 文件"都必须在 pbxproj 里有引用
# 0 条 = 那次"编译成功但没编译新文件"的假绿；本轮实测 34 个 = 4 条，只有 ChatView.swift = 12（进多个 target）
cd ../.. && for p in $(git status --porcelain -- apps/ios | awk '{print $NF}' | grep '\.swift$'); do n=$(basename $p); printf "%s=%s " "${n%.swift}" "$(grep -c "$n" apps/ios/POPOPX.xcodeproj/project.pbxproj)"; done; echo; cd apps/ios
# 门禁日志读数：BUILD SUCCEEDED 必须配非 0 的"每文件一行"的编译数才是真编过
# `ld=` 只数主二进制那一次链接（`grep -c 'Ld '` 会连其它 target 的链接一起数到 16，别用它当证据）
# `compile=` 是**日志行**（批次头 + 每文件行都算），`perfile=` 才是文件数：本轮实测
#   bc2 6182行 succ1 err0 warn3 perfile265 ld1
#   bc3  851行 succ1 err0 warn0 perfile4   ld1
#   bc4  787行 succ1 err0 warn0 perfile1   ld1
#   bc5 1438行 succ0 err2 warn4 perfile87  ld0   XCODEBUILD_EXIT=65（missing return，第 10 节）
#   bc6 2092行 succ1 err0 warn0 perfile256 ld1   XCODEBUILD_EXIT=0
for L in bc2 bc3 bc4 bc5 bc6; do F=build/gate_$L.log; [ -f "$F" ] || continue; printf "%s " "$L"; echo "lines=$(wc -l < $F) succ=$(grep -c 'BUILD SUCCEEDED' $F) err=$(grep -c 'error:' $F) warn=$(grep -c 'warning:' $F) compile=$(grep -c 'SwiftCompile ' $F) perfile=$(grep -cE "^SwiftCompile normal arm64 /.*\.swift \(in target 'POPOPX \(iOS\)' " $F) ld=$(grep -c 'Ld .*POPOPX.app/POPOPX' $F) exit=$(grep -o 'XCODEBUILD_EXIT=[0-9]*' $F)"; done
grep 'warning:' build/gate_bc2.log | sed 's/^.*warning: //' | sort | uniq -c     # 3 条全是 appintentsmetadataprocessor
# 最硬的一条证据：本批改动的每个 Swift 文件都出现在最终门禁 bc6 的**单文件编译行**里（期望 missing: 0）
cd ../.. && python3 - <<'PY'
import subprocess, re
changed = [l[3:] for l in subprocess.run(["git","status","--porcelain","--","apps/ios"],
                                         capture_output=True,text=True).stdout.splitlines()
           if l.endswith(".swift")]
txt = open("apps/ios/build/gate_bc6.log", errors="replace").read()
names = {p.split("/")[-1] for p in re.findall(
    r"^SwiftCompile normal arm64 (\S+\.swift) \(in target 'POPOPX \(iOS\)'", txt, re.M)}
names |= set(re.findall(r"builtin-SwiftPerFileCompile (\S+\.swift)", txt))
missing = [c for c in changed if c.split("/")[-1] not in names]
print(f"changed={len(changed)} covered={len(changed)-len(missing)} missing={len(missing)}")
for m in missing: print("  MISSING", m)
PY
cd apps/ios
stat -f "%Sm %N" -t "%H:%M:%S" build/DerivedData/Build/Products/Debug-iphoneos/POPOPX.app/POPOPX   # 主二进制
stat -f "%Sm %N" -t "%H:%M:%S" Shared/Features/BadgeCredits/*.swift | sort | tail -1                # 必须早于上面
# 钥匙串可访问性
grep -n "kSecAttrAccessible" Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift
# 术语红线：VPN/专网/代理/proxy 在用户可见文本里为 0
# 本轮实测：全模块只有 2 处命中，两处都不是给用户看的字——
#   PopopxBadgeCreditsModels.swift:1285 的 comment: "never VPN"（防复发标记本身）
#   PopopxBadgePaywallView.swift:381 的文档注释（写明这条红线）
grep -rn "VPN\|专网\|代理\|proxy\|Proxy" Shared/Features/BadgeCredits/
# 用户可见字符串里再查一次：只查 NSLocalizedString 与 Copy 的赋值行，期望 0
grep -rn 'NSLocalizedString("[^"]*\(VPN\|代理\|proxy\)' Shared/Features/BadgeCredits/ ; \
grep -rn 'static let [a-zA-Z]* = "[^"]*\(VPN\|专网\|代理\)' Shared/Features/BadgeCredits/ ; echo "^ 期望两条都无输出"
# SimpleX 品牌残留：本特性文件里 6 处命中全部是**注释里指向上游 SimpleX 语义**的说明句，
# 没有一处出现在用户可见字符串或类型名里
grep -rn "SimpleX" Shared/Features/BadgeCredits/ | sed 's/:.*\(\/\/.*\)/  \1/' | cut -c1-100
# 术语通俗化：中文"遥测"在所有 Swift 与 .strings 里必须为 0；改名落点为 4 处功能内文案
grep -rn "遥测" Shared POPOPX POPOPXChat *.lproj 2>/dev/null | wc -l                              # 期望 0
grep -rn "节点状态面板" Shared/Features/BadgeCredits/ | cut -c1-90                                  # 期望 4 行
grep -n "遥测" Docs/popopx-brand-spec.md ; echo "^ 期望无输出（2026-11-19 指示后已改）"
grep -rn "遥测" prompt.md ui-prompt.md | cut -c1-70   # 只应命中用户的提示词原件；本文件与 brand-spec 里的命中都是"记录"而非界面文案
# 本地化：49 个 key 在 16 个目录里齐备、占位符合法、plutil 全绿
# 口径 = `enum PopopxCommerceCopy`（Models:1281）+ `private extension PopopxCommerceCopy`（StoreKitManager:446）
# 两块里的 NSLocalizedString 字面量，本轮实测 occurrences 49 == distinct 49（没有一句写两遍）
awk '/^(private )?(extension|enum) PopopxCommerceCopy/{f=1} f&&/NSLocalizedString\(/{c++} f&&/^}/{f=0} END{print c}' \
  Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift Shared/Features/BadgeCredits/PopopxStoreKitManager.swift
# 校验器只查源目录的等价命令（下面那条说明解释为什么不能直接跑 `check`）
cd ../.. && python3 - <<'PY'
from pathlib import Path
import sys; sys.path.insert(0, "scripts/ios")
import localizations as L
paths = sorted(Path("apps/ios").glob("*.lproj/Localizable.strings"))
print("catalogs:", len(paths))
bad = [(p.parent.name, pr) for p in paths for pr in L.check_strings(p)]
print("placeholder/link problems:", len(bad))
print("plutil:", L.lint_with_plutil(paths))
PY
# 期望：catalogs: 17 / problems: 0 / plutil: []   （本轮实测）
cd apps/ios
# 到期降级不动 SMP/联系人/记录；轮换只是本地计数
sed -n '11,16p;283,292p' Shared/Features/BadgeCredits/PopopxBadgeManager.swift
# 快照/预览这一关：本特性把 BadgeCredits 的 23 个 *_Previews 加进了 EXCLUDED（39 → 62）
grep -c '^    "' "POPOPX Snapshots/check-previews.py"                                          # 期望 62
git diff --stat -- "POPOPX Snapshots/check-previews.py"                                          # 期望 23 行纯新增
# 只看 tracked 源：工作区里 build/ 下有 gitignore 掉的 CodeScanner 依赖检出，直跑 check-previews.py 会报它 4 行、rc=1
cd ../.. && python3 - <<'PY'
import re, subprocess
from pathlib import Path
snap = Path("apps/ios/POPOPX Snapshots")
tests = (snap/"SnapshotTests.swift").read_text()
listed = set(re.findall(r"SnapshotScene\((\w+)\.self", tests))
src = re.search(r"EXCLUDED = \{(.*?)\n\}", (snap/"check-previews.py").read_text(), re.S)
excluded = set(re.findall(r'"(\w+)"', src.group(1)))
files = subprocess.run(["git","ls-files","apps/ios"],capture_output=True,text=True).stdout.split()
tracked = [f for f in files if f.endswith(".swift") and f.startswith("apps/ios")]
errors = []
for f in tracked:
    source = Path(f).read_text(errors="replace")
    for p in re.findall(r"^[ \t]*struct[ \t]+(\w+)[ \t]*:[ \t]*PreviewProvider\b", source, re.M):
        if p not in listed and p not in excluded:
            errors.append(f"{f}: {p}")
    if re.search(r"^[ \t]*#Preview\b", source, re.M):
        errors.append(f"{f}: #Preview")
print(f"tracked swift files: {len(tracked)}  listed: {len(listed)}  excluded: {len(excluded)}  errors: {len(errors)}")
for e in errors[:10]: print("  ", e)
PY
cd apps/ios                                                                                       # 期望 listed: 131 / errors: 0
# 本文件每一条 `file.swift:NNN` 引用是否还对得上符号：写文档的人自己也要被复算
cd ../.. && python3 - <<'PY'
import re, pathlib
doc = pathlib.Path("apps/ios/Docs/app-store-review-notes.md").read_text().splitlines()
cite = re.compile(r"([A-Za-z]\w*\.swift):(\d{1,4})(?:[,–-](\d{1,4}))?")
def resolve(name):
    hits = list(pathlib.Path("apps/ios").rglob(name))
    return hits[0] if hits else None
tot = bad = 0
for n, line in enumerate(doc, 1):
    for c in cite.finditer(line):
        tot += 1
        p = resolve(c.group(1))
        if p is None:
            bad += 1; print(f"doc:{n} 文件找不到 {c.group(1)}"); continue
        lines = p.read_text(errors="replace").splitlines()
        a, b = int(c.group(2)), int(c.group(3) or c.group(2))
        span = " ".join(lines[max(0,a-1):min(len(lines),b)])
        ids = [x.split("(")[0].split(".")[-1] for x in re.findall(r"`([A-Za-z_][\w.]{5,})`", line)]
        if not any(i in span for i in ids if len(i) > 5) and not span.strip():
            bad += 1; print(f"doc:{n} {c.group(1)}:{a}-{b} 指向空行")
print(f"citations={tot} 空行/坏引用={bad}")
PY
cd apps/ios
```

> 关于 `scripts/ios/localizations.py check`（本轮两种失败都实测过，都不是本特性引入）：
> - 在**仓库根**跑：它按 `apps/ios/**/*.lproj/*.strings` 递归，会把 `build/`、`product/` 里
>   **编译后的二进制 `.strings`** 也读进来，以 `UnicodeDecodeError: 0xd3` 崩掉。清理那些目录后才会通过。
> - 在 `apps/ios` 里跑：更危险——脚本里 `IOS_DIR = Path("apps/ios")` 是相对当前目录的路径，
>   于是它去解析 `apps/ios/apps/ios`，找不到任何目录，照样打印 **"No problems found." 并返回 0**。
>   这是一条**什么都没检查的绿色**，不能当作证据。
> 因此在带构建产物的工作区里，用上面那段只喂源目录的等价命令。
