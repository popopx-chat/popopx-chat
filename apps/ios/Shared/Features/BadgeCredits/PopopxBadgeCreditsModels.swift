//  PopopxBadgeCreditsModels.swift
//
//  POPOPX 动态隐私节点徽章 + 礼品卡转赠 + 算力点生态的唯一数据层。
//
//  信任模型（写在这里，因为本目录里每一个"签名/验签/防双花/防重放"的判断都引用它）：
//  POPOPX 没有账号、没有业务服务器、没有 Bot（见 AntiTheftDuress 与 mesh 那一轮的裁定）。
//  因此本层的签名**不是身份链**——零服务端就不存在发证的 CA。它承担两件事，不多承诺：
//  1) 篡改留痕：礼品券面额/周期、红包面额、兑换码内容一旦被改动，验签必失败；
//  2) 来源校验：Apple 的 `Transaction.jwsRepresentation` 是唯一的外部锚点，券必须由一笔
//     真实完成且未被核心拒付的 StoreKit 交易铸造（`PopopxStoreKitManager` 负责）。
//  防双花的"花"字也只在本机成立：券的状态机是本地 Keychain 里的原子读改写，
//  跨设备的一致性由"请求只会回到铸造这张券的那条一次性连接上"保证（见 Router）。
//  任何把这套东西描述成"全局账本"的文案都不成立，注释和 UI 措辞都必须遵守上面这条边界。
//
//  铁律：本文件不导入 UIKit/SwiftUI，不读 `UserDefaults.standard` 之外的宿主状态，
//  不做任何网络请求。新增类型一律 `Popopx` 前缀——`Badge*` 那一族命名
//  （`BadgeType`/`BadgeState`/`BadgeStore`/`BadgeLevel`/`BadgePeriod`/`badgeProductIds` …）
//  已被 `Shared/Views/Badges/`（SimpleX 支持者徽章）全局占用，复用等于改别人的语义。

import Foundation
import CryptoKit
import Security

// MARK: - 限额与标定值

/// 全模块共用的标定数。放一处，是为了让"审核备注里的参数表"和代码里的数字
/// 不可能各说一套：文档里的每一个数字都能回到这里被 grep 到。
enum PopopxCommerceLimits {
    /// 72 小时「3 天先锋节点体验徽章」的时长。
    static let trialSeconds: TimeInterval = 72 * 60 * 60
    /// 体验徽章到期后回退免费公共节点时，允许写入的最长时钟漂移（防止未来时间伪造）。
    static let maximumClockSkewMs: Int64 = 15 * 60 * 1000
    /// 本地券包最多存多少张（Keychain 单项体积 + 二维码面板可读性的双重上限）。
    static let maximumVouchers = 200
    /// 算力点流水最多保留多少条。超出即丢弃最旧的（余额本身永远不丢）。
    static let maximumLedgerEntries = 240
    /// 防重放集合的上限：领取过的红包 id / 已核销的券 id / 已入账的交易哈希。
    static let maximumReplayIdentifiers = 2_000
    /// 余额上限。超过它说明数据被改过，钱包直接进 `needsReconcile` 而不是静默截断。
    static let maximumCreditBalance = 100_000
    /// 单个红包的最大面额。
    static let maximumPacketAmount = 10_000
    /// 红包/礼品卡赠言的最长字符数（以解码后的 Unicode 标量计，不是字节）。
    static let maximumNoteCharacters = 60
    /// 一条信令的载荷上限。SMP 自己会分片，但本层拒绝解析超长载荷，
    /// 免得把一段伪造的巨型 base64 交下去解码。
    static let maximumSignalPayloadCharacters = 1_024
    /// 兑换码 checksum 的字节数。
    static let codeChecksumBytes = 2
    /// 个人主页/频道自定义门槛的上限（算力点）。
    static let maximumCreditsThreshold = 100_000
    /// 门槛输入允许的位数，与 `PopopxProfilePayload.maximumTTLDigits` 同一族约束。
    static let maximumThresholdDigits = 6
    /// 红包固定面额档位。苹果 3.1.1 的"不得随机金额"红线：这里只有确定档位，
    /// UI 层不允许出现自由输入的金额字段。
    static let redPacketAmounts: [Int] = [10, 50, 100, 500]
    /// 群聊等额均分红包的单次最大领取人数（超过则拆开发）。
    static let maximumPacketRecipients = 100
    /// 未领完的红包在发送端悬多久才把余款退回去。没有服务端回收，只能由发送端按时间判结束；
    /// 取 30 天是与徽章月档同长的"一个月"，也让退款不会发生在份额还可能被领走的时候——
    /// 提前退就是凭空多出点数，这个特性里最坏的一种错账。
    static let packetClaimGraceSeconds = 30 * 86_400
    /// 频道订阅凭证的有效期。取 30 天是与徽章月档同长的"一个月"，
    /// 也让"每月 x 点"这句话在两个地方说的是同一个长度。
    static let channelTicketSeconds = 30 * 86_400
    /// 绝密"1 小时超长防窥窗口"的时长与价格。
    static let extendedSecureWindowSeconds = 3_600
    static let extendedSecureWindowCost = 20
    /// 流光盾牌头像框 / 暗金二维码名片皮肤的价格。
    static let avatarFrameCost = 150
    static let qrCardSkinCost = 150
    /// 本机计数与胶囊转圈的最小间隔；真正的检查节奏由 `PopopxBadgeManager` 的 30 秒心跳给出。
    static let nodeRotationSeconds: TimeInterval = 15
}

// MARK: - SKU

/// 徽章周期。订阅、礼品券、算力点兑换三处都复用它，避免出现第二种"多久"的表示法。
enum PopopxNodeBadgePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case monthly
    case annual

    var id: String { rawValue }

    /// 自然日天数，用于本地签发时的到期推算（不是账单周期，账单周期归 Apple）。
    var days: Int {
        switch self {
        case .monthly: 30
        case .annual: 365
        }
    }

    /// 算力点兑换同周期的标定价。`100 算力点 = 1 天`：月度 30×20=600、年度 365×20=7300 会被
    /// 读成"年度比 $49.99 贵"，所以标定值按人民币/美元实付价的点数化结果单独给定，
    /// 并只在这里给一次——兑换页、商城页、审核文档三处必须回到这里取值。
    var creditsCost: Int {
        switch self {
        case .monthly: 600
        case .annual: 4_500
        }
    }

    /// 进 URI 的单字母形式。
    var wireValue: String {
        switch self {
        case .monthly: "m"
        case .annual: "y"
        }
    }

    static func from(wire raw: String) -> PopopxNodeBadgePeriod? {
        switch raw {
        case "m": .monthly
        case "y": .annual
        default: nil
        }
    }

    var fallbackPriceText: String {
        switch self {
        case .monthly: "$6.99"
        case .annual: "$49.99"
        }
    }
}

/// SKU 的语义分档。StoreKit 的 `Product` 只有 `Subscription/Consumable` 两型，
/// 而业务上有三种东西（自用续费、可多购的礼品券、点数充值），所以类型 + 周期/面额一起给。
enum PopopxNodeBadgeSkuKind: Hashable, Sendable {
    case subscription(PopopxNodeBadgePeriod)
    case giftCard(PopopxNodeBadgePeriod)
    case credits(Int)
}

/// 7 个内购商品。`productId` 是唯一真相源，`PopopxStoreKit.storekit` 与 App Store Connect
/// 两边都必须逐字对上这 7 串。
enum PopopxNodeBadgeSku: String, CaseIterable, Identifiable, Sendable {
    case subscriptionAnnual
    case subscriptionMonthly
    case giftAnnual
    case giftMonthly
    case credits100
    case credits500
    case credits2000

    var id: String { rawValue }

