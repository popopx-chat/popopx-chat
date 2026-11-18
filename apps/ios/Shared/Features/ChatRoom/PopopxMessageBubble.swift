//
//  PopopxMessageBubble.swift
//  POPOPX (iOS)
//
//  【第五阶段 · 1】现代对话流气泡 + 通道角标。
//
//  这个文件干三件事：
//  1. 把一条**已经定好性**的会话项画成一枚气泡：左（收方）`card` 卡面、右（发方在线）`brand` 实底，
//     外侧 16pt（`PopopxMetrics.radiusCard`），同发送者连续的那一角收紧为 4pt
//     （`PopopxMetrics.radiusBubbleTucked`）——Docs/popopx-brand-spec.md §2.1、§4。
//  2. 说清"这一条是经过哪条通道送达的"：靛紫 = SMP 公网，青绿 = 厢语离线 BLE Mesh（**必带跳数**），
//     灰时钟 = 还躺在 Mesh 中继队列里。语义分工是硬规则（§1.1），不是装饰。
//  3. 【发送位置】的渲染半边：本文件末尾的 `PopopxLocationCardBubble`——地图快照卡片，列表行里
//     只放**位图**，绝不放活的 `Map`/`MKMapView`（`location-prompt.md:72` 那条性能红线）。
//     载荷 `PopopxLocationPayload` 在隔壁 PopopxLocation.swift：发送侧（ComposeView）也要用它，
//     而那个文件一个 MapKit/CoreLocation 符号都不 import。两半边对同一串字节的一致性是
//     `wireString` ↔ `parse(from:)` 这一对函数的事，改任何一边都必须同时看另一边。
//
//  刻意不认识 `ChatItem`：所有值从入参进来（`PopopxBubbleItem`），环境不读全局。通道真值也不在这一层取——
//  `PopopxBubbleTransportResolver` 是挂载缝：host 一次读齐（`allMappings` + `pendingMessages` +
//  `recordedFlushedAppChatItemIDs` 共 3 个 actor hop，其余取自己已经在观察的 `@Published` 快照），
//  压成一张按 message key 索引的表，再逐行喂给气泡。**一行一次 await 是不允许的**
//  （ui-prompt.md 第五阶段"防参数丢失机制"：组件接口必须只吃调用方手里已有的值）。
//
//  配色契约（本文件逐条自查）：
//  - 发方气泡统一 `brand` 实底 + `onBrand` 墨；收方气泡统一 `card` 卡面 + `label` 墨。
//    通道区分交给右下角徽章：SMP = 靛紫锁，Mesh = 青绿波纹 + 跳数贴片，待中继 = 灰时钟。
//    外侧 16pt（`PopopxMetrics.radiusCard`），同发送者连续的那一角收紧为 4pt
//    （`PopopxMetrics.radiusBubbleTucked`）——Docs/popopx-brand-spec.md §2.1、§4。
//  - 实底气泡里的角标退化成"同一支墨"，绝不在靛底上画靛、青底上画青
//    （§1.1"同一条消息行、同一个气泡内不得混用紫与青"）。
//  - `mesh` 在卡面上只有 2.98:1，所以卡面上的青色**文字/图形**一律 `meshInk`（6.03:1）；
//    `mesh` 实底只用来做那块带 `onMesh` 数字的跳数贴片（§1.2 表 + PopopxCabinView.swift:825-837 同一画法）。
//  - `onBrand` 在 Dark 会翻成近黑（`#7D7AFF` 上白字只有 3.44:1，PopopxTheme.swift:66-71），所以本文件
//    从不假设"品牌底上放白字"。
//  - 红只出现在 SMP 投递失败那一枚符号上，取自现网同一判据（`CIItemStatus.statusIcon` 在这几个状态上
//    就给 `.red`，POPOPXChat/ChatTypes.swift:4622-4624）；撤回/待中继都不上红。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import SwiftUI
import UIKit
import CoreLocation
import MapKit
import POPOPXChat
import PopopxMeshKit
import PopopxMeshUI

// MARK: - 通道值

/// 这一条消息是经过哪条通道送达的。一行一个结论，画出来就是 `PopopxBadge`。
enum PopopxBubbleChannel: Hashable {
    /// SMP 公网承载：靛紫锁。
    case smp
    /// 厢语离线 BLE Mesh 承载。`hops` 是这条消息**当时**测到的跳数，0 = 邻居直接持有链路；
    /// 徽章必须把这个数打出来（§1.4 第 3 条），没有数字的青色贴片是违规画法。
    case mesh(hops: Int)
    /// 还压在 Mesh 中继队列里，一条都没出去：灰时钟。`reason` 是有就说的原因。
    case awaitingRelay(reason: PopopxBubbleQueueReason?)
    /// 这一行没有任何通道可承诺：系统行、本机笔记、表还没读出来。不画徽章，也不猜。
    case none

    /// 包里的合并时间线已经给这一行定过性，这里只换一套颜色语义的壳。
    /// 入口用 public 的 `PopopxMeshTimelineChannel`（MergedTimelineModifier.swift:29），
    /// 也就是 `PopopxMeshBadgeDescriptor.init(channel:)`（同文件 :354）的同一个输入；不用
    /// `PopopxMeshChannelBadge.color(of:)`，因为那个是 internal（brand-spec §0.1 已记录）。
    init(_ channel: PopopxMeshTimelineChannel) {
        switch channel {
        case .smpPublicNetwork: self = .smp
        case let .offlineMesh(hopCount): self = .mesh(hops: hopCount)
        case .awaitingRelay: self = .awaitingRelay(reason: nil)
        @unknown default: self = .awaitingRelay(reason: nil)
        }
    }

    /// 这一支通道是不是青色。发方据此决定气泡底色，也据此决定角标是不是退化成同墨。
    var isMesh: Bool {
        if case .mesh = self { return true }
        return false
    }

    /// VoiceOver 的一句话说清通道，图标一律 `accessibilityHidden`。
    var spoken: String {
        switch self {
        case .smp: PopopxBubbleCopy.channelSmp
        case let .mesh(hops): PopopxBubbleCopy.channelMesh(hops)
        case let .awaitingRelay(reason): reason.map { PopopxBubbleCopy.awaitingRelay($0) } ?? PopopxBubbleCopy.awaitingRelayPlain
        case .none: PopopxBubbleCopy.channelNone
        }
    }
}

/// 待中继的具体原因。前 5 个是模块 5 队列里那几个真值，一字不改地搬过来
/// （`PopopxQueueReason`，PopopxMessageRouter.swift:141-152）；后 2 个是本组件自己发现的。
enum PopopxBubbleQueueReason: Hashable {
    case noNetwork
    case peerUnreachable
    case smpUnacknowledged
    case meshRefused
    case awaitingContactUpgrade
    /// 跳数超出 `PopopxMeshConfig.fragmentRelayTtlCap`，或发方这行所绑的邻居已经静默过窗：
    /// 那串数字已经不能被这张网格承诺，退回灰时钟。判据同 ChatsListView.swift:380-381。
    case hopCountUnverifiable(hops: Int, cap: Int)
    /// 模块 5 以后新增的档位，或者 host 没给出原因。
    case unknown

    init(_ reason: PopopxQueueReason) {
        switch reason {
        case .noNetwork: self = .noNetwork
        case .peerUnreachable: self = .peerUnreachable
        case .smpUnacknowledged: self = .smpUnacknowledged
        case .meshRefused: self = .meshRefused
        case .awaitingContactUpgrade: self = .awaitingContactUpgrade
        @unknown default: self = .unknown
        }
    }

    var words: String {
        switch self {
        case .noNetwork: PopopxBubbleCopy.reasonNoNetwork
        case .peerUnreachable: PopopxBubbleCopy.reasonPeerUnreachable
        case .smpUnacknowledged: PopopxBubbleCopy.reasonSmpUnacknowledged
        case .meshRefused: PopopxBubbleCopy.reasonMeshRefused
        case .awaitingContactUpgrade: PopopxBubbleCopy.reasonAwaitingUpgrade
        case let .hopCountUnverifiable(hops, cap): PopopxBubbleCopy.reasonHopUnverifiable(hops, cap)
        case .unknown: PopopxBubbleCopy.awaitingRelayPlain
        }
    }
}

