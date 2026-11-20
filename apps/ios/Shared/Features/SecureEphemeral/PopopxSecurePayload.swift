//
//  PopopxSecurePayload.swift
//  POPOPX (iOS)
//
//  【绝密阅后即焚】的载荷层 + 全套告警语义。本文件是这个特性的唯一契约：
//  检测引擎只**产出** `PopopxSecurityAlert`，窗口只**消费**它，气泡只**读** `PopopxSecurePayload`
//  的三个展示字段。谁都不许绕过这一层自己拼字符串。
//
//  线上形态是两行文本，发出去的是第二行（和 `PopopxLocationPayload` 完全同一个形状）：
//
//  ```text
//  🔒 [绝密阅后即焚] 生物识别后查看
//  popopx://sec?ttl=60&data=<base64url 密文>&k=<base64url 会话密钥>
//  ```
//
//  ### 关于 `k=` 这一格（对提示词的一条如实偏离，改之前先读完）
//  提示词写的格式只有 `ttl` 和 `data`。只有这两格的消息**在收件方永远解不开**：密文要能解，
//  密钥必须落到读它的那台设备上，而 POPOPX 没有任何 Swift 侧可取的会话密钥——SMP 的双棘轮
//  在 Haskell 那一侧（`chatSendCmd` 之上只有明文的 `MsgContent`），蓝牙 Mesh 那条的 Noise
//  密钥在 `PopopxMeshKit` 的 actor 里，两者都不对 app 层暴露"给我派生一条消息密钥"的接口。
//  所以密钥只能跟着消息走，用 `k=` 带上。这不是设计上的偷懒，是这一层唯一的可行解，
//  也正因为如此，下面那条威胁模型必须写死在文件里，而不是含混地叫"加密"。
//
//  ### 这套东西到底防什么、不防什么（只写能自证的句子）
//  防（`data=` 是 AES-256-GCM 密文这一事实带来的）：
//  - 明文进 SQLite：本地库里 `msgContent.text` 存的这两行里没有正文；
//  - 明文进通知、会话列表预览、引用回复条、转发引用：这些都直接取 `text`，看到的只有降级行；
//  - 明文进 Mesh 中继队列：`PopopxMeshRuntime` 的离线兜底记录会原样落盘（POPOPXAPI.swift:3634），
//    中继节点存的是密文；这也是绝密消息敢走双模路由的前提。
//  - GCM tag 顺带管住"载荷被改写过"：`open()` 解不开就是被改过，界面按损毁处理，不画半个字。
//  不防：
//  - **收件方本人**。他手里同时有 `data` 和 `k`，任何能读到自己设备文件的人都能离线解开。
//    这一层从来不是"对收件方保密"，对收件方的约束只有两条：看之前过生物识别，看完物理删除。
//  - 也不防发件方设备被取证——发件方留着的是自己刚打出去的那条明文。
//  把这条写明白比留一句"金融级加密"有用：真正的控制点是模块五的销毁，不是这层编码。
//
//  ### 与 `popopx://loc` 的互斥（硬约束，同 `PopopxLocation.swift:17`-`:21`）
//  `popopx:/` 和 `popopx://` 是邀请链接的前缀，`hasPopopxLink` 认这个 scheme。所以 host 只认
//  `sec`，且 `ttl`/`data`/`k` 三格全部量死后才判活；任一条不满足整串判死、退回纯文本渲染。
//  一条绝密消息被认成邀请链接 = 一次加好友，这条事故的形状和位置那版一模一样。
//
//  ### 生命周期
//  `open()` 交出的明文是 `Data` 而不是 `String` 的内部拷贝：调用方用完必须
//  `popopxSecureErase(_:)`（本文件末尾）覆写，`PopopxSecureWindowManager` 在关闭、归零、
//  熔断三条路径上都调它。Swift 的 `String` 没有可覆写的缓冲，所以**明文在内部一律以 `Data` 存在**，
//  只有送进 SwiftUI 显示的那一刻才变成 `String`——那一份归 ARC 管，本层无法承诺覆写，不假称能覆写。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import CryptoKit
import Foundation

// MARK: - 载荷

