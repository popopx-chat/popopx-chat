//
//  ProfileCardBubbleView.swift
//  POPOPX (iOS)
//
//  【加密个人主页 · 模块四之一】会话里那一张名片卡片：它只报"这份主页现在处于哪一档"，
//  正文一个字都不在这里出现。
//
//  这一张卡片是**接收侧**的入口。挂载点在 `PopopxBubbleMount` 那一侧（由主工程师加
//  `case profile(PopopxProfilePayload, target: PopopxProfileReadKey)` 并路由过来），本文件的
//  `init` 形状与 `PopopxSecureBubbleMount`（PopopxMessageBubble.swift:430-432）逐格对齐：
//  载荷 + 定位键 + 收发方向 + 通道 + 那条消息的时间。
//
//  ### 卡片自己不带任何正文
//  名片的标题、副标题、文字块**只出现在阅读器里**这一句要打个折：标题 `manifest.title` 是
//  对端写的任意文本，它会原样上屏——这是产品要的（"张三 的名片"这种可辨识性就是这张卡片的全部
//  作用），但意味着隐私档的卡片也带着对端写的标题。隐私档真正不进气泡的是正文与媒体原件。
//
//  ### 卡片不自己判"过期"，它只做三件投影
//  1. 读 `ProfileStorageManager.readState(_:ttlSeconds:now:)`（actor，所以走 `.task`）。
//  2. 叠两条只有展示层才知道的规则：**24 小时未读的兜底**（`unreadAutoBurnAfter`，见下面那条注释），
//     以及本会话内已焚键的账（`ProfileReaderHost.isBurned`——销毁路径会 `forgetRead`，
//     记录一没，`readState` 就回到 `.unread`，不接这一手卡片会重新长出"未点开"）。
//  3. 把相位画出来。判据本身（墙钟、回拨、上取整）全在存储层，这里一条都不重写。
//
//  ### 为什么每张卡片都要问一把钟，以及为什么它不贵
//  `readState` 是一次 actor 跳 + 一次内存表读（`ProfileStorageManager` 把状态表缓在内存里，
//  见其 :477-493），而它自己在文件头就写明"阅读计时会被气泡每秒问一次"。计时中每 1 秒问一次、
//  未点开每 2 秒问一次、已焚毁就停表；`.task` 在视图消失时自动取消，所以看不见的行一次都不问。
//  常驻档与出站档**完全不问**这把钟——`readState` 只对 `.ephemeral` 有意义（:520-523 那条门禁）。
//
//  ### 卡片自己管自己的表面颜色
//  `PopopxBubbleInk` 在气泡文件里是 `private`（:475），跨文件拿不到——这条是实测而不是猜的，
//  `PopopxSecureCardBubble` 在 PopopxSecureSheetView.swift:448-452 记的是同一件事。所以这里
//  自带一套固定表面常量，而不是接气泡的墨。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖进 POPOPX (iOS) target —— 红线禁止脚本改 project.pbxproj。
//

import SwiftUI
import UIKit

// MARK: - 会话里的名片卡片

/// 一条主页消息在会话里的那张卡片。
///
/// 整卡一个按钮：点开走 `ProfileReaderHost.shared.present(...)`，被拒一定给可见反馈（卡内一行说明
/// + 一次触觉），不静默。
@MainActor
struct ProfileCardBubbleView: View {
    /// 发出去但一直没人点开的隐私名片，多久按已过期展示。
    ///
    /// 这是**展示层策略**，所以常量落在本文件而不是存储层：`ProfileStorageManager` 的钟只在
    /// `firstOpenedAt` 存在之后才走（隐私语义是"打开后计时"），而产品不能允许一条阅后即焚
    /// 因为收件人从不点开就永远躺在会话里可读。阅读器那一侧引用的是同一个值
    ///（`ProfileReaderHost.openingClock`），两处不出现第二张表。
    static let unreadAutoBurnAfter: TimeInterval = 86_400

