//
//  PersonalProfileModel.swift
//  POPOPX (iOS)
//
//  【加密个人主页 · 模块一之一】主页的数据形状，和它在网络上那两行字节的编解码。
//
//  本文件是四个人共用的唯一契约：制作器只写 `PopopxProfileManifest`，发送器只读
//  `PopopxProfilePayload.messageContent`，卡片与阅读器只吃 `parse` 交回来的载荷。
//  谁都不许在别处自己拼 `popopx://profile` 那串字符——拼一次就多一处能和别人对不上的地方。
//
//  线上形态是两行文本，实际发出去的是第二行（和 `popopx://sec`、`popopx://loc` 完全同一个形状）：
//
//  ```text
//  👤 [加密个人主页] 张三 · 后端 / 摄影 (阅后即焚)
//  popopx://profile?mode=ephemeral&ttl=300&delivery=full&data=<base64url(JSON)>
//  ```
//
//  ### `data=` 不额外加密，是有意的
//  SMP 消息与 Mesh Noise 信道本身已经是端到端加密，这一格的职责是自描述而不是保密；主页的媒体
//  原件除作为普通加密 XFTP 附件之外从不离开设备，`data=` 里只有编排骨架和文字块。
//
//  ### 与邀请链接互斥（同 `PopopxLocation.swift:18`-`:22`、`PopopxSecurePayload.swift:37`-`:41`）
//  `popopx:/` 和 `popopx://` 是邀请链接的前缀，`hasPopopxLink` 认的就是这个 scheme。所以 host
//  只认 `profile`，`mode`/`ttl`/`delivery`/`data` 四格全部量死后才判活，任一条不满足就整串判死、
//  退回纯文本渲染。一条主页消息被认成邀请链接 = 一次加好友，这条事故的形状和位置那版一模一样。
//
//  ### 两个方向的严格程度刻意不同
//  `parse` 的输入是对方送过来的文本，所以它**永不抛错**：越界的块数、超长的标题、字母表外的
//  `data=`、非法 UTF-8 转义、信封与正文不一致，一律返回 nil，调用方把 nil 当"这不是主页消息"。
//  `make` 的输入是本端自己攒出来的 manifest，失败必须讲清是哪一条，所以它抛 `PopopxProfileError`。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import Foundation

// MARK: - 发送模式

/// 这一份主页以哪种隐私语义送达。`ephemeral` = 收件人**首次打开**后计时销毁；`standard` = 常驻。
enum PopopxProfileSendMode: String, Codable, Hashable, Sendable, CaseIterable {
    case ephemeral
    case standard

    /// 线上那格的写法。和 `rawValue` 恰好相同，但两者是两件事：`rawValue` 归 Codable 的本地存档
    /// 格式管（改它会让用户已保存的主页读不出来），`wireValue` 归协议管（改它就是改协议）。
    /// 所以这里逐条写死，不写 `rawValue`。
    var wireValue: String {
        switch self {
        case .ephemeral: return "ephemeral"
        case .standard: return "standard"
        }
    }

    /// 线上字节 → 模式。只认 `wireValue` 的精确拼写，不认 `rawValue`、不认大小写变体、不认别名：
    /// 对端多一个宽容度，本端就少一个能改协议的余地。
    static func fromWire(_ raw: String) -> PopopxProfileSendMode? {
        allCases.first { $0.wireValue == raw }
    }

    /// 卡片徽章上的短语。
    var cardLabel: String {
        switch self {
        case .ephemeral: return "阅后即焚"
        case .standard: return "常驻名片"
        }
    }

    /// 分段器只给一行，长标签在小屏 iPhone 上会被省略号截断，所以直接用卡片徽章那四个字的短标签。
    var sheetLabel: String {
        switch self {
        case .ephemeral, .standard:
            return cardLabel
        }
    }
}

// MARK: - 送达方式

/// 走公网 SMP（带图文视频）还是走蓝牙 Mesh（只剩文字）。与发送模式**正交**：
/// 常驻名片也会被 Mesh 降级，阅后即焚也可以走公网。
enum PopopxProfileDelivery: String, Codable, Hashable, Sendable, CaseIterable {
    case fullMedia
    case meshTextOnly

    var wireValue: String {
        switch self {
        case .fullMedia: return "full"
        case .meshTextOnly: return "mesh"
        }
    }

    static func fromWire(_ raw: String) -> PopopxProfileDelivery? {
        allCases.first { $0.wireValue == raw }
    }

