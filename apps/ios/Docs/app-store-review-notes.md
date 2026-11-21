# POPOPX 动态隐私节点徽章 / 算力点生态 —— App Store 审核备注

# App Store Review Notes — Dynamic Privacy Node Badge & Compute Credits

> 本文件有两类内容，分得很清：
> **①【审核可粘贴】** 是英文、可直接填进 App Store Connect → App Review Information → Notes；
> **②【内部】** 是中文的实现事实、待办与风险，不给审核看。
>
> Every factual claim below is a measurement, not a memory: section 附录 lists the exact command that
> reproduces it. If the code moves, re-run the commands before re-submitting.

- 本特性落地的代码在 `Shared/Features/BadgeCredits/`：**17 个 Swift 文件、10 797 行**，2026-11-21 第 14 轮复测 `wc -l Shared/Features/BadgeCredits/*.swift | tail -1`。上一版记的 10 812 行是同一天第 13 轮的读数，本轮净 **−15**（`git show 71a8f27fe --numstat` = 180/195：删掉两处旁路按钮连同它们的文案）。另外上一版把「8 768 → 10 812」写成"本轮 +157"，算术对不上（8 768 + 157 = 8 925），两次读数之间真实的差是 **+2 044**。第 3、4 节的 110/112 是更早一轮的读数。
- 最后核对 / Last verified: 2026-11-19（本轮：口径收口 + `CHANNEL_SUB_ACK` 核销回执 + 频道卡片防冒充，门禁 `build/gate_bc5.log`（失败，见第 10 节）与 `gate_bc6.log`，读数见第 10 节）；2026-11-21 第 14 轮把本文件的**每一处 `file:NNN` 引用与每一个计数**重跑了一遍，改过的行都带"第 14 轮复测/实测"字样，未带字样的读数属于各自那一轮的历史记录，故意不追改。
- 商店配置文件 / StoreKit config: `apps/ios/Shared/Features/BadgeCredits/PopopxStoreKit.storekit`
- 商店配置文件是 `Shared/Features/BadgeCredits/PopopxStoreKit.storekit`（与代码同目录，不是仓库根的那份）。它**定义了 12 个产品标识符**：`products` 8 个（3 个算力点直购 credits.100/500/2000 + 3 个算力点礼品卡 credits.gift.* + 2 个徽章礼品卡 gift.node.annual/monthly）+ `nonRenewingSubscriptions` 2 个（badge.node.pass.30d/365d）+ `subscriptionGroups[0].subscriptions` 2 个（badge.node.annual/monthly，就是那两条自动续订）；上一版写"9 个：5 消耗型 + 2 自动续订 + 2 非续订"，少算了 3 个，正是后补的三张算力点礼品卡；至于"消耗型"，那是业务口径不是文件字段——`products` 里八条都没有 `consumableStatus`；
  订阅那两条同属一个订阅组 `3020000001`（`annual` / `monthly`）；配置 `version` = major 4）。
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
| 发送与核销算力点红包 | `PopopxCreditsManager.sendRedPacket(...)`（:371）与领取/退款路径（第 3 节①） |

同一裁定还有一条禁止项：任何位置都**不得**写成"购买后改变传输协议""绕过防火墙""提供 VPN 隧道"。
上面这句和下面所有可粘贴文本都服从这一条；**用户可见文本**里这些词是 0 处——模块内只剩 1 处代码注释提到
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
| 高并发中继路由优先调度 | **0 处实现**。全特性没有任何"按优先级选路/调度"的代码路径，客户端也不向中继声明优先级 | 本文件可粘贴块（本节上一版）；`grep -rln '调度\|priorit\|schedul' Shared/Features/BadgeCredits/ \| wc -l` = **3 个文件**（2026-11-21 第 14 轮复测；三处全是注释——`PopopxBadgePaywallView.swift` 的撤回注释、`PopopxChannelSubscriptionSheet.swift:262`、`PopopxVoucherRedeemSheet.swift:16`。这条数的是"提到该词的文件数"，不是"用户可见处数"；用户可见仍为 0，证据是下一列那条剔除注释行的命令，实测 0 行） |
| 节点池每日动态轮换防关联 | **只有本地计数**。`PopopxCommerceLimits.nodeRotationSeconds = 15`（`PopopxBadgeCreditsModels.swift:73`）只是胶囊转圈与本机计数的**最小间隔**，真正的判定每 30 秒心跳最多一次（`PopopxBadgeManager.swift:108`），不发任何请求、不改任何中继地址 | `PopopxTrialWelcomeModal.swift:209`（原句"…中继地址定期轮换"→ 现为"节点状态面板"那一句）、`PopopxBadgePaywallView.swift`（原 `benefitRotation` 那条 bullet **整条删除**，收益清单现为 5 条 :424-428）、`PopopxBadgeDetailSheet.swift`（"遥测"→"节点状态面板"、"间隔"格改为 `≥ 15 秒`） |
| 单文件最大 1GB 的加密传输配额 | **1GB 是无条件的既有上限，不是买来的**。`getMaxFileSize(.xftp:)` 无徽章时返回 `MAX_FILE_SIZE_XFTP = 1_073_741_824`；真正抬高上限的是既存的另一套 `LocalBadge`（supporter 2GB / legend 5GB），与本徽章无关 | 商店短句与本节可粘贴块都不提 1GB（`POPOPXChat/FileUtils.swift:31,365-375`） |

撤完之后，**用户可见文本**里 `轮换 / 优先调度 / 1GB` 三个词是 0 处（附录第一条命令实测：排除注释行后 grep 无命中）。
剩下的路径是：日后若把中继侧调度与轮换做实并上机验证（要核心/服务端配合），再把这些句子放回来，
放回来时必须四件产物同时改，并更新本节与第 8、9 节。

在实现接完之前，App 内那台"节点状态面板"自己带着免责声明
`PopopxBadgeDetailSheet.swift:289`："这一格只是本机计数……没有任何中继节点因为它而改变"——这句**不要删**，
它是目前唯一让 UI 与代码一致的说明。

---

## 2. 内购清单 / IAP inventory

`PopopxNodeBadgeSku`（`PopopxBadgeCreditsModels.swift:147`、`productId` 整表 :165-176、价格回退 :237-245）与
`PopopxStoreKit.storekit` 的 12 个 identifier 已交叉核对，双向一致、无多无少
（核对脚本：解析 storekit JSON 取 products + nonRenewingSubscriptions + subscriptionGroups 三张表的 productID 全集，
与代码里 12 条 `"com.popopx.*"` 字面量做双向差集，两个方向都必须是空集；
核对用的是**工程引用的那一份** = `Shared/Features/BadgeCredits/PopopxStoreKit.storekit`；
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
| 10 | `com.popopx.credits.gift.100` | Consumable（礼品卡/一次性券） | $1.99 | 一张可转赠的 100 点算力点礼品卡 / transferable card worth exactly 100 credits |
| 11 | `com.popopx.credits.gift.500` | Consumable（礼品卡/一次性券） | $8.99 | 正好 500 点礼品卡 / exactly 500 |
| 12 | `com.popopx.credits.gift.2000` | Consumable（礼品卡/一次性券） | $29.99 | 正好 2000 点礼品卡 / exactly 2000 |

