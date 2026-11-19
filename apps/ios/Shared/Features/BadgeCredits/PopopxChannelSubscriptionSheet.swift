//  PopopxChannelSubscriptionSheet.swift
//
//  【第五阶段 · 8】付费频道的订阅确认弹窗：一次本机扣点，换一张带到期时间的本地准入凭证。
//
//  ### 这一页签的是本机凭证，它拦不住频道的分发，也不拦内容页
//  SimpleX 的频道是单向广播：能成为成员就收得到内容，Swift 侧没有"这条消息只发给付过点的人"
//  的接口，所以任何"付费才收得到"的说法都做不到。这一页做的是：按频道主发布的价扣一次点，
//  在本机钥匙串里签一张带到期时间的凭证，凭证决定的是**这台设备上**这一格算不算已订阅。
//
//  内容页也不拦：拦的话会走进死结——门槛只在频道里那条卡片上（没有服务端，成员这边唯一的价
//  来源就是那条消息），把频道内容挡住就等于把"如何知道要付多少、去哪儿付"一起挡住。
//  这一条与它的两种可能的出路都写在 `Docs/app-store-review-notes.md` 第 9 节第 7 条。
//
//  ### 频道主收不到核销回执
//  提示词还有一句"向频道同步已核销凭证回执"。要做这件事得新增一种跨端信令名，
//  而规范列出的只有 `EXT_REDEEM_REQ/ACK`、`CHAT_REDEEM_REQ/ACK`、`REDPACKET_CLAIMED` 五种
//  （见 `PopopxCommerceSignalKind`）。自己编一个第六种线上传输名，比不做更容易出问题：
//  对端旧版本会把它当普通文本显示在时间线上。所以本文件不做回执，并在边界文案里明说。
//  需要它的话，先定名，再在 `PopopxSilentSignalingRouter.observeIncoming` 里加一条分支。
//
//  ### 续订是叠加的
//  `subscribeToChannel` 在旧票的到期时间之上再加一格 `channelTicketSeconds`。
//  提前续费不该把没用完的天数丢掉——点数已经扣了，天数就是这笔钱对应的东西。
//  也因此这一页在凭证还有效时**不提供**续订按钮以外的任何"再买一次"入口：
//  已订阅状态下先看有效期，想续再续。
//
//  ### "免费频道"不发卡片
//  门槛的合法区间是 1 … `maximumCreditsThreshold`：发布页要 `price >= 1` 才可点（`canPublish`），
//  `PopopxChannelAccessPayload.make` 也拒绝 0，所以**这张卡片永远代表一笔真实的扣点**。
//  解析侧仍接受 `p=0`（`isPriceAuthorized` 的下界是 0），那是给"对方客户端发来一张 0 价卡"留的
//  兼容判据：这种卡照常渲染，这一页走 `price == 0` 那一格（"本频道免费"），既不扣点也不签票；
//  即便有人绕过界面直接调 `subscribeToChannel(price: 0)`，它的 `price >= 1` 守卫也会抛 `signalRejected`。
//  一个频道要免费，正确做法是不发卡片，而不是发一张 0 价卡。
//
//  ### 宿主入口（2026-11-19 裁定：必须接上，不留孤立面板）
//  到达这一页有两条真路径：① 频道里那条门槛卡片的"订阅/续订"（`PopopxChannelAccessBubble`）；
//  ② 频道详情页对频道主给的那一格发布页（本文件下半部的 `PopopxChannelThresholdView`，
//  挂载在 `PopopxGroupChatInfoView.subscriptionCard`，判据 `isChannel && isOwner`）。
//  成员那一侧的详情页只显示本机凭证，不给按钮：价格不在本机，在这里点"订阅"就是扣一笔没宣布过的钱。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import SwiftUI

struct PopopxChannelSubscriptionSheet: View {
    let channelId: String
    let channelTitle: String
    /// 频道主定的门槛（算力点/格）。0 表示免费。
    let price: Int
    /// 这条卡片的签名公钥，随票一起存本机：下一次遇到别的钥匙签的同频道卡片时用来判冲突
    /// （判据与它的覆盖面都写在 `PopopxCreditsManager.channelIssuerConflict`）。
    let issuerPublicKeyBase64URL: String
    /// 回执要回到哪个会话。nil 时不发回执——票据照旧成立，只是这程没人可通知。
    let receiptTarget: PopopxCommerceTarget?