/// 一条绝密消息的载荷。不可变：`Hashable` 要进 `PopopxBubbleBody`，而密文一旦铸成就不该再动。
struct PopopxSecurePayload: Hashable, Sendable {
    /// 阅后即焚时长，秒。收件方从**首次打开**开始计时，不是从收到开始（见 `PopopxSecureWindowManager`）。
    let ttlSeconds: Int
    /// AES-256-GCM 密封盒：`nonce(12) || ciphertext || tag(16)`，不含任何自定义头。
    let sealed: Data
    /// 跟着载荷走的 256 位会话密钥。理由见文件头。
    let key: Data

    /// 时长上下限。下限 5 秒：短于此，用户还没走完生物识别 + 认证弹窗消息就烧了，
    /// 等价于"永远读不到"。上限 3600 秒：一小时的绝密明文停在屏幕上不是产品，是事故。
    static let minimumTTLSeconds = 5
    static let maximumTTLSeconds = 3600

    /// 密文长度区间。下限 = 12(nonce) + 0(空正文) + 16(tag) = 28 字节；
    /// 上限 32 KiB 是"一条屏幕读得下的绝密消息"的宽裕估计，同时挡住有人拿一条 10 MB 的
    /// `data=` 去喂 CryptoKit——解密发生在收件方的设备上，成本必须由收件方说了算。
    static let minimumSealedBytes = 28
    static let maximumSealedBytes = 32 * 1024

    /// 唯一的构造入口。生产代码里只有 `make`（发送侧）和 `parse`（接收侧）会调它，
    /// 两者都已经把 ttl / 长度 / 字母表判完；测试用同一只init 造"路上被人动过"的载荷。
    init(ttlSeconds: Int, sealed: Data, key: Data) {
        self.ttlSeconds = ttlSeconds
        self.sealed = sealed
        self.key = key
    }

    // MARK: 铸造 / 解封

    /// 明文长度上限，UTF-8 字节。和 `maximumSealedBytes` 是同一件事的两端（密封盒只比明文长 28 字节），
    /// 单列出来是为了让发送侧能在**铸之前**就给出人话错误，而不是铸出一条对端必然判死的载荷。
    static let maximumPlainBytes = 32 * 1024

    /// 铸造一条载荷：随机 256 位密钥 + 一次性随机 nonce，AES-256-GCM 密封。
    ///
    /// nonce 每次 `seal` 都由 `CryptoKit` 现取随机数，绝不复用——同一把密钥下重复 nonce
    /// 会直接击穿 GCM 的认证性，而这里密钥本身就是每条消息新生成的，复用窗口不存在，
    /// 所以只需保证不自己造 nonce 即可。
    static func make(plaintext: String, ttlSeconds: Int) throws -> PopopxSecurePayload {
        let utf8 = Data(plaintext.utf8)
        guard !utf8.isEmpty else { throw PopopxSecureError.emptyPlaintext }
        guard utf8.count <= maximumPlainBytes else {
            throw PopopxSecureError.plaintextTooLong(bytes: utf8.count)
        }
        let clamped = min(max(ttlSeconds, minimumTTLSeconds), maximumTTLSeconds)
        let sessionKey = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(utf8, using: sessionKey)
        // `box.combined` 是 `Data?`：只有底层组合失败才为 nil。这里不 `try!`，
        // 因为一次绝密消息铸造失败的正确表现是"没发出去 + 一句人话"，不是崩。
        guard let combined = box.combined else { throw PopopxSecureError.sealingFailed }
        return PopopxSecurePayload(
            ttlSeconds: clamped,
            sealed: combined,
            key: sessionKey.withUnsafeBytes { Data($0) }
        )
    }

    /// 解封成明文字节。**调用方负责擦**：用完交给 `popopxSecureErase(_:)`。
    func open() throws -> Data {
        guard key.count == 32 else { throw PopopxSecureError.wrongKeyLength(key.count) }
        guard sealed.count >= Self.minimumSealedBytes, sealed.count <= Self.maximumSealedBytes else {
            throw PopopxSecureError.wrongSealedLength(sealed.count)
        }
        let symmetricKey = SymmetricKey(data: key)
        let box = try AES.GCM.SealedBox(combined: sealed)
        do {
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw PopopxSecureError.decryptionFailed
        }
    }

    // MARK: 线上字节