**【审核可粘贴 · EN】** Both subscriptions belong to a single subscription group
(`3020000001`, "POPOPX Dynamic Privacy Node Badge"). Only those two products auto-renew; the two
`pass` products are **non-renewing** subscriptions (bought once, never renewed, no further payment),
and everything else in the list is a consumable. Five of those consumables are **gift cards**
(`com.popopx.gift.*`, `com.popopx.credits.gift.*`): buying one mints a single-use card on this device
that the owner then sends to another user, and the recipient redeems it inside their own chat — the
purchase price is the same as the identical self-use product, and no gift card grants anything to the
buyer's own balance. Restore Purchases calls StoreKit's `AppStore.sync()`
(`PopopxStoreKitManager.swift:554`) — we do not implement our own restore or refund flow, and the
in-app UI sends users to App Store settings to manage or cancel.

**【内部 · 3.1.2(c) 披露】** 自动续订说明全文走 `NSLocalizedString("Payment will be charged to your Apple
Account at confirmation of purchase. …")`，已进全部 16 个翻译目录（见第 6 节）。付费墙在订阅档下方直接展示
该句；取消/管理入口不自建。

**【内部 · 纯净充值】** 六个点数产品（3 个自用包 + 3 个算力点礼品卡）"到账 = 面额"，代码里没有"赠送/bonus"这条通路；
礼品卡面值与自用包逐档相同（100 / 500 / 2000），买卡的人自己**不得**点数，收款人兑换到的也正是标定面额，
所以同一件商品不存在两个价；`PopopxCommerceCopy` 里那句 "Compute Credits are added at the exact amount shown. No bonus credits
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
| ① 红包（点对点算力点） | 面额只能取 `[10, 50, 100, 500]`（:56），收件人上限 100（:58），**无自定义金额输入框**；**只出现在 1:1 单聊**（裁定 2026-11-19，群聊里这一格不渲染，见第 9 节第 8 条） | `sendRedPacket(amount:recipientCount:note:)` :371 |
| ② 频道订阅 | 门槛由**频道主自己**设定：1 到 100,000、最多 6 位数字（:51、:53；`make` :1018 拒绝 0，`canPublish` 也要 `price >= 1`，所以"免费"的表达方式是**不发卡片**而不是发一张 0 价卡，`PopopxChannelSubscriptionSheet.swift:474`）；一 period 30 天（:65） | `subscribeToChannel(...)` :491 |
| ③ 加密资料卡解锁 | 价格来自 `popopx://profile` URI 的可选参数 `credits=`（`PersonalProfileModel.swift:445-458`，缺省即免费） | `unlockProfile(...)` :539 |
| ④ 防窥窗口延长 | 20 点 / +3600 秒（:67-68），只延长本机一侧的查看窗口 | `purchaseExtendedSecureWindow()` :570 |
| ⑤ 外观（头像框 / 暗金二维码皮肤） | 各 150 点（:70-71），一次性、仅本机生效 | `purchase(_:)` :576 / `owns(_:)` :584 |
| ⑥ 算力点兑徽章 | 600 点 / 30 天，4500 点 / 365 天（:98-99）；**先扣点后点亮，点亮失败原额退回** | `exchangeCreditsForBadge(period:)` :297 |

**② 的宿主入口（本轮裁定"必须接上、不得留孤立死代码"后的实测链，行号本轮重测）**：
频道页 `PopopxGroupChatInfoView.swift:270`（`subscriptionCard`，仅 `groupInfo.isChannel` 时出现）
→ 频道主/管理员那一格 `:276` 推进 `PopopxChannelThresholdView`（`PopopxChannelSubscriptionSheet.swift:341`；
   进不进这一格由 `popopxCanPublishChannelThreshold` 决定，见下）
→ `sendChannelAccess`（`PopopxSilentSignalingRouter.swift:563`）把**一条可见的**门槛卡片
（`popopx://channel?p=&t=&e=&s=`，载荷 `PopopxBadgeCreditsModels.swift:969`）发进频道会话
→ 成员在气泡上点订阅（`PopopxCommerceCards.swift:514` 的 `PopopxChannelAccessBubble`）才真正走
`subscribeToChannel` 扣点 → 票据写本机钥匙串，成员回到频道页那一格读到"有效至 …"（`:294`）
→ **票签成之后**成员这一侧再补发一条静默核销回执 `CHANNEL_SUB_ACK`（第 4 节第七种），
   它是尽力而为的：发不出去只留一行日志，绝不回滚那张已经成立的票据。
双向键都用 `ChatInfo.id`（群/频道即 `"#<groupId>"`），生产侧与消费侧同一个串，不会各算一次。
卡片是**看得见的消息**、不删不隐藏：它是成员那一侧唯一的价目来源（详见 `PopopxChannelAccessPayload`
顶部注释与本文件第 9 节第 7 条偏差）。

**发布端判据只有一份**（本轮裁定"防冒充必做"里可以落地的部分）：
`PopopxSilentSignalingRouter.swift:52` 的 `GroupInfo.popopxCanPublishChannelThreshold`
= `isChannel && membership.memberRole >= .admin && membership.memberCurrent`，
频道页那一格（`:274`）与 `sendChannelAccess` 的守卫（`:564`）读的是同一个计算属性，
所以"能不能发布"不会出现两个答案。接收端的两道闸见第 9 节第 7 条。

**②③④⑤ 都不经过 Apple**：它们花的是"此前已经通过 Apple 买过的余额"，不产生新的 IAP。
这是本特性最需要主动解释的一块，第 7 节给了口径。

---

## 4. 零 Bot、零中心账本 / No bot, no central ledger

**【审核可粘贴 · EN】** This feature contacts no server of ours. Every redemption or gift step is a
message between the two users over the existing end-to-end encrypted SMP connection. The whole
feature makes **five distinct** calls to the local messaging layer, at **eight** sites, all inside
one file (`PopopxSilentSignalingRouter.swift`: `apiDeleteContact` :315 and :351, `apiConnect` :366 and
:438, `apiAddContact` :400 and :469, `apiSendMessages` :607, `apiDeleteChatItems` :638): create a
temporary incognito connection, send the control message, then delete the message rows and the
temporary connection.
Nothing is persisted on our side because we run no side for this feature.