    /// 卡片角标。`mesh` 那一档在界面上配厢语的青绿，`full` 配品牌紫——颜色归 `PopopxTheme`，
    /// 这一层只给字。
    var badgeLabel: String {
        switch self {
        case .fullMedia: return "在线全媒体"
        case .meshTextOnly: return "厢语 · 离线纯文字"
        }
    }
}

// MARK: - 媒体块

/// 一个媒体块在 manifest 里的**描述**，不含字节：原件在 `ProfileStorageManager` 的沙盒目录里，
/// 网络上只走这一小段元数据 + 普通 XFTP 附件。
struct PopopxProfileMedia: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case image
        case video
    }

    /// `UUID().uuidString.lowercased()`。它在沙盒里直接当文件名用，所以收件方给的那个值
    /// 必须先过字符白名单（见 `ProfileStorageManager`）。
    let mediaId: String
    let kind: Kind
    /// 落盘后的字节数（压缩/转码之后的实际大小，不是相册原图的大小）。
    let bytes: Int
    /// 只有视频有；图片为 nil。已按 30 秒上限截断之后的时长。
    let durationSeconds: Int?
    /// 图片/视频的说明文字。为保持全 `let`（媒体描述一旦进过网络就不该被就地改掉），
    /// 需要写 caption 的调用方用成员初始化器重建一个值即可，`mediaId` 沿用旧的。
    let caption: String?

    init(
        mediaId: String,
        kind: Kind,
        bytes: Int,
        durationSeconds: Int? = nil,
        caption: String? = nil
    ) {
        self.mediaId = mediaId
        self.kind = kind
        self.bytes = bytes
        self.durationSeconds = durationSeconds
        self.caption = caption
    }
}

/// 主页正文的一段。用带关联值的枚举而不是"一个 type 字段 + 三个可选字段"，
/// 于是"文字块带 mediaId"、"视频块没有时长"这类组合在类型层面就拼不出来。
enum PopopxProfileBlock: Codable, Hashable, Sendable {
    case text(String)
    case image(PopopxProfileMedia)
    case video(PopopxProfileMedia)

    var media: PopopxProfileMedia? {
        switch self {
        case .text: return nil
        case let .image(media): return media
        case let .video(media): return media
        }
    }

    /// 参与 `omittedMediaCount` 统计的口径：一个媒体块 = 1。
    var mediaCount: Int {
        switch self {
        case .text: return 0
        case .image, .video: return 1
        }
    }
}

// MARK: - 主页清单

/// 一份主页的全部内容。`Codable` 的形态就是 `data=` 里那段 JSON，也是本地
/// `manifest.json` 的形态——两者共用一套编解码（`encodedJSON()` / `decoded(json:)`），
/// 免得"存得下来但发不出去"或反过来。
struct PopopxProfileManifest: Codable, Hashable, Sendable {
    /// 协议版本。改字段含义必须换掉这个串，加可选字段不用。
    static let version = "popopx_profile_v1"

    var profileVersion: String
    /// `UUID().uuidString.lowercased()`。收件方的媒体目录按它分格。
    var profileId: String
    var title: String
    var subtitle: String?
    var sendMode: PopopxProfileSendMode
    /// 秒。`sendMode == .standard` 时恒为 0（由 `normalized()` 保证）。
    var ttlSeconds: Int
    var deliveryMode: PopopxProfileDelivery
    /// Mesh 降级时被剔除的图片/视频个数。`deliveryMode == .fullMedia` 时恒为 0。
    var omittedMediaCount: Int
    /// 阅读时是否启动前置镜头的防窥防偷拍检测。只在 `.ephemeral` 一档有意义，但字段本身常驻。
    var enableAntiSpyCamera: Bool
    var updatedAt: TimeInterval
    var blocks: [PopopxProfileBlock]

    /// 制作器的起点。默认落在 `.standard`（常驻）而不是 `.ephemeral`：一份还没写内容的骨架
    /// 不该默认带上"打开后 60 秒销毁"这种会改变收件方行为的属性，隐私档要由用户明确选一次。
    static func blank() -> PopopxProfileManifest {
        PopopxProfileManifest(
            profileVersion: version,
            profileId: UUID().uuidString.lowercased(),
            title: "",
            subtitle: nil,
            sendMode: .standard,
            ttlSeconds: 0,
            deliveryMode: .fullMedia,
            omittedMediaCount: 0,
            enableAntiSpyCamera: false,
            updatedAt: Date().timeIntervalSince1970,
            blocks: []
        )
    }