    /// 机器读的那一行。三个值全都是 base64url 与十进制数字，不含 `&`/`=`/`+`/`/`/空白，
    /// 所以这里不需要 `PopopxLocation.swift` 那套 `.alphanumerics` 转义——也正因此
    /// 解析端可以按空白切 token、按 `&` 切字段、按第一个 `=` 分键值而不失血。
    var wireString: String {
        "popopx://sec?ttl=\(ttlSeconds)&data=\(sealed.popopxBase64URL)&k=\(key.popopxBase64URL)"
    }

    /// 给人看的那一行。绝不包含正文字符——这是"严禁在列表中暴露明文"这条硬约束的落点：
    /// 会话列表、通知横幅、引用预览取的都是 `text`，也就是这个 `degradeLine` + 换行 + 机器行。
    var degradeLine: String {
        "🔒 [绝密阅后即焚] 生物识别后查看 · \(PopopxSecureCopy.duration(ttlSeconds))"
    }

    /// 实际发出去的那条文本。它是纯文本，所以和位置消息一样天然满足
    /// `PopopxComposerRouting` 的 mesh 前提（无附件、无引用、1:1 直聊），不需要为它开判据格。
    var messageContent: String {
        degradeLine + "\n" + wireString
    }

    /// 展示用：把载荷说成一句人话（卡片副标题、VoiceOver）。不含正文，永远不含。
    var summaryText: String {
        PopopxSecureCopy.duration(ttlSeconds)
    }

    // MARK: 解析

    /// 从任意文本里读出一条绝密载荷；读不到返回 nil，调用方（`PopopxBubbleMount`）
    /// 把 nil 当"这不是绝密消息"，交回原来的纯文本渲染。
    ///
    /// 输入是接收方主动送进解析器的东西，每一步都当它在试探边界：先按空白切 token，
    /// 再逐格判 scheme / host / 键名白名单 / 数字 / 长度 / base64url 字母表。
    ///
    /// 命中多个候选取**最后一个**，和生产端把机器行拼在可读行之后这一事实对齐
    /// （`PopopxLocation.swift:123`-`:126` 同一条理由，那边实测过：取首个会让载荷自己回不到自己）。
    static func parse(from text: String) -> PopopxSecurePayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) {
                return payload
            }
        }
        return nil
    }

    private static func parseToken(_ token: String) -> PopopxSecurePayload? {
        guard let components = URLComponents(string: token),
              components.scheme == "popopx",
              components.host == "sec"
        else { return nil }

        var fields: [String: String] = [:]
        // 必须走 `percentEncodedQuery`：`query` 给的是**已解码**的串，`data=a%26b` 在它手里
        // 先变成 `data=a&b`，再按 `&` 切就把密文截断成一格。同 `PopopxLocation.swift:143`-`:145`。
        for pair in components.percentEncodedQuery?.split(separator: "&") ?? [] {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            // 白名单比较用**编码原字节**：写成 `d%61ta` 的键进不来（`PopopxLocation.swift:150` 同判据）。
            guard fieldNames.contains(key) else { continue }
            guard let value = String(pair[pair.index(after: separator)...]).removingPercentEncoding
            else { return nil }
            fields[key] = value
        }

        guard let rawTTL = fields["ttl"],
              let ttl = Int(rawTTL),
              // `Int("+60")` 也解得成功，所以长度上限必须靠"整串只有数字"来卡，而不是靠值域。
              rawTTL.allSatisfy(\.isNumber),
              rawTTL.count <= 4,
              (minimumTTLSeconds...maximumTTLSeconds).contains(ttl),
              let encodedSealed = fields["data"],
              let encodedKey = fields["k"],
              let sealed = Data(popopxBase64URL: encodedSealed),
              let key = Data(popopxBase64URL: encodedKey),
              sealed.count >= minimumSealedBytes,
              sealed.count <= maximumSealedBytes,
              key.count == 32
        else { return nil }

        return PopopxSecurePayload(ttlSeconds: ttl, sealed: sealed, key: key)
    }

    private static let fieldNames: Set<String> = ["ttl", "data", "k"]
}

// MARK: - 错误