// MARK: - 版式值

/// 气泡的朝向。收方在左、发方在右——判据与现网同一处（`ChatView.swift:2252` 的
/// `ci.chatDir.sent && !terminal`），由 host 传进来，本文件不读会话模型。
enum PopopxBubbleSide: Hashable {
    case received
    case sent

    var alignment: Alignment { self == .sent ? .trailing : .leading }
}

/// 收紧哪一个角。简报的口径是"靠近上一条同发送者消息的那个角"，也就是发送者一侧的**上**角；
/// 现网 `ChatItemClipped` 把 tail 画在**下**沿（ChatItemClipShape.swift:130-141）。
/// 默认按简报（`.top`）；要回到现网视觉记忆，挂载点改一行 `.bottom` 就够。
enum PopopxBubbleTuckCorner: Hashable {
    case top
    case bottom
}

/// 气泡的圆角几何。四角外圈一律 `radiusCard`，只有 `tucked` 那一角换 `radiusBubbleTucked`。
struct PopopxBubbleTail: Hashable {
    var side: PopopxBubbleSide = .received
    /// 上一行是同一个发送者 → 收紧。host 的判据就是它现在用来决定 tail 的那一个
    /// （`ChatView.swift:2280` 的 `tailVisible`）。
    var tucked: Bool = false
    var corner: PopopxBubbleTuckCorner = .top
    /// `DEFAULT_CHAT_ITEM_TAIL` 关掉、或 terminal 布局时不合并圆角：四角齐 16pt。
    /// 现网同一条开关在 ChatItemClipShape.swift:49（`tailEnabled && !terminal`）。
    var enabled: Bool = true

    /// 具体半径由 `UnevenRoundedRectangle` 自己在高度不足时夹到 h/2，所以 Dynamic Type 拉到
    /// 120% 也不会像现网那样把气泡画变形（ChatItemClipShape.swift:103-109 是手工夹的同一件事）。
    var shape: UnevenRoundedRectangle {
        let outer = PopopxMetrics.radiusCard
        let near = tucked && enabled ? PopopxMetrics.radiusBubbleTucked : outer
        let leading = side == .received
        return UnevenRoundedRectangle(
            topLeadingRadius: leading && corner == .top ? near : outer,
            bottomLeadingRadius: leading && corner == .bottom ? near : outer,
            bottomTrailingRadius: !leading && corner == .bottom ? near : outer,
            topTrailingRadius: !leading && corner == .top ? near : outer,
            style: .continuous
        )
    }
}

/// 一条会话项要画的内容。前五个档覆盖现网这一行真正会出现的五种东西，第六档（`.location`）
/// 是【发送位置】带来的：挂载点只需做一次 `ChatItem.content` → 本枚举的映射，不在气泡里读 `ChatItem`。
enum PopopxBubbleBody: Hashable {
    /// 正文。
    case text(String)
    /// 图/视/语音/文件：名字 + 一行说明（尺寸、时长）。缩略图由 host 继续拥有——
    /// 本组件不接管 `CIFileView`/`CIVoiceView` 的那套播放控件。
    case media(name: String, detail: String?)
    /// 撤回/被审核掉留下的那句（现网 `MarkedDeletedItemView`，ChatItemView.swift:79-80）。
    /// 中性墨 + 斜体：红在本色板里只属于"危险动作"（§1.1），一条已经撤回的历史不是危险动作。
    case withdrawn(String)
    /// 系统/协议行：整行文字，不上气泡底。
    case event(String)
    /// 读不懂的内容（`invalidJSON`、解密失败）。
    case unavailable(String)
    /// 一条位置消息。载荷本身带着经纬度、地名和地址，渲染成地图卡片（本文件末 `PopopxLocationCardBubble`）。
    case location(PopopxLocationPayload)

    /// VoiceOver 要说的那句正文。`.event` 由 `PopopxMessageBubble.body` 分给 `eventLine`，
    /// 不上气泡底——判据只写在那一处分流里。
    var spokenText: String {
        switch self {
        case let .text(text): text
        case let .media(name, detail): detail.map { "\(name)，\($0)" } ?? name
        case let .withdrawn(text): text
        case let .event(text): text
        case let .unavailable(text): text
        case let .location(payload): PopopxLocationCopy.spoken(payload)
        }
    }
}

/// 投递回执。本枚举只表意，不复制现网那两枚资产勾（`checkmark.wide` / `checkmark.2`，
/// `CIItemStatus.statusIcon`，POPOPXChat/ChatTypes.swift:4614-4627）：挂载时二选一，
/// 要么把 `statusIcon` 的结果映射成这里的档位由气泡画，要么 `receipt = nil` 让 `CIMetaView` 继续画。
enum PopopxBubbleReceipt: Hashable {
    /// 已发出、还没等到任何确认（`sndNew`/`sndSent`）。
    case inFlight
    /// 服务器收下（`sndSent` 完整进度）。
    case delivered
    /// 对端已读（`sndRcvd(.ok)`）。
    case read
    /// 收方这条还没被本端读完（`rcvNew`）。
    case received
    /// 投递失败或警告（`sndError`/`sndErrorAuth`/`sndWarning`/`invalid`）。
    case failed(String?)

    /// 全用真的 SF Symbol：现网那两枚勾（`checkmark.wide`、`checkmark.2`）是资产图，
    /// 归 `CIMetaView`，本文件不复制资产、也不假装系统里有同名符号。
    var symbolName: String {
        switch self {
        case .inFlight: "circle.dashed"
        case .delivered: "checkmark"
        case .read: "checkmark.circle.fill"
        case .received: "circlebadge.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var words: String {
        switch self {
        case .inFlight: PopopxBubbleCopy.receiptInFlight
        case .delivered: PopopxBubbleCopy.receiptDelivered
        case .read: PopopxBubbleCopy.receiptRead
        case .received: PopopxBubbleCopy.receiptReceived
        case .failed: PopopxBubbleCopy.receiptFailed
        }
    }
}

/// 一枚气泡要的全部输入值。字段都有默认值，挂载点按名字填。
struct PopopxBubbleItem: Hashable {
    /// 通道表用的键：现网 app 行就是 `String(ChatItem.id)`（`PopopxMeshApplicationStream.rows(from:)`
    /// 在 Shared/Model/POPOPXAPI.swift:3924 就是这么喂时间线的），mesh 行是 envelope 的 `messageId`。
    var messageKey: String
    var content: PopopxBubbleBody = .text("")
    var tail: PopopxBubbleTail = PopopxBubbleTail()
    var channel: PopopxBubbleChannel = .none
    /// 群/频道里那条消息是谁发的（现网 `senderRole`，ChatView.swift:2247）。
    var author: String?
    /// host 格式化好的时间；`nil` 就不画——现网那一刀是 `.environment(\.showTimestamp)`
    /// （ChatView.swift:2279），这里换成值，组件不读环境开关。
    var timeText: String?
    var receipt: PopopxBubbleReceipt?
    /// 会话对象的 id，只用来让判定表能把"这个联系人的邻居"和这一行对上；nil = 广播/未知。
    var contactId: Int64?
    /// 行宽上限，挂载点现成的那个 `maxWidth`（ChatView.swift:2251 的入参）。
    var maxWidth: CGFloat = .infinity

    var side: PopopxBubbleSide { tail.side }
}

// MARK: - 气泡本体

/// 一条会话项 = 一枚气泡 + 一枚角标。
///
/// 用法（唯一入口）：
/// ```swift
/// PopopxMessageBubble(
///     PopopxBubbleItem(
///         messageKey: String(ci.id),
///         content: .text(ci.text),
///         tail: PopopxBubbleTail(side: ci.chatDir.sent ? .sent : .received,
///                               tucked: !itemSeparation.largeGap),
///         channel: table.channel(forKey: String(ci.id)),
///         author: senderRoleText,
///         timeText: itemSeparation.timestamp ? dateText(ci.meta.itemTs) : nil,
///         contactId: contactId
///     )
/// )
/// ```
/// `contextMenu`、滑动回复、多选、反应条那些行交互**留在挂载点**（ChatView.swift:2281-2321），
/// 本组件只提供内容视图与几何，不去抢宿主的手势。
@MainActor
struct PopopxMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let item: PopopxBubbleItem