    var mediaCount: Int {
        blocks.reduce(0) { $0 + $1.mediaCount }
    }

    /// Mesh 那条路的投影：剔掉所有图片/视频块，记下剔了几个，送达方式改成 `.meshTextOnly`。
    /// 发送模式、时长、`profileId` 全部原样保留——降级改变的是**内容量**，不是隐私语义。
    var textOnly: PopopxProfileManifest {
        var copy = self
        var texts: [PopopxProfileBlock] = []
        texts.reserveCapacity(blocks.count)
        for block in blocks {
            switch block {
            case let .text(body): texts.append(.text(body))
            case .image, .video: break
            }
        }
        copy.blocks = texts
        // 幂等：已经降级过一次的清单不能再算一遍（那时 `mediaCount` 是 0，会把真实省略数抹掉）。
        copy.omittedMediaCount = deliveryMode == .meshTextOnly ? omittedMediaCount : mediaCount
        copy.deliveryMode = .meshTextOnly
        return copy
    }

    /// 把清单收敛回不变量。发送前的唯一入口是 `PopopxProfilePayload.make`，它先验后规范化，
    /// 所以这里的每一条都对应一个"对端一定会拒绝"的形状。
    ///
    /// 注意 `.standard` 只抹 `ttlSeconds`，**不**抹 `omittedMediaCount`：常驻名片走 Mesh 一样要
    /// 剔除媒体，把那个数归零会让阅读器报"已自动省去 0 个"——那是当着一对用户的面撒谎。
    /// 跨模式的不变量是 `fullMedia ⇒ omitted == 0`，不是 `standard ⇒ omitted == 0`。
    func normalized() -> PopopxProfileManifest {
        var copy = self
        switch copy.sendMode {
        case .standard:
            copy.ttlSeconds = 0
        case .ephemeral:
            copy.ttlSeconds = min(max(copy.ttlSeconds, PopopxProfilePayload.minimumTTLSeconds), PopopxProfilePayload.maximumTTLSeconds)
        }
        switch copy.deliveryMode {
        case .fullMedia:
            copy.omittedMediaCount = 0
        case .meshTextOnly:
            var texts: [PopopxProfileBlock] = []
            texts.reserveCapacity(copy.blocks.count)
            for block in copy.blocks {
                switch block {
                case let .text(body): texts.append(.text(body))
                case .image, .video: break
                }
            }
            copy.blocks = texts
            copy.omittedMediaCount = min(max(copy.omittedMediaCount, 0), PopopxProfilePayload.maximumBlocks)
        }
        return copy
    }

    // MARK: JSON

    /// 本地存档与 `data=` 共用的编码：键名排序、不缩进。排序是为了让同一份内容每次得到同样的字节
    /// （测试可以直接比字符串，日志里的两段 `data=` 也能肉眼对比）；不缩进是因为整个清单要挤进
    /// `maximumJSONBytes` 那一格预算。
    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw PopopxProfileError.damagedJSON
        }
        guard data.count <= PopopxProfilePayload.maximumJSONBytes else {
            throw PopopxProfileError.oversizedJSON(bytes: data.count)
        }
        return data
    }

    /// 解码任意来路的一段 JSON。任何不合格都返回 nil，不抛：调用方有的是"整个 token 判死"的路径，
    /// 而这里连"是不是主页"都还没确定。
    ///
    /// 上限全部在**构造之前**判，因为 `JSONDecoder` 会照着 JSON 里的数组长度真的去分配内存。
    static func decoded(json data: Data) -> PopopxProfileManifest? {
        guard !data.isEmpty, data.count <= PopopxProfilePayload.maximumJSONBytes else { return nil }
        guard let manifest = try? JSONDecoder().decode(PopopxProfileManifest.self, from: data) else { return nil }
        guard manifest.profileVersion == version else { return nil }
        guard manifest.blocks.count <= PopopxProfilePayload.maximumBlocks else { return nil }
        guard manifest.title.count <= PopopxProfilePayload.maximumTitleCharacters else { return nil }
        guard manifest.ttlSeconds >= 0 else { return nil }
        return manifest
    }
}

// MARK: - 错误

