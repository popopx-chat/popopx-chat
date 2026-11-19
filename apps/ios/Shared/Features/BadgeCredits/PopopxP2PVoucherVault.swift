//  PopopxP2PVoucherVault.swift
//
//  礼品卡券的本地保险柜 + 防双花仲裁者。
//
//  ### 为什么是 actor 而不是 MainActor 类
//  一张券的状态从 `unused` 翻到 `redeemed` 必须是**串行的、且在返回 grant 之前完成**的，
//  否则同一张券的两条并发兑换请求会各自读到 `unused`、各自拿到一份授权。actor 的
//  隔离正好把这件事变成语言保证：`authorizeRedemption(voucherId:)` 里"判状态 + 写状态 + 签名"
//  三段之间不可能插入第二次调用。这是本特性唯一真正的双花防线（另一条在
//  `PopopxSilentSignalingRouter`：兑换请求只可能回到铸券那一台设备上）。
//
//  ### 防双花的边界要说清楚（不夸称）
//  守得住：同一台设备上的并发兑换、重放同一个码、ACK 丢包后的重复兑现。
//  守不住：赠方把券码截图/转发给多人后**在另一台设备上**同时兑换——那需要一台全局记账的服务器，
//  而零 Bot / 零服务器是本特性的前提。工程上把风险压到可接受的做法是：
//  一张券只发一次、码在 ACK 后立即失效、券列表里"已兑出"状态对用户可见（`state == .redeemed`）。
//  这句话同时是审核文档里"为什么没有服务器也能防双花"的答案。
//
//  ### 不落 Keychain 的东西
//  `PPX1-…` 兑换码本体不落盘（只落 `codeDigest`）：那串码是"提款凭据"，
//  一次备份恢复就能把没送出去的券全部还原成可提现状态。
//  码需要复现时由 `PopopxSilentSignalingRouter` 用 envelope 参数重新铸，不靠存原文。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。

import Foundation

// MARK: - 来源

/// 一张券的来源。决定它对账时用哪个标识，而不是决定它值多少——面值只由 `period` 决定。
enum PopopxVoucherSource: Hashable, Sendable {
    /// 由一张已验签的 StoreKit 礼品卡收据铸出。
    case receipt(PopopxStoreReceipt)
    /// 由一笔已扣减成功的算力点流水铸出（`giftVoucherExchange`）。
    case creditEntry(id: String)

    var transactionId: String {
        switch self {
        case let .receipt(receipt): receipt.digest
        case let .creditEntry(id): id
        }
    }

    var jwsDigest: String {
        switch self {
        case let .receipt(receipt): PopopxCommerceSignature.shortDigest(receipt.jwsRepresentation)
        case let .creditEntry(id): PopopxCommerceSignature.shortDigest("credit.\(id)")
        }
    }
}

// MARK: - 保险柜