    let payload: PopopxProfilePayload
    /// 这一行的定位键。`nil` = 挂载点拿不到会话身份：卡片**不许**猜一个键去读别人的计时，
    /// 于是它画成不可点的"无法定位所属会话"。
    let target: PopopxProfileReadKey?
    let incoming: Bool
    let channel: PopopxBubbleChannel
    /// 那条消息的时间，只服务于上面那条 24 小时兜底。
    let createdAt: Date

    /// 卡片当前画哪一档。初值 `.pending`：`readState` 还没回话之前不许先画"未点开"，
    /// 否则一张已焚的卡片会在回话前的一帧里亮出"可打开"的门。
    @State private var phase: Phase = .pending
    /// 拒绝打开的那一句。留在卡内而不是飘一条 toast：气泡在列表里，toast 飘到屏幕顶就没了，
    /// 而这一句要用户在两秒后还看得见。
    @State private var refusal: String?
    /// 已经为这一档删过媒体了（视图实例内的去重，避免每次重绘都往存储层发一次删除）。
    @State private var didRemoveMedia = false
    /// 那一次"点开"的进行中请求。
    @State private var openTask: Task<Void, Never>?
    /// 本地账本：只为"这一张要不要先收钱"这一问服务，扣点全走它的方法，卡片自己不算余额。
    @State private var credits = PopopxCreditsManager.shared
    /// 解锁回执的唯一出口。卡片不自己拼信令文本——那是路由器那一层的职责。
    @State private var signaling = PopopxSilentSignalingRouter.shared
    /// 等用户点头的那一笔解锁。它是**唯一**的真值：弹窗的可见性由它派生（下面那个 Binding），
    /// 所以不存在"弹窗还在、键已经空了"或者反过来的中间帧。
    @State private var pendingUnlock: PopopxProfileReadKey?

    /// 卡片的可见相位。与 `PopopxProfileReadState` 不是一一对应：这里多了两条展示层规则
    /// （24 小时兜底、本会话已焚账），少了存储层的细节（起点时刻）。
    enum Phase: Hashable {
        case pending
        case sealed
        case counting(remainingSeconds: Int)
        case destroyed
        case unlocated
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                headline
                statusLine
                priceLine
                if let refusal {
                    refusalLine(refusal)
                }
            }
            .padding(.horizontal, PopopxMetrics.spaceM)
            .padding(.vertical, PopopxMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
            .background(surfaceFill)
            .overlay(
                RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                    .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isOpenable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier(incoming ? "popopx.bubble.profile" : "popopx.bubble.profile.outgoing")
        .popopxAnimation(PopopxSpring.fluid, value: phase, reduceMotion: reduceMotion)
        // `.task(id:)` 而不是裸 `.task`：载荷或定位键换了身份时必须停掉上一条钟。
        .task(id: PollIdentity(payload: payload, target: target)) { await poll() }
        // 被拒那一句出现的那一刻就要被读屏念出来。这里不用 live region：本 SDK 的 SwiftUI
        // 没有 `accessibilityLiveRegion`（实测 `xcrun -sdk iphonesimulator swiftc -typecheck`
        // 报 "no member"），而这一句是"内容变了但用户没碰屏幕"——正是播报通知的用途。
        // 同一句也已经并进 `accessibilityText`，所以焦点本来就在卡片上时重读标签也听得见。
        .onChange(of: refusal, initial: false) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .alert(Copy.unlockTitle, isPresented: unlockPromptShown) {
            Button(Copy.unlockConfirm(unlockPrice)) { confirmUnlock() }
            Button(Copy.unlockCancel, role: .cancel) {}
        } message: {
            Text(Copy.unlockMessage(price: unlockPrice, balance: credits.balance))
        }
    }

    /// `.task(id:)` 要的身份值。元组不能符合 `Equatable`（Swift 的元组不参与协议一致性），
    /// 所以载荷与定位键各带一份——两者都是 `Hashable`。
    private struct PollIdentity: Equatable {
        let payload: PopopxProfilePayload
        let target: PopopxProfileReadKey?
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: 版面

    private var headline: some View {
        HStack(spacing: PopopxMetrics.spaceS) {
            Image(systemName: markSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(markInk)
                .frame(width: PopopxMetrics.space2XL - PopopxMetrics.spaceS)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(title)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(ink)
                    .lineLimit(2)
                badge
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            trailingMark
        }
    }

    /// 徽章。三档互斥：隐私档 = 锁盾 + 限时；常驻 + 全媒体 = 深靛紫；常驻（或降级）+ 厢语纯文字 = 青绿。
    private var badge: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: badgeSymbol)
                .font(PopopxType.microTag)
                .accessibilityHidden(true)
            Text(badgeText)
                .font(PopopxType.microTag)
                .lineLimit(1)
        }
        .foregroundStyle(badgeInk)
        .padding(.vertical, PopopxMetrics.space2XS)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .background(badgeFill, in: .rect(cornerRadius: PopopxMetrics.radiusChip, style: .continuous))
    }

