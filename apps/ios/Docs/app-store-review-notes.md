# POPOPX 动态隐私节点徽章 / 算力点生态 —— App Store 审核备注

# App Store Review Notes — Dynamic Privacy Node Badge & Compute Credits

> 本文件有两类内容，分得很清：
> **①【审核可粘贴】** 是英文、可直接填进 App Store Connect → App Review Information → Notes；
> **②【内部】** 是中文的实现事实、待办与风险，不给审核看。
>
> Every factual claim below is a measurement, not a memory: section 附录 lists the exact command that
> reproduces it. If the code moves, re-run the commands before re-submitting.

- 本特性落地的代码在 `Shared/Features/BadgeCredits/`：**17 个 Swift 文件、10 797 行**，2026-11-21 第 14 轮复测 `wc -l Shared/Features/BadgeCredits/*.swift | tail -1`。上一版记的 10 812 行是同一天第 13 轮的读数，本轮净 **−15**（`git show 71a8f27fe --numstat` = 180/195：删掉两处旁路按钮连同它们的文案）。另外上一版把「8 768 → 10 812」写成"本轮 +157"，算术对不上（8 768 + 157 = 8 925），两次读数之间真实的差是 **+2 044**。第 3、4 节的 110/112 是更早一轮的读数。
- 最后核对 / Last verified: 2026-11-19（本轮：口径收口 + `CHANNEL_SUB_ACK` 核销回执 + 频道卡片防冒充，门禁 `build/gate_bc5.log`（失败，见第 10 节）与 `gate_bc6.log`，读数见第 10 节）；2026-11-21 第 14 轮把本文件的**每一处 `file:NNN` 引用与每一个计数**重跑了一遍，改过的行都带"第 14 轮复测/实测"字样，未带字样的读数属于各自那一轮的历史记录，故意不追改。**2026-11-21 第 15 轮**再把全部 `file:NNN` 重推了一遍（按内容重推，不是统一 ±N：26 条引用里 20 条是我改动造成的位移、6 条是上一版就已存在的错位，见第 12 节末），SKU 计数 12 → 13，新增第 12 节（发现页服务号 + 30 天周期计费）。
- 商店配置文件 / StoreKit config: `apps/ios/Shared/Features/BadgeCredits/PopopxStoreKit.storekit`
- 商店配置文件是 `Shared/Features/BadgeCredits/PopopxStoreKit.storekit`（与代码同目录，不是仓库根的那份）。它**定义了 13 个产品标识符**（第 15 轮 +1）：`products` 9 个（4 个算力点直购 credits.100/500/2000/5000 + 3 个算力点礼品卡 credits.gift.* + 2 个徽章礼品卡 gift.node.annual/monthly）+ `nonRenewingSubscriptions` 2 个（badge.node.pass.30d/365d）+ `subscriptionGroups[0].subscriptions` 2 个（badge.node.annual/monthly，就是那两条自动续订）；上一版写"9 个：5 消耗型 + 2 自动续订 + 2 非续订"，少算了 3 个，正是后补的三张算力点礼品卡；第 15 轮再加 `com.popopx.credits.5000`（12 → 13）：这一条在代码侧早已存在（Models `case credits5000` :160、identifier :178、回退价 :250），缺的是 `.storekit` 里的条目——补之前附录那条双向差集命令实测报 `code_only=['com.popopx.credits.5000']`，补之后两个方向都是空集；至于"消耗型"，那是业务口径不是文件字段——`products` 里九条都没有 `consumableStatus`；
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

`PopopxNodeBadgeSku`（`PopopxBadgeCreditsModels.swift:147`、13 个 case :148-163、`productId` 整表 :167-183（13 条字面量 :169-181）、价格回退 :243-252）与
`PopopxStoreKit.storekit` 的 13 个 identifier 已交叉核对，双向一致、无多无少
（核对脚本：解析 storekit JSON 取 products + nonRenewingSubscriptions + subscriptionGroups 三张表的 productID 全集，
与代码里 13 条 `"com.popopx.*"` 字面量做双向差集，两个方向都必须是空集；
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
| 10 | `com.popopx.credits.5000` | Consumable | $69.99 | 正好 5000 / exactly 5000（第 15 轮新增，纯面额，无礼品卡孪生） |
| 11 | `com.popopx.credits.gift.100` | Consumable（礼品卡/一次性券） | $1.99 | 一张可转赠的 100 点算力点礼品卡 / transferable card worth exactly 100 credits |
| 12 | `com.popopx.credits.gift.500` | Consumable（礼品卡/一次性券） | $8.99 | 正好 500 点礼品卡 / exactly 500 |
| 13 | `com.popopx.credits.gift.2000` | Consumable（礼品卡/一次性券） | $29.99 | 正好 2000 点礼品卡 / exactly 2000 |

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

**【内部 · 纯净充值】** 七个点数产品（4 个自用包 + 3 个算力点礼品卡）"到账 = 面额"，代码里没有"赠送/bonus"这条通路；
礼品卡面值与自用包逐档相同（100 / 500 / 2000）；第 15 轮的 5000 档只有自用包、**没有**对应的礼品卡 SKU，所以它在 `fallbackPriceText` 里单独成一臂（:250）而不是并臂，买卡的人自己**不得**点数，收款人兑换到的也正是标定面额，
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
→ `sendChannelAccess`（`PopopxSilentSignalingRouter.swift:589`）把**一条可见的**门槛卡片
（`popopx://channel?p=&t=&e=&s=`，载荷 `PopopxBadgeCreditsModels.swift:976`）发进频道会话
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
one file (`PopopxSilentSignalingRouter.swift`: `apiDeleteContact` :341 and :377, `apiConnect` :392 and
:464, `apiAddContact` :426 and :495, `apiSendMessages` :670, `apiDeleteChatItems` :701): create a
temporary incognito connection, send the control message, then delete the message rows and the
temporary connection.
Nothing is persisted on our side because we run no side for this feature.

**【内部】** 十三个静默信令种类（`PopopxCommerceSignalKind`，`PopopxBadgeCreditsModels.swift:1091-1134`，
case 逐条在 :1092-1096、:1100、:1104、:1107、:1112-1115、:1125）：
`EXT_REDEEM_REQ` / `EXT_REDEEM_ACK` / `CHAT_REDEEM_REQ` / `CHAT_REDEEM_ACK` / `REDPACKET_CLAIMED`
/ `PROFILE_UNLOCKED` / `CHANNEL_SUB_ACK`
/ `CREDIT_EXT_REDEEM_REQ` / `CREDIT_EXT_REDEEM_ACK` / `CREDIT_CHAT_REDEEM_REQ` / `CREDIT_CHAT_REDEEM_ACK`，
线上格式 `::popopx_sys::` + 大写名 + `::` + 载荷（`PopopxSysMarker.wireString(for:)` :1160，前缀常量 :1158）。
前五种是需求点名的；**第六种是按需求补的**（资料卡解锁回执在需求里被写成"静默通知"却没有对应名字），
理由与"只进不出、收到即删行、绝不落库为可见记录"的语义记在 `PROFILE_UNLOCKED` 那一格的注释里，
本文件第 9 节把它列为 deviation。**第七种 `CHANNEL_SUB_ACK` 是 2026-11-19 裁定点名的**
（需求 :88"向频道同步已核销凭证回执"那一格，见第 8 节第 7 条的关闭记录）：成员扣点签票成功后，
本机把 `::popopx_sys::CHANNEL_SUB_ACK::<chatInfoId>::<expiresAtMs>` 发回那条频道会话，
载荷 `"chatInfoId::expiresAtMs"`（`PopopxSilentSignalingRouter.swift:603`，载荷拼装那一句是 :607。上一条引用的旧行号是**上一版就已错位**（那一行是 `sendChannelAccess` 的 guard，不是 SUB_ACK），本轮按内容重推。
群/频道这一支的放行判据也从"只有 REDPACKET_CLAIMED"改成了 enum 上的计算属性
`acceptedInGroup`（:1131），两种回执 kinds 共用它，避免"两处各写一份白名单"。
"用完即删"是裁定过的方案：Swift 层不渲染 + ACK 后删行 + 一次性连接整条删除（`.full(notify: false)`，:341、:377）。
宿主侧三处闸（本轮重测行号，判据都只有 `PopopxSysMarker` 一份，`PopopxBadgeCreditsModels.swift:1157`）：
渲染抑制在**行**这一层 `ChatView.swift:2318-2325`（命中即 `Color.clear.frame(height: 0)`，
挂在行而不是气泡，因为终端排版与群里的行会绕过气泡）；会话列表预览 `ChatPreviewView.swift:301-307`
（信令常常正是该会话的最后一条，预览会把它念出来）；通知横幅 `NtfManager.swift:254-262`
（横幅在删行的 `Task` 之前**同步**发出，只靠删行赶不上）。
收信旁路在 `POPOPXAPI.swift:2785-2810`（三个处理器：徽章 `:2791`、服务号 `:2799`、服务器集群 `:2806`）。