    init(_ item: PopopxBubbleItem) {
        self.item = item
    }

    var body: some View {
        let row = Group {
            switch item.content {
            case let .event(text):
                eventLine(text)
            default:
                bubble
            }
        }
        .frame(maxWidth: item.maxWidth, alignment: item.side.alignment)
        if case .location = item.content {
            // 位置卡片里有一枚真按钮。`.combine` 会把子树的点击动作并进整行，VoiceOver 就再也
            // 打不开那张地图了，所以这一支改成 `.contain`：容器还在，children 各自保留自己的
            // 标签与动作（正文文本 + 「打开位置卡片菜单」那一句在卡片内部说）。
            row.accessibilityElement(children: .contain)
        } else {
            row.accessibilityElement(children: .combine)
                .accessibilityLabel(spoken)
        }
    }

    // MARK: 气泡

    private var bubble: some View {
        let ink = PopopxBubbleInk(channel: item.channel, side: item.side)
        return VStack(alignment: item.side.alignment.horizontal, spacing: PopopxMetrics.space2XS) {
            if let author = item.author {
                Text(author)
                    .font(PopopxType.caption)
                    .foregroundStyle(ink.meta)
                    .lineLimit(1)
            }
            contentText(ink)
            footer(ink)
        }
        .padding(.horizontal, PopopxMetrics.spaceS)
        .padding(.vertical, PopopxMetrics.spaceXS)
        .fixedSize(horizontal: false, vertical: true)
        .background(ink.fill, in: item.tail.shape)
        // 卡面气泡在纯黑底上需要一点边缘信息（§2.3 同一判据）；实底气泡不描边，免得又生出一支色。
        .overlay {
            if ink.onCard {
                item.tail.shape.strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
            }
        }
        // Light 叠阴影、Dark 自动是 `.clear`：`popopxCardElevation` 自己按 colorScheme 选好了，
        // 实底气泡在 Light 下那点阴影本来就是卡片该有的。
        .popopxCardElevation(colorScheme: colorScheme)
        // 通道迁移是"用户没碰的东西自己变了"，所以走 `fluid`；Reduce Motion 下直接落定
        // （§5，PopopxTheme.swift:242-264 的同一个入口）。
        .popopxAnimation(PopopxSpring.fluid, value: item.channel, reduceMotion: reduceMotion)
    }

    /// 正文。`withdrawn` / `unavailable` 与正文同字号，只换墨与字体倾斜——撤回不是危险动作。
    @ViewBuilder private func contentText(_ ink: PopopxBubbleInk) -> some View {
        switch item.content {
        case let .text(text):
            Text(text)
                .font(PopopxType.body)
                .foregroundStyle(ink.text)
        case let .media(name, detail):
            VStack(alignment: item.side.alignment.horizontal, spacing: PopopxMetrics.space2XS) {
                Label {
                    Text(name)
                } icon: {
                    Image(systemName: "doc.viewfinder")
                }
                .font(PopopxType.meta)
                .foregroundStyle(ink.text)
                .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(PopopxType.caption)
                        .foregroundStyle(ink.meta)
                }
            }
        case let .withdrawn(text):
            Text(text)
                .font(PopopxType.body)
                .italic()
                .foregroundStyle(ink.meta)
        case let .event(text):
            // `.event` 在 `body` 里就被分给 `eventLine` 了，到不了这里；这一支只为 switch 完备而留。
            Text(text)
                .font(PopopxType.caption)
                .foregroundStyle(ink.meta)
        case let .unavailable(text):
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "questionmark.folder")
                    .font(PopopxType.meta)
                    .foregroundStyle(ink.caution)
                    .accessibilityHidden(true)
                Text(text)
                    .font(PopopxType.caption)
                    .foregroundStyle(ink.meta)
            }
        case let .location(payload):
            // 气泡的内边距就是这张地图卡与气泡边缘的呼吸，所以缩略图自己圆角、不另描边。
            // 时间 / 回执 / 通道角标由下面那个 `footer` 出，卡片只出地图、地名、地址。
            PopopxLocationCardBubble(payload: payload, ink: ink, channel: item.channel)
        }
    }

    /// 下沿一行：时间 + 回执 + 角标。三个都是次要信息，所以同一支 `meta` 墨，
    /// 只有角标自己带通道色——一行一支主色。
    @ViewBuilder private func footer(_ ink: PopopxBubbleInk) -> some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            if let timeText = item.timeText {
                Text(verbatim: timeText)
                    .font(PopopxType.caption)
                    .foregroundStyle(ink.meta)
                    .accessibilityHidden(true)
            }
            if let receipt = item.receipt {
                Image(systemName: receipt.symbolName)
                    .font(PopopxType.caption)
                    .imageScale(.medium)
                    .foregroundStyle(receiptIsDanger(receipt) ? ink.failure : ink.meta)
                    .accessibilityHidden(true)
            }
            PopopxBadge(channel: item.channel, monochromeInk: ink.monochromeBadgeInk)
        }
        .font(PopopxType.caption)
    }

    /// 系统行：居中、无底、不上角标——它不过任何通道。
    private func eventLine(_ text: String) -> some View {
        Text(text)
            .font(PopopxType.caption)
            .foregroundStyle(PopopxPalette.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: item.maxWidth)
            .padding(.vertical, PopopxMetrics.space2XS)
            .accessibilityLabel(text)
    }

    /// 一行只说一句"谁发的什么，走哪条通道"。图标全部 hidden，语义由文字承载。
    private var spoken: String {
        var parts: [String] = []
        if let author = item.author { parts.append(author) }
        parts.append(item.content.spokenText)
        if let timeText = item.timeText { parts.append(timeText) }
        if let receipt = item.receipt { parts.append(receipt.words) }
        if item.channel != .none { parts.append(item.channel.spoken) }
        return parts.joined(separator: "，")
    }

    /// 失败态才上红，而且只在卡面上上红：`dangerInk` 在 `brand`/`mesh` 实底上不保证对比，
    /// 那种情况下同一枚符号用气泡自己的墨。判据沿用现网 `statusIcon` 给 `.red` 的那几个状态。
    private func receiptIsDanger(_ receipt: PopopxBubbleReceipt) -> Bool {
        if case .failed = receipt { return true }
        return false
    }
}

/// 气泡的一整套墨。把"底 + 正文 + 次要 + 角标画法"绑成一个值，避免出现第 3 种组合。
private struct PopopxBubbleInk {
    let fill: Color
    let text: Color
    let meta: Color
    /// 卡面 → 角标可以用通道色；实底 → 角标退化成同墨，见 `PopopxBadge`。
    let onCard: Bool
    /// 只在卡面上是红，实底上退回本墨。
    let failure: Color
    let caution: Color

    /// 角标要不要退化成"同一支墨"：实底 = 要，卡面 = 不要（用通道色）。
    var monochromeBadgeInk: Color? { onCard ? nil : text }

    init(channel: PopopxBubbleChannel, side: PopopxBubbleSide) {
        switch (side, channel) {
        case (.sent, .smp):
            fill = PopopxPalette.brand
            text = PopopxPalette.onBrand
            meta = PopopxPalette.onBrand
            onCard = false
            failure = PopopxPalette.onBrand
            caution = PopopxPalette.onBrand
        case (.sent, .mesh):
            // 裁定 3：发送方气泡统一使用现代深靛紫主色（brand），离线 Mesh 通过右下角青绿蓝牙波纹 + 跳数微标区分。
            fill = PopopxPalette.brand
            text = PopopxPalette.onBrand
            meta = PopopxPalette.onBrand
            onCard = false
            failure = PopopxPalette.onBrand
            caution = PopopxPalette.onBrand
        case (.sent, .awaitingRelay), (.sent, .none):
            // 裁定 3：发送方气泡统一使用现代深靛紫主色（brand），待中继/未发送通过右下角灰时钟徽章区分。
            fill = PopopxPalette.brand
            text = PopopxPalette.onBrand
            meta = PopopxPalette.onBrand
            onCard = false
            failure = PopopxPalette.onBrand
            caution = PopopxPalette.onBrand
        case (.received, _):
            // 收方永远是卡面：通道信息归角标（§2.1 第 2、3 行）。
            fill = PopopxPalette.card
            text = PopopxPalette.label
            meta = PopopxPalette.labelSecondary
            onCard = true
            failure = PopopxPalette.dangerInk
            caution = PopopxPalette.labelSecondary
        }
    }
}