    var productId: String {
        switch self {
        case .subscriptionAnnual: "com.popopx.badge.node.annual"
        case .subscriptionMonthly: "com.popopx.badge.node.monthly"
        case .giftAnnual: "com.popopx.gift.node.annual"
        case .giftMonthly: "com.popopx.gift.node.monthly"
        case .credits100: "com.popopx.credits.100"
        case .credits500: "com.popopx.credits.500"
        case .credits2000: "com.popopx.credits.2000"
        }
    }

    static let productIds: [String] = PopopxNodeBadgeSku.allCases.map(\.productId)

    static func sku(for productId: String) -> PopopxNodeBadgeSku? {
        allCases.first { $0.productId == productId }
    }

    var kind: PopopxNodeBadgeSkuKind {
        switch self {
        case .subscriptionAnnual: .subscription(.annual)
        case .subscriptionMonthly: .subscription(.monthly)
        case .giftAnnual: .giftCard(.annual)
        case .giftMonthly: .giftCard(.monthly)
        case .credits100: .credits(100)
        case .credits500: .credits(500)
        case .credits2000: .credits(2_000)
        }
    }

    var badgePeriod: PopopxNodeBadgePeriod? {
        switch kind {
        case let .subscription(period), let .giftCard(period): period
        case .credits: nil
        }
    }

    /// 算力点充值包的**入账面额**。严格等于标定值，绝不加赠——
    /// 一旦出现"赠送 XX 算力点"，苹果 3.1.1 的等额性与国内促销条款两边都踩。
    var creditedAmount: Int? {
        if case let .credits(amount) = kind { amount } else { nil }
    }

    var isSubscription: Bool {
        if case .subscription = kind { return true }
        return false
    }

    /// 兜底价格文案。StoreKit 的 `displayPrice` 才是权威（区域货币不同），
    /// 这里只在 `Product.products(for:)` 失败或还没返回时占位，占位期间不显示"立即购买"。
    var fallbackPriceText: String {
        switch self {
        case .subscriptionAnnual, .giftAnnual: "$49.99"
        case .subscriptionMonthly, .giftMonthly: "$6.99"
        case .credits100: "$1.99"
        case .credits500: "$8.99"
        case .credits2000: "$29.99"
        }
    }
}

// MARK: - 徽章状态

/// 徽章的来源。体验、订阅、算力点兑换、别人赠的券，四种来源点亮的是同一个徽章，
/// 差别只在续费归谁、以及能不能被恢复购买找回来。
enum PopopxBadgeSource: String, Codable, CaseIterable, Sendable {
    case pioneerTrial
    case appleSubscription
    case creditsExchange
    case giftedVoucher

    /// 只有订阅这一档由 Apple 自动续费；恢复购买（`AppStore.sync()`）也只对它有意义。
    var renewsAutomatically: Bool { self == .appleSubscription }
}

/// 一条徽章记录的持久化形态。整个模块只有 `PopopxBadgeManager` 会写它。
struct PopopxBadgeRecord: Codable, Hashable, Sendable {
    var period: PopopxNodeBadgePeriod
    var source: PopopxBadgeSource
    var issuedAtMs: Int64
    var expiresAtMs: Int64
    /// 节点路由轮换计数。真机上线前它只是本地计数，不代表任何服务端行为。
    var rotationIndex: Int
    /// 来源凭据的 SHA-256 前 16 位十六进制（JWS 原文/兑换流水），用于事后对账。
    var receiptDigest: String?
    /// 体验徽章的防重放指纹（DeviceCheck token 或本机安装指纹的摘要）。
    var trialGuard: String?
}

/// 胶囊渲染要的那一档状态。和 `PopopxBadgePhase` 分开，是因为视图层不该拿到日期再自己比。
enum PopopxBadgeCapsuleState: String, Hashable, Sendable {
    /// 体验态：赛博青呼吸光晕。
    case trialPulsing
    /// 正式点亮态：翡翠绿 + 节点刷新旋转。
    case activeLit
    /// 休眠态：冷雾灰。
    case dormant
}

/// 徽章三态。`dormant` 不是"失败"，是"用免费公共 SMP 节点"这个正常态——
/// UI 文案与无障碍描述都必须按这个措辞，不能写成"已过期/未激活"。
enum PopopxBadgePhase: Hashable, Sendable {
    case dormant
    case trial(expiresAt: Date)
    case active(source: PopopxBadgeSource, expiresAt: Date)

    var capsuleState: PopopxBadgeCapsuleState {
        switch self {
        case .trial: .trialPulsing
        case .active: .activeLit
        case .dormant: .dormant
        }
    }

    var isLit: Bool {
        switch self {
        case .dormant: false
        case .trial, .active: true
        }
    }

    var remainingSeconds: TimeInterval {
        switch self {
        case .dormant: 0
        case let .trial(expiresAt), let .active(_, expiresAt):
            max(0, expiresAt.timeIntervalSinceNow)
        }
    }

    /// 到期日期；休眠态为 nil，调用方因此无法显示"0 秒"或"1970 年"这种假到期。
    var expiresAt: Date? {
        switch self {
        case .dormant: nil
        case let .trial(expiresAt), let .active(_, expiresAt): expiresAt
        }
    }

    /// 由记录推当前态。`now` 注入而不是内部 `Date()`，是为了让"到期回退"可被单测命中。
    static func phase(for record: PopopxBadgeRecord?, now: Date = Date()) -> PopopxBadgePhase {
        guard let record else { return .dormant }
        let expiresAt = Date(timeIntervalSince1970: Double(record.expiresAtMs) / 1_000)
        guard expiresAt > now else { return .dormant }
        if record.source == .pioneerTrial { return .trial(expiresAt: expiresAt) }
        return .active(source: record.source, expiresAt: expiresAt)
    }
}

// MARK: - 礼品券

/// 券的生命周期。`consumed` 只给接收方：对方回传的 grant 已经点亮了本机徽章，这张券就此落地。
enum PopopxVoucherState: String, Codable, CaseIterable, Sendable {
    case unused
    case redeemed
    case consumed
}

/// 本地铸造的礼品徽章券。`jwsDigest` 是 Apple 收据的摘要——原文不落地，
/// 因为那串东西里带 Apple ID 关联信息，留在 Keychain 里只是把风险搬进自己的备份。
struct PopopxNodeVoucher: Codable, Hashable, Identifiable, Sendable {
    let voucherId: String
    var period: PopopxNodeBadgePeriod
    var state: PopopxVoucherState
    let mintedAtMs: Int64
    let transactionId: String
    let jwsDigest: String
    /// 兑换码（`PPX1-…`）的摘要，用于"这张券发出去过"的可追溯，不存码本身。
    var codeDigest: String?
    var redeemedAtMs: Int64?
    /// 接收方才会有的字段：对方 ACK 回来的授权原文。发送方保持 nil。
    var grantBase64URL: String?

    var id: String { voucherId }

    var isRedeemable: Bool { state == .unused }
}

/// 券的授权书：由赠方本地签名、随 ACK 回传给兑方、兑方据此点亮徽章并记入券包。
/// 签名覆盖 `canonicalBytes`，所以 period 被人从 `m` 改成 `y` 会当场验不过。
struct PopopxBadgeGrant: Codable, Hashable, Sendable {
    let voucherId: String
    let period: PopopxNodeBadgePeriod
    let grantedAtMs: Int64
    let expiresAtMs: Int64
    /// 赠方本地密钥的 x963 公钥（无填充 base64url）。
    let giverPublicKey: String
    /// 对 `canonicalBytes` 的 ECDSA P-256 签名（DER，无填充 base64url）。
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "grant", parts: [voucherId, period.wireValue, String(grantedAtMs), String(expiresAtMs)])
    }

    var isSignatureValid: Bool {
        PopopxCommerceSignature.verify(signatureBase64URL: signature, for: canonicalBytes, publicKeyBase64URL: giverPublicKey)
    }
}

// MARK: - 一次性连接 + 徽章 的二合一兑换码