/// 铸造一份载荷时会说出口的全部原因。界面显示的是下面这些句子，不显示枚举本身，所以没有
/// `LocalizedError`。
///
/// `invalidMode` / `invalidDelivery` / `damagedBase64` 三条在本文件里**不会被抛出**：它们描述的是
/// 接收方向上的失败，而 `parse` 的契约是返回 nil。留着是为了"先拿到字符串字段、再决定怎么报错"
/// 的调用方（例如扫码那条路要给出一句人话），删掉的话那些调用点就只能自己造字符串了。
enum PopopxProfileError: Error, Hashable, Sendable {
    /// 清单版本不认识。
    case unknownVersion(String)
    /// `mode=` 那一格不是 `ephemeral`/`standard` 之一。
    case invalidMode(String)
    /// `delivery=` 那一格不是 `full`/`mesh` 之一。
    case invalidDelivery(String)
    /// 时长越界，或常驻档带了非 0 的时长。
    case invalidTTL(Int)
    /// `data=` 不是合法的 base64url。
    case damagedBase64
    /// JSON 编不出来或读不出来。
    case damagedJSON
    /// 编码后的清单超过 `PopopxProfilePayload.maximumJSONBytes`。
    case oversizedJSON(bytes: Int)
    /// 标题超过 `PopopxProfilePayload.maximumTitleCharacters`。
    case oversizedTitle(characters: Int)
    /// 内容块超过 `PopopxProfilePayload.maximumBlocks`。
    case tooManyBlocks(count: Int)

    /// 面向用户的一行中文：讲清"哪儿不行"，不承诺补救动作。
    var reasonText: String {
        switch self {
        case let .unknownVersion(version):
            return "这份主页的数据版本不认识（\(version)），需要更新 POPOPX 才能打开"
        case let .invalidMode(mode):
            return "这份主页的发送方式不认识（\(mode)）"
        case let .invalidDelivery(delivery):
            return "这份主页的送达方式不认识（\(delivery)）"
        case let .invalidTTL(ttl):
            return "这份主页的阅后即焚时长不合法（\(ttl) 秒）"
        case .damagedBase64:
            return "这份主页的内容编码已损坏，无法读取"
        case .damagedJSON:
            return "这份主页的内容结构已损坏，无法读取"
        case let .oversizedJSON(bytes):
            return "这份主页内容太多（\(bytes) 字节，上限 \(PopopxProfilePayload.maximumJSONBytes) 字节），请删减文字或媒体"
        case let .oversizedTitle(characters):
            return "标题太长（\(characters) 个字，上限 \(PopopxProfilePayload.maximumTitleCharacters) 个字）"
        case let .tooManyBlocks(count):
            return "内容块太多（\(count) 个，上限 \(PopopxProfilePayload.maximumBlocks) 个）"
        }
    }
}

// MARK: - 载荷

/// 一条主页消息的载荷。它是 `manifest` 的纯投影：不缓存任何编码结果，所以不存在
/// "改了 manifest 但线上字节还是旧的"这种状态，`Hashable` 也因此只需要比一个字段。
struct PopopxProfilePayload: Hashable, Sendable {
    static let scheme = "popopx"
    /// 只认这一个 host；`sec` 和 `loc` 已经被另外两个特性占了。
    static let host = "profile"

    /// 制作器里可选的三档。范围校验走 `minimum/maximumTTLSeconds`，这三档只是 UI 的取值集合。
    static let ttlOptions = [60, 300, 3600]
    /// 下限 1 秒：再短就没有"打开"这个动作可言了，收件方会在内容画出来之前归零。
    static let minimumTTLSeconds = 1
    /// 上限 3600 秒：一小时的图文名片停在屏幕上不是产品，是事故。
    static let maximumTTLSeconds = 3600
    /// 清单 JSON 的字节预算。`6 KiB` 的由来：Mesh 一条消息的分片预算按 KB 计，而名片的文字量
    /// 用不了这么多；把上限写死比让发送方在链路里撞上截断更便宜。
    static let maximumJSONBytes = 6_144
    /// 内容块上限。挡住对端用 10 万个空块把收件方主线程喂死——解析发生在对方的设备上，
    /// 成本必须由收件方说了算。
    static let maximumBlocks = 24
    /// 标题上限（字素个数，不是字节）。降级行、卡片、通知预览都只放这一行标题。
    static let maximumTitleCharacters = 40

    var manifest: PopopxProfileManifest

    init(manifest: PopopxProfileManifest) {
        self.manifest = manifest
    }

    // MARK: 铸造