// MARK: - 角标

/// 通道角标。一行一枚，图标是装饰，数字与 `accessibilityLabel` 才是信息。
///
/// 画法表（Docs/popopx-brand-spec.md §2.2）：
/// | 通道 | 卡面上 | 实底上 |
/// |---|---|---|
/// | SMP | `lock.shield.fill` · `brand` | 同墨符号 |
/// | Mesh | `antenna.radiowaves.left.and.right` · `meshInk` + 一块 `mesh` 贴片写着「N 跳」(`onMesh`) | 同墨符号 + 同墨数字 |
/// | 待中继 | `clock` · `labelSecondary` + 原因 | 同墨符号 + 原因 |
/// | 无通道 | 什么都不画 | 同 |
@MainActor
struct PopopxBadge: View {
    let channel: PopopxBubbleChannel
    /// 非 nil = 气泡是实底，角标退化成这一支墨，绝不在靛底上画靛、青底上画青（§1.1）。
    var monochromeInk: Color? = nil

    var body: some View {
        if let spoken {
            badge
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("popopx.bubble.channel")
        } else {
            EmptyView()
        }
    }

    @ViewBuilder private var badge: some View {
        switch channel {
        case .none:
            EmptyView()
        case .smp:
            glyph(PopopxBubbleCopy.smpSymbol, tint: accent(PopopxPalette.brand))
        case let .mesh(hops):
            meshBadge(hops)
        case let .awaitingRelay(reason):
            HStack(spacing: PopopxMetrics.space2XS) {
                glyph(PopopxBubbleCopy.relaySymbol, tint: accent(PopopxPalette.labelSecondary))
                Text(verbatim: reason?.words ?? PopopxBubbleCopy.awaitingRelayPlain)
                    .font(PopopxType.microTag)
                    .foregroundStyle(accent(PopopxPalette.labelSecondary))
            }
        }
    }

    /// `.none` 不占一个无障碍元素：没有通道可说，就不要凭空生出一个可聚焦点。
    private var spoken: String? {
        channel == .none ? nil : channel.spoken
    }