/// 兑换码里装的东西：一条一次性 SMP 连接链接 + 一张券的身份 + 赠方公钥。
struct PopopxRedeemEnvelope: Codable, Hashable, Sendable {
    /// `popopx:/…` 形式的一次性连接链接（由 `PopopxInviteLink.mintOneTime` 那同一条接口铸出）。
    let inviteLink: String
    let voucherId: String
    let period: PopopxNodeBadgePeriod
    let mintedAtMs: Int64
    /// 16 字节随机数。同一张券重复出码（用户点"重新生成"）时用它区分前后两码。
    let nonce: String
    /// 赠方公钥（x963 base64url）。
    let giverPublicKey: String
    /// 赠方对 `canonicalBytes` 的签名。
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "code", parts: [voucherId, period.wireValue, String(mintedAtMs), nonce, inviteLink])
    }

    var isSignatureValid: Bool {
        PopopxCommerceSignature.verify(signatureBase64URL: signature, for: canonicalBytes, publicKeyBase64URL: giverPublicKey)
    }
}

/// `PPX1-…` 兑换码的编解码。
///
/// 为什么码里要有 checksum：`decode` 先验两个字节再解 JSON，是为了让手输错一位
/// 直接落到"校验失败"而不是"解出一段看不懂的 JSON"——前者能提示用户重来，后者只能报内部错误。
enum PopopxRedeemCode {
    static let prefix = "PPX1-"

    /// 分段展示用的组宽（每 8 个字符一段，共 5 段一屏正好）。
    static let displayGroupWidth = 8

    static func encode(_ envelope: PopopxRedeemEnvelope) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(envelope), body.count <= 4_096 else { return nil }
        var payload = Data(capacity: PopopxCommerceLimits.codeChecksumBytes + body.count)
        payload.append(PopopxCommerceSignature.digest(body).prefix(PopopxCommerceLimits.codeChecksumBytes))
        payload.append(body)
        return prefix + payload.popopxBase64URL
    }

    static func decode(_ code: String) -> PopopxRedeemEnvelope? {
        let stripped = normalized(code)
        guard stripped.hasPrefix(prefix) else { return nil }
        let body = String(stripped.dropFirst(prefix.count))
        guard !body.isEmpty, let payload = Data(popopxBase64URL: body) else { return nil }
        guard payload.count > PopopxCommerceLimits.codeChecksumBytes else { return nil }
        let checksum = payload.prefix(PopopxCommerceLimits.codeChecksumBytes)
        let json = payload.dropFirst(PopopxCommerceLimits.codeChecksumBytes)
        guard PopopxCommerceSignature.digest(json).starts(with: checksum) else { return nil }
        return try? JSONDecoder().decode(PopopxRedeemEnvelope.self, from: Data(json))
    }

    /// 归一化。**只**去掉空白与前缀大小写差异：base64url 的字母表里就含 `-`，
    /// 把 `-` 当分隔符删掉会静默改坏载荷，所以分隔符只能是空白，UI 也必须按这个约束展示。
    static func normalized(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        var text = String(String.UnicodeScalarView(stripped))
        if text.uppercased().hasPrefix("PPX1-") {
            text = prefix + String(text.dropFirst(prefix.count))
        }
        return text
    }

    /// 给人抄的分组形式（`PPX1-ABCD1234 EFGH…`）。
    static func grouped(_ code: String) -> String {
        let body = code.hasPrefix(prefix) ? String(code.dropFirst(prefix.count)) : code
        guard !body.isEmpty else { return code }
        var groups: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty {
            let take = min(displayGroupWidth, rest.count)
            groups.append(String(rest.prefix(take)))
            rest = rest.dropFirst(take)
        }
        return prefix + groups.joined(separator: " ")
    }

    /// 复制给用户的整码：前缀 + 未分组原文（分组只给屏幕上看，复制要能直接粘）。
    static func clipboardValue(_ code: String) -> String { code }
}

// MARK: - 会话流 URI（popopx://gift、popopx://redpacket 与 popopx://channel）

/// 礼品卡气泡的载荷。
///
/// 字段命名和 `loc`/`sec`/`profile` 三支保持同一族（单字母、值一律无需转义）：
/// `note` 里可能有任何字符，所以它进 URI 前是 base64url，而不是 percent-encoding——
/// 解析端因此可以始终按 `&` 切、按第一个 `=` 分，这一条前提和三支完全一致。
struct PopopxGiftCardPayload: Codable, Hashable, Sendable {
    static let scheme = "popopx"
    static let host = "gift"
    static let fieldNames: Set<String> = ["v", "p", "n", "t", "s"]
    static let maximumVoucherIdCharacters = 22
    static let maximumSignatureCharacters = 180

    let voucherId: String
    let period: PopopxNodeBadgePeriod
    let note: String
    let mintedAtMs: Int64
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "gift", parts: [voucherId, period.wireValue, String(mintedAtMs)]) + Data(note.utf8)
    }

    var isSignatureValid: Bool {
        // 卡片不带赠方公钥（会话流里公钥属于隐私面），所以这一支只在"本端就是赠方"时可判；
        // 接收侧的真伪判定发生在 ACK 回来的 `PopopxBadgeGrant` 上，不在这里。
        PopopxCommerceSignature.verifySelfIssued(signatureBase64URL: signature, for: canonicalBytes)
    }

    init(voucherId: String, period: PopopxNodeBadgePeriod, note: String, mintedAtMs: Int64, signature: String) {
        self.voucherId = voucherId
        self.period = period
        self.note = note
        self.mintedAtMs = mintedAtMs
        self.signature = signature
    }

    /// 铸造：签一次、编码一次。失败 = 本机身份密钥取不到，调用方必须给可见反馈。
    static func make(voucherId: String, period: PopopxNodeBadgePeriod, note: String, mintedAtMs: Int64) -> PopopxGiftCardPayload? {
        let trimmed = String(note.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        let body = PopopxCommerceSignature.canonical(kind: "gift", parts: [voucherId, period.wireValue, String(mintedAtMs)]) + Data(trimmed.utf8)
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: body) else { return nil }
        return PopopxGiftCardPayload(voucherId: voucherId, period: period, note: trimmed, mintedAtMs: mintedAtMs, signature: signature)
    }

    var wireString: String {
        let noteField = Data(note.utf8).popopxBase64URL
        return "\(Self.scheme)://\(Self.host)?v=\(voucherId)&p=\(period.wireValue)&n=\(noteField)&t=\(mintedAtMs)&s=\(signature)"
    }

    /// 与 `PopopxLocationPayload.parse` 同一判据：按空白切、从最后一个 token 试起、
    /// scheme+host 双查、字段名白名单、必需字段齐备、长度封顶。
    static func parse(from text: String) -> PopopxGiftCardPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) { return payload }
        }
        return nil
    }

    static func parseToken(_ token: String) -> PopopxGiftCardPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }
        var fields: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fieldNames.contains(key), fields[key] == nil else { continue }
            fields[key] = String(parts[1])
        }
        guard
            let voucherId = fields["v"],
            voucherId.count <= maximumVoucherIdCharacters,
            !voucherId.isEmpty,
            let periodRaw = fields["p"],
            let period = PopopxNodeBadgePeriod.from(wire: periodRaw),
            let rawTime = fields["t"],
            rawTime.allSatisfy(\.isNumber),
            !rawTime.isEmpty,
            rawTime.count <= 15,
            let mintedAtMs = Int64(rawTime),
            let signature = fields["s"],
            signature.count <= maximumSignatureCharacters,
            !signature.isEmpty
        else { return nil }
        let noteField = fields["n"] ?? ""
        let note: String
        if noteField.isEmpty {
            note = ""
        } else if let data = Data(popopxBase64URL: noteField), let decoded = String(data: data, encoding: .utf8) {
            note = String(decoded.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        } else {
            return nil
        }
        return PopopxGiftCardPayload(
            voucherId: voucherId,
            period: period,
            note: note,
            mintedAtMs: mintedAtMs,
            signature: signature
        )
    }
}