**【内部】服务器集群配置的两种名字不在这十三个里。** `::popopx_sys::SERVER_CFG_V1`（下行）与
`::popopx_sys::SERVER_CFG_ACK`（上行回执）由 `Shared/Features/ServerConfigSync/` 自带语法，本轮实测三文件 1 299 行
（`PopopxServerClusterConfig.swift` 372 / `PopopxServerConfigStore.swift` 388 / `PopopxServerConfigSignalHandler.swift` 539）。
原因只有一个，且是结构性的：`PopopxCommerceSignalKind`（`PopopxBadgeCreditsModels.swift:1091-1134`，本轮重测 13 个 case）
经 `PopopxSysMarker.parse` 解析，而 parse 对载荷有硬顶 `maximumSignalPayloadCharacters` = 1 024（:47，强制于 :1177）——
注册进去不等于收得进来：4 主机加签名的帧超限即判否，判否的行不再是信令，会当普通文本渲染成气泡，
正是本特性必须永不出现的一屏。故抑制判据改为第四个 OR 项 `PopopxServerConfigWire.isControlText`
（`isSignalText`，重测 :1201-1204），三处闸照旧自动继承（本轮实测：`ChatView.swift:2328`、
`Shared/Views/ChatList/ChatPreviewView.swift:305`、`Shared/Model/NtfManager.swift:258`）。
判据**只看形状不看签名**：验不过的帧与验得过的帧隐藏得一模一样。
这里比既有的三路更宽，且是有意为之——`PopopxSysMarker.parse`（`PopopxBadgeCreditsModels.swift:1164-1180`）要求
载荷非空（:1176）且 ≤ 1 024（:1177），`PopopxEcoMarker.isControlText`（`PopopxEcoModels.swift:136-138`）要求 JSON
先解析成功，`PopopxEcoUplink.isUplinkText`（:186-190 → `isSendablePayload` :194-198）同样要求非空且有长度上限：
那三处里畸形或超限的行都**不**隐藏。本模块把「隐藏」与「载荷能不能解析」彻底脱钩，因为无感不能依赖解析成功；
空载荷也算这个形状（`::popopx_sys::SERVER_CFG_ACK::` 后面什么都不带也一样隐藏）——诚实的对端不会发它
（无载荷必然验签失败），但若把它当普通文本，"以我们语法开头的行永不成为消息"这句话就恰好在那一行上不成立。

该帧的作用与边界，审核口径逐条：
- 只有与本机已有 SMP 直连会话的对端、或群/广播频道里的同类行能触发它；两种来源**都删行、都可安装**
  （生成端第 1 层就是把整个签名信封群发，见 `WIRE.md:952`），但**只有 1:1 会话可以上行回执**：
  判据集中在一处 `PopopxServerConfigSignalHandler.owesReceipt(policy:source:)` = `policy.ack && source.maySendReceipt`，
  而 `Source.maySendReceipt` 只认 `chatType == .direct`。群内绝不发 `SERVER_CFG_ACK`（否则一次下发会变成
  面向该群每个成员会话的回执风暴）。staged 记录同时存 `chatType` 与 `chatId`，因为群与联系人的 `apiId`
  是两套编号、同号不同会话，裸号路由会把回执发进错误的会话。
- 必须 Ed25519 验签通过——**严格先验签、后解压**，压缩段在验签之前一个字节都不碰，所以伪造帧无论
  其载荷声称什么，一律死在 `.signatureNotVerifying`；必须落在 `popopx|popx_srv_cfg_v1|` 这个域前缀上
  （前像 = 域前缀 + 压缩段 base64url 的 ASCII，不含 `POPOPXCFG1-`、不含点、不含签名）；
  必须在有效期内（**有效期上限 30 天**：`exp - iat ≤ 2_592_000`，旧口径写的 400 天是错的）；
  主机名必须命中白名单：`.onion` 主机，或 `popopx.chat` / `popopx.im` 后缀。
  白名单与本机真正会拨号的名单严格相等：`Presets.hs:24 serverDomains = ["popopx.im"]`，出厂预设里的
  SMP / xftp / ntf / relay 行全部落在这两个域内，所以它**不新增任何信任**，只限制泄露签名钥的爆炸半径。
  早期版本还允许 `*.simplex.im`（那时上游主机仍在出厂预设里）；预设清空后这一条已随 iOS、Android、
  生成器三处同步删除——本机没有任何服务器会命中一条允许后缀时，它只剩风险。
  **白名单只覆盖本机真正会拨号的名单**（smp / xftp / ntf / relay）。`ice` 名单里的 TURN 主机只做形状校验：
  生成端对它不施加任何域名规则（`models.py:266-365`），而它自己发布的 cluster 里那条 TURN 写的是
  `turn.example.net`（`cluster.json:59`）——若在这里也查白名单，每一帧真帧都会因一个本机根本不会联系的
  主机被整帧拒绝，与它同批签发的 SMP 名单一起丢掉。将来把 `ice` 接进呼叫路径时（见裁定 B），
  域名这道闸必须落在拨号处，不能靠签发侧的名单兜底。
- **合并，绝不整表替换**：只增删本机制自己引入过的 URI，用户手工添加的行、XFTP 行、会话中继行、
  以及上游默认服务器（Core 自己的 `preset` 标记）一律不动；这三条都有单测断言。
- 应用前先把改动前的完整服务器表落盘（App Group 内 `popopx_server_config/rollback.json`，
  写入失败即拒绝应用），随后 3 秒 / 10 秒两次读取既有会话统计判断可达性；**只有出现肯定失败证据才回滚**，
  读不到数据（设备本就空闲）不做任何决定。回滚后该 `kid|seq` 进熔断清单，永不再试——熔断只压制那一代，
  不压制该钥的其它世代，这样运营侧签出的下一代修正名单仍能落地。
- 全程零 UI、零文案、本轮不写任何 `.lproj`；上行回执为明文 `::popopx_sys::SERVER_CFG_ACK::<seq>[::<bh>]`
  （旧的 base64(JSON{outcome,v}) 形式生成端恒判 `None`，`acked` 因此永久为 0），仅在帧里 `pol.ack` 为真且
  会话为 1:1 时发送，同一 `(kid, seq, chatType, chatId)` 只发一次。`bh` 是对**解压出来的 body 字节**求
  SHA-256 取前 16 位小写 hex（`sha256("")[:16] = e3b0c44298fc1c14` 是该算法的已知向量）；设备未安装的世代
  回执不带 `bh`，因为那半截是在声称"我装了这份字节"。**拒收不回执**：本契约的 ACK 文法没有任何原因位，
  给一个拒收帧回裸 `<seq>` 会被运营侧 `state.py` 记进 `acked`，那是谎报覆盖率而不是部分报告。
- 版本地板本轮实测解析值：`xcodebuild -showBuildSettings` 给 `IPHONEOS_DEPLOYMENT_TARGET = 17.0`
  （`project.pbxproj` 里 12 处写的是 `"$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)"`，值由工具链决定），
  三文件 0 处 `@available`，arm64 门禁在该地板下 0 error —— 这就是「没有用到超出地板的 API」的证明。
- 收到的行随即删除（`apiDeleteChatItems(mode: .cidmInternal)`），本机不保存该消息本身；
  持久化的只有每把钥的世代地板（`kid → seq`，永不递减）、熔断清单、本机制引入的 URI 清单、
  回滚快照、待回执记录，以及来不及应用时暂存的**原始段文本**（不存解码结果，晋升时重新验签，
  所以过期在等待期间照样生效）。
- **反降级地板的方向已定为单向抬高（裁定 F 已裁）**：`classify` 取 `max(本机该 kid 的地板, ms - 1)`
  （`PopopxServerConfigSignalHandler.swift:229`），`pol.ms` 因此只能抬安全基线、绝不把已应用的地板拉低。
  上一版取 `min(...)` 时，出厂配置里的 `min_seq: 1`（`cluster.json:210`）把每一次比较都算成 0，本机地板形同
  虚设——持生产私钥的一方可把任何尚未过期的旧世代重放回来重新安装。落盘的地板同时改为只增不减且限定在
  验签通过的那把钥（`revoke(kid:below:)`，`PopopxServerConfigStore.swift:276`），上面那句「永不递减」至此
  才成为事实。运营侧后果写清楚：`ms` 一旦被签高，只有更高的世代能越过它；生成端的编码器不会签出
  `ms > seq` 的帧（`WIRE.md:937-938`，`scripts/ios/server-config-mint.swift:362` 同样拒这种写法）。