    /// 发送侧唯一的构造入口：先验（抛错），再规范化（保证不变量），最后编码（判字节预算）。
    ///
    /// 校验放在规范化**之前**是故意的：`normalized()` 会把 3000 秒钳到 3600，静默钳值意味着
    /// 用户选了 50 分钟、对端收到 1 小时，这一格必须当场拒。
    static func make(_ manifest: PopopxProfileManifest) throws -> PopopxProfilePayload {
        guard manifest.profileVersion == PopopxProfileManifest.version else {
            throw PopopxProfileError.unknownVersion(manifest.profileVersion)
        }
        guard manifest.title.count <= maximumTitleCharacters else {
            throw PopopxProfileError.oversizedTitle(characters: manifest.title.count)
        }
        guard manifest.blocks.count <= maximumBlocks else {
            throw PopopxProfileError.tooManyBlocks(count: manifest.blocks.count)
        }
        switch manifest.sendMode {
        case .standard:
            guard manifest.ttlSeconds == 0 else { throw PopopxProfileError.invalidTTL(manifest.ttlSeconds) }
        case .ephemeral:
            guard (minimumTTLSeconds...maximumTTLSeconds).contains(manifest.ttlSeconds) else {
                throw PopopxProfileError.invalidTTL(manifest.ttlSeconds)
            }
        }
        let normalized = manifest.normalized()
        // 编不出来就是清单本身有毛病（`encodedJSON` 会抛 `damagedJSON` / `oversizedJSON`）。
        _ = try normalized.encodedJSON()
        return PopopxProfilePayload(manifest: normalized)
    }

    // MARK: 线上字节

    /// 给人看的那一行。绝不包含任何 block 正文——会话列表、通知横幅、引用预览取的都是这条消息的
    /// `text`，标题以外的内容只能从 `data=` 里解出来，而那几个视图拿到的是这一行，不是 JSON。
    ///
    /// **恒为一行**：`title` 来自对端，里面完全可能有换行，所以这里把空白收敛成单个空格
    /// （和 `PopopxLocation.swift:105`-`:112` 同一手法，只不过那边在 `init` 里收敛，
    /// 这里必须在展示点收敛，因为载荷不接受"清洗过的副本"）。
    var degradeLine: String {
        "👤 [加密个人主页] \(Self.oneLine(manifest.title)) (\(manifest.sendMode.cardLabel))"
    }

    /// 机器读的那一行。四个值全都只含 `[A-Za-z0-9-_]`：`mode`/`delivery` 是白名单词，`ttl` 是十进制
    /// 数字，`data` 是无填充 base64url（`+` `/` `=` 三个字符在字母表里就没有了）。所以这里既不需要
    /// `PopopxLocation.swift:81`-`:84` 那套 `.alphanumerics` 转义，也不会出现 `PopopxSecurePayload.swift:131`-`:133`
    /// 说的"字段值里带空白/`&`/`=`"，解析端按空白切 token、按 `&` 切字段、按第一个 `=` 分键值才安全。
    var wireString: String {
        let mode = manifest.sendMode.wireValue
        let ttl = manifest.ttlSeconds
        let delivery = manifest.deliveryMode.wireValue
        // `make` 已经编过一次并保证编得出；这里的 `try?` 只兜住"手工塞进来一个畸形 manifest"
        // 这一种情况，代价是一条空载荷——见 `init(manifest:)` 的说明。
        let data = (try? manifest.encodedJSON()).map { $0.popopxBase64URL } ?? ""
        return "\(Self.scheme)://\(Self.host)?mode=\(mode)&ttl=\(ttl)&delivery=\(delivery)&data=\(data)"
    }

    /// 实际发出去的那条文本。它是纯文本，所以和位置、绝密消息一样天然满足 `PopopxComposerRouting`
    /// 的 mesh 前提（无附件、无引用、1:1 直聊），不需要为它多开一个判据格。
    var messageContent: String {
        degradeLine + "\n" + wireString
    }

    /// 这张卡片是不是"打开后按时销毁"的那一档。阅读时钟只在真的时候才该被问起（见
    /// `ProfileStorageManager.readState`）。
    var isEphemeral: Bool {
        manifest.sendMode == .ephemeral
    }

    /// 把计时语义说成一句人话（卡片副标题、VoiceOver）。时长本身交给 `PopopxSecureCopy.duration`，
    /// 全 app 只有两处时长格式化，不必出现第三处。
    var ttlText: String {
        switch manifest.sendMode {
        case .standard:
            return "不设销毁时间"
        case .ephemeral:
            return "\(PopopxSecureCopy.duration(manifest.ttlSeconds)) · 打开后起计"
        }
    }

    // MARK: 解析