/// 算力点红包气泡的载荷。规范列出的字段是 `id`/`amount`/`note`/`sig`，这里多出**一个** `n`（份数）：
/// 群聊等额均分时，领取端必须知道自己那一份是多少，而那一格只有这张卡片可看——
/// 没有 `n`，要么让收件人自己除以人数（别人能改），要么把份数写进 `note`（那是用户文本，不是账目）。
/// 所以 `n` 进签名原文，改份数与改金额同样是"验签失败"。单聊即 `n=1`，缺省也按 1 解。
struct PopopxRedPacketPayload: Codable, Hashable, Sendable {
    static let scheme = "popopx"
    static let host = "redpacket"
    static let fieldNames: Set<String> = ["id", "amount", "note", "sig", "n"]
    static let maximumPacketIdCharacters = 32
    static let maximumAmountDigits = 6
    static let maximumRecipientsDigits = 3
    static let maximumSignatureCharacters = 180

    let packetId: String
    let amount: Int
    let recipients: Int
    let note: String
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "rp", parts: [packetId, String(amount), String(recipients)]) + Data(note.utf8)
    }

    var isSelfSignatureValid: Bool {
        PopopxCommerceSignature.verifySelfIssued(signatureBase64URL: signature, for: canonicalBytes)
    }

    /// 面额必须落回标定档位之一：UI 只给固定档位，但**判据不能只在 UI**——
    /// 一条被改过 amount 的红包文本完全可以被粘贴进会话，这里必须拒绝。
    var isAmountAuthorized: Bool {
        PopopxCommerceLimits.redPacketAmounts.contains(amount)
    }

    /// 单人应得额。除不尽的载荷一律当作伪造：它不可能是"等额均分"，
    /// 而按向下取整去入账就是把差额悄悄吞掉，那笔钱谁也对不上。
    var amountPerRecipient: Int? {
        guard recipients >= 1, amount % recipients == 0 else { return nil }
        return amount / recipients
    }

    init(packetId: String, amount: Int, recipients: Int, note: String, signature: String) {
        self.packetId = packetId
        self.amount = amount
        self.recipients = recipients
        self.note = note
        self.signature = signature
    }

    static func make(packetId: String, amount: Int, recipients: Int, note: String) -> PopopxRedPacketPayload? {
        guard PopopxCommerceLimits.redPacketAmounts.contains(amount),
              recipients >= 1,
              recipients <= PopopxCommerceLimits.maximumPacketRecipients,
              amount % recipients == 0
        else { return nil }
        let trimmed = String(note.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        let body = PopopxCommerceSignature.canonical(kind: "rp", parts: [packetId, String(amount), String(recipients)]) + Data(trimmed.utf8)
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: body) else { return nil }
        return PopopxRedPacketPayload(packetId: packetId, amount: amount, recipients: recipients, note: trimmed, signature: signature)
    }

    var wireString: String {
        let noteField = Data(note.utf8).popopxBase64URL
        return "\(Self.scheme)://\(Self.host)?id=\(packetId)&amount=\(amount)&n=\(recipients)&note=\(noteField)&sig=\(signature)"
    }

    static func parse(from text: String) -> PopopxRedPacketPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) { return payload }
        }
        return nil
    }

    static func parseToken(_ token: String) -> PopopxRedPacketPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }
        var fields: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fieldNames.contains(key), fields[key] == nil else { continue }
            fields[key] = String(parts[1])
        }
        guard
            let packetId = fields["id"],
            !packetId.isEmpty,
            packetId.count <= maximumPacketIdCharacters,
            let rawAmount = fields["amount"],
            rawAmount.allSatisfy(\.isNumber),
            !rawAmount.isEmpty,
            rawAmount.count <= maximumAmountDigits,
            let amount = Int(rawAmount),
            amount > 0,
            let signature = fields["sig"],
            !signature.isEmpty,
            signature.count <= maximumSignatureCharacters
        else { return nil }
        // 份数缺省为 1：那是"单聊红包"的唯一合法取值，也是 `n` 出现之前铸出的载荷该有的样子。
        let rawRecipients = fields["n"] ?? "1"
        guard rawRecipients.allSatisfy(\.isNumber), !rawRecipients.isEmpty,
              rawRecipients.count <= maximumRecipientsDigits,
              let recipients = Int(rawRecipients), recipients >= 1,
              recipients <= PopopxCommerceLimits.maximumPacketRecipients
        else { return nil }
        let noteField = fields["note"] ?? ""
        let note: String
        if noteField.isEmpty {
            note = ""
        } else if let data = Data(popopxBase64URL: noteField), let decoded = String(data: data, encoding: .utf8) {
            note = String(decoded.unicodeScalars.prefix(PopopxCommerceLimits.maximumNoteCharacters))
        } else {
            return nil
        }
        return PopopxRedPacketPayload(packetId: packetId, amount: amount, recipients: recipients, note: note, signature: signature)
    }
}

/// 频道订阅门槛卡片气泡的载荷。它是一条**可见**消息，不是静默信令：
/// 门槛是"频道主要让成员知道的那个价"，把它藏起来就等于让成员对一个看不见的数字付钱。
///
/// ### 为什么必须走消息，而不是"本机存一份"
/// 没有服务端，也没有频道主的地址簿：成员那台设备唯一的真值来源就是频道里发出来的这一行。
/// 所以发布 = 发一条消息（`PopopxSilentSignalingRouter.sendChannelAccess`），
/// 订阅面板的价格 = 从这条消息里解出来的 `p`。任何一侧都不自己编一个数。
///
/// ### 字段
/// 与 `gift`/`redpacket` 同一族（单字母、值无需转义）：`p`=门槛（算力点/格，0 允许但发不出卡片，
/// 见 `make`），`t`=发布时刻（毫秒），`e`=发布方公钥（x963 无填充 base64url），`s`=签名。
/// 频道本身**不进载荷**：成员侧的凭证键是本机那个会话 id（`GroupInfo.id`），
/// 它在一台设备上稳定，跨设备本来就不通用（凭证只写在本机钥匙串，第 4 节那句话）。
/// 把本机 id 签进消息里，只会造出一个"对方那台设备上根本不存在"的键。
struct PopopxChannelAccessPayload: Codable, Hashable, Sendable {
    static let scheme = "popopx"
    static let host = "channel"
    static let fieldNames: Set<String> = ["p", "t", "e", "s"]
    static let maximumPriceDigits = 6
    static let maximumPublicKeyCharacters = 120
    static let maximumSignatureCharacters = 180

    let price: Int
    let publishedAtMs: Int64
    let issuerPublicKeyBase64URL: String
    let signature: String

    var canonicalBytes: Data {
        PopopxCommerceSignature.canonical(kind: "chan", parts: [String(price), String(publishedAtMs), issuerPublicKeyBase64URL])
    }

    /// 签发方自己那台设备上的复核（与 `PopopxRedPacketPayload.isSelfSignatureValid` 同一档用途）。
    var isSelfSignatureValid: Bool {
        PopopxCommerceSignature.verifySelfIssued(signatureBase64URL: signature, for: canonicalBytes)
    }

    /// 成员侧的真伪判定：公钥就在这条消息里，因此**不需要**双方是联系人，也不依赖本机钥匙。
    /// 这一条不是装饰：改一次 `p` 就是一次验签失败，而门槛直接决定扣多少钱。
    var isIssuerSignatureValid: Bool {
        PopopxCommerceSignature.verify(
            signatureBase64URL: signature,
            for: canonicalBytes,
            publicKeyBase64URL: issuerPublicKeyBase64URL
        )
    }

    /// 门槛必须是判据范围内的数：`0` 合法（免费的频道），负数、超过 100,000 都不合法，
    /// 而判据放在这一层而不是只放在输入框，是因为这条 URI 可以被粘贴进任何会话。
    var isPriceAuthorized: Bool {
        price >= 0 && price <= PopopxCommerceLimits.maximumCreditsThreshold
    }