- **锚点已是生产公钥，不再是 DEV placeholder**：`PopopxServerConfigTrust.signingPublicKeyHexes`
  （`PopopxServerClusterConfig.swift:385-387`）当前只有 `d3941ecfa89f4e6d916cebc103a79fe3b6dd37ca8bbbc2087f70d7dece5aab6e`
  一把，其 `kid = k-ad1dc5463a` 由 `sha256(32 字节公钥).hex[:10]` 现算（本轮复算：
  `python3 -c "import hashlib;print('k-'+hashlib.sha256(bytes.fromhex('<hex>')).hexdigest()[:10])"`），
  body 里的 `kid` 必须等于**验签成功那把钥**的 kid，所以载荷不能自选身份。私钥从未进入本仓库、本工作树
  或本会话——但它确实在本机：`~/popopx-prod-keys/cluster-ed25519.seed`（mode 600，65 字节 = 64 个 hex
  字符 + 换行）派生出的公钥逐字符等于上面那把锚点；mint 要的是 32 字节原始 seed，所以取证顺序是
  `xxd -r -p cluster-ed25519.seed > cluster-ed25519.raw && chmod 600` 再把 `--key` 指过去。后果写清楚：
  **用 DEV 私钥签的帧从此不被本 App 接受**，能造出本 App 认的帧的只剩持生产私钥的一方，而这一方包含这台开发机。
  正向验签仍只在仓库外证明（`/tmp/cfgcheck`，145/145 leg 全绿，且每条负例都由生成端自己的
  `wire.decode + validate_document` 判成同一拒绝原因；其中 `accept ice_offbrand_host` 与「off-brand 的 ICE
  主机连同它的名单一起保留」两条是上面那条 ICE 例外的执行证据——同一 body 交生成端 `from_wire` 也判
  accepted，所以这不是本机单方面放宽）。本轮进一步把三端放到**同一批字节**上对了一遍，
  这比单测更有说服力：用生产钥签生成端自己的 `cluster.json` entry 名单（`fill_temporary_ice` 填过 TURN）
  跑 `wire.encode` = 整帧 986 字符 / 段 957 / body 981 字节 / body hash `c61bc30468ade998`，同一帧交给本机
  编解码器 = **ACCEPTED**，六个 SMP 主机全部命中白名单，body hash 一字不差；摘掉那条 TURN 是
  870 / 841 / 848 与 `8b03214c2d0364e9`，同样 ACCEPTED。mint 复算同形帧 = 995 / 966，它打印的 body hash、
  服务 `wire.decode` 算出的、本机算出的三者相同（`1138504690e13f22`）。这轮也修掉了 mint 的三处不合规写法：
  指纹尾随的 `=` 必须在签名前去掉（生成端 `to_wire` 会 rstrip，留着 `=` 的 body 通不过它自己的重编码检查，
  `wire.py:318-320`），`ice` 对象的键名必须加引号（`{t:"turn"}` 不是合法 JSON，设备与生成端都会拒绝），
  以及补上 `to_wire` 会在凭据过期时发出的 `x` 字段（`models.py:239-247`）——在此之前工具签不出带过期时间的 TURN。
  最小帧（临时钥、单台 SMP）= 253 / 200 / 365 / 394。
  段上限 1 024 个 **unicode 标量**（计数单位本轮从字素簇改为标量，与生成端 `len` 对齐），签名段固定 86 字符，
  解压输出硬上限 65 536 字节（zip-bomb：超限、截断、尾部多余字节、校验和不符四种都有断言）。
  **仍未证的只剩**：真机上一次真实的下发 → 换服务器 → 探活 → 回滚全链路、群内投递的安装，
  以及 App Group 容器不可用时的降级路径。

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
一条**代码注释**里 —— `PopopxBadgeCreditsModels.swift:1667` 的 `comment: "never VPN"`，那是防复发标记本身。
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
  `zh-Hans.lproj/Localizable.strings:8039` 的一条译文值（键句 `This build bundles no analytics or crash-reporting SDK
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
`PopopxBadgeCreditsModels.swift:1708-1709`：（上一版记的 :1585-1592 在上一版就已经指错——那几行是错误枚举的 case，不是判据注释，本轮按内容重推到注释本身）
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
   written to the device Keychain only (`PopopxBadgeCreditsModels.swift:1449`,
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
   （`PopopxSilentSignalingRouter.swift:603`）把 `::popopx_sys::CHANNEL_SUB_ACK::<chatInfoId>::<expiresAtMs>`
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
   （`id/amount/note/sig`），实现加入 `n=<收件人份数>`（`PopopxBadgeCreditsModels.swift:848`、wireString :903）
   并把 `n` 纳入签名原文，因此改份数与改金额一样导致验签失败。多收件人是"一个红包发给 100 人"这条
   需求语义的必要承载，删不掉；但它是**协议字段的增加**，请在提交前确认这套 URI 不与其他客户端互操作。
2. **`popopx://gift` 的字段集是实现自定的**（需求只写了 `popopx://gift?...`）：
   `v/p/n/t/s`（徽章券 :629）与算力点礼品卡的 `v/a/n/t/s`（:740，`a` 是面额不是周期），`n` 在两种礼品卡里都是 base64url 的赠言，**与红包里的 `n`（收件人份数）不同义**。
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
   （`PopopxBadgeCreditsModels.swift:976`，字段名 :979，wireString :1034），签名原文是
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
        `sendChannelAccess`（:589）与频道页那一格（`PopopxGroupChatInfoView.swift:274`）读同一份，
        所以本机不是频道主/管理员就发不出这张卡。
     2. **接收端"必须在频道里"闸（已实现）**：气泡按 `context.isChannel` 分档
        （`PopopxCommerceCards.swift:572`，判据 = `GroupInfo.isChannel`
        = `publicGroup?.groupType == .channel`，`POPOPXChat/ChatTypes.swift:3064`、`:3233`；
        **不是** `ChatInfo.isChannel` 那个 `useRelays` 版本，后者对大型私群也为真）。
        伪造一张 `popopx://channel` 粘进单聊，会显示"这一条不在频道里"而**走不到扣点**。
        信息页那一格用同一个 `isChannel`，两处不可能给出不同答案。
     3. **签发密钥钉扎（已实现，覆盖面有限）**：付过一次之后本机那张票记下发卡公钥
        （`PopopxChannelSubscriptionTicket.issuerPublicKeyBase64URL`，`PopopxBadgeCreditsModels.swift:1306`）（上一版这处也是旧错位：:1275 在上一版是结构体的收尾括号，字段本身在 :1306），
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
   有 `.group` 那一档，但宿主侧 `ComposeView.swift:1543` 的 `popopxPacketDestination` **只认单聊联系人**，
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

- `PopopxNodeBadgeSku` 本轮落库时 **12 个 case**（第 15 轮加 `.credits5000` 后为 **13 个**，整表 `PopopxBadgeCreditsModels.swift:147`、case :148-163），新增 `.creditsGift100/500/2000`（现 :161-163）；
  `productId` 整表现 :167-183（三条 `com.popopx.credits.gift.*` 在 :179-181）；交付类型 `.creditGiftCard(amount)` 现 :203-205。
- 回退价现 :243-252 把礼品卡与自用档**并进同一臂**（:247-249：`.credits100, .creditsGift100 → "$1.99"`，5000 档不在任何并臂里），
  "转赠不额外收费"这句在代码里因此是真的，不是注释里的承诺。
- `PopopxStoreKit.storekit` 本轮落库时 12 个 identifier（本轮 +45 行），双向差集两个方向都是空集（附录第一条命令实测）；第 15 轮补 `credits.5000` 之后为 13，见 12.1。
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
  `.full(notify: false)` 删连接（:341、:377）+ ACK 后删行（:701），Swift 侧照旧不渲染（第 4 节那三处宿主闸）。
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
  `ComposeView.swift:1494` 只在单聊联系人**且该会话可发送**（`contact != nil && sendMsgEnabled`）时可用 → :1576-1581 打开 `PopopxCreditsStoreView(contactId:)`（挂载 :756-761）；
  带 `contactId` 时页面直接落在礼品卡段，卡面多一枚"在本会话发送"的按钮，因此**不新建第二个选会话的抽屉**。
  气泡侧 `PopopxCommerceCards.swift:63 / :72 / :86` 认出 `.creditGift`，宿主 `PopopxMessageBubble.swift:458` 分派。
- 徽章与算力点仍在两个页面；点数余额与礼品卡券包也各自一格，没有把商店并成付费墙的子页。

### 11.4 本轮修掉的三处既存缺陷（都不是本轮新写的功能代码）