    @Environment(\.dismiss) private var dismiss

    @State private var credits = PopopxCreditsManager.shared
    @State private var router = PopopxSilentSignalingRouter.shared
    /// 载入时取一次，订阅成功后换成新票。不每帧查：`ticket(forChannelId:)` 每次都要 `loadIfNeeded`。
    @State private var ticket: PopopxChannelSubscriptionTicket?
    @State private var stage: PopopxSubscriptionStage = .idle

    var body: some View {
        PopopxSheetContainer(PopopxCommerceCopy.channelSubscriptionTitle, subtitle: Copy.subtitle(channelTitle)) {
            content
        } footer: {
            footer
        }
        .task {
            credits.loadIfNeeded()
            ticket = credits.ticket(forChannelId: channelId)
        }
    }

    // MARK: 版面

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                if price == 0 {
                    PopopxSectionCard(Copy.freeTitle, footnote: Copy.freeFootnote) {
                        Text(verbatim: Copy.freeBody)
                            .font(PopopxType.secondary)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let ticket {
                    activeCard(ticket)
                } else {
                    priceCard
                    balanceCard
                }
                statusCard
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
    }

    private var priceCard: some View {
        PopopxSectionCard(Copy.priceTitle) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, price))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
                Text(verbatim: String(
                    format: PopopxCommerceCopy.channelSubscriptionPeriodFormat,
                    PopopxCommerceLimits.channelTicketSeconds / 86_400
                ))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var balanceCard: some View {
        PopopxSectionCard(Copy.balanceTitle) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: PopopxCommerceCopy.creditsBalance)
                    .font(PopopxType.secondary)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Spacer(minLength: PopopxMetrics.spaceS)
                Text(verbatim: String(format: PopopxCommerceCopy.creditsAmountFormat, credits.balance))
                    .font(PopopxType.metric)
                    .foregroundStyle(PopopxPalette.label)
            }
            if credits.balance < price {
                Divider().overlay(PopopxPalette.separator)
                Text(verbatim: String(format: PopopxCommerceCopy.errorInsufficientCreditsFormat, price, credits.balance))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activeCard(_ ticket: PopopxChannelSubscriptionTicket) -> some View {
        PopopxSectionCard(Copy.activeTitle, footnote: Copy.activeFootnote(PopopxCommerceFormat.date(ticket.expiresAtMs))) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(verbatim: Copy.activeUntil(PopopxCommerceFormat.date(ticket.expiresAtMs)))
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.successInk)
                Text(verbatim: String(
                    format: PopopxCommerceCopy.channelSubscriptionStackFormat,
                    PopopxCommerceLimits.channelTicketSeconds / 86_400
                ))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch stage {
        case .idle, .busy:
            boundariesCard
        case let .subscribed(ticket):
            PopopxSectionCard {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.successInk)
                        Text(verbatim: Copy.subscribedHeadline)
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.successInk)
                    }
                    Text(verbatim: Copy.subscribedUntil(PopopxCommerceFormat.date(ticket.expiresAtMs)))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .refused(error):
            PopopxSectionCard {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                        Image(systemName: "xmark.circle")
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.dangerInk)
                        Text(verbatim: Copy.refusedHeadline)
                            .font(PopopxType.emphasis)
                            .foregroundStyle(PopopxPalette.dangerInk)
                    }
                    Text(verbatim: gloss(error))
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var boundariesCard: some View {
        PopopxSectionCard(Copy.boundariesTitle, footnote: Copy.boundariesFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                bullet(Copy.boundaryOne)
                bullet(Copy.boundaryTwo)
                bullet(Copy.boundaryThree)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: "circle")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
                .frame(width: PopopxMetrics.spaceL, alignment: .leading)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 底栏

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if price > 0 {
                PopopxButton(Copy.subscribe(price), systemImage: "checkmark.seal",
                             isLoading: stage == .busy) {
                    await subscribe()
                }
                .disabled(!canSubscribe)
                if credits.balance < price {
                    // 不在这一页里塞充值面板：那一套价格表只在购买页有一份，两个地方各写一次就会各错一次。
                    // 所以"去充值"只是把这一页关掉——它下面就是购买页。
                    PopopxButton(Copy.topUp, role: .ghost) { dismiss() }
                }
            }
            PopopxButton(Copy.close, role: .ghost) { dismiss() }
        }
    }

    // MARK: 动作

    private var canSubscribe: Bool {
        price > 0 && stage != .busy && credits.balance >= price
    }

    private func subscribe() async {
        guard canSubscribe else { return }
        stage = .busy
        do {
            let issued = try credits.subscribeToChannel(
                channelId: channelId, channelTitle: channelTitle, price: price,
                issuerPublicKeyBase64URL: issuerPublicKeyBase64URL
            )
            ticket = issued
            stage = .subscribed(issued)
            PopopxHaptics.notice(.success)
            // 回执排在票据之后：点数已经扣了、凭证已经写进钥匙串了，这一条发不发得出去都不再改变结果。
            // 频道里订阅者能不能发言由核心的群设置决定，Swift 侧没有那个判据，所以这一条是尽力而为，
            // 失败也只留在日志里（`sendChannelSubscriptionAck`）。
            if let receiptTarget {
                _ = await router.sendChannelSubscriptionAck(
                    chatInfoId: channelId, expiresAtMs: issued.expiresAtMs, to: receiptTarget
                )
            }
        } catch let error as PopopxBadgeCreditsError {
            stage = .refused(error)
            PopopxHaptics.notice(.error)
        } catch {
            stage = .refused(.keychainUnavailable)
            PopopxHaptics.notice(.error)
        }
    }

    private func gloss(_ error: PopopxBadgeCreditsError) -> String {
        switch error {
        case let .insufficientCredits(balance, required): "还差 \(required - balance) 点。先去充值，充完再回这一页。"
        case .keychainUnavailable: Copy.glossKeychain
        case .signalRejected: Copy.glossRejected
        default: error.errorDescription ?? Copy.glossGeneric
        }
    }
}