/// 载荷层会说出口的全部原因。界面不显示枚举本身，只显示下面这些句子，所以没有 `LocalizedError`。
enum PopopxSecureError: Error, Hashable {
    case emptyPlaintext
    case plaintextTooLong(bytes: Int)
    case sealingFailed
    case wrongKeyLength(Int)
    case wrongSealedLength(Int)
    /// GCM 认证失败：要么不是这条消息的密钥，要么载荷在路上被人动过。两种都按损毁处理。
    case decryptionFailed
    /// 密钥对得上、tag 验得过、字节交出来了，但拼不成一段可读的 UTF-8（或是空的）。
    ///
    /// 必须和 `decryptionFailed` 分开：那一句的言外之意是"路上被人动了"，而这里**没有任何东西
    /// 被动过**——GCM 恰恰证明了它完整。真实成因只能是发信端铸了一条空正文（本端的 `make`
    /// 明确拒绝空串，所以那是别家实现或以后的代码路径）。仍然按损毁处理（打不开就是打不开），
    /// 但把成因说对：让用户去怀疑传输链路，是一次彻头彻尾的误导。
    case unusablePlaintext
    /// 生物识别没过，或被用户取消。和"解不开"是两件事，不能并成一格——界面上一个是"再试一次"，
    /// 一个是"这条已经毁了"。
    case authenticationFailed
    /// 当前设备没有可用的生物识别（没录 Face ID / Touch ID）。绝密消息**不降级**成"直接看"，
    /// 也不借用 app 全局那个 `privacyLocalAuthMode = .passcode` 模式：那条链路的口令是 app 口令，
    /// 和提示词要求的"生物识别后查看"不是一回事。
    case biometricsUnavailable
    /// 打开前预检发现屏幕正在被采集（录屏 / AirPlay / 采集卡）。
    case screenIsCaptured
}

// MARK: - 告警

/// 检测引擎能报出的全部安全事件。一个 case = 一条用户看得见的理由，也是回执上的那一句。
enum PopopxSecurityAlert: Hashable, Sendable {
    // 采集类（模块四）
    /// 用户按了截屏组合键。`UIApplication.userDidTakeScreenshotNotification` 是唯一能拿到这个信号的公开入口。
    case screenshotTaken
    /// `UIScreen.isCaptured` 翻真：录屏、AirPlay、有线采集卡三者之一。
    case screenCaptured
    /// 绝密窗口还在倒计时时 app 进了后台/被切走：这一刻起快照缓存和任务切换器缩略图都不再受控。
    case leftForeground

    // 视觉类（模块二、三）
    /// 前置镜头里出现第二张脸，或有人凑到主用户旁边。
    case secondaryFaceDetected
    /// 主用户离开了视角超过 0.5 秒：屏幕此刻对任何人都是敞开的。
    case primaryViewerLost
    /// 镜头高光热点达标（连续两帧高圆形度过曝光斑，或整帧均值跃升）。
    case lensGlareDetected
    /// CoreML 目标检测认出的高危物体。
    case recordingDevice(PopopxGuardObject)

    /// 回执里那一句：从**查看方**设备发给**发信方**的一条普通文本。
    ///
    /// 刻意只用一行普通文本，不再造一个 `popopx://secalert` scheme：接收侧要为此多开一个气泡档、
    /// 多一条解析面，而这条消息的全部作用就是让对面看见"刚才发生了什么"。少一个协议就少一处能烂掉的地方。
    var receiptText: String {
        "⚠️ [绝密安全告警] \(reasonText)；该条绝密消息已就地销毁。"
    }

    /// 界面/toast 上的短语。一句话说清"哪一类风险"，不声称抓到了谁、也不预测后果。
    var reasonText: String {
        switch self {
        case .screenshotTaken: return "检测到截屏"
        case .screenCaptured: return "检测到屏幕正在被录制或镜像"
        case .leftForeground: return "绝密消息未读完即退出前台"
        case .secondaryFaceDetected: return "检测到画面中出现第二个人"
        case .primaryViewerLost: return "机主离开视角"
        case .lensGlareDetected: return "检测到镜头反光热点"
        case let .recordingDevice(object): return "检测到\(object.displayName)"
        }
    }

    /// 会不会把消息销毁。三档里 `leftForeground` 是唯一可以商量的一档，
    /// 默认销毁（`PopopxSecureSettings.destructiveOnBackground` 开着），关掉之后只锁屏不销毁。
    var destroysMessage: Bool {
        switch self {
        case .leftForeground: return false
        default: return true
        }
    }
}