1. `PopopxP2PVoucherVault.swift:172` 与 :185 两个家族过滤器**缺 `return`**：门禁日志只报了 `[#NoUsage]`
   （"结果未使用"）而没报硬错误，但 `swiftc -frontend -parse` 单独复现同一形状时是 "missing return"。
   后果是**卡包与徽章券列表都拿不到值**——界面照常渲染、列表恒空，属于"编译绿但功能死"那一类。补显式 `return` 后
   两条列表各自按家族返回（`creditVouchers` 只给 `isCreditVoucher` 为真的，`badgeVouchers` 取反）。
2. `ComposeView.swift:1582` 那个 `.photo/.camera/.file` 内层分派 switch 在新 case 后不穷尽（门禁第三条错误）：
   补 `break` 臂，保持"这三种之外由上面的分支处理"的原意，而不是把新 case 塞进去走文件选择器。
3. **普查脚本自身的假绿**：`NSLocalizedString(` 与键字面量分处两行时，上一版同行正则看不见它，
   于是"0 缺键 ×16"是假的——有 5 条键 × 16 目录 = 80 行根本没写进去。补写后重测为 0 缺键。
   其中一条 219 字符长句在源码里被拆成两段字面量（`PopopxBadgeCreditsModels.swift:1744-1746`：`creditsGiftCodeFootnote` 的 `NSLocalizedString(` 与两段字面量分处三行——上一版记的 :1675-1676 在上一版就已错位，那两行是 `creditsBalance` 与它的分组注释，本轮按内容重推到 `Paste this whole string` 这条），
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

## 12. 第 15 轮：5000 点自用包 + 发现页服务号 / Round 15 — the 5000-credit pack and the Discover service accounts (2026-11-21)

本轮把已完成的 Mac 宿主（`/Users/elliot/popopx-chat/PopopxMacNode`）的协议面接到 iOS 侧：第 13 个商店条目、
五个 Tab、发现页的 10 个官方服务号、`NODE_CMD` 静默信令、以及**应用内**的 30 天周期自动续订。
新代码 6 个文件全部在 `Shared/Features/Discover/`；`.pbxproj` 由用户在 Xcode 手工拖入（红线：脚本零改动），
本节最后实测时这 6 个文件名在 `POPOPX.xcodeproj/project.pbxproj` 里各 **0** 处引用 = **尚未拖入**，拖入后应各为 4 条
（复算：`for f in $(ls Shared/Features/Discover); do printf "%s=%s " "${f%.swift}" "$(grep -c "$f" POPOPX.xcodeproj/project.pbxproj)"; done`）。

### 12.1 新增自用包 `com.popopx.credits.5000`（3.1.1）

- 第 2 节表格第 10 行：Consumable、回退价 $69.99、**正好 5000 点**、无加赠、无礼品卡孪生。
- 代码与产物这一次是**先代码后产物**：`case credits5000`（Models :160）、identifier（:178）、回退价单臂（:250）
  上一轮就在，`.storekit` 里却没有这一条 —— 也就是说商店配置从未 offer 过这个商品。补条目之前，附录
  "13 个 SKU" 那条双向差集命令实测报 `code_only=['com.popopx.credits.5000']`；补之后
  `storekit=13 code=13 storekit_only=[] code_only=[]`（本轮实测，命令在附录）。
- 四档自用包在界面上取自**同一份清单**：`PopopxCreditPlan.packs`（Models :288-289）
  = `[credits100, credits500, credits2000, credits5000]`，`PopopxCreditsStoreView` 画的就是它，没有第二处硬写档位。

### 12.2 发现页与 30 天周期计费（3.1.1 与 3.1.2(c)）

**【审核可粘贴 · EN】**

> The Discover tab lists official service accounts that run on the user's own Mac; the app only talks to
> them over the same end-to-end encrypted chat it uses for people. Each service states its price per
> 30-day cycle before anything is charged, and the only way to pay is with Compute Credits that were
> themselves bought through Apple In-App Purchase. "Auto-renew" here is a feature of this app, not an
> Apple subscription: it debits only the user's own on-device credit balance, it never starts an App
> Store purchase and never touches the user's Apple Account payment method. If the balance is not enough
> the renewal is not attempted — the app notifies the user and the service pauses while keeping its
> settings. Auto-renew can be switched off for any single service at any time from its own detail page;
> there is no minimum term and no cancellation flow. No money and no credits move outside the app.

**【内部 · 中文口径】** 发现页列出的是**用户自己那台 Mac 上跑的官方服务号**，通信走既有的一对一加密会话，
App 不引入任何第三方服务器、不做**加密钱包 / 资产托管**、不做站外支付（界面里那格「算力点钱包」是
本机余额的标签，第 11 节之前就在，不是链上钱包，见 12.8）。付费只有一个入口：扣本机算力点余额，
而算力点只能经 Apple IAP 购买（见第 3 节）。"自动续订"是**应用内**的续订：它不发起 App Store 购买、
不碰用户 Apple Account 的付款方式；余额不足时**不扣**，只发一条本地通知并把该服务暂停（设置保留）。
任一服务都能随时在自己的详情页单独关掉自动续订，无合约期、无取消流程、无退款口径。

实现事实，每条都是本轮按内容重推的读数：

| 声明 | 证据 |
|---|---|
| 周期只有一个来源 | `DiscoverSubscriptionManager.swift:96` `cycleSeconds = 30 * 86_400`；界面标签、到期日、账本说明、剩余天数都从它派生，全仓再无第二处写 30 |
| 续订窗口 24 小时 | 同文件 `:97` `renewalWindowSeconds = 24 * 60 * 60` |
| 触发点只有两个 | `MainTabView.swift:227-228`（`scenePhase == .active`）与 `:230`（`onAppear`），两者都调 `onSceneActive()`；没有后台定时器（`:224-226` 注释记了原因） |
| 扣点只走一条路 | `DiscoverSubscriptionManager.swift:282`（开通）与 `:351`（续订）都调 `PopopxCreditsManager.shared.payForService(amount:note:)`；不足即抛 `.balanceShort`，**不回落成任何 Apple 扣款** |
| 缺口只通知、不静默 | 同文件 `:394-399` `postShortfallNotice(for:required:balance:_:inout:)`，随后保留设置地暂停（`:309` 的停止分支注明"dropping the row, keeping the inbox"） |
| 计量服务不给名义价 | `DiscoverCatalogModels.swift:208-228`：`PopopxNodeCycleCost` 只有 `.credits(Int)` 与 `.usageBased` 两臂，`renewalCredits` 对后者返回 **nil**（:217），续订引擎因此拿不到可扣的数字 |
| 10 个服务号的价 | `DiscoverCatalogModels.swift:311-323`：200 / 500 / 300 / 500 / 300 / 计量 / 100 / 100 / 200 / 200，与产品需求逐档一致；`edge_compute_mesh` 是唯一计量项，界面写"按任务结算，10% 协议费" |

### 12.3 服务号身份与宿主逐字符相同（ interoperability ）

`PopopxNodeServiceId`（`DiscoverCatalogModels.swift:234`）的 10 个 raw value 是宿主 `EngineKind`
（`MacNodeModels.swift:1208-1218`）的镜像：本轮实测 `host=10 mine=10`，**双向差集都是空集**
（命令见附录"服务号身份双向核对"）。宿主解析器对不认识的 `serviceId` 直接返回 nil
（`MacNodeModels.swift:128`），所以这 10 个字符串不是命名偏好，而是唯一互通面 —— 任何一方改名都会把
另一端变成"发出去、被丢掉"。

### 12.4 `NODE_CMD`：静默信令，不是聊天气泡

- 第 13 种信令 `case nodeCmd = "NODE_CMD"`（Models `:1125`），线上形式
  `::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}`（`DiscoverCatalogModels.swift:53`/`:56`/`:121`/`:126`）。
- 收到即被吃掉、不显示为文本行：`PopopxSilentSignalingRouter.swift:239` 的 `case .nodeCmd:` 把结果交给
  `DiscoverSubscriptionManager.recordInbound(command:now:)`（`DiscoverSubscriptionManager.swift:453`）再删行。
- 群组/频道里不接收：判据仍是 `acceptedInGroup` 那一份表（Models `:1131`），nodeCmd 不在其中，
  注释记了原因（`:1123`：一条节点命令只指向一台机器）。
- 发出只有一条路：`sendNodeCommand(_:toContactId:)`（`PopopxSilentSignalingRouter.swift:645` 拼装 wireString），
  调用点是 `DiscoverSubscriptionManager.swift:496`/`:510`。

### 12.5 Mac 节点配对：两条入口、一处契约

- **官方配对码** `PPXNODE1-<base64url(body)>.<base64url(sig)>`：解码与 Ed25519 验签在
  `PopopxNodePairingOffer.decode`（`DiscoverCatalogModels.swift:560`），载荷键 `v/node/key/link/iat/exp/once`
  逐条对齐宿主 `MacNodePopopxBridge.swift:605-620`。