    /// 青色角标：符号走 `meshInk`（卡面上 `mesh` 只有 2.98:1，文字必须是 ink），
    /// 数字走一块 `mesh` 贴片 + `onMesh`——和 `PopopxCabinHopBadge`（PopopxCabinView.swift:825-837）
    /// 同一套画法，0 跳也照样把数字写出来（"0 跳 · 直连"）。
    @ViewBuilder private func meshBadge(_ hops: Int) -> some View {
        let words = PopopxBubbleCopy.hopsWords(hops)
        HStack(spacing: PopopxMetrics.space2XS) {
            glyph(PopopxBubbleCopy.meshSymbol, tint: accent(PopopxPalette.meshInk))
            if let monochromeInk {
                Text(verbatim: words)
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(monochromeInk)
                    .accessibilityHidden(true)
            } else {
                Text(verbatim: words)
                    .font(PopopxType.metricSmall)
                    .foregroundStyle(PopopxPalette.onMesh)
                    .padding(.horizontal, PopopxMetrics.space2XS)
                    .padding(.vertical, PopopxMetrics.space2XS / 2)
                    .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    /// 实底上任何通道色都不再出现第二支：一切退回气泡自己的墨。
    private func accent(_ token: Color) -> Color { monochromeInk ?? token }
}

// MARK: - 批量通道判定（挂载缝）

/// 一个邻居能承诺什么。只取 `PopopxMeshPeer` 真实存在的那四个字段
/// （hopCount / lastSeenAt / rssi / isDirect，PopopxMeshEvents.swift:34-38）。
struct PopopxBubblePeerFact: Hashable {
    var hops: Int
    var lastSeenAt: Date
    var isDirect: Bool
    var rssi: Int8?

    init(_ peer: PopopxMeshPeer) {
        hops = peer.hopCount
        lastSeenAt = peer.lastSeenAt
        isDirect = peer.isDirect
        rssi = peer.rssi
    }

    func isFresh(now: Date, window: TimeInterval) -> Bool {
        now.timeIntervalSince(lastSeenAt) <= window
    }
}

/// 判定表的一行输入。host 从会话项里就能凑齐，不需要 await 任何东西。
struct PopopxBubbleRowAddress: Hashable {
    /// 与 `PopopxBubbleItem.messageKey` 同一个键。
    var messageKey: String
    /// 这条会话的联系人 id；广播行、未知对象为 nil。
    var contactId: Int64?
    /// 这条消息是不是"发出去的"。发方才需要重新核验邻居跳数。
    var sent: Bool
    /// 是不是一条真的消息。系统行、本机笔记、读不懂的内容 = false，不给任何通道
    /// （同 ChatsListView.swift:366-368 对 `.local/.contactRequest/.invalidJSON` 给 `.none` 的判据）。
    var isMessage: Bool = true
}

/// 判定表的全部真值，一次读齐之后的快照。字段都可以直接传值，没有一个是环境或单例。
struct PopopxBubbleTransportSources: Hashable {
    /// 全局熔断（`PopopxMeshRuntime.isFuseOn`，Shared/Model/POPOPXAPI.swift:3634）。
    var fuseOn = false
    /// 射频档位（`PopopxMeshStreamState.radioState`，PopopxMeshStateSource.swift:24 + `isUsable`，PopopxMeshEvents.swift:22）。
    var radioUsable = false
    /// 跳数上限：`PopopxMeshConfig.default.fragmentRelayTtlCap`（Core/PopopxMeshConfig.swift:21，7）。
    var hopCap = 1
    /// 静默窗口：`peerReachabilityTimeout`（同文件 :65，15 秒）。
    var reachabilityWindow: TimeInterval = 15
    /// contactId → meshPublicKeyHex，整表一次读完（IdentityMappingStore.swift:201 `allMappings()`）。
    var bindings: [Int64: String] = [:]
    /// meshPublicKeyHex → 邻居事实。
    var peers: [String: PopopxBubblePeerFact] = [:]
    /// message key → 合并时间线/射频状态已经定性的通道。
    var channels: [String: PopopxBubbleChannel] = [:]
    /// mesh message id → 队列原因（`PopopxMessageRouter.pendingMessages()`，Router/PopopxMessageRouter.swift:863）。
    var queueReasons: [String: PopopxQueueReason] = [:]
    /// app 行 id → mesh message id，来自裁定 1 的双 id 表
    /// （`recordedFlushedAppChatItemIDs()`，同文件 :878；app 行键的写法见 POPOPXAPI.swift:3924）。
    var meshKeyByRowKey: [String: String] = [:]
    /// 这批值读出来的时刻。新鲜度一律用它，不用 `Date.now`：重画不等于重新判定。
    var readAt = Date.now
    /// `false` = 表还没读出来。这时候不猜通道。
    var isLoaded = false
}

/// 一次 pass 出来的结果。行渲染只是查字典。
struct PopopxBubbleChannelTable: Hashable {
    private var channels: [String: PopopxBubbleChannel]
    var sourceReadAt: Date = Date.now

    init(channels: [String: PopopxBubbleChannel], sourceReadAt: Date = .now) {
        self.channels = channels
        self.sourceReadAt = sourceReadAt
    }

    /// 查不到就给 `.none`：不画角标，也不编一条通道。
    func channel(for address: PopopxBubbleRowAddress) -> PopopxBubbleChannel {
        channels[address.messageKey] ?? .none
    }

    func channel(forKey messageKey: String) -> PopopxBubbleChannel {
        channels[messageKey] ?? .none
    }

    var count: Int { channels.count }
    var isEmpty: Bool { channels.isEmpty }
}

/// 挂载缝：读一次、成一次表。
///
/// host 的用法（一个 `.task(id:)` 里跑完，行渲染零 await）：
/// ```swift
/// let sources = await PopopxBubbleTransportResolver.loadSources(
///     fuseOn: runtime.isFuseOn,
///     state: runtime.stateSource.state,
///     timelineRows: runtime.timelineModel.result.rows,
///     mappingStore: runtime.mappingStore,
///     router: runtime.router
/// )
/// let table = PopopxBubbleTransportResolver.table(sources, rows: addresses)
/// ```
@MainActor
enum PopopxBubbleTransportResolver {
    /// 三次 actor hop 读完全部来源，其余都是 host 手里已经在观察的快照值。除此之外没有任何 await。
    static func loadSources(
        fuseOn: Bool,
        state: PopopxMeshStreamState,
        timelineRows: [PopopxMeshTimelineRow],
        mappingStore: IdentityMappingStore,
        router: PopopxMessageRouter,
        config: PopopxMeshConfig = .default,
        now: Date = .now
    ) async -> PopopxBubbleTransportSources {
        var sources = PopopxBubbleTransportSources()
        sources.fuseOn = fuseOn
        sources.readAt = now
        sources.isLoaded = true
        sources.hopCap = Int(config.fragmentRelayTtlCap)
        sources.reachabilityWindow = config.peerReachabilityTimeout
        sources.radioUsable = state.radioState.isUsable

        // 邻居表：一次 pass，按 hex 索引（`peerID.hex`，Protocol/PopopxMeshProtocol.swift:56）。
        var peers: [String: PopopxBubblePeerFact] = [:]
        peers.reserveCapacity(state.peers.count)
        for peer in state.peers { peers[peer.peerID.hex] = PopopxBubblePeerFact(peer) }
        sources.peers = peers

        // 时间线行的定性（MergedTimelineModifier.swift:185 的 `channel`），再用射频自己报过的
        // `awaitingRelayMessageIDs`（PopopxMeshStateSource.swift:37）补上时间线没覆盖到的 id。
        var channels: [String: PopopxBubbleChannel] = [:]
        channels.reserveCapacity(timelineRows.count + state.awaitingRelayMessageIDs.count)
        for row in timelineRows { channels[row.messageID] = PopopxBubbleChannel(row.channel) }
        for id in state.awaitingRelayMessageIDs where channels[id] == nil {
            channels[id] = .awaitingRelay(reason: nil)
        }
        sources.channels = channels

        // 保险丝关着时，绑定表里的键一条都不作数（现网同一判据：ChatsListView.swift:374），
        // 所以那三次 hop 根本不发起。
        guard fuseOn else { return sources }

        var bindings: [Int64: String] = [:]
        var newestUpdate: [Int64: Date] = [:]
        let mappings = await mappingStore.allMappings()          // hop 1
        for mapping in mappings {
            // 只认已经指向真实联系人的绑定（`contactId` 的语义，IdentityMappingStore.swift:35-42）。
            guard let contactId = mapping.contactId else { continue }
            if let seen = newestUpdate[contactId], seen >= mapping.updatedAt { continue }
            newestUpdate[contactId] = mapping.updatedAt
            bindings[contactId] = mapping.meshPublicKeyHex
        }
        sources.bindings = bindings

        var reasons: [String: PopopxQueueReason] = [:]
        let pending = await router.pendingMessages()             // hop 2
        for entry in pending { reasons[entry.messageId] = entry.reason }
        sources.queueReasons = reasons

        var meshByRow: [String: String] = [:]
        let flushed = await router.recordedFlushedAppChatItemIDs()  // hop 3
        for (meshMessageId, appItemId) in flushed {
            meshByRow[String(appItemId)] = meshMessageId
        }
        sources.meshKeyByRowKey = meshByRow
        return sources
    }

    /// 纯函数：一趟过完所有行，不开任务、不读环境、不碰 actor。
    static func table(
        _ sources: PopopxBubbleTransportSources,
        rows: [PopopxBubbleRowAddress]
    ) -> PopopxBubbleChannelTable {
        var resolved: [String: PopopxBubbleChannel] = [:]
        resolved.reserveCapacity(rows.count)
        for row in rows { resolved[row.messageKey] = channel(for: row, sources: sources) }
        return PopopxBubbleChannelTable(channels: resolved, sourceReadAt: sources.readAt)
    }

    /// 单行的判定。顺序即优先级，前一条命中就不再往下走：
    /// 1. 不是消息 → `.none`；2. 保险丝关 → 只有公网这一条真相 → `.smp`；
    /// 3. 队列里有它 → 灰时钟（带模块 5 的原因）；4. 时间线定过性 → 按定性的走，
    /// 青色那条再核验跳数还能不能被承诺；5. 谁都没认领的 app 行 → `.smp`
    /// （现网同一口径：app 自己流里的行按定义就是 SMP，MergedTimelineModifier.swift:118）。
    static func channel(
        for address: PopopxBubbleRowAddress,
        sources: PopopxBubbleTransportSources
    ) -> PopopxBubbleChannel {
        guard address.isMessage else { return .none }
        guard sources.fuseOn else { return .smp }
        guard sources.isLoaded else { return .none }

        let meshKey = sources.meshKeyByRowKey[address.messageKey]
        if let reason = sources.queueReasons[address.messageKey] ?? meshKey.flatMap({ sources.queueReasons[$0] }) {
            return .awaitingRelay(reason: PopopxBubbleQueueReason(reason))
        }

        guard let found = sources.channels[address.messageKey] else { return .smp }
        switch found {
        case .smp, .none:
            return .smp
        case let .awaitingRelay(reason):
            return .awaitingRelay(reason: reason)
        case let .mesh(hops):
            guard hops >= 0, hops <= sources.hopCap else {
                return .awaitingRelay(reason: .hopCountUnverifiable(hops: hops, cap: sources.hopCap))
            }
            // 发方这一行是在说"我刚刚经邻居送出去了"，所以邻居必须还在模块 4 的可达窗口里、
            // 射频还得开着；收方那一行是历史事实，不重新核验。
            if address.sent, !sources.radioUsable {
                return .awaitingRelay(reason: .peerUnreachable)
            }
            if address.sent,
               let contactId = address.contactId,
               let hex = sources.bindings[contactId],
               let peer = sources.peers[hex],
               !peer.isFresh(now: sources.readAt, window: sources.reachabilityWindow) {
                return .awaitingRelay(reason: .peerUnreachable)
            }
            return .mesh(hops: hops)
        }
    }
}

// MARK: - 顶部同意横幅的挂载位

/// 手动建联同意横幅：只**引用**包里那一条真横幅（`ManualPairingBannerView(model:)`，
/// PopopxMeshKit/Sources/PopopxMeshUI/ManualPairingBannerView.swift:365），不复制它的文案与判定，
/// 也不改那个文件。
///
/// 现网已经有一处挂载：`ChatView.swift:119/127` 的 `.popopxMeshBanner(...)`（包里的
/// `popopxMeshBanner(_:)`，ManualPairingBannerView.swift:466），它挂在安全区上。
/// **两者只能存在一个**：同时在，用户会看到两条一模一样的同意横幅、两个 approve 按钮。
/// 整体替换对话流时，用下面这一个把横幅放进流水顶部，并把那两行 modifier 去掉。
@MainActor
struct PopopxBubbleConsentBanner: View {
    let model: PopopxMeshBannerModel

    var body: some View {
        ManualPairingBannerView(model: model)
    }
}

// MARK: - 文案

/// 本文件的用户可见文字。和其他阶段的新视图一样：字面量集中在这里，符号表也集中在这里，
/// 好让"一行只出现一枚徽章符号"这种规则可查（§6 图标词汇表）。
enum PopopxBubbleCopy {
    static let smpSymbol = "lock.shield.fill"
    static let meshSymbol = "antenna.radiowaves.left.and.right"
    static let relaySymbol = "clock"

    static let channelSmp = "SMP 在线加密"
    static let channelNone = "不经过任何通道"
    static let awaitingRelayPlain = "待中继"

    static let reasonNoNetwork = "待中继 · 无公网"
    static let reasonPeerUnreachable = "待中继 · 邻居不在射程"
    static let reasonSmpUnacknowledged = "待中继 · 公网未确认"
    static let reasonMeshRefused = "待中继 · Mesh 拒收"
    static let reasonAwaitingUpgrade = "待中继 · 等名片升级"
    static let receiptInFlight = "发送中"
    static let receiptDelivered = "已送达"
    static let receiptRead = "已读"
    static let receiptReceived = "未读"
    static let receiptFailed = "投递失败"

    static func channelMesh(_ hops: Int) -> String {
        hops == 0 ? "厢语离线，直连（0 跳）" : "厢语离线，\(hops) 跳"
    }

    /// 跳数徽章永远带数字（§1.4 第 3 条）；0 跳把"直连"一起写出来，同 PopopxCabinView.swift:1402。
    static func hopsWords(_ hops: Int) -> String { hops == 0 ? "0 跳 · 直连" : "\(hops) 跳" }

    static func awaitingRelay(_ reason: PopopxBubbleQueueReason) -> String { reason.words }

    static func reasonHopUnverifiable(_ hops: Int, _ cap: Int) -> String {
        "待中继 · 跳数 \(hops) 超上限 \(cap)"
    }
}

// MARK: - B5 挂载适配（ChatItem → PopopxBubbleItem）

/// 现网 `ChatItem` 到气泡入参的唯一映射入口。
///
/// `CIContent`（POPOPXChat/ChatTypes.swift:4862，**33 个 case**）在这里是**穷尽枚举**的：`switch` 没有
/// `default`，Haskell 端以后加一个 case 就编译不过，映射表不会悄悄落后于协议。
///
/// 但"覆盖"不等于"交给气泡画"。`PopopxBubbleBody` 只有 5 个档（本文件 :172），而缩略图、播放器、
/// 文件下载控件、链接预览卡、引用回复条、通话回拨、入群接受/拒绝都不在它的能力之内——本文件 :174-176
/// 写明了这条边界。这些行一律返回 `nil`，挂载点据此把**整行**继续交给现网 `ChatItemView`，
/// 而不是压成 `.media(name:detail:)` 之后把控件悄悄画没（裁定 A：分层挂载，零回归优先于全覆盖）。
@MainActor
enum PopopxBubbleMount {
    /// `nil` = 这一行现网 `ChatItemView` 继续负责。
    ///
    /// 本轮只接管**直接会话**：群/频道的内容行由现网画头像和成员名（`CIMemberNameView`），
    /// 气泡只有一个 `author: String?`，接管就等于把头像画没了。系统行（`.event`）本来就没头像，
    /// 扩到群/频道只差去掉这一条 guard——留作后续单独一轮，因为它要重新核对 `eventItemViewText`
    /// 里拼进去的发送者。
    static func body(of ci: ChatItem, chat: Chat) -> PopopxBubbleBody? {
        guard chat.chatInfo.chatType == .direct else { return nil }
        guard !ci.isLiveDummy, !ci.localNote else { return nil }
        let isChannel = chat.chatInfo.isChannel
        switch ci.content {
        case let .sndMsgContent(mc), let .rcvMsgContent(mc):
            return msgBody(mc, ci: ci)
        case .sndDeleted, .rcvDeleted, .sndModerated, .rcvModerated, .rcvBlocked:
            return .withdrawn(ci.text(isChannel: isChannel))
        case .rcvIntegrityError, .rcvDecryptionError, .rcvMsgError, .invalidJSON:
            return .unavailable(ci.text(isChannel: isChannel))
        case .rcvDirectEvent, .rcvGroupEvent, .sndGroupEvent, .rcvConnEvent, .sndConnEvent,
             .rcvChatFeature, .sndChatFeature, .rcvChatPreference, .sndChatPreference,
             .rcvGroupFeature, .sndGroupFeature, .rcvChatFeatureRejected, .rcvGroupFeatureRejected,
             .sndDirectE2EEInfo, .rcvDirectE2EEInfo, .sndGroupE2EEInfo, .rcvGroupE2EEInfo:
            let text = ci.text(isChannel: isChannel)
            return text.isEmpty ? nil : .event(text)
        case .sndCall, .rcvCall:
            return nil
        case .rcvGroupInvitation, .sndGroupInvitation:
            return nil
        case .chatBanner:
            return nil
        }
    }

    /// 内容行。文本之外的 7 个 `MsgContent` 档都有现网专属控件，一个都不接管。
    private static func msgBody(_ mc: MsgContent, ci: ChatItem) -> PopopxBubbleBody? {
        switch mc {
        case .text:
            // 位置卡片排在最前面，而且必须压过下面那三道 guard：载荷里带 `popopx://loc`，
            // 现网的 `formattedText`/`markdownBlocks` 会把它认成链接，于是这一行永远走不到
            // 卡片这一支——真机上表现成"位置消息静默退化成一行纯文本"，比崩还难查。
            if let location = PopopxLocationPayload.parse(from: mc.text) {
                return .location(location)
            }
            // 带富文本/提及/markdown 的行交给现网：气泡只画纯 `Text`，链接和 @ 就不再可点。
            guard ci.formattedText == nil, ci.mentions == nil, ci.markdownBlocks == nil else { return nil }
            // 引用回复条和附件都不在 `PopopxBubbleBody` 的 6 个档里。
            guard ci.quotedItem == nil, ci.file == nil else { return nil }
            // 下面这些标记现网画在 `CIMetaView` 里，气泡的下沿没有对应位置（本文件 :199 的"挂载时二选一"）。
            guard ci.meta.itemDeleted == nil, !ci.meta.itemEdited, ci.meta.itemTimed == nil,
                  ci.meta.itemForwarded == nil, ci.meta.sentViaProxy != true,
                  ci.meta.msgVerified == nil, !ci.meta.isLive
            else { return nil }
            return mc.text.isEmpty ? nil : .text(mc.text)
        case let .unknown(_, text):
            return .unavailable(text)
        case .link, .image, .video, .voice, .file, .report, .chat:
            return nil
        }
    }

    /// 组装气泡入参；只在 `body(of:)` 已经给出内容之后调用。
    static func item(
        _ ci: ChatItem,
        content: PopopxBubbleBody,
        chat: Chat,
        maxWidth: CGFloat,
        timestamp: Bool,
        tailVisible: Bool,
        table: PopopxBubbleChannelTable
    ) -> PopopxBubbleItem {
        // 撤回/不可读/系统行现网不画 tail（ChatItemClipShape.swift:55-60），气泡也就不收紧任何角。
        let tucked: Bool
        switch content {
        case .withdrawn, .unavailable, .event: tucked = false
        case .text, .media, .location: tucked = tailVisible
        }
        return PopopxBubbleItem(
            messageKey: String(ci.id),
            content: content,
            tail: PopopxBubbleTail(side: ci.chatDir.sent ? .sent : .received, tucked: tucked),
            channel: table.channel(forKey: String(ci.id)),
            timeText: timestamp ? formatTimestampMeta(ci.meta.itemTs) : nil,
            receipt: receipt(of: ci),
            contactId: contactId(of: chat),
            maxWidth: maxWidth
        )
    }

    /// 投递回执。判据和现网 `CIStatus.statusIcon` 同一处（ChatTypes.swift:4614-4627），
    /// 只是把那两枚资产勾换成 `PopopxBubbleReceipt` 的档位。
    static func receipt(of ci: ChatItem) -> PopopxBubbleReceipt? {
        switch ci.meta.itemStatus {
        case .sndNew: .inFlight
        case let .sndSent(progress): progress == .partial ? .inFlight : .delivered
        case let .sndRcvd(status, progress):
            status == .ok ? (progress == .partial ? .delivered : .read) : .failed(nil)
        case .sndErrorAuth, .sndError, .sndWarning, .invalid: .failed(nil)
        case .rcvNew: .received
        case .rcvRead: nil
        }
    }

    static func contactId(of chat: Chat) -> Int64? {
        if case let .direct(contact) = chat.chatInfo { return contact.contactId }
        return nil
    }

    /// 建通道表要的全部行地址。**只在 ChatView 层调用一次**——逐行 await 是本组件禁止的画法
    /// （本文件 :17）。
    static func addresses(for items: [ChatItem], chat: Chat) -> [PopopxBubbleRowAddress] {
        let contact = contactId(of: chat)
        var rows: [PopopxBubbleRowAddress] = []
        rows.reserveCapacity(items.count)
        for ci in items where body(of: ci, chat: chat) != nil {
            rows.append(
                PopopxBubbleRowAddress(
                    messageKey: String(ci.id),
                    contactId: contact,
                    sent: ci.chatDir.sent,
                    isMessage: ci.content.msgContent != nil
                )
            )
        }
        return rows
    }
}

// MARK: - 位置卡片

/// 位置卡片的全部文案。和载荷、渲染同文件，理由见文件头第 7 条。
enum PopopxLocationCopy {
    /// VoiceOver 说这一条气泡的一句话正文。**不含通道**——通道由
    /// `PopopxMessageBubble.spoken` 在前面拼好，这里重复一次就会念两遍。
    static func spoken(_ payload: PopopxLocationPayload) -> String {
        var parts = ["位置"]
        if let name = payload.name { parts.append(name) }
        if let address = payload.address { parts.append(address) }
        parts.append(payload.coordinateString)
        return parts.joined(separator: "，")
    }

    /// 卡片自己的动作提示。SwiftUI 会自己补"按钮"，所以这里只说点了会怎样。
    static let hint = "打开位置菜单"
    static let openNavigation = "在 Apple 地图中打开导航"
    static let copyCoordinates = "复制经纬度坐标"
    static let copied = "已复制经纬度坐标"
    static let cancel = "取消"
}

/// 一条位置消息的渲染。
///
/// 红线（`location-prompt.md:72`）：**列表里的气泡绝不内嵌可交互的 `MKMapView`**——那是一整条
/// GL 渲染管线，一屏七八行就是七八条。这里只有一张 `MKMapSnapshotter` 渲出来的静态位图，配
/// 一个进程内 LRU（`PopopxLocationSnapshotCache`）。图没到、渲染失败、或这个坐标正被别人渲，
/// 一律退回品牌色占位块：地名、地址、坐标永远在，缺的只是那张图。
///
/// 整张卡片是一枚无边框按钮，点了弹 `confirmationDialog`（导航 / 复制坐标）。通道角标不在这里
/// 画——`PopopxMessageBubble.footer` 本来就负责时间、回执、角标那一行。
private struct PopopxLocationCardBubble: View {
    let payload: PopopxLocationPayload
    let ink: PopopxBubbleInk
    /// 针的颜色要跟右下角那枚角标讲同一条通道，而 `PopopxBubbleInk` 只留颜色不留结论，
    /// 所以通道自己传进来。
    let channel: PopopxBubbleChannel

    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: UIImage?
    @State private var showMenu = false
    /// 聊天列表这一层没有屏幕级的 toast 宿主：`.popopxToast` 的契约是"一屏挂一次、贴在最上面"
    /// （PopopxToast.swift:131），而我不打算为一句回执去改 ChatView。所以它挂在卡片自己头顶——
    /// 离动作最近，也不越界。
    @State private var toast = PopopxToastModel()

    var body: some View {
        Button(action: presentMenu) {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                thumbnail
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(payload.displayName)
                        .font(PopopxType.meta)
                        .foregroundStyle(ink.text)
                        .lineLimit(2)
                    if let address = payload.address {
                        Text(address)
                            .font(PopopxType.caption)
                            .foregroundStyle(ink.meta)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: PopopxLocationSnapshotCache.size.width, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PopopxLocationCopy.spoken(payload))
        .accessibilityHint(PopopxLocationCopy.hint)
        // 标题用坐标而不是地名：一个会话里发过两个"家"，菜单得说清是哪一个。
        .confirmationDialog(
            payload.coordinateString,
            isPresented: $showMenu,
            titleVisibility: .visible
        ) {
            Button(PopopxLocationCopy.openNavigation) { openInMaps() }
            Button(PopopxLocationCopy.copyCoordinates) { copyCoordinates() }
            Button(PopopxLocationCopy.cancel, role: .cancel) {}
        }
        .popopxToast(toast)
        .task(id: cacheKey) {
            let image = await PopopxLocationSnapshotCache.shared.image(
                forKey: cacheKey,
                coordinate: coordinate,
                tint: markerTintColor,
                style: interfaceStyle
            )
            // 取不到（没网、被限流、这个坐标正有人在渲）就保留现状：已经画出来的地图不该
            // 因为一次失败的取数被抹回占位块。键变了会再跑一次，命中缓存的那条路径是纯查表。
            if let image { snapshot = image }
        }
    }

    // MARK: 图

    /// 载荷自己不认识 CoreLocation（PopopxLocation.swift 文件头第 1 条），坐标在这一层现拼。
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude)
    }

    /// SwiftUI 的 `ColorScheme` 翻成 UIKit 的 trait：底图样式、针的颜色解析、缓存键三处都
    /// 要它，只在这里翻一次。
    private var interfaceStyle: UIUserInterfaceStyle { colorScheme == .dark ? .dark : .light }

    /// 缓存键要带三样：坐标、针的通道色、深浅色。通道色进键是因为它真的会画进位图里——
    /// 同一个坐标，SMP 那枚是靛针、Mesh 那枚是青针，省掉这一段就会串色。深浅色换的是底图
    /// 样式（苹果给深色底图另有一套瓦片）。
    private var cacheKey: String {
        "\(payload.coordinateKey)|\(channel.isMesh ? "mesh" : "smp")|\(interfaceStyle == .dark ? "d" : "l")"
    }

    /// 针的颜色跟右下角那枚角标讲同一条通道：靛紫 = SMP，青绿 = Mesh（§1.1 第 2 条：
    /// 色相不跨通道借用，所以青色通路的消息在地图上继续用青）。
    private var markerColor: Color { channel.isMesh ? PopopxPalette.mesh : PopopxPalette.brand }

    /// 占位块的墨：卡面（收方）可以用通道色，实底（发方）必须退成本墨——判据和角标那条
    /// 一模一样（`PopopxBubbleInk.onCard` / `monochromeBadgeInk`）。
    private var placeholderInk: Color { ink.onCard ? markerColor : ink.text }

    /// `UIColor(_:) + resolvedColor(with:)` 是 SwiftUI `Color` 落到 UIKit 侧唯一站得住的写法
    /// （PopopxQRCardSheet.swift:145-149 同一先例）。
    private var markerTintColor: UIColor {
        UIColor(markerColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: interfaceStyle))
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
            } else {
                // 占位块：一层极淡的底色 + 一枚针。它不是"加载失败"的红色告警——图缺了
                // 这条消息照样读得懂，也不该在历史消息里长期挂着一个报错。
                //
                // 底色和针**都不许用通道色本身**：发方气泡是 `brand` 实底，靛底画靛针等于没画
                // （§1.1 同一条禁令，`PopopxBubbleInk.monochromeBadgeInk` 在角标上做的就是这件事）。
                // 快照里那枚针不受这条限制——它有整张底图给它做对比度。
                placeholderInk.opacity(colorScheme == .dark ? 0.16 : 0.08)
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(placeholderInk)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PopopxLocationSnapshotCache.size.height)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusControl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusControl, style: .continuous)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        }
        // 图不单独播报：坐标、地名、地址都在下面那两行和整张卡片的 label 里。
        .accessibilityHidden(true)
    }

    // MARK: 动作

    private func presentMenu() {
        PopopxHaptics.selection()
        showMenu = true
    }

    /// 交给 Apple 地图并直接进步行导航态——发位置的场景几乎总是"我要过来"。
    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = payload.displayName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private func copyCoordinates() {
        UIPasteboard.general.string = payload.coordinateString
        PopopxHaptics.notice(.success)
        toast.show(PopopxLocationCopy.copied)
    }
}