    init(price: Int, publishedAtMs: Int64, issuerPublicKeyBase64URL: String, signature: String) {
        self.price = price
        self.publishedAtMs = publishedAtMs
        self.issuerPublicKeyBase64URL = issuerPublicKeyBase64URL
        self.signature = signature
    }

    /// 发布：签一次、编码一次。取不到本机密钥就返回 nil，调用方必须给可见反馈。
    /// `make` 拒绝 `price == 0`：那一格既不扣点也不留流水，发出去只是一条噪音（面板里那一支说明过）。
    /// `localPublicKeyBase64URL()` 在取不到密钥时返回**空串**，所以这里先排空再签——
    /// 一把没有的钥匙签出来的卡片，成员那边只会得到"验不过"，而真实原因是"本机没密钥"。
    static func make(price: Int, publishedAtMs: Int64) -> PopopxChannelAccessPayload? {
        guard price >= 1, price <= PopopxCommerceLimits.maximumCreditsThreshold else { return nil }
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty else { return nil }
        let body = PopopxCommerceSignature.canonical(kind: "chan", parts: [String(price), String(publishedAtMs), publicKey])
        guard let signature = PopopxCommerceSignature.signatureBase64URL(for: body) else { return nil }
        return PopopxChannelAccessPayload(price: price, publishedAtMs: publishedAtMs, issuerPublicKeyBase64URL: publicKey, signature: signature)
    }

    var wireString: String {
        "\(Self.scheme)://\(Self.host)?p=\(price)&t=\(publishedAtMs)&e=\(issuerPublicKeyBase64URL)&s=\(signature)"
    }

    /// 与 `PopopxRedPacketPayload.parse` 同一判据：按空白切、从最后一个 token 试起、
    /// scheme+host 双查、字段名白名单、必需字段齐备、长度封顶。
    static func parse(from text: String) -> PopopxChannelAccessPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) { return payload }
        }
        return nil
    }

    static func parseToken(_ token: String) -> PopopxChannelAccessPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }
        var fields: [String: String] = [:]
        for pair in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fieldNames.contains(key), fields[key] == nil else { continue }
            fields[key] = String(parts[1])
        }
        guard
            let rawPrice = fields["p"],
            rawPrice.allSatisfy(\.isNumber),
            !rawPrice.isEmpty,
            rawPrice.count <= maximumPriceDigits,
            let price = Int(rawPrice),
            price >= 0,
            price <= PopopxCommerceLimits.maximumCreditsThreshold,
            let rawTime = fields["t"],
            rawTime.allSatisfy(\.isNumber),
            rawTime.count <= 15,
            let publishedAtMs = Int64(rawTime),
            let publicKey = fields["e"],
            !publicKey.isEmpty,
            publicKey.count <= maximumPublicKeyCharacters,
            let signature = fields["s"],
            !signature.isEmpty,
            signature.count <= maximumSignatureCharacters
        else { return nil }
        return PopopxChannelAccessPayload(
            price: price,
            publishedAtMs: publishedAtMs,
            issuerPublicKeyBase64URL: publicKey,
            signature: signature
        )
    }
}

// MARK: - 不可见信令

/// 信令种类。字符串与规范逐字对齐（`::popopx_sys::` + 大写名 + `::` + 载荷）。
enum PopopxCommerceSignalKind: String, CaseIterable, Sendable {
    case externalRedeemRequest = "EXT_REDEEM_REQ"
    case externalRedeemAcknowledge = "EXT_REDEEM_ACK"
    case chatRedeemRequest = "CHAT_REDEEM_REQ"
    case chatRedeemAcknowledge = "CHAT_REDEEM_ACK"
    case redPacketClaimed = "REDPACKET_CLAIMED"
    /// 资料卡解锁回执。提示词把它和频道核销回执写成"静默通知"，但五种名字里没有它们那一个，
    /// 所以这一格是**按需求补的第六种**，`Docs/app-store-review-notes.md` 里单独一条说明它为什么存在。
    /// 它只进不出：收到的一侧删行、不动任何界面，因为"谁看了你的主页"一旦变成持久记录就不再是静默。
    case profileUnlocked = "PROFILE_UNLOCKED"
    /// 频道订阅的核销回执。载荷是 `{chatInfoId}::{expiresAtMs}` 两截，用**最后一对** `::` 分，
    /// 因为会话键本身形如 `#<本机行号>`，只有末尾那一段保证是数字。
    /// 名字由产品裁定给定（第 2 轮第 2 条），字段顺序也是：这台设备上"哪个频道、哪一期到期"。
    case channelSubscriptionAcknowledge = "CHANNEL_SUB_ACK"

    /// 只有这两种信令允许在群/频道里被接手。判据的原因不是"群里不能收信令"，
    /// 而是 `awaitingAcks` 按 chatId 记账：群里第三个人发来的兑换 ACK 会把别人那一笔判掉
    /// （路由器 `observeIncoming` 那一节）。红包回执与频道核销回执各自按 packetId / 会话键记，
    /// 不经 `awaitingAcks`，所以它们在群里是安全的。
    var acceptedInGroup: Bool {
        self == .redPacketClaimed || self == .channelSubscriptionAcknowledge
    }
}

/// 一条已解析的信令。
struct PopopxCommerceSignal: Hashable, Sendable {
    let kind: PopopxCommerceSignalKind
    /// 载荷：voucherId，或 grant 的 base64url，或 packetId。
    let payload: String

    var isRequest: Bool {
        switch kind {
        case .externalRedeemRequest, .chatRedeemRequest: true
        case .externalRedeemAcknowledge, .chatRedeemAcknowledge, .redPacketClaimed, .profileUnlocked,
             .channelSubscriptionAcknowledge: false
        }
    }
}

/// `::popopx_sys::` 的编解码。
///
/// 为什么 `parse` 要求整串相等而不是 contains：`contains` 会让一句
/// "看这段 ::popopx_sys:: 的截图" 变成一条可执行信令。整串相等是唯一安全的解析边界，
/// 渲染端的抑制逻辑也共用它——判据只有一份。
enum PopopxSysMarker {
    static let marker = "::popopx_sys::"

    static func wireString(for signal: PopopxCommerceSignal) -> String {
        "\(marker)\(signal.kind.rawValue)::\(signal.payload)"
    }

    static func parse(wholeText text: String) -> PopopxCommerceSignal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }
        let rest = String(trimmed.dropFirst(marker.count))
        // 只按**第一个** `::` 切：类型名里不可能有冒号，grant 的 base64url 里也不可能。
        // 用 split(maxSplits:) 会把 `EXT_REDEEM_REQ:abc`（单个冒号）也当成合法形式，
        // 于是切出一个不存在的类型名之后，再把偏移硬算进载荷——那是最容易静默错位的地方。
        guard let separator = rest.range(of: "::") else { return nil }
        let kindText = String(rest[..<separator.lowerBound])
        let payload = String(rest[separator.upperBound...])
        guard
            let kind = PopopxCommerceSignalKind(rawValue: kindText),
            !payload.isEmpty,
            payload.count <= PopopxCommerceLimits.maximumSignalPayloadCharacters
        else { return nil }
        return PopopxCommerceSignal(kind: kind, payload: payload)
    }

    /// 渲染抑制的入口：命中即整行不上气泡、不进预览、不朗读。
    static func isSignalText(_ text: String) -> Bool {
        parse(wholeText: text) != nil
    }
}

// MARK: - 算力点值类型