// MARK: - 阶段

enum PopopxSubscriptionStage: Hashable {
    case idle
    case busy
    /// 已签发的那张票：面板因此能把真实的到期时间念给用户，而不是"30 天"这种约数。
    case subscribed(PopopxChannelSubscriptionTicket)
    case refused(PopopxBadgeCreditsError)
}

// MARK: - 文案

private extension PopopxChannelSubscriptionSheet {
    enum Copy {
        static func subtitle(_ name: String) -> String { "为「\(name)」订阅一次，凭证写在本机，到期前随时可看。" }
        static let freeTitle = "这个频道免费"
        static let freeFootnote = "这一条卡片上写的门槛是 0。"
        static let freeBody = "免费频道不需要点数，也不会留下任何流水——直接打开即可。"
        static let priceTitle = "订阅门槛"
        static let balanceTitle = "本机余额"
        static let activeTitle = "已订阅"
        static func activeFootnote(_ date: String) -> String { "凭证到 \(date) 到期，到期后这一页会重新要点数。" }
        static func activeUntil(_ date: String) -> String { "有效期至 \(date)" }
        static let subscribedHeadline = "凭证已签发"
        static func subscribedUntil(_ date: String) -> String { "有效期到 \(date)。历史记录与已收到的消息都不会因为到期而消失。" }
        static let boundariesTitle = "这几点先说清"
        static let boundariesFootnote = "只说这一层真能做到的部分。"
        static let boundaryOne = "凭证只存在这台设备的钥匙串里：没有服务端来核验它，也不需要。"
        static let boundaryTwo = "订阅成功会向频道补一条静默核销回执：它不显示、不弹提示，也没有点数进到频道主账上。"
        static let boundaryThree = "门槛守的是本机的准入，不改变频道本身能广播给谁。"
        static func subscribe(_ value: Int) -> String { "订阅 · 扣 \(value) 点" }
        static let topUp = "去充值"
        static let close = "关闭"
        static let refusedHeadline = "订阅没有成立"
        static let glossKeychain = "本机安全存储取不到，点数没有动过。"
        static let glossRejected = "这个门槛本机不接受（要么为 0，要么超出上限），点数没有动过。"
        static let glossGeneric = "这次没有完成，点数没有被扣走。"
    }
}

// MARK: - 频道主：发布门槛