/// 进程内的地图快照缓存：`坐标 + 深浅色` → 位图，LRU。
///
/// 上限是照着内存算的：一张 `size`（244×140 pt）@2x 的位图约 0.5 MB，24 张最坏 ≈ 13 MB，
/// 换来的是翻回上半屏不必重渲；再往上就是拿整个 App 的内存换几行已经滚过去的图。
///
/// 这个类**永不 import Metal/GL，也不持有任何 `MKMapView`**：它只是把 `MKMapSnapshotter`
/// 的一次性输出存起来（`location-prompt.md:72` 那条红线的另一半）。
@MainActor
final class PopopxLocationSnapshotCache {
    static let shared = PopopxLocationSnapshotCache()

    /// 缩略图尺寸（pt）。卡片的排版宽度和快照的渲染尺寸是同一个数，改一处两处一起变。
    static let size = CGSize(width: 244, height: 140)

    /// 快照视野的**整幅宽度**（米）：800 m 就是中心点向东西各 400 m，够看清一个路口，
    /// 又不会糊到只剩街区色块。它比选择器那张工作面的视野（`PopopxLocationPickerSheet.swift:443`）宽得多——卡片是缩略图，选择器要认得出单个门牌。
    static let spanMeters: Double = 800

    private static let capacity = 24
    private static let renderScale: CGFloat = 2