/// 流水类别。`sign` 只在这里定义一次，UI 的正负号与颜色都从它派生。
enum PopopxCreditsEntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case storePurchase
    case badgeExchange
    case giftVoucherExchange
    case redPacketSent
    case redPacketReceived
    case redPacketRefund
    case channelSubscription
    case profileUnlock
    case secureWindow
    case cosmetic
    case adjustment

    var id: String { rawValue }

    /// 收入为正、支出为负。`adjustment` 两头都可能，所以它返回 nil 由条目自己带符号。
    var sign: Int? {
        switch self {
        case .storePurchase, .redPacketReceived, .adjustment: nil
        case .badgeExchange, .giftVoucherExchange, .redPacketSent, .channelSubscription,
             .profileUnlock, .secureWindow, .cosmetic: -1
        case .redPacketRefund: 1
        }
    }

    var isIncome: Bool {
        switch self {
        case .storePurchase, .redPacketReceived, .redPacketRefund: true
        case .adjustment: false
        default: false
        }
    }
}

/// 一条流水。`id` 就是防重放用的交易哈希，所以它同时是账目主键和去重键。
struct PopopxCreditsEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let amount: Int
    let kind: PopopxCreditsEntryKind
    let note: String
    let timestampMs: Int64
    /// 记账后的余额快照。缺省是旧条目（升级前写的），UI 对缺省不显示"余额"那一行。
    var balanceAfter: Int?
}

/// 钱包本体。放 Keychain，不放文件：这台设备上的余额一旦被越狱工具改掉，
/// 改的是一段 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 的密文，风险面比明文 plist 小。
struct PopopxCreditsWallet: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var balance: Int
    var updatedAtMs: Int64
    /// 余额与流水对不上时置真。宁可让用户看到"需要重新对账"，也不要静默把错账当余额花掉。
    var needsReconcile: Bool
}

/// 一条还没被领完的红包（发送方持有，用于校验 ACK 与退款）。
struct PopopxPendingRedPacket: Codable, Hashable, Identifiable, Sendable {
    let packetId: String
    let amount: Int
    let note: String
    let recipientCount: Int
    var claimedCount: Int
    let createdAtMs: Int64
    /// 群聊均分时的单人应得额；单人红包等于 `amount`。
    let amountPerRecipient: Int
    var settled: Bool
    /// 群红包里已经回执过的成员（`GroupMember.groupMemberId` 的字符串形态）。可选且默认 nil，
    /// 是因为：一、direct 红包没有"成员"这个概念，一份份额天然由领取端账本去重；
    /// 二、解码端对缺失键走 `decodeIfPresent`，将来加字段不会读到空数组就当"没人领过"。
    /// 它只是**去重集**，退款金额算的是 `claimedCount`——两者在群里相等，在单聊里只有后者有值。
    var claimKeys: [String]?

    var id: String { packetId }

    var isFullyClaimed: Bool { claimedCount >= recipientCount || settled }

    /// 本端最早可以判定"这一单结束、余款退回"的时刻。领满之前绝不退款：
    /// 余款一旦退回，群里剩下的份额仍可被领走，那一份点数就是无中生有的。
    var claimGraceEndsAtMs: Int64 { createdAtMs + Int64(PopopxCommerceLimits.packetClaimGraceSeconds * 1_000) }

    /// 未被领取部分的退款额（只有本端能算，因为没有服务器兜底账）。
    var refundableAmount: Int {
        max(0, amount - claimedCount * amountPerRecipient)
    }
}

/// 频道订阅凭证。频道主自定义门槛，成员本地入账后持有一张带到期时间的票。
struct PopopxChannelSubscriptionTicket: Codable, Hashable, Identifiable, Sendable {
    let channelId: String
    let channelTitle: String
    let price: Int
    let paidAtMs: Int64
    let expiresAtMs: Int64
    let transactionId: String
    /// 签这张票时那条卡片的发布者公钥。**可选**是为了兼容升级前写好的票：那一代的 JSON 里没有这个键，
    /// 非可选会让整个钥匙串数组解码失败，于是所有人的"已订阅"状态一夜之间变成就没订阅过。
    /// 缺这一格的旧票一律不参与防冒充比对（判据见 `PopopxCreditsManager.channelIssuerConflict`）。
    var issuerPublicKeyBase64URL: String?

    var id: String { transactionId }

    func isValid(at now: Date) -> Bool {
        expiresAtMs > Int64(now.timeIntervalSince1970 * 1_000)
    }
}

/// 解锁某个加密个人主页后留下的收据（付方持有，供"我看过谁"回看与对账）。
struct PopopxProfileUnlockReceipt: Codable, Hashable, Identifiable, Sendable {
    let profileId: String
    let chatId: Int64
    let itemId: Int64
    let price: Int
    let unlockedAtMs: Int64
    let transactionId: String

    var id: String { transactionId }
}

/// 高阶外观兑换。本地渲染生效，不上传、不校验，所以这里只需要"什么时候解锁的"。
enum PopopxCosmetic: String, Codable, CaseIterable, Identifiable, Sendable {
    case auroraShieldAvatarFrame
    case darkGoldQRCardSkin

    var id: String { rawValue }

    var cost: Int {
        switch self {
        case .auroraShieldAvatarFrame: PopopxCommerceLimits.avatarFrameCost
        case .darkGoldQRCardSkin: PopopxCommerceLimits.qrCardSkinCost
        }
    }
}

/// 防重放集合：领取过的红包 id、已核销的券 id、已入账的交易哈希。
/// 三个集合共用一个上限，超限按 FIFO 丢最旧——最旧那条对应的事务早已结束。
struct PopopxReplayGuard: Codable, Hashable, Sendable {
    var claimedPacketIds: [String] = []
    var redeemedVoucherIds: [String] = []
    var creditedTransactionHashes: [String] = []

    mutating func claim(packetId: String) { append(packetId, to: \.claimedPacketIds) }
    mutating func redeem(voucherId: String) { append(voucherId, to: \.redeemedVoucherIds) }
    mutating func credit(transactionHash: String) { append(transactionHash, to: \.creditedTransactionHashes) }

    func hasClaimed(packetId: String) -> Bool { claimedPacketIds.contains(packetId) }
    func hasRedeemed(voucherId: String) -> Bool { redeemedVoucherIds.contains(voucherId) }
    func hasCredited(transactionHash: String) -> Bool { creditedTransactionHashes.contains(transactionHash) }

    private mutating func append(_ value: String, to keyPath: WritableKeyPath<PopopxReplayGuard, [String]>) {
        guard !self[keyPath: keyPath].contains(value) else { return }
        self[keyPath: keyPath].append(value)
        let overflow = self[keyPath: keyPath].count - PopopxCommerceLimits.maximumReplayIdentifiers
        if overflow > 0 { self[keyPath: keyPath].removeFirst(overflow) }
    }
}

// MARK: - Keychain

/// Keychain 条目分槽。命名全部带 `popopx.commerce.` 前缀，与
/// `kcDatabasePassword`/`kcSelfDestructPassword` 那一族、以及 duress 自己的 `popopx.duress.*` 分开，
/// 三套 account 空间互不覆盖。
enum PopopxCommerceKeychainSlot: String, CaseIterable, Sendable {
    case badgeRecord = "popopx.commerce.badge"
    case trialGuard = "popopx.commerce.trial"
    case vouchers = "popopx.commerce.vouchers"
    case wallet = "popopx.commerce.wallet"
    case ledger = "popopx.commerce.ledger"
    case replayGuard = "popopx.commerce.replay"
    case signingKey = "popopx.commerce.signing-key"
    case pendingPackets = "popopx.commerce.pending-packets"
    case channelTickets = "popopx.commerce.channel-tickets"
    case profileReceipts = "popopx.commerce.profile-receipts"
    case cosmetics = "popopx.commerce.cosmetics"
    case ephemeralConnections = "popopx.commerce.ephemeral-connections"
    /// 本机安装指纹（体验徽章防重放的第二半）。单独一格，不与临时连接混用：
    /// 那一条会被兑换流程反复覆写，指纹被覆写一次就等于体验徽章可以无限重领。
    case installIdentity = "popopx.commerce.install-identity"
    /// 收件侧验签通过的授权原文（grant）。单独一格，不借用 `profileReceipts`：
    /// 那一格是解锁资料卡的收据，兑换流程覆写它会把别人的解锁凭据一起抹掉。
    case grants = "popopx.commerce.grants"
}