**【内部】** 十一个静默信令种类（`PopopxCommerceSignalKind`，`PopopxBadgeCreditsModels.swift:1084-1105`，
case 逐条在 :1085-1089、:1093、:1097、:1102-1105）：
`EXT_REDEEM_REQ` / `EXT_REDEEM_ACK` / `CHAT_REDEEM_REQ` / `CHAT_REDEEM_ACK` / `REDPACKET_CLAIMED`
/ `PROFILE_UNLOCKED` / `CHANNEL_SUB_ACK`
/ `CREDIT_EXT_REDEEM_REQ` / `CREDIT_EXT_REDEEM_ACK` / `CREDIT_CHAT_REDEEM_REQ` / `CREDIT_CHAT_REDEEM_ACK`，
线上格式 `::popopx_sys::` + 大写名 + `::` + 载荷（`PopopxSysMarker.wireString(for:)` :1139，前缀常量 :1137）。
前五种是需求点名的；**第六种是按需求补的**（资料卡解锁回执在需求里被写成"静默通知"却没有对应名字），
理由与"只进不出、收到即删行、绝不落库为可见记录"的语义记在 `PROFILE_UNLOCKED` 那一格的注释里，
本文件第 9 节把它列为 deviation。**第七种 `CHANNEL_SUB_ACK` 是 2026-11-19 裁定点名的**
（需求 :88"向频道同步已核销凭证回执"那一格，见第 8 节第 7 条的关闭记录）：成员扣点签票成功后，
本机把 `::popopx_sys::CHANNEL_SUB_ACK::<chatInfoId>::<expiresAtMs>` 发回那条频道会话，
载荷 `"chatInfoId::expiresAtMs"`（`PopopxSilentSignalingRouter.swift:577`）。
群/频道这一支的放行判据也从"只有 REDPACKET_CLAIMED"改成了 enum 上的计算属性
`acceptedInGroup`（:1111），两种回执 kinds 共用它，避免"两处各写一份白名单"。
"用完即删"是裁定过的方案：Swift 层不渲染 + ACK 后删行 + 一次性连接整条删除（`.full(notify: false)`，:315、:351）。
宿主侧三处闸（本轮重测行号，判据都只有 `PopopxSysMarker` 一份，`PopopxBadgeCreditsModels.swift:1136`）：
渲染抑制在**行**这一层 `ChatView.swift:2318-2325`（命中即 `Color.clear.frame(height: 0)`，
挂在行而不是气泡，因为终端排版与群里的行会绕过气泡）；会话列表预览 `ChatPreviewView.swift:301-307`
（信令常常正是该会话的最后一条，预览会把它念出来）；通知横幅 `NtfManager.swift:254-262`
（横幅在删行的 `Task` 之前**同步**发出，只靠删行赶不上）。
收信旁路在 `POPOPXAPI.swift:2785-2796`。

防双花：券/红包状态机在 `actor PopopxP2PVoucherVault`（`PopopxP2PVoucherVault.swift:63`）里，
单写者、跨调用串行，兑换记录写在 `AfterFirstUnlockThisDeviceOnly` 的钥匙串条目上。

**频道门槛卡片仍然不是静默信令，第七种才是。** 卡片走同一个 `send(text:)`（调用点 :568 → `send(text:)` 定义 :597 → `apiSendMessages` :607），因此
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
一条**代码注释**里 —— `PopopxBadgeCreditsModels.swift:1597` 的 `comment: "never VPN"`，那是防复发标记本身。
上一版记的第二处（付费墙里写明这条红线的文档注释）在 2026-11-20 的全库清扫里被改写为
`encrypted-tunnel vocabulary`（`PopopxBadgePaywallView.swift:418`），不再含这些字面词，所以计数是 1 而不是 2。
用户可见文本仍为 0 处。16 个翻译目录里同样各有一行 `/* never VPN */`（那是给译者的说明，不是译文），
**译文值 0 处**含这些词；目录里其余的 "proxy/VPN" 命中全部在本特性之外的既存条目
（例如 onion 主机的连接设置）。这一点很重要：如果产品描述里出现"隐藏你的网络活动"，3.1.4（硬件/网络功能）
与 VPN 相关条款就会把 app 推到另一个审核类别。

**术语通俗化记录（2026-11-19 追加）**：产品要求把用户看得见的"遥测面板 / Telemetry"改成
"节点状态面板 / Node Status Panel"。落点四处；2026-11-20 门禁二/门禁三之后这四处都是英文原句 key（`key("…")` → 进 16 个目录），
不再是"功能内中文常量、不走 `.lproj`"：
`PopopxBadgeDetailSheet.swift:288`（面板标题本身）、`:289`（脚注）、`PopopxTrialWelcomeModal.swift:209`、
`PopopxBadgePaywallView.swift:659`（收益条目那句 `Copy.benefitStatusPanel`，调用点 :425，措辞红线注释在 :418）。复算与例外：
- `遥测` 在**本特性 17 个 Swift 文件**里 = 0 处；目录侧本轮复算有 **1 处**命中：
  `zh-Hans.lproj/Localizable.strings:8036` 的一条译文值（键句 `This build bundles no analytics or crash-reporting SDK
  and no telemetry collector…`，属本特性之外的既存隐私声明条目）。"全部 Swift 与 `.strings` = 0 处"这句上一版是假的，
  现按实测改写；`en.lproj` 与其它 15 本目录 0 命中。
- `Docs/popopx-brand-spec.md` 原有 2 处（`:44` 小节标题、`:279` 字号表"顶栏遥测数字"）已按用户
  2026-11-19 的明确指示改为"节点状态"；**同一次指示覆盖了此前"不改 brand-spec"的裁定 4**，
  但只覆盖这两行——§2.4 那类条目仍然没有动（第 9 节第 4 条的例外仍由你定）。
- 类型与文件名 `Shared/Navigation/PopopxTelemetryHeader.swift` **保持原样**：改名要动 `.pbxproj`（红线），
  且 brand-spec `:249` 与 `:352` 引用的是这个真实路径，改了会让文档对不上代码。
- 用户自己的输入件 `apps/ios/prompt.md:64` 与 `apps/ios/ui-prompt.md:72` 仍写"遥测导航栏"，我没有改。

---

## 6. 本地化 / Localization evidence

**【审核可粘贴 · EN】** All purchase, renewal, refund and compliance sentences are localized. The
commerce copy set is **430 distinct keys** (measured by the two-line command in the appendix, which joins a
three commerce-copy keys (219, 222 and 154 characters) that the Swift source splits across two literals), delivered into **all 16 translation catalogs** in the app
(bg, cs, de, es, fi, fr, hu, it, ja, nl, pl, ru, th, tr, uk, zh-Hans). English is the development
region, so it renders from the source key. Every entry passes the repository's own placeholder and
link validator (`scripts/ios/localizations.py`), and `plutil -lint` reports all 17 catalogs OK.