    private var images: [String: UIImage] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []

    /// 取一张快照：命中就返回，没命中就现渲。
    ///
    /// 同一个 key 已经有别人在渲时直接返回 nil——这一支先退回占位块，等这张卡片下次
    /// `.task(id:)` 重跑（翻回上半屏、换深浅色都会重跑）。不做等待队列：一个会话里的
    /// 位置消息是个位数的量，为它排队不值这套复杂度。
    func image(
        forKey key: String,
        coordinate: CLLocationCoordinate2D,
        tint: UIColor,
        style: UIUserInterfaceStyle
    ) async -> UIImage? {
        if let hit = touch(key) { return hit }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        guard let image = await Self.render(coordinate: coordinate, tint: tint, style: style) else { return nil }
        store(image, forKey: key)
        return image
    }

    private func touch(_ key: String) -> UIImage? {
        guard let image = images[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    private func store(_ image: UIImage, forKey key: String) {
        while images.count >= Self.capacity, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
        images[key] = image
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static func render(
        coordinate: CLLocationCoordinate2D,
        tint: UIColor,
        style: UIUserInterfaceStyle
    ) async -> UIImage? {
        // 这个类型的 ObjC 名是 `MKMapSnapshotOptions`，Swift 侧只认嵌套写法（探针实测：
        // 直接写 ObjC 名会报 "has been renamed to 'MKMapSnapshotter.Options'"）。
        let options = MKMapSnapshotter.Options()
        options.size = size
        // 倍率和深浅色一次写进同一个 trait：`scale` 这个属性在本 SDK 已经标了
        // deprecated（"Use traitCollection.displayScale"），碰它就破 0 警告门禁。
        options.traitCollection = UITraitCollection { traits in
            traits.displayScale = renderScale
            traits.userInterfaceStyle = style
        }
        // 视野用 `region` 而不是 `cameraBoundary`：后者在本 SDK 的 Options 上不存在（探针实测）。
        options.region = MKCoordinateRegion(center: coordinate, span: span(around: coordinate))
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let base = snapshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = true
        return UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            base.draw(at: .zero)
            // 针画在正中央：`region` 本来就是绕着目标点要的视野，所以"画面中心 = 坐标"这一步
            // 不需要 `point(for:)`，也就不必为一张静态位图去造一个 `MKAnnotation`。
            if let pin = pin(tint: tint) {
                pin.draw(at: CGPoint(
                    x: (base.size.width - pin.size.width) / 2,
                    y: base.size.height / 2 - pin.size.height
                ))
            }
        }
    }

    /// 一枚通道色的针。这里没有用 `MKMarkerAnnotationView`：本 SDK 的 `MKMapSnapshotOptions`
    /// 已经没有 `annotationViews` 这个属性，而 marker 那套默认还会带一只白色标题框——
    /// "除角标那两块贴片之外不得再引入第三种蓝"这条红线在地图上同样成立。
    private static func pin(tint: UIColor) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        return UIImage(systemName: "mappin.circle.fill", withConfiguration: configuration)
            .map { $0.withTintColor(tint, renderingMode: .alwaysTemplate) }
    }

    /// 把"米"换算成经纬度 delta：纬度 1°≈111.32 km，经度还要除 cos(纬度)，否则中高纬度
    /// 的视野会被压扁。两个 delta 按卡片的长宽比分配，好让 `region` 的比画率和位图一致
    /// （不一致时苹果会自己凑，代价是实际视野比名义值宽或窄一截）。
    /// 极地附近 cos→0，这时退回用纬度那一档：宁可视野窄一点，也不要算出 inf 递进 MapKit。
    private static func span(around coordinate: CLLocationCoordinate2D) -> MKCoordinateSpan {
        let degreesPerMeter = 1.0 / 111_320.0
        let width = spanMeters * degreesPerMeter
        let height = spanMeters * Double(size.height / size.width) * degreesPerMeter
        let cosine = cos(coordinate.latitude * .pi / 180)
        return MKCoordinateSpan(
            latitudeDelta: height,
            longitudeDelta: cosine > 0.01 ? width / cosine : width
        )
    }
}

// MARK: - 预览

#if DEBUG
@MainActor
private struct PopopxBubbleGallery: View {
    private static let rows: [PopopxBubbleItem] = [
        PopopxBubbleItem(
            messageKey: "1",
            content: .text("周六上午十点老地方见，我把图纸一起带上。"),
            tail: PopopxBubbleTail(side: .received),
            channel: .smp,
            timeText: "09:12",
            receipt: nil
        ),
        PopopxBubbleItem(
            messageKey: "2",
            content: .text("好，到了给你发消息。"),
            tail: PopopxBubbleTail(side: .sent, tucked: true),
            channel: .mesh(hops: 3),
            timeText: "09:13",
            receipt: .delivered
        ),
        PopopxBubbleItem(
            messageKey: "3",
            content: .text("图纸在附件里。"),
            tail: PopopxBubbleTail(side: .sent, tucked: false),
            channel: .awaitingRelay(reason: .peerUnreachable),
            timeText: "09:14"
        ),
        PopopxBubbleItem(
            messageKey: "4",
            content: .media(name: "IMG_0421.HEIC", detail: "1.4 MB"),
            tail: PopopxBubbleTail(side: .received, tucked: true),
            channel: .mesh(hops: 0),
            timeText: "09:15",
            receipt: .read
        ),
        PopopxBubbleItem(
            messageKey: "5",
            content: .event("对方开启了阅后即焚"),
            channel: .none
        ),
        PopopxBubbleItem(
            messageKey: "6",
            content: .withdrawn("这条消息已撤回"),
            tail: PopopxBubbleTail(side: .sent),
            channel: .none,
            timeText: "09:16"
        ),
        PopopxBubbleItem(
            messageKey: "7",
            content: .location(
                PopopxLocationPayload(
                    latitude: 22.543096,
                    longitude: 114.057865,
                    name: "深圳北站",
                    address: "深圳市龙华区民治街道留仙大道"
                )
            ),
            tail: PopopxBubbleTail(side: .sent),
            channel: .smp,
            timeText: "09:18",
            receipt: .delivered
        ),
        PopopxBubbleItem(
            // 只有坐标、没有地名：卡片第一行退化成 `coordinateString`，这条退化路径要能在
            // 画布里一眼看到。
            messageKey: "8",
            content: .location(PopopxLocationPayload(latitude: 31.230416, longitude: 121.473701)),
            tail: PopopxBubbleTail(side: .received, tucked: true),
            channel: .mesh(hops: 2),
            timeText: "09:20"
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            ForEach(PopopxBubbleGallery.rows, id: \.messageKey) { row in
                PopopxMessageBubble(row)
            }
        }
        .padding(PopopxMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(PopopxPalette.base)
    }
}

#Preview("popopx message bubble") {
    PopopxBubbleGallery()
}
#endif