/// Keychain 读写。
///
/// 可访问性用 `AfterFirstUnlockThisDeviceOnly`（规范点名要求）：徽章与余额要在锁屏收到信令时
/// 就读得到，而 ThisDeviceOnly 又保证它不进 iCloud Keychain——一张别人设备上的券
/// 如果被同步过来，双花就在两台上同时成立，那是最糟的结果。
/// accessGroup 只在真机上带：模拟器里带 group 的 `SecItemAdd` 会直接失败，
/// 这一条抄 `POPOPXChat/KeyChain.swift:112-120` 的既有做法。
enum PopopxCommerceKeychain {
    static let service = "popopx.commerce"
    static let accessGroup = "PDBA6XRBQT.com.popopxchat.popopx"

    static func read(_ slot: PopopxCommerceKeychainSlot) -> Data? {
        var query = lookupQuery(slot)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// 写。先 `SecItemUpdate` 再 `SecItemAdd`，并且 **accessibility 只挂在 add 那一支**：
    /// `SecItemUpdate` 改不了已存在条目的 accessibility，把它塞进查询条件反而会让
    /// 旧条目（用别的 accessibility 写下的）匹配不上，于是更新静默失败、退化成"再加一份"。
    /// 需要改 accessibility 的升级路径是"先删再写"，由调用方显式做，这里不假装能覆盖。
    static func write(_ data: Data, _ slot: PopopxCommerceKeychainSlot) -> Bool {
        if SecItemUpdate(lookupQuery(slot) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var add = lookupQuery(slot)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ slot: PopopxCommerceKeychainSlot) -> Bool {
        let status = SecItemDelete(lookupQuery(slot) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func contains(_ slot: PopopxCommerceKeychainSlot) -> Bool {
        read(slot) != nil
    }

    static func decode<T: Decodable>(_ type: T.Type, _ slot: PopopxCommerceKeychainSlot) -> T? {
        guard let data = read(slot) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T, _ slot: PopopxCommerceKeychainSlot) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        return write(data, slot)
    }

    /// 抹掉本模块在 Keychain 里的全部痕迹（紧急自毁与"清除我的数据"都调它）。
    static func removeAll() {
        for slot in PopopxCommerceKeychainSlot.allCases { _ = remove(slot) }
    }

    /// 定位用的一组属性：不含 accessibility，所以新旧条目都匹配得上。
    private static func lookupQuery(_ slot: PopopxCommerceKeychainSlot) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue
        ]
        #if os(iOS) && !targetEnvironment(simulator)
        query[kSecAttrAccessGroup as String] = accessGroup
        #endif
        return query
    }
}

// MARK: - 本地签名身份

/// CryptoKit P-256 签名的唯一入口。
///
/// 为什么是 ECDSA P-256 而不是 Ed25519：本模块要和 `PopopxSecurePayload` 那支共用
/// CryptoKit 的既有用法（AES-GCM + SHA256），而签名只需要"本机密钥 + 篡改留痕"，
/// P-256 的 x963/DER 两个表示都是 iOS 13 起就稳定的 API；
/// `compressedRepresentation` 在 `P256.Signing.PublicKey` 上不保证可用，所以选 x963。
enum PopopxCommerceSignature {
    /// 取（或首次铸造）本机签名密钥。私钥以 PEM 形式存 Keychain，
    /// 每次调用都重新解析，密钥材料不进静态变量——静态变量会把它留在内存里到进程结束。
    ///
    /// 存不进去就返回 nil，**不返回一把临时钥匙**：静默降级的话，上一次签发的兑换码
    /// 会在下一次启动时因为"换了一把钥匙"而全部验不过，用户看到的是"我的码失效了"，
    /// 而真实原因藏在一条没人会读的日志里。宁可当场报"安全存储不可用"。
    static func signingKey() -> P256.Signing.PrivateKey? {
        if let data = PopopxCommerceKeychain.read(.signingKey),
           let pem = String(data: data, encoding: .utf8),
           let existing = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return existing
        }
        let minted = P256.Signing.PrivateKey()
        guard PopopxCommerceKeychain.write(Data(minted.pemRepresentation.utf8), .signingKey) else { return nil }
        return minted
    }

    /// 本机公钥（x963，无填充 base64url）。兑换码与授权书里带的就是这一串。
    static func localPublicKeyBase64URL() -> String {
        signingKey()?.publicKey.x963Representation.popopxBase64URL ?? ""
    }

    /// 签名一段规范化字节，返回 DER 的无填充 base64url。
    static func signatureBase64URL(for canonical: Data) -> String? {
        guard let key = signingKey() else { return nil }
        guard let signature = try? key.signature(for: canonical) else { return nil }
        return signature.derRepresentation.popopxBase64URL
    }

    /// 严格验签：公钥解不出来、签名解不出来、验不过，三者都是 false，不区分原因。
    static func verify(signatureBase64URL: String, for canonical: Data, publicKeyBase64URL: String) -> Bool {
        guard
            !signatureBase64URL.isEmpty, !publicKeyBase64URL.isEmpty,
            let signatureData = Data(popopxBase64URL: signatureBase64URL),
            let keyData = Data(popopxBase64URL: publicKeyBase64URL),
            let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData)
        else { return false }
        return publicKey.isValidSignature(signature, for: canonical)
    }

    /// 自签校验：只在"这条载荷是本机铸造的"这一前提下有意义（赠方本地看自己发出去的卡片）。
    /// 命名区别于 `verify`，是为了让调用侧不可能把"自签通过"读成"对方确认过了"。
    static func verifySelfIssued(signatureBase64URL: String, for canonical: Data) -> Bool {
        verify(signatureBase64URL: signatureBase64URL, for: canonical, publicKeyBase64URL: localPublicKeyBase64URL())
    }

    /// 规范化字节。字段顺序固定、以 `|` 分隔、第一段是载荷类型名：
    /// 把 gift 的规范化结果拿去当 redpacket 验，开头就比不上。
    ///
    /// 只保留**一种**入参形态（`[String]`），是刻意的：两种形态迟早会演化成
    /// "同一个载荷两条规范化路径"，那正是"篡改留痕"这条承诺失效的地方。
    /// 自由文本（赠言）不进 `parts`，而是像下面各处那样拼在末尾——
    /// 赠言里允许出现 `|`，只要它永远是最后一段，就不可能把前面的字段挤位。
    static func canonical(kind: String, parts: [String]) -> Data {
        Data((["popopx", kind] + parts).joined(separator: "|").utf8)
    }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func digest(_ text: String) -> Data { digest(Data(text.utf8)) }

    /// 前 16 位十六进制，用于落账和对账展示。
    static func shortDigest(_ data: Data) -> String {
        digest(data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func shortDigest(_ text: String) -> String { shortDigest(Data(text.utf8)) }
}

// MARK: - 错误

/// 本模块的统一失败类型。集中在一处，是为了让 6 个视图文件里的 catch 分支
/// 不会各自造出一套互不兼容的错误枚举。
enum PopopxBadgeCreditsError: Error, LocalizedError, Hashable {
    case storeUnavailable
    case productNotFound(String)
    case purchaseFailed(String)
    case purchaseCancelled
    case verificationFailed
    case keychainUnavailable
    case insufficientCredits(balance: Int, required: Int)
    case voucherUnavailable
    case voucherAlreadyRedeemed
    case codeMalformed
    case connectionUnavailable
    case signalRejected
    case expiryInPast
    /// 入账后会超过余额上限。**只有收入方向会走到这一格**（支出方向由 `insufficientCredits` 管）。
    /// 单列而不是复用 `purchaseFailed`：那一句的言外之意是"付款出了问题"，
    /// 而这里付款是成功的、钱到了，只是这台设备的钱包装不下——用户要做的是先花掉一部分再领。
    case creditBalanceTooHigh(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable: PopopxCommerceCopy.errorStoreUnavailable
        case let .productNotFound(id): String(format: PopopxCommerceCopy.errorProductUnavailableFormat, id)
        case let .purchaseFailed(reason): String(format: PopopxCommerceCopy.errorPurchaseFailedFormat, reason)
        case .purchaseCancelled: PopopxCommerceCopy.errorPurchaseCancelled
        case .verificationFailed: PopopxCommerceCopy.errorVerificationFailed
        case .keychainUnavailable: PopopxCommerceCopy.errorKeychainUnavailable
        case let .insufficientCredits(balance, required):
            String(format: PopopxCommerceCopy.errorInsufficientCreditsFormat, required, balance)
        case .voucherUnavailable: PopopxCommerceCopy.errorVoucherUnavailable
        case .voucherAlreadyRedeemed: PopopxCommerceCopy.errorVoucherAlreadyRedeemed
        case .codeMalformed: PopopxCommerceCopy.errorCodeMalformed
        case .connectionUnavailable: PopopxCommerceCopy.errorConnectionUnavailable
        case .signalRejected: PopopxCommerceCopy.errorSignalRejected
        case .expiryInPast: PopopxCommerceCopy.errorExpiryInPast
        case let .creditBalanceTooHigh(maximum):
            String(format: PopopxCommerceCopy.errorCreditBalanceTooHighFormat, maximum)
        }
    }
}