actor PopopxP2PVoucherVault {
    static let shared = PopopxP2PVoucherVault()

    private var issued: [PopopxNodeVoucher] = []
    /// 收件侧：ACK 里带回来的授权原文。键是 voucherId，值只在兑换成功后写，
    /// 交给 `PopopxBadgeManager.activate(grant:)` 之后再保留一位用于对账。
    private var received: [String: PopopxBadgeGrant] = [:]
    private var loaded = false

    private init() {}

    // MARK: 载入

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        issued = PopopxCommerceKeychain.decode([PopopxNodeVoucher].self, .vouchers) ?? []
        received = PopopxCommerceKeychain.decode([String: PopopxBadgeGrant].self, .grants) ?? [:]
    }

    // MARK: 铸券

    /// 一次性铸 `quantity` 张券。数量上限的存在只有一个理由：
    /// 券表整个存在 Keychain 的一格里，200 张是"一次买 200 张礼品卡"这种真实批量
    /// 与"把 5 万个随机数写进密码串"之间的分界。超量必须走多条收据，不是把上限调大。
    func mint(period: PopopxNodeBadgePeriod, quantity: Int, source: PopopxVoucherSource) throws -> [PopopxNodeVoucher] {
        loadIfNeeded()
        guard quantity >= 1, quantity <= PopopxCommerceLimits.maximumVouchers else {
            throw PopopxBadgeCreditsError.voucherUnavailable
        }
        guard issued.count + quantity <= PopopxCommerceLimits.maximumVouchers else {
            throw PopopxBadgeCreditsError.voucherUnavailable
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        var minted: [PopopxNodeVoucher] = []
        minted.reserveCapacity(quantity)
        for _ in 0..<quantity {
            minted.append(
                PopopxNodeVoucher(
                    voucherId: UUID().uuidString.lowercased(),
                    period: period,
                    state: .unused,
                    mintedAtMs: nowMs,
                    transactionId: source.transactionId,
                    jwsDigest: source.jwsDigest,
                    codeDigest: nil,
                    redeemedAtMs: nil,
                    grantBase64URL: nil
                )
            )
        }
        issued.append(contentsOf: minted)
        // 先落盘再返回码：返回给 UI 的券如果没写进 Keychain，用户下一次进这个面板就看见它消失了，
        // 而那张券的 StoreKit 收据已经 finish 掉——这是"付了钱什么都没得到"的确切形状。
        guard PopopxCommerceKeychain.encode(issued, .vouchers) else {
            issued.removeAll(where: { minted.contains($0) })
            throw PopopxBadgeCreditsError.keychainUnavailable
        }
        return minted
    }

    func vouchers(state: PopopxVoucherState? = nil) -> [PopopxNodeVoucher] {
        loadIfNeeded()
        guard let state else { return issued }
        return issued.filter { $0.state == state }
    }

    func voucher(voucherId: String) -> PopopxNodeVoucher? {
        loadIfNeeded()
        return issued.first { $0.voucherId == voucherId }
    }

    /// 记下落在码里的摘要，用于"这张券发出去过"。不存码本身，理由见文件头。
    func recordCodeDigest(_ digest: String, forVoucherId voucherId: String) {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }) else { return }
        issued[index].codeDigest = digest
        _ = PopopxCommerceKeychain.encode(issued, .vouchers)
    }

    /// 赠方主动作废一张还没送出去的券（UI 上的"删除"）。
    /// 已兑换的券**不能**删：那是别人花钱买下的权益，删掉记录不会让对方的徽章消失，
    /// 只会让对账少一行。
    func discard(voucherId: String) -> Bool {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }), issued[index].state == .unused else {
            return false
        }
        issued.remove(at: index)
        return PopopxCommerceKeychain.encode(issued, .vouchers)
    }

    // MARK: 防双花仲裁

    /// 唯一的兑现入口。**同步**返回授权或 nil，因为 actor 的可重入点只在 `await` 上，
    /// 而这个函数一次都不 await——判状态、翻状态、落盘、签名全在一次隔离执行里完成。
    ///
    /// `codeDigestSource` 由调用方给：一次性链接兑换传"码里的 nonce + 邀请链接"，
    /// 会话内礼品卡兑换传那条信令原文。两者都只是"这张券被哪个码兑掉"的证据，不参与判活。
    ///
    /// 注意它不是 `async throws`：调用方（`PopopxSilentSignalingRouter`）拿到 nil 的语义
    /// 就是"这张券已经被兑过了"，那不是异常，是一条需要如实回给对方的答复。
    func authorizeRedemption(voucherId: String, codeDigestSource: String) -> PopopxBadgeGrant? {
        loadIfNeeded()
        guard let index = issued.firstIndex(where: { $0.voucherId == voucherId }),
              issued[index].state == .unused
        else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let period = issued[index].period
        let expiresAtMs = nowMs + Int64(period.days * 86_400) * 1_000
        // 先把状态翻成 redeemed 并落盘，再签名返回。顺序反过来的话，
        // 落盘失败会留下一张"已经授过权但状态还是 unused"的券——那才是双花。
        issued[index].state = .redeemed
        issued[index].redeemedAtMs = nowMs
        issued[index].codeDigest = PopopxCommerceSignature.shortDigest(codeDigestSource)
        guard PopopxCommerceKeychain.encode(issued, .vouchers) else {
            // 写不进去就撤销这次授权并返回 nil：宁可让收件方看到"兑换没成功、请重试"，
            // 也不能让他拿到一份本地已经不认账的授权。
            issued[index].state = .unused
            issued[index].redeemedAtMs = nil
            return nil
        }
        return grant(voucherId: voucherId, period: period, grantedAtMs: nowMs, expiresAtMs: expiresAtMs)
    }

    /// 授权原文：`grant` 的规范串只含四个字段（券号 / 周期 / 发行时间 / 到期时间），
    /// 免费文案和邀请链接永远不进 `parts`——签名一旦覆盖到可变文本，
    /// 对方改一个字就对不上，而那是完全合法的内容变化。
    private func grant(voucherId: String, period: PopopxNodeBadgePeriod, grantedAtMs: Int64, expiresAtMs: Int64) -> PopopxBadgeGrant? {
        // 公钥为空串 = 本机签名密钥没能从 Keychain 取出来（`localPublicKeyBase64URL` 的失败形态）。
        // 这时绝不能签出一份"公钥字段是空的"授权：收件方那边 verify 会稳定失败，
        // 用户看到的是一句"对方没有确认这次兑换"，而真正坏的是本机存储。
        let publicKey = PopopxCommerceSignature.localPublicKeyBase64URL()
        guard !publicKey.isEmpty,
              let signature = PopopxCommerceSignature.signatureBase64URL(
                  for: PopopxCommerceSignature.canonical(
                      kind: "grant",
                      parts: [voucherId, period.wireValue, String(grantedAtMs), String(expiresAtMs)]
                  )
              )
        else { return nil }
        return PopopxBadgeGrant(
            voucherId: voucherId,
            period: period,
            grantedAtMs: grantedAtMs,
            expiresAtMs: expiresAtMs,
            giverPublicKey: publicKey,
            signature: signature
        )
    }

    // MARK: 收件侧

    /// 收到 ACK 后先验签再存。验不过直接丢：一份伪造的 grant 如果进了本地记录，
    /// 后面 `activate(grant:)` 就会点亮一枚没有人付过钱的徽章。
    @discardableResult
    func record(_ grant: PopopxBadgeGrant) -> Bool {
        loadIfNeeded()
        guard grant.isSignatureValid else { return false }
        received[grant.voucherId] = grant
        return PopopxCommerceKeychain.encode(received, .grants)
    }

    func grant(voucherId: String) -> PopopxBadgeGrant? {
        loadIfNeeded()
        return received[voucherId]
    }

    /// 收件侧的全部有效授权（已验签过一次，存进来就不再验，只为对账显示）。
    func receivedGrants() -> [PopopxBadgeGrant] {
        loadIfNeeded()
        return received.values.sorted { $0.grantedAtMs > $1.grantedAtMs }
    }

    /// 用 voucherId 找一张已兑入的授权，给"这枚徽章来自哪张券"那句对账文案用。
    func sourceOfBadge(voucherId: String) -> (period: PopopxNodeBadgePeriod, grantedAt: Date)? {
        guard let grant = received[voucherId] else { return nil }
        return (grant.period, Date(timeIntervalSince1970: Double(grant.grantedAtMs) / 1_000))
    }
}