/// 频道主这一侧的发布页。它存在的唯一理由：**成员那台设备上的价只能从频道里那一条消息来**。
/// 没有这一页，`PopopxChannelSubscriptionSheet` 的 `price` 就只能由客户端自己编，
/// 那就是"对着一个不存在的价扣钱"。所以这一页做的事只有一件：签一条门槛卡片发进频道。
///
/// 三条边界，界面上也照写：
/// - 发布 = 往频道里发一条**可见**消息（`PopopxSilentSignalingRouter.sendChannelAccess`），
///   不是静默信令，不删行；成员看得见价，才谈得上"知情"。
/// - 门槛改一次就发一条新卡片：本特性没有"更新已发出去的那一条"的机制，
///   旧卡片仍然指向旧价。成员点开哪一条，就按那一条的价扣点，那一条的签名也确实在保护这个价。
/// - 免费不发布：`price == 0` 时既没有扣款也没有流水，发一条"0 点"卡片只会多一条噪音。
struct PopopxChannelThresholdView: View {
    /// 门槛卡片发进哪个会话。频道在模型里就是 `useRelays` 的群会话，所以落点是 `.group`。
    let groupId: Int64
    let channelTitle: String

    @Environment(\.dismiss) private var dismiss

    @State private var router = PopopxSilentSignalingRouter.shared
    @State private var priceText = ""
    @State private var stage: PopopxThresholdStage = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceM) {
                editorCard
                boundariesCard
                statusCard
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.bottom, PopopxMetrics.spaceL)
        }
        .background(PopopxPalette.base)
        .navigationTitle(Copy.publishTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    // MARK: 版面

    private var editorCard: some View {
        PopopxSectionCard(Copy.editorTitle, footnote: Copy.editorFootnote(channelTitle)) {
            PopopxTextField(
                Copy.field,
                prompt: Copy.fieldPrompt,
                text: $priceText,
                systemImage: "circle.hexagongrid.fill",
                keyboard: .numberPad
            )
            .accessibilityIdentifier("popopx.channel.threshold")
            .disabled(stage == .busy)
            Text(verbatim: Copy.fieldNote(PopopxCommerceLimits.maximumCreditsThreshold,
                                          PopopxCommerceLimits.channelTicketSeconds / 86_400))
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton(Copy.publish, systemImage: "paperplane.fill",
                         isLoading: stage == .busy) {
                await publish()
            }
            .disabled(!canPublish)
        }
    }

    private var boundariesCard: some View {
        PopopxSectionCard(Copy.boundariesTitle, footnote: Copy.boundariesFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                bullet(Copy.boundaryOne)
                bullet(Copy.boundaryTwo)
                bullet(Copy.boundaryThree)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceS) {
            Image(systemName: "circle")
                .font(PopopxType.microTag)
                .foregroundStyle(PopopxPalette.labelHint)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch stage {
        case .idle, .busy:
            EmptyView()
        case let .published(payload):
            PopopxSectionCard(Copy.publishedTitle) {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    note(systemImage: "checkmark.seal.fill",
                         text: Copy.publishedBody(payload.price),
                         ink: PopopxPalette.successInk)
                    Text(verbatim: Copy.publishedHint)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .undelivered:
            PopopxSectionCard(Copy.failedTitle) {
                note(systemImage: "exclamationmark.arrow.circlepath",
                     text: Copy.undeliveredBody, ink: PopopxPalette.dangerInk)
            }
        case .refused:
            PopopxSectionCard(Copy.failedTitle) {
                note(systemImage: "key.slash", text: Copy.refusedBody, ink: PopopxPalette.dangerInk)
            }
        }
    }

    /// 一行结论：图标 + 一句话。`PopopxCommerceCardNote` 是卡片那个文件私有的，
    /// 为了复用一行的排版而把它的访问级别放开，会让两张卡片和这一页从此共享一个不能各自改的形状。
    private func note(systemImage: String, text: String, ink: Color) -> some View {
        HStack(alignment: .top, spacing: PopopxMetrics.spaceXS) {
            Image(systemName: systemImage)
                .font(PopopxType.emphasis)
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(PopopxType.caption)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: 动作

    /// 框里的字到数字只有一次换算：只认数字、超上限就贴到上限。
    /// 这与名片门槛那一格同一判据（`ProfileBuilderView` 的 `unlockCreditsText`），
    /// 两处各写一个数就会各错一次。
    private var price: Int {
        let entered = Int(priceText.filter(\.isNumber)) ?? 0
        return min(entered, PopopxCommerceLimits.maximumCreditsThreshold)
    }

    /// 角色判据走路由器那一份（`canPublishChannelThreshold`）：这一页的按钮和 `sendChannelAccess`
    /// 的守卫必须是同一个数，否则会出现"按得下去、发不出去"的第三种状态。
    private var canPublish: Bool {
        stage != .busy && price >= 1 && PopopxSilentSignalingRouter.canPublishChannelThreshold(groupId: groupId)
    }

    private func publish() async {
        guard canPublish else { return }
        stage = .busy
        guard let payload = PopopxChannelAccessPayload.make(
            price: price,
            publishedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        ) else {
            // 本机签名密钥取不到。这里没扣任何人的点，也不需要留什么待重投的单子。
            stage = .refused
            PopopxHaptics.notice(.error)
            return
        }
        if await router.sendChannelAccess(payload, to: .group(groupId)) {
            stage = .published(payload)
            PopopxHaptics.notice(.success)
        } else {
            stage = .undelivered
            PopopxHaptics.notice(.warning)
        }
    }
}

// MARK: - 发布阶段

enum PopopxThresholdStage: Hashable {
    case idle
    case busy
    /// 发出去的那张卡片：状态格里把真实的价念出来，而不是"已发布"三个字。
    case published(PopopxChannelAccessPayload)
    /// 消息没出去（SMP 那一侧没返回会话项）。门槛没有被改写，因为对端从没收到新价。
    case undelivered
    /// 本机签名密钥取不到，卡片根本没能签出来。
    case refused
}

// MARK: - 文案（发布页）

private extension PopopxChannelThresholdView {
    enum Copy {
        static let publishTitle = "订阅门槛"
        static let editorTitle = "成员订阅一次要多少算力点"
        static func editorFootnote(_ name: String) -> String { "发布到「\(name)」，成员在那条卡片上点订阅才扣点。" }
        static let field = "算力点"
        static let fieldPrompt = "留空 = 免费，不发布"
        static func fieldNote(_ maximum: Int, _ days: Int) -> String {
            "1 到 \(maximum) 之间的整数，一格 \(days) 天。留空或 0 表示免费：免费不必发卡片，也不会扣任何人的点。"
        }
        static let publish = "发布门槛"
        static let boundariesTitle = "这几点先说清"
        static let boundariesFootnote = "只说这一层真能做到的部分。"
        static let boundaryOne = "发布 = 往频道里发一条看得见的消息：价要让人看见，才谈得上知情。"
        static let boundaryTwo = "改一次就发一条新卡片，旧的不会跟着变：成员点到哪一条，就按那一条的价扣点。"
        static let boundaryThree = "成员订阅时频道里会多一条静默核销回执：它不显示，也不会给你转来任何点数。"
        static let publishedTitle = "已发布"
        static func publishedBody(_ price: Int) -> String { "门槛 \(price) 算力点 / 格已经发进频道。" }
        static let publishedHint = "成员那侧点这条卡片才会扣点；这一步不产生你的任何花费。"
        static let failedTitle = "没有发布成功"
        static let undeliveredBody = "消息没送出去：门槛没有被改写，因为对端从没收到新价。可以再按一次。"
        static let refusedBody = "本机签名密钥取不到，这张卡片没能签出来；点数没有动过。"
    }
}

// MARK: - Previews

struct PopopxChannelSubscriptionSheetDark_Previews: PreviewProvider {
    static var previews: some View {
        PopopxChannelSubscriptionSheet(channelId: "channel.preview", channelTitle: "夜航随笔", price: 200,
                                       issuerPublicKeyBase64URL: "preview.key", receiptTarget: nil)
            .preferredColorScheme(.dark)
    }
}

struct PopopxChannelSubscriptionSheetLight_Previews: PreviewProvider {
    static var previews: some View {
        PopopxChannelSubscriptionSheet(channelId: "channel.preview", channelTitle: "夜航随笔", price: 0,
                                       issuerPublicKeyBase64URL: "preview.key", receiptTarget: nil)
            .preferredColorScheme(.light)
    }
}

/// 发布页的预览停在 `.idle`：`stage` 是 `@State`，预览里没有钥匙串也没有 SMP，
/// 所以能给的只有版面本身（那三个结论格在真机上验，见审核说明的自测清单）。
struct PopopxChannelThresholdViewDark_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxChannelThresholdView(groupId: 2, channelTitle: "夜航随笔")
        }
        .preferredColorScheme(.dark)
    }
}

struct PopopxChannelThresholdViewLight_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxChannelThresholdView(groupId: 2, channelTitle: "夜航随笔")
        }
        .preferredColorScheme(.light)
    }
}