- **相机在识别成功那一刻就停**：`metadataOutput` 把码交给主线程之前先 `stopCapture?()`
  （`MacNodePairingSheet.swift:532`），该闭包由 `makeUIView`（`:495`）接到 `view.teardown()`；
  另两条释放路径是 `dismantleUIView`（`:504`）与 `didMoveToWindow`（`:600`），三条都走同一个
  `teardown()`（定义 `:585`，`session.stopRunning()` 在 `:593`）。顺序是"摘图层 → 停会话 →
  摘输入输出 → 置 nil"，注释说明 `stopRunning` 会阻塞自己的队列。
  **这一条在上一版是假的**：识别回调里当时没有任何停止动作，只有文件头注释声称有；本轮把闭包接上之后
  代码与文档才第一次一致（编译门见 12.6，真机指示灯仍未验）。
- **桥接说明只读不连**：`PopopxDiscoverBridgePane`（`MacNodePairingSheet.swift:613`）呈现
  `127.0.0.1:18920` 与 `X-PPX-Token: $PPX_BRIDGE_SECRET · ?t=$PPX_BRIDGE_SECRET`（常量
  `DiscoverCatalogModels.swift:70-73`），界面上出现的永远是**变量名而不是秘密值**；
  App 不向该地址发起任何连接 —— 手机上这个地址是手机自己，:610-612 的注释记了这条判断。