    @ViewBuilder private var trailingMark: some View {
        if isOpenable {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryInk)
                .accessibilityHidden(true)
        } else {
            // 打不开的一档不留箭头：一枚指向自己的箭头会承诺一个并不存在的动作。
            EmptyView()
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .pending:
            line(Copy.loading, ink: secondaryInk)
        case .sealed:
            line(payload.isEphemeral ? Copy.ephemeralUnopened(payload.ttlText) : Copy.standardHint, ink: secondaryInk)
        case let .counting(remaining):
            line(Copy.counting(remaining), ink: remaining <= 5 ? PopopxPalette.danger : secondaryInk)
        case .destroyed:
            line(Copy.destroyed, ink: secondaryInk)
        case .unlocated:
            line(Copy.unlocated, ink: secondaryInk)
        }
    }

    /// 收费那一档在卡片上的预告。只在那一笔还没付时出现：解锁过之后再写一遍就成了承诺第二次收费。
    /// 用品牌色而不是次要灰 —— 这一行要回答的是"点下去会发生什么"，它是这张卡当前最重要的一句事实。
    @ViewBuilder private var priceLine: some View {
        if unlockRequired, let price = payload.manifest.unlockCredits {
            line(Copy.price(price), ink: PopopxPalette.brand)
        }
    }

    private func line(_ text: String, ink: Color) -> some View {
        Text(text)
            .font(PopopxType.caption)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refusalLine(_ text: String) -> some View {
        Label {
            Text(text)
                .font(PopopxType.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.shield")
        }
        .foregroundStyle(PopopxSurface.dangerInk)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 文案取值

    private var title: String {
        let collapsed = payload.manifest.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? Copy.untitled : collapsed
    }

    private var badgeText: String {
        switch phase {
        case .destroyed:
            return Copy.destroyedBadge
        case .unlocated:
            return payload.manifest.sendMode.cardLabel
        case .pending, .sealed, .counting:
            if payload.isEphemeral { return Copy.ephemeralBadge }
            return payload.manifest.deliveryMode.badgeLabel
        }
    }

    private var badgeSymbol: String {
        if phase == .destroyed { return "flame" }
        return payload.isEphemeral
            ? "lock.shield.fill"
            : (payload.manifest.deliveryMode == .fullMedia ? "person.text.rectangle" : "antenna.radiowaves.left.and.right")
    }

    private var markSymbol: String {
        switch phase {
        case .destroyed: return "flame"
        case .unlocated: return "questionmark.folder"
        case .pending, .sealed, .counting:
            return payload.isEphemeral ? "lock.shield.fill" : "person.text.rectangle.fill"
        }
    }

    // MARK: 表面与墨

    /// 隐私档用固定的深靛紫面（这份卡片和绝密那一档一样是"要走过去才看得见"的门），
    /// 常驻档用随模式翻转的卡面（它就是一份能被反复查阅的东西，不该长得像保险柜）。
    private var surfaceFill: Color {
        payload.isEphemeral ? PopopxSurface.ephemeralFill : PopopxPalette.card
    }

    private var ink: Color {
        payload.isEphemeral ? PopopxSurface.ink : PopopxPalette.label
    }

    private var secondaryInk: Color {
        payload.isEphemeral ? PopopxSurface.inkSecondary : PopopxPalette.labelSecondary
    }

    private var markInk: Color {
        if phase == .destroyed { return PopopxSurface.inkTertiary }
        return payload.isEphemeral ? PopopxPalette.brand : PopopxPalette.labelSecondary
    }

    private var badgeFill: Color {
        if phase == .destroyed { return Color.popopx(0xFFFFFF, opacity: 0.10) }
        if payload.isEphemeral { return PopopxPalette.brand }
        switch payload.manifest.deliveryMode {
        case .fullMedia:
            // 直接用调色板那一支，不在这里重写一遍十六进制：卡片与气泡的靛紫必须是同一个值。
            return PopopxPalette.brand
        case .meshTextOnly:
            return PopopxPalette.mesh
        }
    }

    private var badgeInk: Color {
        if phase == .destroyed { return PopopxSurface.inkSecondary }
        if payload.isEphemeral { return PopopxPalette.onBrand }
        switch payload.manifest.deliveryMode {
        case .fullMedia:
            return PopopxPalette.onBrand
        case .meshTextOnly:
            // 青绿当底时必须换深色墨：`mesh` 上叠白字只有 2.98:1（PopopxTheme.swift:82-85 的同一判据）。
            return PopopxPalette.onMesh
        }
    }

    // MARK: 可达性与判据

    /// 只有"未点开 / 计时中"这两档能点开。已焚毁与定位不到一律不可点。
    private var isOpenable: Bool {
        guard target != nil else { return false }
        switch phase {
        case .sealed, .counting: return true
        case .pending, .destroyed, .unlocated: return false
        }
    }

    /// 这一张现在要不要先收钱。判据只有本地账本那一格：`hasUnlocked` 按（谁的哪张、哪个会话、哪一行）
    /// 三个字段一起查，所以"在别的会话里解锁过"不会被当成这里也付过了。
    private var unlockRequired: Bool {
        guard let price = payload.manifest.unlockCredits, price > 0, let key = target else { return false }
        return !credits.hasUnlocked(profileId: payload.manifest.profileId, chatId: key.chatId, itemId: key.itemId)
    }

    /// 弹窗上要写的价。它只在 `pendingUnlock != nil` 期间被读，而那个键只可能由 `open()` 在
    /// `unlockCredits > 0` 那一支里设起来，所以这里不需要再判一次存在性。
    private var unlockPrice: Int { payload.manifest.unlockCredits ?? 0 }

    /// 弹窗的可见性不另存一格真值：读 `pendingUnlock`，关掉时把它清空。
    /// 两处各存一份的话，"弹窗还在但键已经空了"那一帧会让确认按钮拿不到落点。
    private var unlockPromptShown: Binding<Bool> {
        Binding(
            get: { pendingUnlock != nil },
            set: { shown in if !shown { pendingUnlock = nil } }
        )
    }

    private var accessibilityText: String {
        var parts: [String] = []
        parts.append(payload.isEphemeral ? Copy.modeEphemeral : Copy.modeStandard)
        parts.append(title)
        switch phase {
        case .pending: parts.append(Copy.loading)
        case .sealed: parts.append(payload.isEphemeral ? payload.ttlText : Copy.standardHint)
        case let .counting(remaining): parts.append(Copy.countingSpoken(remaining))
        case .destroyed: parts.append(Copy.destroyed)
        case .unlocated: parts.append(Copy.unlocated)
        }
        if let channelSpoken { parts.append(channelSpoken) }
        // 收费那一档也是这张卡的一部分：读屏要先把价念出来，才轮到"点开"那句提示。
        if unlockRequired, let price = payload.manifest.unlockCredits { parts.append(Copy.price(price)) }
        // 卡内那行拒绝理由同样是这张卡的一部分（整卡一个无障碍元素，子视图被 ignore）。
        if let refusal { parts.append(refusal) }
        return parts.joined(separator: "，")
    }

    private var accessibilityHint: String {
        guard isOpenable else { return "" }
        return incoming ? Copy.hintOpen : Copy.hintOpenOutgoing
    }

    /// 通道那一句话。判据来自 `PopopxBubbleChannel` 的四档（PopopxMessageBubble.swift:53-62），
    /// 跳数不进这一句：角标已经在气泡的下沿把它打出来了，这里只说承载方式。
    private var channelSpoken: String? {
        switch channel {
        case .smp: return NSLocalizedString("Delivered online over the encrypted route", comment: "card accessibility, delivery channel")
        case .mesh: return NSLocalizedString("Delivered offline over the mesh", comment: "card accessibility, delivery channel")
        case .awaitingRelay: return NSLocalizedString("Still waiting in the relay queue", comment: "card accessibility, delivery channel")
        case .none: return nil
        }
    }

    // MARK: 交互

    private func open() {
        guard isOpenable, let key = target else { return }
        // 收费那一档先问钱，再谈打开：`present` 一上去就是阅读器前台，那时已经没有"用户还没点头"这条退路。
        // 判据用 `hasUnlocked` 而不是本视图的一格状态：同一张卡可以转发、可以在别的会话里再出现一次，
        // 而那三个字段（谁、哪个会话、哪一行）才是"这一次解锁付过钱没有"的完整答案。
        if let price = payload.manifest.unlockCredits, price > 0,
           !credits.hasUnlocked(profileId: payload.manifest.profileId, chatId: key.chatId, itemId: key.itemId) {
            refusal = nil
            pendingUnlock = key
            return
        }
        // 记在 `openTask` 上而不是随手丢掉：一次点击对应一个进行中的打开请求，
        // 重绘不该让它变成孤儿（视图身份换掉时 `.task` 会停掉轮询，这一条则由下一次点击接管）。
        openTask = Task {
            // 这里读 `isPresented` 只是为了给一次即时反馈；真正的互斥判据在 `present` 里面，
            // 那一判据才是唯一可信的来源（卡片这一读随时可能过期）。
            if ProfileReaderHost.shared.isPresented {
                refusal = PopopxProfilePresentFailure.sessionAlreadyOpen.reasonText
                PopopxHaptics.notice(.warning)
                return
            }
            refusal = nil
            let failure = await ProfileReaderHost.shared.present(
                payload: payload,
                target: key,
                incoming: incoming,
                createdAt: createdAt
            )
            if Task.isCancelled { return }
            if let failure {
                // 失败/被拒一定给可见反馈：一句卡内说明 + 一次触觉，绝不静默。
                refusal = failure.reasonText
                PopopxHaptics.notice(.warning)
            }
            // 点开了也要重读：卡片得立刻从"未点开"翻成"计时中"，而不是等下一拍。
            await pollOnce(key: key)
        }
    }

    /// 用户点头之后才扣点，扣成功了才打开。反过来就是"钱付了没看到内容"，是这一族里最难看的失败。
    ///
    /// 扣点这件事只有本地账本知道：`PopopxCreditsManager` 是唯一能改余额的东西，卡片不碰它的钱包，
    /// 只调这一个方法，于是"同一张卡点两次不会收两次钱"由 `unlockProfile` 里那三条 guard 一起保证。
    private func confirmUnlock() {
        guard let key = pendingUnlock, let price = payload.manifest.unlockCredits else { return }
        pendingUnlock = nil
        do {
            _ = try credits.unlockProfile(profileId: payload.manifest.profileId,
                                          chatId: key.chatId, itemId: key.itemId, price: price)
            PopopxHaptics.notice(.success)
            open()
            sendUnlockReceipt(key: key)
        } catch {
            // 一句卡内说明就够：`errorDescription` 那批句子本来就说清了"差多少点"，
            // 在这里再抄一遍余额只会给出第二个数。
            refusal = Copy.unlockFailed(error.localizedDescription)
            PopopxHaptics.notice(.error)
        }
    }

    /// 解锁回执：告诉主页主人"这张名片被解开了"。它是五种既有静默信令之外补的第六种
    /// （`PopopxCommerceSignalKind.profileUnlocked`），只进不出——收的一侧删行、不动任何界面。
    ///
    /// **尽力而为**：钱已扣、内容已开，这一条发不出去不影响这一笔，所以既不重试也不告诉用户。
    /// 排在 `open()` 之后：回执不该推迟阅读器第一帧。
    ///
    /// 两道 gate 都是必须的，不是保险丝：
    /// - `incoming`：出站那一格是我自己发出的名片，"查看的人"在对端设备上，这里没有可通知的对象。
    /// - `getContactChat`：`PopopxProfileReadKey.chatId` 在群聊里装的是**群号**，而落点要的是
    ///   **联系人号**，两套编号各自从 1 往上排、完全可能撞成同一个数。拿群号当 contactId 会把这条
    ///   机器行发给一个毫不相干的人，所以宁可少发一条：少一条回执只是主页主人不知道，
    ///   发错人则是在别人的会话里多出一行谁都不会看见的东西。
    private func sendUnlockReceipt(key: PopopxProfileReadKey) {
        guard incoming, ChatModel.shared.getContactChat(key.chatId) != nil else { return }
        let profileId = payload.manifest.profileId
        Task { _ = await signaling.sendProfileUnlockReceipt(profileId: profileId, contactId: key.chatId) }
    }

    // MARK: 钟

    /// 相位轮询。`.task(id:)` 的生命周期就是它的生命周期：视图消失即停表。
    private func poll() async {
        guard payload.isEphemeral, incoming else {
            // 常驻档与出站档都不问这把钟：前者没有钟，后者的钟在对方设备上。
            phase = target == nil ? .unlocated : .sealed
            return
        }
        guard let key = target else {
            phase = .unlocated
            return
        }
        while !Task.isCancelled {
            await pollOnce(key: key)
            if Task.isCancelled { return }
            switch phase {
            case .destroyed:
                await removeMediaIfNeeded()
                return
            case .counting:
                try? await Task.sleep(for: .seconds(1))
            case .sealed, .pending:
                // 未点开也要留一拍：24 小时兜底、以及阅读器里焚完之后那一格翻转，
                // 都只能靠重读看见。2 秒足够，且看不见的行压根不会走到这里。
                try? await Task.sleep(for: .seconds(2))
            case .unlocated:
                return
            }
        }
    }

    /// 读一次状态并把两条展示层规则叠上去。
    private func pollOnce(key: PopopxProfileReadKey) async {
        let now = Date()
        let state = await ProfileStorageManager.shared.readState(key, ttlSeconds: payload.manifest.ttlSeconds, now: now)
        if Task.isCancelled { return }
        phase = project(state, now: now)
    }

    private func project(_ state: PopopxProfileReadState, now: Date) -> Phase {
        guard let key = target else { return .unlocated }
        // 本会话内焚过就是焚了：销毁路径 `forgetRead` 之后 `readState` 会退回 `.unread`，
        // 不接这一手，卡片会重新长出"未点开"那一扇门。
        if ProfileReaderHost.shared.isBurned(key) { return .destroyed }
        if state.blocksReading { return .destroyed }
        switch state {
        case .unread:
            // 24 小时未读的兜底：按已过期展示，而不是继续给人一扇能推开的门。
            if now.timeIntervalSince1970 - createdAt.timeIntervalSince1970 > Self.unreadAutoBurnAfter {
                return .destroyed
            }
            return .sealed
        case let .counting(_, remaining):
            return remaining > 0 ? .counting(remainingSeconds: remaining) : .destroyed
        case .expired, .clockRewound:
            return .destroyed
        }
    }

    /// 过期卡片把关联媒体删掉（"对端已焚"的展示态必须是真的，不留一份还能翻出来的原件）。
    ///
    /// 只在收件方向删，而且**不**调 `forgetRead`：阅读记录是 `.expired` 这一格的唯一来源，
    /// 抹掉它卡片就会翻回"未点开"。销毁路径里那一次 `forgetRead` 归阅读器负责，
    /// 因为它同时会删掉 DB 那一行——卡片可没有那个上下文。
    private func removeMediaIfNeeded() async {
        guard incoming, !didRemoveMedia else { return }
        didRemoveMedia = true
        await ProfileStorageManager.shared.removeAllMedia(profileId: payload.manifest.profileId)
    }
}

// MARK: - 卡片的固定表面

/// 卡片这一格的表面色。名字与阅读器的那一套分开，是因为卡片要**跟随气泡的边**：
/// 它常驻列表，深浅两套都得验一遍对比，而阅读器那一屏的黑是恒定的。
private enum PopopxSurface {
    /// 隐私档的卡面：比绝密那一档浅一档，避免两张"要打开的门"在列表里长成同一枚控件。
    static let ephemeralFill = Color.popopx(light: 0x2A1B4C, dark: 0x1B1132)
    static let ink = Color.popopx(0xF4F4F6)
    static let inkSecondary = Color.popopx(0xA6A6B0)
    static let inkTertiary = Color.popopx(0x8A8A94)
    /// 拒绝说明那一句的红：卡面上用 `dangerInk`（`danger` 在深紫底上不保证对比）。
    static let dangerInk = Color.popopx(0xFF453A)
}

// MARK: - 文案

private enum Copy {
    static let untitled = NSLocalizedString("Untitled profile page", comment: "card title fallback")
    static let loading = NSLocalizedString("Reading this device's state…", comment: "card placeholder line")
    static let unlocated = NSLocalizedString("Cannot locate the chat this card belongs to", comment: "card state line")
    static let destroyed = NSLocalizedString("This card was destroyed; nothing is kept on this device", comment: "card state line")
    static let destroyedBadge = NSLocalizedString("Destroyed", comment: "card badge")
    static let ephemeralBadge = NSLocalizedString("Burn after reading", comment: "card badge")
    static let standardHint = NSLocalizedString("Permanent profile page · tap to read any time", comment: "card hint line")
    static let modeEphemeral = NSLocalizedString("Burn-after-reading card", comment: "card accessibility mode")
    static let modeStandard = NSLocalizedString("Permanent card", comment: "card accessibility mode")
    static let hintOpen = NSLocalizedString("Tap to open and read", comment: "card accessibility hint")
    static let hintOpenOutgoing = NSLocalizedString("Tap to view the copy you sent", comment: "card accessibility hint, outgoing")

    static func ephemeralUnopened(_ ttlText: String) -> String {
        String(format: NSLocalizedString("Burn after reading · open for %@", comment: "card state line"), ttlText)
    }

    static func counting(_ seconds: Int) -> String { String(format: NSLocalizedString("%lld seconds left for this read", comment: "card countdown"), seconds) }
    static func countingSpoken(_ seconds: Int) -> String { String(format: NSLocalizedString("Counting down, %lld seconds left", comment: "card countdown, spoken"), seconds) }

    // 收费那一档。数字直接插进句子里，不套 `PopopxCommerceCopy.creditsAmountFormat`：那一句是给
    // 全语种目录里的钱话用的，这两句按本地化裁定留在文件内，两处各抄一遍迟早对不上。
    static func price(_ value: Int) -> String { String(format: NSLocalizedString("Reading this costs %lld Compute Credits", comment: "card price line"), value) }
    static let unlockTitle = NSLocalizedString("Unlock this profile page", comment: "unlock alert title")
    static func unlockConfirm(_ value: Int) -> String { String(format: NSLocalizedString("Spend %lld Compute Credits", comment: "unlock alert button"), value) }
    static let unlockCancel = NSLocalizedString("Cancel", comment: "unlock alert button")
    static func unlockMessage(price: Int, balance: Int) -> String {
        String(format: NSLocalizedString("The sender set a gate of %1$lld Compute Credits on this copy; your balance is %2$lld Compute Credits. The unlock record is written only into this device's keychain.", comment: "unlock alert body"), price, balance)
    }
    static func unlockFailed(_ reason: String) -> String { String(format: NSLocalizedString("Not unlocked: %@", comment: "card refusal line"), reason) }
}

// MARK: - 预览

#if DEBUG
struct ProfileCardBubbleView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileCardBubbleView(
            payload: PopopxProfilePayload(manifest: .blank()),
            target: PopopxProfileReadKey(chatId: 1, itemId: 1),
            incoming: true,
            channel: .smp,
            createdAt: .now
        )
        .padding()
        .background(PopopxPalette.base)
    }
}
#endif