**【内部】** 三条刻意不复用已有 key 的说明：目录是 app 级共享的，`"History"`、`"For me"`、
`"Restore purchases"` 已被别的页面占用（zh-Hans 把 "For me" 译成"仅自己"、de 把 "History" 译成
"Nachrichtenverlauf"），所以本特性用 `"For myself"` / `"Restore badge purchases"` 独立成条，
并删掉了三条普查后无人引用的 key。分线判据原先写在 `PopopxCommerceCopy` 的文档注释里，现记在
`PopopxBadgeCreditsModels.swift:1585-1592`：
**涉钱、涉退款、涉合规 → 目录；其余功能内文案 → 各文件私有 `enum Copy`。**
判据的后半句在 2026-11-20 被"全库硬编码中文显示串收口为英文原句 Key"这条裁定取代（门禁二 `5a4506b3c` +
门禁三 `10326e9b9`）：`Shared/Features/BadgeCredits/` 现在 **CJK = 0 行**，私有 `Copy` 也改存英文原句，
点数消费的确认弹窗（外观、解锁资料卡、频道订阅）因此已进 16 个目录，
**"2026-11-19 裁定保持中文、不扩写 16 个目录"这条已被取代并关闭**（第 8 节第 4 条同步作废）。

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
   written to the device Keychain only (`PopopxBadgeCreditsModels.swift:1403`,
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
   - `PopopxTrialWelcomeModal.swift:209`：原"流量走动态 SMP 中继节点集群，中继地址定期轮换。"
     → 现"徽章详情是一台只读本机的节点状态面板：档位、到期、对账摘要、本机计数。"
   - `PopopxBadgePaywallView.swift`：原 `Copy.benefitRotation` 那条 bullet **整条删除**，
     收益清单现为 5 条（:424-428），其中新增的 `benefitStatusPanel` 与上面同一套说法。
   商店短句与本文件的可粘贴块一起换成第 1 节那两句（中英各一），"1GB" 不再出现在任何付费语境里。
   复算：排除注释行后 `grep -rn '轮换\|优先调度\|1GB' Shared/Features/BadgeCredits/*.swift` **0 命中**（附录）。
   第 1 节表格里那三项的实现状态**没有变化**——这次改的是"App 说什么"，不是"App 能做什么"。
2. ~~**频道订阅面板还没有宿主入口**~~ —— **本轮已关闭（裁定 1：必须接上、不得留孤立死代码）。**
   挂载链见第 3 节末尾，实测锚点：`PopopxGroupChatInfoView.swift:271`（仅 `groupInfo.isChannel` 出现）、
   频道主发布页 `PopopxChannelSubscriptionSheet.swift:341`、成员卡片 `PopopxCommerceCards.swift:514`、
   扣点 `PopopxCreditsManager.subscribeToChannel` :491、本机凭证查询 `ticket(forChannelId:)` :532。
   审核现在**走得到**这个场景：频道页 →「订阅门槛」→ 填数发布 → 频道里出现卡片 → 成员点订阅扣点。
   剩下的不是入口问题，而是第 1 条那类"宣称与实现"问题，以及下面第 5 条的上机验证。
3. ~~DeviceCheck capability 尚未在工程里开启~~ —— **本轮裁定：维持现状，不加 entitlements/capability。**
   `DCDevice.current.generateToken()` 已带墙钟超时调用
   （`PopopxBadgeManager.swift:417-436`，超时 2 秒的常量在 :46，`isSupported` 先判 :419），
   且**任何失败（不支持 / capability 未开 / 超时 / 无网络）都合并成 nil**，改用本机安装指纹
   （:445，一个自铸 UUID 存在钥匙串 `installIdentity` 格）作防重放标识；取哪一种由 :408-413 决定。
   后果（裁定已接受，写在这里免得日后当成 bug）：体验徽章防的是"同一台设备卸载重装再来一次"，
   **不防跨设备转移**；capability 没开时 :419 直接返回 nil，走的就是本机指纹那条路，行为不变、不会崩。
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
   （`PopopxSilentSignalingRouter.swift:577`）把 `::popopx_sys::CHANNEL_SUB_ACK::<chatInfoId>::<expiresAtMs>`
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
   （`id/amount/note/sig`），实现加入 `n=<收件人份数>`（`PopopxBadgeCreditsModels.swift:841`、wireString :896）
   并把 `n` 纳入签名原文，因此改份数与改金额一样导致验签失败。多收件人是"一个红包发给 100 人"这条
   需求语义的必要承载，删不掉；但它是**协议字段的增加**，请在提交前确认这套 URI 不与其他客户端互操作。
2. **`popopx://gift` 的字段集是实现自定的**（需求只写了 `popopx://gift?...`）：
   `v/p/n/t/s`（徽章券 :622）与算力点礼品卡的 `v/a/n/t/s`（:733，`a` 是面额不是周期），`n` 在两种礼品卡里都是 base64url 的赠言，**与红包里的 `n`（收件人份数）不同义**。
   两个 host 不同、解析器不同，不会互相误读；但如果以后要做跨端解析，这条命名冲突要写进协议文档。
3. **第六种信令 `PROFILE_UNLOCKED` 与第七种 `CHANNEL_SUB_ACK`** 都在需求点名的五种之外：
   第一种是本实现自补的名字（理由见第 4 节），第二种由 2026-11-19 裁定点名定名（第 8 节第 7 条）。
4. **暗金二维码皮肤动到品牌规范 §2.4**（`Docs/popopx-brand-spec.md` 的"唯一允许渐变的地方"）。
   实现只换单一色相（品牌紫 → 暗金），三个 stop 位置、三个 alpha、`label` 底、`onBrand` 墨全部不动，
   二维码模块色另取深青铜以保持 ≥4.5:1 扫码对比度
   （`Shared/Features/AddFriend/PopopxQRCardSheet.swift:112-181`、:241-252）。
   **我没有改 brand-spec 文档**（红线之外还因为它是你的裁定件）；§2.4 要不要写这条例外，由你定。
5. **付费墙多了一个无条件入口。** 需求的进入路径是顶栏胶囊；实测胶囊按状态分发
   （`PopopxBadgeCapsuleView.swift:353-358`：`.activeLit → 徽章详情`），于是**已点亮徽章的人再也没有
   任何购买入口**（买不了点数，也就兑不了续期）。已在"我的"页加一条常驻"充值算力点"
   （`PopopxMeView.swift:305`）。这是修死路，不是加营销位。
6. **`popopx://channel` 这个 URI 整个是实现自定的**——需求只写了"订阅确认弹窗"（:86-88），没给任何线上传输形状。
   实现落在**一条可见消息**上：`?p=<点数>&t=<发布时间毫秒>&e=<发卡方 P-256 公钥 base64url>&s=<签名>`
   （`PopopxBadgeCreditsModels.swift:969`，字段名 :972，wireString :1027），签名原文是
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
        `sendChannelAccess`（:563）与频道页那一格（`PopopxGroupChatInfoView.swift:274`）读同一份，
        所以本机不是频道主/管理员就发不出这张卡。
     2. **接收端"必须在频道里"闸（已实现）**：气泡按 `context.isChannel` 分档
        （`PopopxCommerceCards.swift:572`，判据 = `GroupInfo.isChannel`
        = `publicGroup?.groupType == .channel`，`POPOPXChat/ChatTypes.swift:3064`、`:3233`；
        **不是** `ChatInfo.isChannel` 那个 `useRelays` 版本，后者对大型私群也为真）。
        伪造一张 `popopx://channel` 粘进单聊，会显示"这一条不在频道里"而**走不到扣点**。
        信息页那一格用同一个 `isChannel`，两处不可能给出不同答案。
     3. **签发密钥钉扎（已实现，覆盖面有限）**：付过一次之后本机那张票记下发卡公钥
        （`PopopxChannelSubscriptionTicket.issuerPublicKeyBase64URL`，`PopopxBadgeCreditsModels.swift:1275`），
        同一 `chatId` 上再出现另一把钥匙签的卡 → "签名密钥与本机上一次付费记下的发布者不一致"
        （`PopopxCreditsManager.channelIssuerConflict` :524 → 气泡 :576）。
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
   有 `.group` 那一档，但宿主侧 `ComposeView.swift:1402` 的 `popopxPacketDestination` **只认单聊联系人**，
   所以群聊里的"+"菜单不出现这一格（判据只有一份，`popopxPlusActions` 读同一个可选值，
   不存在第二处开关会把它放回来）。
   原因写在 `:1402` 的注释里：零服务端意味着群里并发拆包没有互斥，最坏情况是同一笔点数字面上被多记几次到账。
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
  (Product → Scheme → Edit Scheme → Run → Options → StoreKit Configuration). It contains all 12
  products, so the app is fully testable with no App Store account and no network.
- Path to each surface: top bar badge capsule → paywall / detail / trial; Me → 算力点中心 (credits
  store, badge exchange, gift-code redeem, cosmetics) → the six spend scenarios; the message
  composer "+" menu → send a credit packet (1:1 chats only); an encrypted profile card in a chat →
  unlock prompt; a **channel** → channel info page → "订阅门槛" (owner sets a price and publishes a
  card into the channel) → a member taps Subscribe on that card.
- To exercise a gift: mint a card in 算力点中心 → 赠送徽章, copy the `PPX1-…` code, and redeem it
  from a second simulator/device (two installs of the app connected as contacts).

**【内部】** 已验证到哪一步（诚实口径，本轮实测数字）：

- **工程挂载**：`git status` 里本批改动的 Swift 文件共 **35** 个 = 17 个新特性文件 + 18 个既存宿主文件（第 12 轮那棵工作树的读数；附录那条循环数的是 `git status` 里的脏文件，工作树一干净它就返回 0 行）；
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
- **本地化**：本特性引用 430 条 key（口径与普查命令见第 6 节与附录）；第 12 轮另新增 36 键 × 16 目录 = 576 行、
  改名/退役 6 键 × 16 = 96 行，16 个翻译目录再加 `en.lproj`（实测 `ls -d *.lproj` = **17**），用只喂源目录的
  等价命令复算 = `catalogs: 17 / problems: 0 / plutil: []`（本轮实测）。
- **`check-previews` 这一步**：本轮把 BadgeCredits 的 23 个 `*_Previews` 加进了
  `"POPOPX Snapshots"/check-previews.py` 的 `EXCLUDED`（**39 → 62** 项，`git diff` = 23 行纯新增）。
  对 **tracked 源**跑（附录给命令）= `listed: 131 / errors: 0`；
  在带构建产物的工作区里直跑会 `rc=1`，报的 4 行全是
  `build/**/SourcePackages/checkouts/CodeScanner/…: CodeScannerView_Previews`——
  那是 gitignore 掉的依赖检出，不是本特性的文件，不能当成回归。
- **仍未验证的部分（不要把上面任何一条当成运行时证据）**：StoreKit 真实交付、SMP 收发信令、
  DeviceCheck、扫码、Face ID、临时连接删除、**本轮新增的频道卡片发布/订阅与 `CHANNEL_SUB_ACK`
   核销回执整条链**、第 11 节整轮算力点礼品卡链（购买交付、铸码、扫码核销、隐形连接收发与删连、卡包列表、
  发进会话的卡片气泡）、`GroupInfo.isChannel` 在真机频道会话里的实际取值、发卡公钥 pinning 的两台设备行为、
  以及第 8 节第 5 条那三处抑制闸在另一款客户端面前的表现。全部只有编译证据。
- `POPOPX (iOS)` target 之外没有新增任何 target；没有动 `project.pbxproj` 的脚本改动（红线）。

---

## 11. 第 12 轮：算力点礼品卡 / Round 12 — compute-credit gift cards (2026-11-21)

本轮把「我 → 算力点商店」的购买 / 转赠 / 核销做成与徽章付费墙对称的一套。下面每一格都是本轮实测（命令见附录末段）。
**本轮全部只有编译 + 安装证据：没有两台设备走过一次真实兑换。**

### 11.1 模块一 · 三个纯面额礼品卡 SKU（3.1.1）

- `PopopxNodeBadgeSku` 现 **12 个 case**（`PopopxBadgeCreditsModels.swift:147-159`），新增 `.creditsGift100/500/2000`（:157-159）；
  `productId` 整表 :163-177（三条 `com.popopx.credits.gift.*` 在 :174-176）；交付类型 `.creditGiftCard(amount)` :197-199。
- 回退价 :237-245 把礼品卡与自用档**并进同一臂**（:241-243：`.credits100, .creditsGift100 → "$1.99"`），
  "转赠不额外收费"这句在代码里因此是真的，不是注释里的承诺。
- `PopopxStoreKit.storekit` 现 12 个 identifier（本轮 +45 行），双向差集两个方向都是空集（附录第一条命令实测）。
- **零加赠**：本轮新增的 36 条键在 16 本目录里的值，`买N送 / 加赠 / 额外获得 / bonus / extra credits / 赠送\d+` 命中 **0 处**。
  有一个**不是违规**的命中要记下来：zh-Hans 把
  `With a redemption code, receive on this device what the other side gifted.` 译作「凭兑换码，在本机领取对方赠送的礼品。」
  ——这个"赠送"是点对点对赠的动词，不是购买加赠，所以普查必须用窄式，宽式 `赠送` 会假报一条违规。

### 11.2 模块二 · 券、码、临时隐形连接（3.1.4 与双花）

- 一个 `PopopxNodeVoucher` 承载两个家族，判据只有一个字段：`isCreditVoucher = creditsAmount != nil`（Models :413），
  显示回退 `badgeDays` :420 / `creditFaceValue` :425。
- 码：算力点前缀 `PPXC1-` 与徽章 `PPX1-` 同族不同串（`prefixes` :541，编码/解码 :546-552）；
  载荷 `PopopxCreditGiftPayload` :730，字段名 `v/a/n/t/s` :733（`a` 是面额，徽章券同位置是 `p` 周期）。
  签名原文走 `canonical(kind: "credit_code" / "credit_grant" / "creditgift")` 一族，与徽章族**互斥**——
  一张徽章券的签名过不了算力点券的校验，反之也一样，这是"两种码不会互相冒领"的唯一保证。
- 状态机全在 `actor PopopxP2PVoucherVault`（`PopopxP2PVoucherVault.swift:63`）：`mintCredit` :126、
  `creditVouchers(state:)` :170、`authorizeCreditRedemption` :293、`signedCreditGrant` :349、`recordCredit` :400、
  `creditGrant(voucherId:)` :407、`receivedCreditGrants()` :413。`unused → redeemed` 的翻转与回执写入在同一次
  actor 调用里完成（`markRedeemed` :307），这是本机唯一的防双花闸；没有服务端核销，也没有第二道锁。
- 信令：`CREDIT_EXT_REDEEM_REQ` / `CREDIT_EXT_REDEEM_ACK` / `CREDIT_CHAT_REDEEM_REQ` / `CREDIT_CHAT_REDEEM_ACK`
  （Models :1102-1105）。这四个名字是**本轮需求正文点名**的，`BadgeCredits_prompt.md` 里没有出现过这四个串（实测 grep = 0），
  所以既不是实现自取、也不是上游遗留。发送侧 `startExternalCreditRedeem(code:)` :433、`redeemCreditInChat(_:contactId:)` :451、
  `mintCreditCode(for:)` :466、`sendCreditGiftCard(_:note:contactId:)` :501；接收侧 `answerCreditRedeemRequest` :260、
  `applyCreditRedeemAcknowledgement` :322；回执编解码 :679 / :687。临时连接仍然"用完即删"：
  `.full(notify: false)` 删连接（:315、:351）+ ACK 后删行（:638），Swift 侧照旧不渲染（第 4 节那三处宿主闸）。
- 相机红线：扫码页不用 `CodeScanner` 包，本文件自带一个 `AVCaptureSession`；停止顺序"先摘 delegate → `stopRunning` →
  释放引用"写在 `stop()` :498-506（`session = nil` :500、`previewLayer?.session = nil` :453），
  **识别成功瞬间**（:518 调 `stop()`）与**弹窗消失**（`dismantleUIView` :436-437 调 `coordinator.stop()`）各一次。
  顺序反了会让 `stopRunning` 期间的迟到帧回调到一个已经没人持有的会话上，这段理由就写在 :496-497 的注释里。

### 11.3 模块三 · 商店页对称

- `PopopxCreditsStoreView` 顶部 `PopopxSegmentedControl` :158 两段（enum `PopopxCreditsStoreTab` :919-921，
  标签为什么故意短写在 :917）；四张卡：充值 :252、买礼品卡 :394、余额转礼品卡 :490、卡包 :585。
  **永久核销入口**：`.sheet(isPresented: $showsRedeem) { PopopxVoucherRedeemSheet() }` :126，入口行在 :901 置位，
  不随余额、商品是否就绪或卡包是否为空而消失。
- 卡面只有一份：`PopopxGiftCardPresenter`（`PopopxGiftBadgeCardSheet.swift:381`，数据体 `PopopxMintedGiftCard` :366）
  同时服务两个家族，三处真差异（铸券函数、标题句、发进会话时签哪种载荷）都按 `isCreditVoucher` 分支；
  理由写在 :376-380——再写一个 presenter 等于让两条 QR 路径在旋转、纠错级别、粘贴格式上各自漂移。
- 聊天入口：`PopopxPlusAction.creditsGiftCard`（`PopopxInputBar.swift:548`，标题 :564，图标 :580）→
  `ComposeView.swift:1389` 只在单聊联系人**且该会话可发送**（`contact != nil && sendMsgEnabled`）时可用 → :1471-1476 打开 `PopopxCreditsStoreView(contactId:)`（挂载 :739-744）；
  带 `contactId` 时页面直接落在礼品卡段，卡面多一枚"在本会话发送"的按钮，因此**不新建第二个选会话的抽屉**。
  气泡侧 `PopopxCommerceCards.swift:63 / :72 / :86` 认出 `.creditGift`，宿主 `PopopxMessageBubble.swift:458` 分派。
- 徽章与算力点仍在两个页面；点数余额与礼品卡券包也各自一格，没有把商店并成付费墙的子页。

### 11.4 本轮修掉的三处既存缺陷（都不是本轮新写的功能代码）

1. `PopopxP2PVoucherVault.swift:172` 与 :185 两个家族过滤器**缺 `return`**：门禁日志只报了 `[#NoUsage]`
   （"结果未使用"）而没报硬错误，但 `swiftc -frontend -parse` 单独复现同一形状时是 "missing return"。
   后果是**卡包与徽章券列表都拿不到值**——界面照常渲染、列表恒空，属于"编译绿但功能死"那一类。补显式 `return` 后
   两条列表各自按家族返回（`creditVouchers` 只给 `isCreditVoucher` 为真的，`badgeVouchers` 取反）。
2. `ComposeView.swift:1491` 那个 `.photo/.camera/.file` 内层分派 switch 在新 case 后不穷尽（门禁第三条错误）：
   补 `break` 臂，保持"这三种之外由上面的分支处理"的原意，而不是把新 case 塞进去走文件选择器。
3. **普查脚本自身的假绿**：`NSLocalizedString(` 与键字面量分处两行时，上一版同行正则看不见它，
   于是"0 缺键 ×16"是假的——有 5 条键 × 16 目录 = 80 行根本没写进去。补写后重测为 0 缺键。
   其中一条 219 字符长句在源码里被拆成两段字面量（`PopopxBadgeCreditsModels.swift:1675-1676`），
   **普查必须把两段并起来查**：只取第一段的正则会报"16 本目录全缺"，而它其实 16/16 都在（附录给那条命令）。

### 11.5 本轮门禁读数

- 增量 arm64 设备门禁：`** BUILD SUCCEEDED **` / `error:` 0 / **Swift warning 0**（日志里 3 条
  `appintentsmetadataprocessor … Metadata extraction skipped` 不是 Swift 警告），`^SwiftCompile ` 282 行、
  主二进制 `Ld` 1 次、`CopyStringsFile` 16 次；新目录行在**产物 bundle 内**实测（zh-Hans 4,466 行、de 4,490、ja 3,795），
  券包与算力点回执符号在 `nm -U` 里 demangle 后可见，主二进制 mtime 晚于最后一个源文件改动。
- **test target 单独一腿**（`xcodebuild build` 从不编译测试目标）：
  `build-for-testing -only-testing:"Tests iOS"` = `TEST BUILD SUCCEEDED` / 0 error / 4 条非 Swift warning /
  `^SwiftCompile ` 148 行，其中 23 行属于 `Tests iOS`。
- 纯度：`Shared/Features/BadgeCredits/` 17 个文件 CJK = **0 行**（门禁三之后连注释都是英文）；
  `en.lproj` 未被写入（本轮 36 条键在其中命中 0）；`plutil -lint` **17/17 OK**。

---

## 附录：每条声明的复算命令 / Re-derivation appendix

```sh
cd apps/ios
# 规模与文件数
ls Shared/Features/BadgeCredits/*.swift | wc -l && wc -l Shared/Features/BadgeCredits/*.swift | tail -1
# 12 个 SKU：identifier 与 .storekit 双向核对（用工程真正引用的那一份，不是根目录那份重复副本）
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
# 注意：裸 grep 得到 **10** 行，其中 2 行是文件头注释里提到这些名字；去掉注释行是 8 处调用点 / 5 个不同函数。
grep -rn "apiConnect(\|apiAddContact(\|apiSendMessages(\|apiDeleteChatItems(\|apiDeleteContact(" Shared/Features/BadgeCredits/
grep -rn "apiConnect(\|apiAddContact(\|apiSendMessages(\|apiDeleteChatItems(\|apiDeleteContact(" Shared/Features/BadgeCredits/ | grep -v '//' | wc -l   # 期望 8；本轮实测 8：:315 :351 :366 :400 :438 :469 :607 :638
grep -rn "apiConnect(\|apiAddContact(\|apiSendMessages(\|apiDeleteChatItems(\|apiDeleteContact(" Shared/Features/BadgeCredits/ | grep -v '//' | grep -o 'api[A-Za-z]*(' | sort -u | wc -l   # 期望 5
# 十一种静默信令与线上前缀（本轮复算：enum 1084-1105、`marker` 在 1137、`wireString(for:)` 在 1139、`parse` 从 1143 起）
sed -n '1084,1105p;1136,1146p' Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift
# 本轮新增的核销回执（发送侧一行 + 判据入组白名单一行）
grep -n 'channelSubscriptionAcknowledge\|CHANNEL_SUB_ACK' Shared/Features/BadgeCredits/*.swift
# 口径撤下的三项在**用户可见文本**里为 0（注释里保留一条撤回说明，那是裁定要求的记录）
grep -rn '轮换\|优先调度\|1GB' Shared/Features/BadgeCredits/*.swift | grep -v '^\S*:[0-9]*: *//' | wc -l   # 期望 0
grep -rln '调度\|priorit\|schedul' Shared/Features/BadgeCredits/                                          # 命中数本身不是判据：2026-11-21 第 14 轮实测 3 个文件（Paywall 的撤回注释 + ChannelSubscriptionSheet.swift:262 + VoucherRedeemSheet.swift:16），三条都是注释；用户可见 0 由上一条剔除注释行的命令证明
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
# 0 条 = 那次"编译成功但没编译新文件"的假绿；第 12 轮实测 34 个 = 4 条，只有 ChatView.swift = 12（进多个 target）。工作树干净时下面这条循环返回 0 行，复算改用落地提交：`git show --name-only --pretty=format: 31d10bf4f | grep '\.swift$'`（第 14 轮用这条重跑，仍得 35 个文件、34×4、ChatView=12）
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
# 本轮实测：全模块只有 1 处命中，且不是给用户看的字——
#   PopopxBadgeCreditsModels.swift:1597 的 comment: "never VPN"（防复发标记本身）
#   （上一版记的第二处 PopopxBadgePaywallView.swift:381 已在门禁三改写为 encrypted-tunnel vocabulary，见 :418）
grep -rn "VPN\|专网\|代理\|proxy\|Proxy" Shared/Features/BadgeCredits/
# 用户可见字符串里再查一次：只查 NSLocalizedString 与 Copy 的赋值行，期望 0
grep -rn 'NSLocalizedString("[^"]*\(VPN\|代理\|proxy\)' Shared/Features/BadgeCredits/ ; \
grep -rn 'static let [a-zA-Z]* = "[^"]*\(VPN\|专网\|代理\)' Shared/Features/BadgeCredits/ ; echo "^ 期望两条都无输出"
# SimpleX 品牌残留：本特性文件里 **0 处命中**（2026-11-21 第 14 轮复测；上一版记的那 6 处注释说明句已在门禁二改写为英文原句），
# 没有一处出现在用户可见字符串或类型名里
grep -rn "SimpleX" Shared/Features/BadgeCredits/ | sed 's/:.*\(\/\/.*\)/  \1/' | cut -c1-100
# 术语通俗化：中文"遥测"在所有 Swift 与 .strings 里必须为 0；改名落点为 4 处功能内文案
grep -rn "遥测" Shared POPOPX POPOPXChat *.lproj 2>/dev/null | grep -v '\.lproj/' | wc -l                              # 期望 0：Swift 侧实测 0；目录里另有 1 处 `zh-Hans.lproj:8036`，是"本构建不内置统计/崩溃 SDK"那句译文的用词，不是界面文案
grep -rn "节点状态面板" Shared/Features/BadgeCredits/ | cut -c1-90                                  # 门禁二之后本目录 **0 行**（四处落点都转成了英文原句 Key）；改名事实改由 Key 与 zh 值证明：`grep -rn '"Node status panel"' *.lproj` 命中 16 本，`zh-Hans.lproj:9095` = "节点状态面板"
grep -n "遥测" Docs/popopx-brand-spec.md ; echo "^ 期望无输出（2026-11-19 指示后已改）"
grep -rn "遥测" prompt.md ui-prompt.md | cut -c1-70   # 只应命中用户的提示词原件；本文件与 brand-spec 里的命中都是"记录"而非界面文案
# 本地化：73 个 key 在 16 个目录里齐备、占位符合法、plutil 全绿
# 口径 = `enum PopopxCommerceCopy`（Models:1593）+ `private extension PopopxCommerceCopy`（StoreKitManager:631）
# 两块里的 NSLocalizedString 字面量，第 14 轮实测 occurrences 73 == distinct 73（没有一句写两遍；上一版记的 49 是门禁二之前的库存）
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
# ——— 以下为第 12 轮（算力点礼品卡，2026-11-21）新增的复算命令 ———
# 12 个 SKU 与 .storekit 双向差集：storekit_only 与 code_only 都必须是空集
python3 - <<'PY'
import json, re
sk = json.load(open('Shared/Features/BadgeCredits/PopopxStoreKit.storekit')); ids = set()
for k in ('products', 'nonRenewingSubscriptions'):
    for p in sk.get(k, []): ids.add(p['productID'])
for g in sk.get('subscriptionGroups', []):
    for s in g.get('subscriptions', []): ids.add(s['productID'])
code = set(re.findall(r'"(com\.popopx\.[^"]+)"', open('Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift').read()))
print('storekit=%d code=%d storekit_only=%s code_only=%s' % (len(ids), len(code), sorted(ids - code), sorted(code - ids)))
PY
# 券族判据、码族、信令名（四个 CREDIT_* 在 1102-1105）
grep -n "var isCreditVoucher\|var creditFaceValue\|static let prefixes\|enum PopopxCommerceSignalKind" Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift
# actor 状态机；以及两处"缺 return"的位置（没有 return 时列表恒空）
grep -n "actor PopopxP2PVoucherVault\|func mintCredit\|func creditVouchers\|func badgeVouchers\|func authorizeCreditRedemption\|func markRedeemed" Shared/Features/BadgeCredits/PopopxP2PVoucherVault.swift
sed -n '167,188p' Shared/Features/BadgeCredits/PopopxP2PVoucherVault.swift
# 隐形连接的收发与删连：8 处调用点 / 5 个不同函数
grep -n "func startExternalCreditRedeem\|func redeemCreditInChat\|func mintCreditCode\|func sendCreditGiftCard\|func answerCreditRedeemRequest\|func applyCreditRedeemAcknowledgement" Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift
# 相机：停止顺序与两处调用点（识别成功 :518、页面消失 :436）
grep -n "func stop()\|session = nil\|dismantleUIView\|stop()" Shared/Features/BadgeCredits/PopopxVoucherRedeemSheet.swift
# 商店页四张卡 + 永久核销入口 + 唯一卡面 + 聊天入口
grep -n "PopopxSegmentedControl\|giftBuyCard\|giftExchangeCard\|giftWalletCard\|showsRedeem\|PopopxVoucherRedeemSheet" Shared/Features/BadgeCredits/PopopxCreditsStoreView.swift
grep -n "struct PopopxGiftCardPresenter\|struct PopopxMintedGiftCard\|isCreditVoucher" Shared/Features/BadgeCredits/PopopxGiftBadgeCardSheet.swift
grep -n "creditsGiftCard" Shared/Features/ChatRoom/PopopxInputBar.swift Shared/Views/Chat/ComposeMessage/ComposeView.swift
# 目录门：本轮新增键 16 本逐本都在，且值内没有"购买加赠"句式（宽式 赠送 会假报，见 11.1）
python3 - <<'PY'
import subprocess, json, re, glob, os
d = subprocess.run(['git', 'diff', '-U0', '--', '*.lproj/Localizable.strings'], capture_output=True, text=True).stdout
keys, cur = set(), None
for l in d.splitlines():
    if l.startswith('+++ b/'): cur = os.path.basename(os.path.dirname(l[6:])); continue
    if not cur: continue
    m = re.match(r'^\+\s*"((?:[^"\\]|\\.)*)"\s*=', l)
    if m: keys.add(m.group(1))
BONUS = re.compile(r'买\s*\d+\s*(?:送|赠)|\bbonus\b|加赠|额外获得|extra\s+\w*\s*credits?|free\s+\w*\s*credits?|赠送\s*\d+', re.I)
bad = []
for c in sorted(glob.glob('*.lproj')):
    if c == 'en.lproj': continue
    j = '/tmp/ap_%s.json' % c.replace('.lproj', '')
    subprocess.run(['plutil', '-convert', 'json', '-o', j, f'{c}/Localizable.strings'], check=True)
    cat = json.load(open(j, encoding='utf-8'))
    miss = [k for k in keys if k not in cat]
    viol = [k for k in keys if k in cat and BONUS.search(cat[k])]
    if miss or viol: bad.append((c, miss[:2], viol[:2]))
print('added_keys=%d locales=%d problems=%s' % (len(keys), len(glob.glob('*.lproj')) - 1, bad if bad else 'NONE'))
PY
# 跨行拼接的那条 219 字符长句：必须两段并起来才查得到（只取第一段会假报"16 本全缺"）
python3 - <<'PY'
import re, glob, json, subprocess
m = open('Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift', encoding='utf-8').read().splitlines()
i = next(k for k, l in enumerate(m) if 'Paste this whole string' in l)
key = ''.join(re.search(r'"((?:[^"\\]|\\.)*)"', m[k]).group(1) for k in (i, i + 1))
miss = []
for d in sorted(glob.glob('*.lproj')):
    if d == 'en.lproj': continue
    j = '/tmp/ap_%s.json' % d.replace('.lproj', '')
    subprocess.run(['plutil', '-convert', 'json', '-o', j, f'{d}/Localizable.strings'], check=True)
    if key not in json.load(open(j, encoding='utf-8')): miss.append(d)
print('joined_key_len=%d missing=%s' % (len(key), miss if miss else 'NONE (16/16 present)'))
PY
# 纯字符门：本特性 17 个文件 CJK = 0（含注释）
grep -rn '[一-鿿]' Shared/Features/BadgeCredits/ | wc -l

> 关于 `scripts/ios/localizations.py check`（本轮两种失败都实测过，都不是本特性引入）：
> - 在**仓库根**跑：它按 `apps/ios/**/*.lproj/*.strings` 递归，会把 `build/`、`product/` 里
>   **编译后的二进制 `.strings`** 也读进来，以 `UnicodeDecodeError: 0xd3` 崩掉。清理那些目录后才会通过。
> - 在 `apps/ios` 里跑：更危险——脚本里 `IOS_DIR = Path("apps/ios")` 是相对当前目录的路径，
>   于是它去解析 `apps/ios/apps/ios`，找不到任何目录，照样打印 **"No problems found." 并返回 0**。
>   这是一条**什么都没检查的绿色**，不能当作证据。
> 因此在带构建产物的工作区里，用上面那段只喂源目录的等价命令。