    /// 从任意文本里读出一条主页载荷；读不到返回 nil，调用方（`PopopxBubbleMount`）
    /// 把 nil 当"这不是主页消息"，交回原来的纯文本渲染。
    ///
    /// 命中多个候选取**最后一个**：生产端把机器行拼在可读行之后，而标题里就可能夹着一个
    /// 长得像载荷的串（`popopx://profile?mode=standard&ttl=0&delivery=full&data=` 被谁当昵称写了，
    /// 或者是转发来的文本）。取第一个会让卡片渲染成用户自己打的那半行字。
    /// 同 `PopopxSecurePayload.swift:163`-`:164`、`PopopxLocation.swift:123`-`:126`。
    static func parse(from text: String) -> PopopxProfilePayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) {
                return payload
            }
        }
        return nil
    }

    /// 单个 token 的判定。暴露出来是给"已经知道自己切好了一个候选串"的调用方（扫码那条路）复用，
    /// 免得它们再抄一遍四格校验。
    static func parseToken(_ token: String) -> PopopxProfilePayload? {
        guard let components = URLComponents(string: token),
              components.scheme == scheme,
              components.host == host
        else { return nil }

        var fields: [String: String] = [:]
        // 必须走 `percentEncodedQuery`：`query` 给的是**已解码**的串，`data=eyJ%61` 在它手里先
        // 变了形，再按 `&` 切就把清单截断成一格。同 `PopopxSecurePayload.swift:181`-`:182`。
        for pair in components.percentEncodedQuery?.split(separator: "&") ?? [] {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            // 白名单比较用**编码原字节**：写成 `d%61ta` 的键进不来（`PopopxLocation.swift:149`-`:151`
            // 同判据）。野键一律丢掉，不让一条字符串借着我们的 scheme 拿到界面。
            guard fieldNames.contains(key) else { continue }
            let rawValue = String(pair[pair.index(after: separator)...])
            // `URLComponents` 会先把非法转义修好，所以这道 guard 挡的是"语法合法但字节不是 UTF-8"
            // 的序列（`%C0%80`、`%FF`）。那种 token 整串判死，不 fallback 到原串。
            // 同 `PopopxLocation.swift:154`-`:157`。
            guard let value = rawValue.removingPercentEncoding else { return nil }
            fields[key] = value
        }

        guard let rawMode = fields["mode"], let mode = PopopxProfileSendMode.fromWire(rawMode),
              let rawDelivery = fields["delivery"], let delivery = PopopxProfileDelivery.fromWire(rawDelivery),
              // `Int("+300")` 也解得成功，所以长度上限必须靠"整串只有数字"来卡，而不是靠值域。
              let rawTTL = fields["ttl"],
              rawTTL.allSatisfy(\.isNumber),
              rawTTL.count <= Self.maximumTTLDigits,
              let ttl = Int(rawTTL),
              let encodedJSON = fields["data"],
              // 先按字符数卡住分配，再解码：一段 8 MB 的 `data=` 值得在变成 `Data` 之前就被拒掉。
              encodedJSON.count <= Self.maximumEncodedJSONCharacters,
              let jsonData = Data(popopxBase64URL: encodedJSON),
              let manifest = PopopxProfileManifest.decoded(json: jsonData)
        else { return nil }

        // 信封与正文必须讲同一件事。三格里任何一格和 JSON 里的字段不一致，就是这条路被人动过
        // （或者是别家实现的另一种编码），不能挑一半信下来。
        guard manifest.sendMode == mode, manifest.deliveryMode == delivery, manifest.ttlSeconds == ttl else {
            return nil
        }
        switch mode {
        case .standard:
            guard ttl == 0 else { return nil }
        case .ephemeral:
            guard (minimumTTLSeconds...maximumTTLSeconds).contains(ttl) else { return nil }
        }

        return PopopxProfilePayload(manifest: manifest.normalized())
    }

    private static let fieldNames: Set<String> = ["mode", "ttl", "delivery", "data"]

    /// `ttl=` 的位数上限。`maximumTTLSeconds` 是 3600，四位数够用；多出来的位数一律判死，
    /// 免得有人拿 `99999999999` 去试探 `Int` 的边界。
    private static let maximumTTLDigits = 4

    /// base64url 后的最大字符数（含容忍带填充的写法）。`((bytes + 2) / 3) * 4` 是标准 base64
    /// 的长度上界，从它反推就不必先把整段解成 `Data` 才知道超标。
    private static let maximumEncodedJSONCharacters = ((maximumJSONBytes + 2) / 3) * 4

    /// 空白收敛成单个空格；空标题给一个占位词，免得降级行上出现两个连着的空格。
    private static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? "未命名主页" : collapsed
    }
}