/// CoreML 那一条链路上的物体分类。类别名到本枚举的映射写在 `PopopxCameraGuardEngine`，
/// 这一层只表意，不认字符串——引擎可以降级到没有模型的状态，而这个枚举不能变。
enum PopopxGuardObject: String, Hashable, Sendable, CaseIterable {
    /// 高危拍摄类：置信度 ≥ 0.40 立即熔断。
    case cellPhone
    case camera
    case mobilePhone
    case lens
    /// 潜在近距离录屏类：置信度 ≥ 0.55 才熔断。
    case laptop
    case television
    case remote

    /// 高危档：阈值 0.40。其余（`laptop`/`television`/`remote`）是 0.55 的"近距录屏"档。
    var isHighRisk: Bool {
        switch self {
        case .cellPhone, .camera, .mobilePhone, .lens: return true
        case .laptop, .television, .remote: return false
        }
    }

    var threshold: Double { isHighRisk ? 0.40 : 0.55 }

    var displayName: String {
        switch self {
        case .cellPhone, .mobilePhone: return "手机"
        case .camera: return "相机"
        case .lens: return "镜头"
        case .laptop: return "笔记本电脑"
        case .television: return "屏幕"
        case .remote: return "遥控器"
        }
    }

    /// 模型标签 → 本枚举。键名逐字对齐 ultralytics COCO 导出的 `classes`（`coco_names` 里
    /// 是 `cell phone` / `tvmonitor` / `laptop` / `remote`），空格和大小写都算。
    ///
    /// `mobile phone` / `camera` / `lens` 不是 COCO 的类名，是 `--custom-weights` 那条路
    /// （第三方手机检测权重）会带进来的别名，留着是为了换权重不用改 Swift。
    ///
    /// `tv` 与 `tvmonitor` 两种拼法都要：COCO 的官方类名是 `tvmonitor`，而 ultralytics 的
    /// `names` 字典在不同版本里给过 `tv`。只认一种的后果是"近距对屏幕录屏"这一整档
    /// 静默失效（判定不报错，只是永远不触发）——`scripts/setup_pretrained_coreml.py`
    /// 的 `COCO_SYNONYMS` 专门为此 WARN，这张表就是它要求同步的那一侧。
    static func resolve(modelLabel: String) -> PopopxGuardObject? {
        switch modelLabel.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cell phone": return .cellPhone
        case "mobile phone": return .mobilePhone
        case "camera": return .camera
        case "lens": return .lens
        case "laptop": return .laptop
        case "tv", "tvmonitor", "television", "monitor": return .television
        case "remote", "remote control": return .remote
        default: return nil
        }
    }
}

// MARK: - 文案

/// 载荷/窗口共用的短句。集中一处，避免卡片、toast、回执三处各说一个版本。
enum PopopxSecureCopy {
    static func duration(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return String(format: NSLocalizedString("%lld days", comment: "secure duration"), seconds / 86_400) }
        if seconds % 3_600 == 0 { return String(format: NSLocalizedString("%lld hours", comment: "secure duration"), seconds / 3_600) }
        if seconds % 60 == 0 { return String(format: NSLocalizedString("%lld minutes", comment: "secure duration"), seconds / 60) }
        return String(format: NSLocalizedString("%lld seconds", comment: "secure duration"), seconds)
    }

    /// 绝密档的可选时长。不复用 `PopopxComposerRouting.durationOptions`（30 秒/1 分钟/5 分钟）：
    /// 那一档是"阅后即焚"，语义是消息多久从**服务器**消失；这一档是明文允许停在**屏幕上**多久，
    /// 借同一组值会让两个时长在用户心里变成一个。
    static let ttlOptions: [PopopxSecureTTLOption] = [
        .init(seconds: 15, title: "15 seconds"),
        .init(seconds: 30, title: "30 seconds"),
        .init(seconds: 60, title: "1 minute"),
        .init(seconds: 300, title: "5 minutes")
    ]

    /// 刚打开「绝密」那一档时的默认停留时长：60 秒。
    ///
    /// 不是最短档：收件方得先走完一次生物识别，15 秒经常在读完第一行之前就归零；
    /// 也不是最长档：一屏字读不了 5 分钟，选大档应当由用户明确承担。
    /// 落点必须在这一层（载荷是这个短时的契约方），输入条和宿主都从这里取值，
    /// 免得两处各写一个 60 然后各自漂移。
    static let defaultTTLSeconds = 60

    static let cardTitle = "绝密阅后即焚"
    static let cardLockedHint = "轻触后通过生物识别查看"
    static let cardDestroyed = "已销毁"
    static let cardDamaged = "载荷已损坏，无法打开"
    static let biometricReason = "查看绝密消息"
}