- 绑定信息存 Keychain：三个新槽位 `popopx.commerce.discover-subscriptions` / `-node-binding` / `-inbox`
  （Models `:1437-1439`），可读性级别 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`；
  因为它们是 `PopopxCommerceKeychainSlot: CaseIterable` 的成员，胁迫码那条 `removeAll()` 会一并清掉，
  不需要也没有给发现页单独写一条清除路径。

### 12.6 本轮证据边界（不要越读）

- 现在**已证**：6 个新文件 `swiftc -frontend -parse` 全绿（rc=0、`error:` 0 条，逐文件）；源码零中文
  （CJK 计数 6/6 文件为 0）；SKU 双向差集 13↔13；服务号身份双向差集 10↔10；10 档价格与需求一致；
  184 条新键 × 16 本目录 = 2 944 行（`en.lproj` 依既有约定不动）。
  目录门同时证明 **196 条代码键 = 184 新 + 12 复用**、`unreferenced_new=0`（没有写进目录却没人引用的键）、
  `plutil -lint` 17/17、`git diff --numstat` 每本 **184/0**；红线词表门七个词族在 2 944 行里 **0 命中**，
  只有 `token`（宿主控制台凭据）与 `wallet`（既有余额叫法）两族命中并按 12.8 逐条裁定。
- **编译门（拖入 Target 之后跑了三次，附录第 (10) 条可复算读数）**
  - 第一次 clean（`build/gate_d15.log`，5 609 行）**没有过**：`error:` **30** 条、无 `BUILD SUCCEEDED`、
    我的新文件里 4 条 Swift warning。四类根因：`@State showsTopUp` 在同一个 struct 里声明两次
    （`DiscoverServiceRoomView.swift:29` 与旧 :100）；`DiscoverCopy.sendFailed` 跨文件重名且字面量还不同
    （`DiscoverCatalogModels.swift:749` ↔ 旧 `DiscoverServiceRoomView.swift:457`，后者改名 `commandNotDelivered`，
    两个键本来都在 16 本目录里，目录零改动）；两处把 `static let`（String）当函数调用
    （`activatedFormat` / `pairingSucceededFormat`，改成本仓库既有的 `String(format: …, …)`，见
    `PopopxAddFriendView.swift:603`）；`.accessibilityLiveRegion` 在本 SDK 的 SwiftUI 接口里 **0 命中**
    （`arm64e-apple-ios.swiftinterface` 实测），改用仓库既有的 `AccessibilityNotification.Announcement(…).post()`
    （先例 `ProfileCardBubbleView.swift:128-131`）。
  - 修复后的增量门（`build/gate_d15b.log`）：`** BUILD SUCCEEDED **` / `XCODEBUILD_EXIT=0` / `error:` **0** /
    295 次 `SwiftCompile` / 1 次 `Ld`；6 个新文件各在日志里出现 **4** 次。
  - 最终 clean 门（`build/gate_d15c.log`，5 505 行，就是交付那棵树）：`** BUILD SUCCEEDED **` /
    `XCODEBUILD_EXIT=0` / `error:` **0** / **555** 次 `SwiftCompile` / **16** 次 `Ld` / **101** 次 `CopyStringsFile`
    / 10 次 `CompileC`；6 个新文件仍各 **4** 次（= 这三次门禁真的编译了它们，不是 0 引用的空过）；
    主二进制 mtime 19:23:05 晚于日志起始 19:21，说明是重链而非复用旧产物。
  - 本轮**新增** Swift warning = **0**（那 4 条随修复消失）。全仓残留 Swift warning = **3 个坐标**，都在
    `Shared/Features/ServiceAccount/PopopxEcoRouterAndDeepLink.swift:334/:645/:646`
    （`main actor-isolated static property 'shared' can not be referenced from a nonisolated context`），
    `git blame` 三条都归 `c5c6c705ee`，本轮没碰过该目录（`git diff --numstat -- Shared/Features/ServiceAccount/` 为空）。
    原始命中 **19** 行的对账：8 行 `文件:行:列` 形式（同一坐标在多批次里重复：2+3+3）+ 8 行诊断树里的镜像行
    + 3 行 `appintentsmetadataprocessor … Metadata extraction skipped`（非 Swift）。
  - 签名设备构建（`build/device_d15b.log`，`-destination generic/platform=iOS -allowProvisioningUpdates`）：
    `** BUILD SUCCEEDED **` / `error:` 0，产物 `com.popopxchat.popopx`，
    `Apple Development: gang sun (RG6JMG38C8)` / Team `PDBA6XRBQT`，321 MB，留档
    `build/artifacts/POPOPX-D15-cb311aea8.app`（第一次 `-destination id=<UDID>` 那一次没建成：
    `xcodebuild: error: Timed out waiting for all destinations …` + `The tunnel connection failed`，见下条）。
- 现在**未证**：**真机安装与走查**（设备 `Device State: disconnected`，`devicectl` 报 CoreDeviceError 4
  `tunnel connection failed`，产物已备好等回线）、`POPOPX Snapshots` 测试目标、
  以及相机扫码 / Ed25519 验签 / Keychain 读写 / 本地通知 / StoreKit 购买这五处的真机行为。
- 特别一句：**30 天自动续订的"扣自己余额"这条路径，只到函数与调用点被证明存在为止。**
  没有任何一次真实扣点、也没有任何一次通知在设备上出现过。审核口径段（12.2）写的每一句都指向代码位置，
  不指向"已验证的行为"。

### 12.7 本轮 `file:NNN` 重推账

本轮改动 `PopopxBadgeCreditsModels.swift`（+32/−5）、`PopopxSilentSignalingRouter.swift`（+33/−0）、
`PopopxCreditsStoreView.swift`（+4/−3）、`MainTabView.swift`（+32/−3）之后，指向这 4 个文件的引用共
**24 处 / 18 个不同的 file:line**（附录那条计数命令可复算），另有 **17 处省略式 `:NNN`**（同段先点名文件、后面只写行号）——它们与被点名的引用是同一种测量，本轮一并按符号复算，**14 处在上一版就已错位**（`apiDeleteContact` :315/:351→**:341/:377**、`apiConnect` :366/:438→**:392/:464**、`apiAddContact` :400/:469→**:426/:495**、`apiSendMessages` :607→**:670**、`apiDeleteChatItems` :638→**:701**、`sendChannelAccess` :563→**:589**；HEAD 实测分别是 :328/:364、:379/:451、:413/:482、:637、:668、:576），**3 处是本轮的**（两枚 `fieldNames` :622/:733→**:629/:740** 随本轮 +7 改号，以及 `PopopxNodeCycleCost.renewalCredits` 的 nil 臂我在自己的新文件里写成 :219-220，真位 **:217**）。这 17 个号码与上面 24 个，全部由附录那条 SYM 表逐条 grep 断言，不靠人眼对表。

上一版这一节记的是"逐条按 HEAD 文本重推"，
本轮改成**按被引符号 grep 定位**（附录给命令）——这两件事不等价：对齐文本会把既有的错位原样搬下去。
重测结果：

- **8 处在上一版就已错位**（引用点在 HEAD 就对不上被引符号），本轮按符号改正，括号里是 HEAD 实测位：`acceptedInGroup` :1111→**:1131**（HEAD :1114）、两处 `.full(notify: false)` :315/:351→**:341/:377**（HEAD :328/:364）、`PopopxSysMarker` :1154→**:1157**（HEAD :1139）、`comment: "never VPN"` :1624→**:1667**（HEAD :1640，第 4 节与附录各一处）、文案分线判据注释 :1683-1685→**:1708-1709**（HEAD :1681-1682，那两行是判据注释，:1683 起是句子本身）、`enum PopopxCommerceKeychain` :1421→**:1449**（HEAD :1422）。
- 上一版列的"6 条既存错位"里，**5 条本轮 grep 复核仍然成立**：router :577→:603、Models :1275→:1306、
  :1675-1676→:1744-1746、SysMarker :1137/:1139→:1158/:1160；被本轮推翻的只有它给"分线判据注释"写的
  :1683-1685（HEAD 真位 :1681-1682），已并入上面那 8 条。
- **其余 16 处**只是随本轮插入改号或本来就对，逐条 grep 复核命中：Models :848/:976/:979/:1034/:1091-1134/:1306/:1744-1746、router :239/:589/:603/:607/:645、MainTabView :220/:221-222/:224。其中 :848/:976/:979/:1034/:1306/:1744-1746 这一组**上一版记的就已经是新值**——那是本轮插入把它们"搬对了"，不是上一版量准了；复算仍按符号名，不按号码。
- 一条**故意不改**：第 10 节里 `PopopxSilentSignalingRouter.swift:417:9: error: missing return …` 是从
  `gate_bc5.log` 抄下来的**历史报错原文**，那一行后来被改写，它不是指向当前树的锚点。
- 计数更正一条：第 4 节写"十一个静默信令种类"，HEAD 实测已是 12 个（`CHANNEL_PAY_RCPT` 漏在列表里），
  本轮加 `NODE_CMD` 为 13 个，逐条行号一并重推。
- 另有 4 处指向宿主的注释（`MacNodeModels.swift:64`/`:66-68`/`:100`/`40-55`）是**我自己写错的**，
  本轮对表宿主源码后改为 `:98-99`（lockTriggers）、`:57-58`+`:89-96`（console 契约）、`:101-102`（offer 有效期）、
  `:40`/`:44`/`:55`+`:58`/`:90`/`:93`/`:96`/`:102`；`Core/MacNodePopopxBridge.swift:586-617` 改成 `:586-620`。
  教训一句：**跨仓引用同样是测量，写之前必须打开对面那个文件。**
- **修复那 30 个错误之后的二次重推（同日，附录第 (7)(8)(9) 条复算）**：第二次改动只落在 6 个新文件里的 2 个 ——
  `MacNodePairingSheet.swift` 674→**685**（+11）、`DiscoverServiceRoomView.swift` 466→**464**（−2：那条重复的
  `@State` 与它**下面**那个空行一起删），其余 4 个文件全是同行改写（行数不变），总计 3 692→**3 701**。
  指向配对页的 7 个坐标因此位移，逐条按符号重推（不是统一 +11）：`context.coordinator.stopCapture` **:495**、
  `func dismantleUIView` **:504**、`stopCapture?()` **:532**、`func teardown` **:585**、`session.stopRunning` **:593**、
  `override func didMoveToWindow` **:600**、`struct PopopxDiscoverBridgePane` **:613**（12.5 的两条 bullet 已改成这组号码，
  那段"只读不连"注释的区间由 :599-601 变为 **:610-612**）。`DiscoverServiceRoomView.swift` 在**本轮之前**没有任何
  引用指进来（`grep -rn "DiscoverServiceRoomView\.swift:" Docs spec Shared POPOPX "Tests iOS"` 当时 = 0）；现在仅有的
  2 条是本节 12.6 描述这两处缺陷时新写的：`:29`（保留的那条 `@State`，删的是后面那条，未位移）与
  **旧** :457（那枚成员改名后现位 **:455**，声明处 `commandNotDelivered`，调用点 :113）。新文件侧共 **19 个锚点**，
  附录第 (9) 条断言 **mismatch 0**。
- 这一轮我自己的**两台仪器**各错一次，都记在这儿：
  ① 打印宿主区间时用了 `sed -n '85,110p' | grep -n . | awk '{print NR+84}'` —— `grep -n .` 会**跳过空行重新编号**，
     于是宿主的 `consoleHost/consoleTokenHeader/consoleTokenQuery` 被显示成 :88/:90/:92，我据此把本来**正确**的
     `:89-96` "改正"成 `:87-92`。裸 `grep -n` 实测真位是 **:90/:93/:96**，区间 `:89-96` 没错，已改回。
     **规则：区间打印只能用 `grep -n ""` 或 `awk 'NR>=a && NR<=b {print NR": "$0}'`，先 `grep -n .` 就废了行号。**
  ② 写进附录的第 (9) 条自己带了 `enumerate(…, 1)` 又加 `i + 1`，把 19 个锚点**全**报成 MISMATCH（整齐差 1）——
     文档号码是对的，检查器是错的。已在附录里改掉那一行、从文档抽出重跑，结果 19/19 OK。
     一句判据：**满盘同号的偏差先怀疑量具，不要先改被量的东西。**
- **26 条**跨仓引用（= 6 个新文件的注释 **19** 条 + 本文第 12 节 **7** 条；那 7 条里 §12.7 自己的账占 **3** 条，
  把量具的文字除外是 **23** 条——这一句本身又会加 1 条，所以两个数都写出来）用"区间首行不得为空行、区间不得全为空"
  这道门复算，**bad = 0**；其中 2 条被我另加的"区间必须含声明"判据标成 NO-DECL，打开对面原文看清它们指的是宿主的
  **guard 语句**（`MacNodeModels.swift:127-128` 与 `:128`），引用正确 —— 是判据不适用于这一类引用，不是文档 rot。
- §12.5 那句"相机在识别成功那一刻就停"**上一版是假的**：识别回调里当时没有任何停止动作，只有文件头注释声称有。
  本轮把 `stopCapture` 由 `makeUIView`（`:495`）接到 `teardown()` 并在交给主线程之前调用（`:532`）之后，
  代码与文档才第一次一致；**指示灯是否真灭仍未在设备上验**（见 12.6 最后一条）。

### 12.8 术语红线普查（暗网 / 挖矿 / 加密货币 / 无牌照 / 吹哨人 / 死亡遗嘱 / VPN 代理）

发现页把"控制台口令""按任务结算""余额"这几个词第一次带进新界面，所以本轮对**本轮 184 条新键的键面 +
16 本目录的值面**（184 × 16 = **2 944 行**，命令在附录「红线词表门」）跑了一次窄词界普查，逐族读数：

| 词族 | 命中 | 裁定 |
|---|---|---|
| 暗网 / dark web | **0** | — |
| 挖矿 / mining / miner | **0** | — |
| 无牌照 / unlicensed / 未持证 | **0** | — |
| 吹哨人 / whistleblower | **0** | — |
| 死亡遗嘱 / death will / testament | **0** | — |
| VPN / 专网 / 代理 / proxy | **0** | — |
| 加密货币族 crypto / coin / blockchain / bitcoin | **0** | — |
| `token` | 184 条英文键里 **2 条**（×16 = 32 行）；16 本值面里 **22 行**把 `token` 当技术词照抄；头名 `X-PPX-Token` **32 处** | **保留**（见下） |
| `wallet` | 184 条英文键里 **2 条**（×16 = 32 行）；值面只有 zh「钱包」2 行 + ja「ウォレット」2 行真译成钱包，de/fr/es/it/nl/pl/fi **一律译成余额**（Guthaben / solde / saldo） | **保留**（见下） |

- **`token` 无一指通证。** 那 2 条是配对指引里的**宿主控制台凭据**：一句写"宿主每次启动打印一枚新
  token，既当 `X-PPX-Token` 头也当 `t=` 查询项收"，一句是标签"Token header"。头名与查询项是宿主契约
  字面量（`DiscoverCatalogModels.swift:70-73` ↔ 宿主 `MacNodeModels.swift:89-96`），iOS 单方换词就是
  自断互通；译本保留 `token` 这个loanword 也是各语种技术词的常规做法。
- **`wallet` 不是本轮引入的词。** `Compute Credits wallet` 是 HEAD 就在的既有键
  （`PopopxMeView.swift:1139`，16 本目录都已有值），本轮那 2 条只是沿用同一个余额叫法；换成别的词，
  同一个界面里就会出现两种称呼。红线要挡的是**托管他人资产 / 链上钱包**，这两条说的都是本机余额读数。
  7 本欧洲目录自己就把值译成了"余额"，英文键面保留 wallet，这一层差异如实记在这里。
- 正因为上一条，12.2 里那句「不做钱包」是会被我们自己的界面反驳的，已改成
  「不做**加密钱包 / 资产托管**」并指向本节。
- 那条命令同时打印**出现级**与**行级**两个数：出现级 `token=101 / wallet=36`，行级 `token=54 / wallet=36`。
  差的 47 次是同一行里的同一个词根被数了两遍——英文原句既有 "a fresh token" 又带 `X-PPX-Token`，而
  `\btoken\b` 在连字符处也算一次词边界。本表和上面的裁定用的是**行级**；两种口径都写在这里，
  是为了复算的人不必先猜我数的是哪一种。
- 全库（不限本轮）另有既存 `SimpleX` / `VPN` 残留 ~12 个文件与 74 个上游缺键，属第 9 节与
  「需要你决定」清单，本轮未动。

---

## 附录：每条声明的复算命令 / Re-derivation appendix

```sh
cd apps/ios
# 规模与文件数
ls Shared/Features/BadgeCredits/*.swift | wc -l && wc -l Shared/Features/BadgeCredits/*.swift | tail -1
# 13 个 SKU：identifier 与 .storekit 双向核对（用工程真正引用的那一份，不是根目录那份重复副本）
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
#   PopopxBadgeCreditsModels.swift:1667 的 comment: "never VPN"（防复发标记本身）
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
```sh
# ——— 以下为第 12 轮（算力点礼品卡，2026-11-21）新增的复算命令 ———
# 13 个 SKU 与 .storekit 双向差集：storekit_only 与 code_only 都必须是空集
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
```

> 关于 `scripts/ios/localizations.py check`（本轮两种失败都实测过，都不是本特性引入）：
> - 在**仓库根**跑：它按 `apps/ios/**/*.lproj/*.strings` 递归，会把 `build/`、`product/` 里
>   **编译后的二进制 `.strings`** 也读进来，以 `UnicodeDecodeError: 0xd3` 崩掉。清理那些目录后才会通过。
> - 在 `apps/ios` 里跑：更危险——脚本里 `IOS_DIR = Path("apps/ios")` 是相对当前目录的路径，
>   于是它去解析 `apps/ios/apps/ios`，找不到任何目录，照样打印 **"No problems found." 并返回 0**。
>   这是一条**什么都没检查的绿色**，不能当作证据。
> 因此在带构建产物的工作区里，用上面那段只喂源目录的等价命令。

```sh
# ——— 以下为第 13 轮（发现页 / 30 天周期计费 / 第 13 个 SKU，2026-11-21）新增的复算命令 ———
# (1) 服务号身份双向核对：宿主 EngineKind 与 iOS PopopxNodeServiceId 的 raw value 必须是同一个集合
python3 - <<'PY'
import re
host = open('/Users/elliot/popopx-chat/PopopxMacNode/Sources/PopopxMacNode/Models/MacNodeModels.swift', encoding='utf-8').read()
mine = open('Shared/Features/Discover/DiscoverCatalogModels.swift', encoding='utf-8').read()
def band(src, head, tail):
    i = src.index(head); return src[i:src.index(tail, i)]
h = set(re.findall(r'case \w+ = "([a-z0-9_]+)"', band(host, 'enum EngineKind', 'public var id: String { rawValue }')))
m = set(re.findall(r'case \w+ = "([a-z0-9_]+)"', band(mine, 'enum PopopxNodeServiceId', 'var id: String { rawValue }')))
print('host=%d mine=%d host_only=%s mine_only=%s' % (len(h), len(m), sorted(h - m), sorted(m - h)))
PY
# (2) 目录门：196 条代码键 = 184 新 + 12 复用；184 条逐本齐备，且每条都被代码引用（无孤儿键）
python3 - <<'PY'
import re, glob, subprocess
lits = set()
for f in glob.glob('Shared/Features/Discover/*.swift'):
    s = open(f, encoding='utf-8').read()
    lits |= set(re.findall(r'key\(\s*"((?:[^"\\]|\\.)*)"\s*\)', s))
    lits |= set(re.findall(r'NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"', s))
added = [m.group(1) for m in re.finditer(r'^\+\s*"((?:[^"\\]|\\.)*)"\s*=',
         subprocess.run(['git', 'diff', '-U0', '--', 'zh-Hans.lproj/Localizable.strings'],
                        capture_output=True, text=True).stdout, re.M)]
new, reused = set(added) & lits, lits - set(added)
print('code=%d added=%d new=%d reused=%d  unreferenced_new=%d' % (len(lits), len(added), len(new), len(reused), len(set(added) - lits)))
for d in sorted(glob.glob('*.lproj')):
    if d == 'en.lproj': continue
    s = __import__('json').loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-', d + '/Localizable.strings'], capture_output=True, text=True).stdout)
    miss = [k for k in lits if k not in s]
    assert not miss, (d, miss[:3])
print('16 catalogs complete for all %d keys; en.lproj deliberately untouched' % len(lits))
PY
# (3) 红线词表门：本轮 184 条新键的键面 + 16 本值面（184 x 16 = 2 944 行）
python3 - <<'PY'
import re, glob, json, subprocess
keys = [m.group(1) for m in re.finditer(r'^\+\s*"((?:[^"\\]|\\.)*)"\s*=',
        subprocess.run(['git', 'diff', '-U0', '--', 'zh-Hans.lproj/Localizable.strings'], capture_output=True, text=True).stdout, re.M)]
fam = {'dark web': r'暗网|dark\s*web', 'mining': r'挖矿|\bmin(e|ing|er)\b', 'crypto': r'\bcrypto\w*|\bcoin\b|blockchain|bitcoin',
       'unlicensed': r'无牌照|未持证|unlicensed|unregulated', 'whistleblower': r'吹哨|whistleblow',
       'death will': r'死亡遗嘱|death\s*(will|testament)', 'vpn/proxy': r'\bVPN\b|专网|代理|\bprox(y|ies)\b',
       'token': r'\btokens?\b', 'wallet': r'\bwallet\b|钱包|ウォレット|Börse|portefeuille', 'bearer-credential': r'X-PPX-Token'}
rows = 0; hits = dict.fromkeys(fam, 0); tok_rows = wal_rows = 0
for d in sorted(glob.glob('*.lproj')):
    if d == 'en.lproj': continue
    s = json.loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-', d + '/Localizable.strings'], capture_output=True, text=True).stdout)
    for k in keys:
        rows += 1
        for f, pat in fam.items():
            hits[f] += len(re.findall(pat, s[k], re.I)) + len(re.findall(pat, k, re.I))
        tok_rows += bool(re.findall(fam['token'], s[k], re.I)) + bool(re.findall(fam['token'], k, re.I))
        wal_rows += bool(re.findall(fam['wallet'], s[k], re.I)) + bool(re.findall(fam['wallet'], k, re.I))
print('rows=%d' % rows, ' '.join('%s=%d' % (f, hits[f]) for f in fam))
print('occurrence 计数会重复数同一行：token 命中 %d 行、wallet 命中 %d 行（行级，键面+值面各计一次）' % (tok_rows, wal_rows))
PY
# (4) 锚点按符号复算：对齐 HEAD 文本会把既有错位搬下去（见 12.7），所以按被引符号名 grep
python3 - <<'PY'
import re, subprocess
doc = open('Docs/app-store-review-notes.md', encoding='utf-8').read()
F = {'Models': 'Shared/Features/BadgeCredits/PopopxBadgeCreditsModels.swift',
     'Router': 'Shared/Features/BadgeCredits/PopopxSilentSignalingRouter.swift',
     'MainTabView': 'Shared/Navigation/MainTabView.swift'}
cites = re.findall(r'(PopopxBadgeCreditsModels|PopopxSilentSignalingRouter|MainTabView)\.swift:(\d+)(?:-(\d+))?', doc)
print('citation occurrences=%d distinct=%d' % (len(cites), len(set(cites))))
SYM = [('Router', 670, 'await apiSendMessages('), ('Router', 701, 'try await apiDeleteChatItems('),
       ('Router', 392, 'await apiConnect('), ('Router', 464, 'await apiConnect('),
       ('Router', 426, 'await apiAddContact('), ('Router', 495, 'await apiAddContact('),
       ('Models', 629, 'fieldNames: Set<String> = ["v", "p", "n", "t", "s"]'),
       ('Models', 740, 'fieldNames: Set<String> = ["v", "a", "n", "t", "s"]'),
       ('Models', 1131, 'var acceptedInGroup: Bool {'), ('Models', 1157, 'enum PopopxSysMarker {'),
       ('Models', 1449, 'enum PopopxCommerceKeychain {'), ('Models', 1667, 'comment: "never VPN"'),
       ('Models', 1708, 'The amount is passed in by the caller'), ('Models', 1709, 'Hard-coding it into the sentence'),
       ('Router', 589, 'func sendChannelAccess'), ('Router', 603, 'func sendChannelSubscriptionAck'),
       ('Router', 341, 'apiDeleteContact(id: chatId, chatDeleteMode: .full'), ('Router', 377, 'apiDeleteContact(id: chatId, chatDeleteMode: .full')]
for who, want, needle in SYM:
    L = open(F[who], encoding='utf-8').read().split('\n')
    got = [i + 1 for i, l in enumerate(L) if needle in l]
    print('%-6s :%-5d %-42s -> grep %s %s' % (who, want, needle[:42], got, 'OK' if want in got else 'MISMATCH'))
    assert want in got, 'anchor mismatch'
PY
# (5) 纯字符门与语法门（6 个新文件）
grep -rn '[一-鿿]' Shared/Features/Discover/ | wc -l
xcrun swiftc -frontend -parse Shared/Features/Discover/*.swift && echo PARSE_RC=$?
```

```sh
# ══ 第 15 轮追加：Discover 侧的门（2026-11-21，都在 apps/ios 下执行）══
cd apps/ios

# (6) 拖入证据：6 个新文件各有 4 条工程引用；0 = 那次 BUILD SUCCEEDED 一个新文件都没编译
for f in Shared/Features/Discover/*.swift; do n=$(basename "$f"); printf "%s=%s " "${n%.swift}" "$(grep -c "$n" POPOPX.xcodeproj/project.pbxproj)"; done; echo

# (7) 第一轮 30 个错误的两类根因，编译之前就能抓：DiscoverCopy 跨文件重名 / 把 String 成员当函数调
python3 - <<'PY'
import re, os, collections
D = 'Shared/Features/Discover'
files = sorted(f for f in os.listdir(D) if f.endswith('.swift'))
src = {f: open(f'{D}/{f}', encoding='utf-8').read().splitlines() for f in files}
mem = collections.defaultdict(list)
for f, txt in src.items():
    blk = False
    for i, l in enumerate(txt, 1):
        if re.match(r'^(?:public )?(?:enum|extension|struct) DiscoverCopy\b', l): blk = True; continue
        if blk and re.match(r'^\}', l): blk = False; continue
        if blk:
            m = re.match(r'\s*(?:static )?(let|var|func)\s+(\w+)', l)
            if m: mem[m.group(2)].append((f, i, m.group(1)))
dups = {k: v for k, v in mem.items() if len(v) > 1}
print('DiscoverCopy members=%d dup=%s' % (len(mem), dups))
assert not dups, dups
nonfunc = {k for k, v in mem.items() if all(t != 'func' for _, _, t in v)}
bad = [f'{f}:{i} {m.group(1)}' for f, txt in src.items() for i, l in enumerate(txt, 1)
       for m in re.finditer(r'\b([a-z]\w*)\(', l)
       if m.group(1) in nonfunc and m.group(1) not in ('key', 'format', 'init', 'string')]
print('non-func called as function=%d %s' % (len(bad), bad[:6]))
assert not bad, bad
# 同一个 struct 里的重复存储属性（本轮那一处 @State showsTopUp 就是这类）
hits = []
for f, txt in src.items():
    cur, store = None, collections.defaultdict(list)
    def flush(cur=cur, store=store, f=f):
        for k, v in store.items():
            if len(v) > 1: hits.append(f'{f}::{cur}.{k} at {v}')
    for i, l in enumerate(txt, 1):
        s = re.match(r'^(?:public |private )?struct\s+(\w+)', l)
        if s:
            if cur: flush()
            cur, store = s.group(1), collections.defaultdict(list); continue
        if cur and (re.match(r'^\}', l) or re.match(r'^(?:public |private )?(?:extension|enum|class|final)\b', l)):
            flush(); cur = None; continue
        if cur:
            m = re.match(r'\s+(?:@State\s+|@AppStorage\([^)]*\)\s+|@Environment\([^)]*\)\s+)?(?:private |public )?(?:static )?(?:let|var)\s+(\w+)', l)
            if m: store[m.group(1)].append(i)
    if cur: flush()
print('dup stored properties=%d %s' % (len(hits), hits))
assert not hits, hits
PY

# (8) 跨仓引用普查：新文件注释与本文第 12 节里每一条 宿主文件:NNN(-NNN)，区间不得落在空行上
python3 - <<'PY'
import re, os
HOST = '/Users/elliot/popopx-chat/PopopxMacNode/Sources/PopopxMacNode'
paths = {'MacNodeModels': f'{HOST}/Models/MacNodeModels.swift',
         'TenBusinessEngines': f'{HOST}/Engines/TenBusinessEngines.swift',
         'MacNodePopopxBridge': f'{HOST}/Core/MacNodePopopxBridge.swift'}
cache = {k: open(v, encoding='utf-8').read().splitlines() for k, v in paths.items()}
pat = re.compile(r'\b(' + '|'.join(paths) + r')\.swift:(\d+)(?:-(\d+))?')
D = 'Shared/Features/Discover'
srcs = [(f, open(f'{D}/{f}', encoding='utf-8').read().splitlines())
        for f in sorted(os.listdir(D)) if f.endswith('.swift')]
doc = open('Docs/app-store-review-notes.md', encoding='utf-8').read().splitlines()
srcs.append(('Docs §12', doc[618:]))
n = bad = 0
for name, txt in srcs:
    for i, l in enumerate(txt, 1):
        for m in pat.finditer(l):
            n += 1
            host, a = m.group(1), int(m.group(2))
            b = int(m.group(3) or m.group(2))
            seg = cache[host][a - 1:b]
            if not seg or all(not s.strip() for s in seg) or not cache[host][a - 1].strip():
                bad += 1; print(f'  BAD {name}:{i} -> {host}:{a}-{b}')
print(f'cross-repo citations={n} bad={bad}')
assert bad == 0 and n >= 25, (bad, n)
PY

# (9) 新文件自身锚点按符号复算（本轮相机改动把这几条整体推了 +11 行）
python3 - <<'PY'
D = 'Shared/Features/Discover/'
SYM = [('MacNodePairingSheet.swift', 495, 'context.coordinator.stopCapture'),
       ('MacNodePairingSheet.swift', 504, 'func dismantleUIView'),
       ('MacNodePairingSheet.swift', 532, 'stopCapture?()'),
       ('MacNodePairingSheet.swift', 585, 'func teardown'),
       ('MacNodePairingSheet.swift', 593, 'session.stopRunning'),
       ('MacNodePairingSheet.swift', 600, 'override func didMoveToWindow'),
       ('MacNodePairingSheet.swift', 613, 'struct PopopxDiscoverBridgePane'),
       ('DiscoverSubscriptionManager.swift', 96, 'static let cycleSeconds'),
       ('DiscoverSubscriptionManager.swift', 282, 'payForService'),
       ('DiscoverSubscriptionManager.swift', 351, 'payForService'),
       ('DiscoverSubscriptionManager.swift', 453, 'func recordInbound'),
       ('DiscoverSubscriptionManager.swift', 496, 'sendNodeCommand'),
       ('DiscoverCatalogModels.swift', 53, 'static let commandPrefix'),
       ('DiscoverCatalogModels.swift', 56, 'static let segmentCount'),
       ('DiscoverCatalogModels.swift', 70, 'static let consoleHost'),
       ('DiscoverCatalogModels.swift', 208, 'enum PopopxNodeCycleCost'),
       ('DiscoverCatalogModels.swift', 234, 'enum PopopxNodeServiceId'),
       ('DiscoverCatalogModels.swift', 311, 'var cycleCost'),
       ('DiscoverCatalogModels.swift', 560, 'static func decode')]
bad = 0
for f, want, needle in SYM:
    got = [i for i, l in enumerate(open(D + f, encoding='utf-8').read().splitlines(), 1) if needle in l]
    print('%-30s :%-5d %-34s -> %s %s' % (f, want, needle[:34], got[:4], 'OK' if want in got else 'MISMATCH'))
    if want not in got: bad += 1
print(f'new-file anchors={len(SYM)} mismatch={bad}')
assert bad == 0, bad
PY

# (10) 干净设备门禁读数（日志名与本轮那一次一致）
L=build/gate_d15c.log
wc -l < $L; grep -c 'BUILD SUCCEEDED' $L; grep -c 'error: ' $L
grep -E '^/Users.*warning: ' $L | sed -E 's|^.*/apps/ios/||' | sort -u
printf 'SwiftCompile=%s Ld=%s CopyStringsFile=%s\n' "$(grep -c '^SwiftCompile ' $L)" "$(grep -c '^Ld ' $L)" "$(grep -c '^CopyStringsFile ' $L)"
for f in Shared/Features/Discover/*.swift; do n=$(basename "$f"); printf "%s=%s " "${n%.swift}" "$(grep -c "$n" $L)"; done; echo
```