// MARK: - 商业文案（全语种）

/// 只有"涉钱的那几句"走 NSLocalizedString。目录现状（本轮实测）：`apps/ios` 下 17 个 `.lproj`，
/// 下面的 37 个 key 全部写进 16 个翻译目录；`en.lproj` 一条都不加——它是开发区域
/// （`developmentRegion = en`），本仓库的约定是那里只放 value ≠ key 的条目，
/// 查不到 key 时 NSLocalizedString 返回源文，英文用户读到的就是这里写的原句。
/// 其余功能内文案继续用各文件自己的 `private enum Copy` 中文常量，
/// 和最近四个 POPOPX 功能保持一致；两套约定的分界线就是"这句话会不会出现在付款/退款/合规证据里"。
///
/// 源文必须在本特性内唯一：目录是 app 级共享的一份，key 相同就必然共用同一条译文。
/// 曾想复用 "History"（16 个语种都已有），实测 de 把它译成"Nachrichtenverlauf"（消息记录）、
/// zh-Hans 把 "For me" 译成"仅自己"——都是别的页面的语义，于是这三条源文各自改成没有歧义的说法。
/// 另有 "Credits" / "Fixed amounts only" / "History" 三条在普查（`PopopxCommerceCopy.<名>`
/// 除声明外 0 处引用）后被删除：留着一句永远不会上屏的"合规文案"，比不写更糟。
enum PopopxCommerceCopy {
    static let badgeProductName = NSLocalizedString("POPOPX Dynamic Privacy Node Badge", comment: "product name")
    static let trialBadgeName = NSLocalizedString("3-Day Pioneer Node Trial Badge", comment: "trial product name")
    static let creditsName = NSLocalizedString("POPOPX Compute Credits", comment: "virtual currency name")
    static let nodeClusterTerm = NSLocalizedString("dynamic SMP relay node cluster", comment: "never VPN")

    static let paywallTitle = NSLocalizedString("Light up a privacy node", comment: "paywall title")
    // 刻意不叫 "For me" / "Restore purchases"：那两个 key 在 11 个语种的目录里已经属于别的页面，
    // 复用它们等于让本特性的一句话由另一个页面的翻译决定。源文唯一 → 目录里只有一份，读到的就是这里写的。
    static let paywallSelfTab = NSLocalizedString("For myself", comment: "segment")
    static let paywallGiftTab = NSLocalizedString("Gift badge", comment: "segment")
    static let paywallRestore = NSLocalizedString("Restore badge purchases", comment: "button")
    static let paywallRedeemEntry = NSLocalizedString("Enter a code or scan", comment: "button")
    static let paywallUseCredits = NSLocalizedString("Exchange with Compute Credits", comment: "button")
    static let pricePerYear = NSLocalizedString("/ year", comment: "price suffix")
    static let pricePerMonth = NSLocalizedString("/ month", comment: "price suffix")
    static let savePercentFormat = NSLocalizedString("Save %lld%% off", comment: "annual badge savings, computed from the two live display prices")
    static let creditsAmountFormat = NSLocalizedString("%lld Compute Credits", comment: "credit pack amount")

    static let renewalStatement = NSLocalizedString("Payment will be charged to your Apple Account at confirmation of purchase. Subscriptions renew automatically unless they are cancelled at least 24 hours before the end of the current period. You can manage or cancel subscriptions in App Store settings at any time.", comment: "Apple 3.1.2(c) auto-renewable disclosure")
    static let noGiftBackStatement = NSLocalizedString("Compute Credits are added at the exact amount shown. No bonus credits are granted.", comment: "no promotional top-up")

    static let creditsBalance = NSLocalizedString("Compute Credits balance", comment: "wallet label")
    static let redPacketTitle = NSLocalizedString("Send Compute Credits", comment: "sheet title")
    /// 合规声明：这一句要在全部 17 个语种里出现，审核读的就是它。
    static let redPacketFixedAmountsStatement = NSLocalizedString("Only the fixed amounts listed here can be sent. Nowhere in this feature can you type a custom amount.", comment: "Apple 3.1.1 no random amounts")
    /// 退款承诺。天数不是写死的字符串：调用方必须把 `PopopxCommerceLimits.packetClaimGraceSeconds` 传进来，
    /// 否则改了常量而文案还说 30 天，这就是一句假承诺。
    static let redPacketRefundStatementFormat = NSLocalizedString("Credits nobody claims are returned to the sender %lld days after the packet was sent.", comment: "refund promise")
    static let channelSubscriptionTitle = NSLocalizedString("Subscribe to this channel", comment: "sheet title")
    /// 一期多长由调用方从 `PopopxCommerceLimits.channelTicketSeconds` 传进来，不写在文案字符串里。
    static let channelSubscriptionPeriodFormat = NSLocalizedString("Each purchase is valid for %lld days.", comment: "channel subscription period")
    static let channelSubscriptionStackFormat = NSLocalizedString("Subscribing again adds %lld days to the time you already have.", comment: "renewal is cumulative, money promise")

    static let errorStoreUnavailable = NSLocalizedString("The store is not available right now.", comment: "error")
    static let errorProductUnavailableFormat = NSLocalizedString("This item is not available (%@).", comment: "error")
    static let errorPurchaseFailedFormat = NSLocalizedString("Purchase failed: %@", comment: "error")
    static let errorPurchaseCancelled = NSLocalizedString("Purchase cancelled.", comment: "error")
    static let errorVerificationFailed = NSLocalizedString("The receipt could not be verified.", comment: "error")
    static let errorKeychainUnavailable = NSLocalizedString("Secure storage is unavailable on this device.", comment: "error")
    static let errorInsufficientCreditsFormat = NSLocalizedString("This needs %1$lld Compute Credits and you have %2$lld.", comment: "error")
    static let errorVoucherUnavailable = NSLocalizedString("This gift badge is no longer available.", comment: "error")
    static let errorVoucherAlreadyRedeemed = NSLocalizedString("This code has already been redeemed.", comment: "error")
    static let errorCodeMalformed = NSLocalizedString("The code is not valid. Check it and try again.", comment: "error")
    static let errorConnectionUnavailable = NSLocalizedString("The secure exchange could not be started.", comment: "error")
    static let errorSignalRejected = NSLocalizedString("The sender did not confirm this exchange.", comment: "error")
    static let errorExpiryInPast = NSLocalizedString("This badge has already expired.", comment: "error")
    static let errorCreditBalanceTooHighFormat = NSLocalizedString("Your Compute Credits balance cannot go above %lld. Spend some credits first.", comment: "error")
}