/// 绝密时长档位。独立类型而不是复用 composer 那一档，理由见上面那条注释。
struct PopopxSecureTTLOption: Hashable, Identifiable, Sendable {
    let seconds: Int
    let title: String
    var id: Int { seconds }
}

// MARK: - base64url

extension Data {
    /// 无填充 base64url。选它而不是标准 base64，是为了让 `data=`/`k=` 里**永远不出现**
    /// `+` `/` `=`：那三个字符一旦进查询串就必须转义，而"字段值不需要转义"正是解析端
    /// 能安全地按 `&` 切、按第一个 `=` 分的前提（`PopopxLocation.swift:81`-`:84` 同一件事，
    /// 那边用 `.alphanumerics` 白名单达成，这里用字母表达成）。
    var popopxBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 严格解码：字母表外任何字符、或补回填充后长度不合法，一律 nil。
    ///
    /// 不用 `Base64DecodingOptions.ignoreUnknownCharacters`——那是"把 30% 长度的人话字符串
    /// 也解出一段字节"的开关，正是接收方最不该有的宽容度。
    init?(popopxBase64URL string: String) {
        guard !string.isEmpty else { return nil }
        var alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        // 接受带填充的写法，只为了对端是别家实现时不至于读不懂；填充符不参与上面的字母表校验。
        alphabet.insert(charactersIn: "=")
        guard string.unicodeScalars.allSatisfy({ alphabet.contains($0) }) else { return nil }
        var canonical = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = canonical.count % 4
        if remainder == 2 { canonical += "==" }
        else if remainder == 3 { canonical += "=" }
        else if remainder != 0 { return nil }
        guard let decoded = Data(base64Encoded: canonical) else { return nil }
        self = decoded
    }
}

// MARK: - 内存覆写

/// 强制覆写一块缓冲。
///
/// 为什么是 `memset_s` 而不是 `memset`：后者是编译器可以证明"写完再没读过"而整条删掉的
/// （DCE），`memset_s` 的语义就是"不得优化掉"（C11 K.3.7.4.2 / Apple 的 `<string.h>`）。
/// Swift 侧 `Darwin` 已经带了它的导入，不需要 C 桥接头——这条是实测（同一台机器、同一份 SDK，
/// `-typecheck` 一个只有 `memset_s` 调用的文件返回 0），不是推测。
///
/// 为什么收 `inout`：`withUnsafeMutableBytes` 在缓冲被共享时会先独占（COW）。所以**擦的永远是
/// 调用方手里这一份**。这条既不是缺陷也不是保障，是 `Data` 的语义，所以销毁路径的规矩写死在
/// `PopopxSecureWindowManager` 里：`open()` 交出的那份 `Data` 从生成到擦除之间不许被第二次持有，
/// 传出去只传 `String`（显示用）而那份 `String` 归 ARC 管——本层无法承诺覆写它，文件头已经写明。
func popopxSecureErase(_ data: inout Data) {
    guard !data.isEmpty else { return }
    data.withUnsafeMutableBytes { raw in
        _ = memset_s(raw.baseAddress, raw.count, 0, raw.count)
    }
}

/// 覆写并放掉一个可选缓冲。销毁路径上调，避免"擦完还在原地摆着一段全零引用"这种歧义状态。
///
/// 这里刻意不写 `if var owned = data`：局部 `var` 会与原值共享缓冲，`withUnsafeMutableBytes`
/// 于是把它独占出去、擦的是**副本**，原件一个字节都没动。必须在 `data` 这个 l-value 上直接取可变字节。
func popopxSecureErase(_ data: inout Data?) {
    guard data != nil else { return }
    data?.withUnsafeMutableBytes { raw in
        _ = memset_s(raw.baseAddress, raw.count, 0, raw.count)
    }
    data = nil
}
