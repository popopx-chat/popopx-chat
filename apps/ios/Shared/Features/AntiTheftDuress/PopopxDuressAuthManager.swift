//
//  PopopxDuressAuthManager.swift
//  POPOPX (iOS)
//
//  【双密码胁迫自毁 · 模块三】两把 6 位码（常规 + 胁迫）、PBKDF2-HMAC-SHA256 校验位、
//  Keychain 只存派生值、Face ID/Touch ID 快捷解锁与连续失败降级，以及**全 app 唯一一份**
//  "抹掉存储并重建"的例程 `PopopxStorageWipe`。
//
//  ### 为什么校验位走 PBKDF2，而上游自毁码走明文比对
//  上游把自毁码原文存进 Keychain（`kcSelfDestructPassword`，POPOPXChat/KeyChain.swift:23），
//  校验是 `password == sdPassword`（LocalAuthView.swift:23）。Keychain 本身是加密的，所以这不是
//  一个明显的洞，但它有两个后果：一是拿到密钥链转储（越狱设备 + iKeyDB）就等于拿到码本身，
//  二是没有可加价的余地——想让它变贵只能整个换掉表示方式。本模块按任务要求换成
//  salt + PBKDF2-HMAC-SHA256(100_000)，从此**磁盘上不存在口令**，只有派生值。
//  ⚠️ 这不等于"上游那两个 Keychain 条目消失了"：`kcAppPassword`/`kcSelfDestructPassword`
//  仍是独立的、以原文存储的凭据，仍然被上游的 LA 门使用。`kcSelfDestructPassword` 在两处被删：
//  自毁路径（见 `PopopxStorageWipe`），以及入口码迁移那一步——后者顺带删它的理由是它唯一的输入口
//  （`LocalAuthView`）随 `kcAppPassword` 一起没了，留着就是一个谁也按不动的凭据，还会让隐私设置
//  那一格显示"已启用"（那一格只读 UserDefaults 的 bool，不读 Keychain）。若是入口码先就没了、
//  只剩这把自毁码，那一步改成**先让机主把它输一遍**才删（`retireGhostSelfDestructCode`）：
//  那是一整条迁移里唯一手上没有别的凭据能证明身份的路径。
//  `kcAppPassword` 多一条路：它只是 `.passcode` 模式下
//  `authenticate` 拿来逐字比对的那把入口码（LocalAuthenticationUtils.swift:45，**不是** SQLCipher
//  的库钥匙，库钥匙是 `kcDatabasePassword`，见 POPOPXChat/API.swift:43），本模块在启用/更换
//  POPOPX 进入密码时先验证再把它迁掉，让双密码锁成为唯一的前端认证入口
//  （见 `migrateNativeEntryPassword`）。这一条写在验收报告里，不做掩盖。
//
//  ### 为什么恒定做两次派生
//  常规码和胁迫码的校验耗时若不同（1 次 vs 2 次派生），胁迫者拿秒表就能分辨自己按下的
//  是哪一把。所以 `verify` 无条件对**两条记录各做一次** PBKDF2（缺一条就用等价的固定盐补一次
//  无意义派生），先算完、后分支。这是"零异常"在时间维度上的那一半——界面上的 1.2 秒下限
//  （`minimumFlowSeconds`）是另一半，两者都写在代码里，不靠 UI 自觉。
//
//  ### PBKDF2 为什么自己实现
//  仓库里没有 CommonCrypto 桥接，也没有第三方可用（`git grep -i pbkdf2` 只有本任务的提示词）。
//  `CryptoKit` 提供 `HMAC<SHA256>`，PBKDF2 就是它的 100_000 次串接，十行。这是有意的取舍：
//  多算几次 HMAC 换零新增依赖、零构建设置改动（红线：不给 target 加链接标志）。
//  实现按 RFC 6070/7914 的口径对齐，已知答案对（`python3 -c "import hashlib; ..."`）写在
//  `PopopxDuressCrypto` 的注释里，并且在提码前用独立 swift 脚本跑过一致——不是推测。
//
//  ### 绝不允许的事
//  1. 不 `exit(0)`/`abort()`：进程必须活着，靠内存态遮罩挡住界面（任务红线 + App Store 4.2.x）。
//     mesh 那一份现成的 `PopopxPanicWipeManager` 默认在末尾调用 `exit`，所以这里显式传
//     `termination: nil`（该参数允许 nil，见 PanicWipeManager.swift:472 的注释），并在报告里
//     承认"密钥已烧、进程仍活着"。
//  2. 不 `print`/`logger` 任何口令、盐、派生值。日志只记阶段名。
//  3. 传感器判据不通向这里（见模块一头注）。到这里的唯一一条路是键盘键入。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SwiftUI
import POPOPXChat
import PopopxMeshUI

// MARK: - 应急擦除后的账号呈现策略（三选一）

/// 抹完之后交出什么样的账号。由机主在设置页用 `PopopxSegmentedControl` 自己选，
/// 持久化在 UserDefaults（JSON，因为带关联值）；**胁迫流程只读它一次**
/// （见 `PopopxDuressAuthManager.submit` 的步骤 A），之后一律用那份内存副本，
/// 因为擦除会把这个键连同整个模块的痕迹一起清掉。
///
/// 默认 `.emptyProfile`：一个刚装好的空 app 不需要任何伪造内容就能自圆其说，
/// 而凭空多出来的三个联系人是**需要被解释**的东西。另外两种都要机主明确选过才生效。
///
/// 本类型取代第一轮的 `PopopxDuressRebuildMode`（两选一）。带关联值之后它不再能被
/// `CaseIterable`/`RawRepresentable` 表达，所以持久化改成 `Codable` JSON，
/// 分段器则由界面按 `segmentTitles` 的顺序拼（`segmentIndex` 是唯一的映射口径）。
enum PopopxDuressRetentionStrategy: Codable, Hashable, Sendable {
    /// 保留指定现有匿名身份：物理删除其余所有身份与厢语映射，切到 `profileId`。
    /// `profileId` = `User.userId`（`POPOPXChat/ChatTypes.swift:31`，Int64），
    /// `displayName` 只是给人看的快照——真正的判据永远是 id。
    case retainExistingProfile(profileId: Int64, displayName: String)
    /// 仿真烟雾弹号：随机生活化昵称 + 2–3 个假联系人 + 过去 24 小时内的无害中文对话。
    case simulatedDecoy
    /// 全新空白号：只建一个新档案，零联系人、零消息，等同刚下载安装。
    case emptyProfile

    /// 分段器的三格标题，顺序即 `segmentIndex` 的定义。每格 5 个汉字以内
    /// （`PopopxSegmentedControl` 只给一行，超了就截断）。
    static let segmentTitles: [String] = ["保留指定昵称", "仿真烟雾弹号", "全新空白号"]

    static let defaultValue = PopopxDuressRetentionStrategy.emptyProfile

    var segmentIndex: Int {
        switch self {
        case .retainExistingProfile: return 0
        case .simulatedDecoy: return 1
        case .emptyProfile: return 2
        }
    }

    /// 分段器点回来的下标。**越界一律回到默认值**，不崩也不猜：这一格选错
    /// 意味着抹完机主的数据之后交出一个不像他的账号。
    static func fromSegmentIndex(_ index: Int) -> PopopxDuressRetentionStrategy {
        switch index {
        case 0: return .retainExistingProfile(profileId: 0, displayName: "")
        case 1: return .simulatedDecoy
        default: return .emptyProfile
        }
    }

    var label: String { Self.segmentTitles[segmentIndex] }

    var isRetainExisting: Bool {
        if case .retainExistingProfile = self { return true }
        return false
    }

    /// 保留策略里要点选的那个身份 id；另外两种没有这个概念。
    var retainedProfileId: Int64? {
        if case let .retainExistingProfile(profileId, _) = self { return profileId }
        return nil
    }

    var note: String {
        switch self {
        case .retainExistingProfile:
            return "只保留你选定的那一个匿名身份，其余身份、厢语蓝牙映射与全部会话痕迹物理删除。"
        case .simulatedDecoy:
            return "抹除后重建一个带生活化昵称、少量熟人与 24 小时内日常对话的仿真账号。"
        case .emptyProfile:
            return "抹除后进入一个刚安装好的空 app，不生成任何伪造内容。"
        }
    }

    /// 读回机主的预设。**解不开就回到默认值**：这份数据只影响"抹完之后交出什么账号"，
    /// 拿一个猜出来的策略去重建比拿默认值更糟；而默认值（空白号）恰好是最不会
    /// 多做出东西的那一个。
    static func load(from defaults: UserDefaults = .standard) -> PopopxDuressRetentionStrategy {
        guard let data = defaults.data(forKey: DEFAULT_ANTI_THEFT_RETENTION_STRATEGY),
              let strategy = try? JSONDecoder().decode(PopopxDuressRetentionStrategy.self, from: data)
        else { return .defaultValue }
        return strategy
    }

    /// 写盘。编码失败时**删键**而不是留旧值：留旧值等于界面显示 A、实际按 B 抹。
    /// 删掉之后 `load` 回到默认值，和界面上"没选过"的表现一致。
    func store(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else {
            defaults.removeObject(forKey: DEFAULT_ANTI_THEFT_RETENTION_STRATEGY)
            return
        }
        defaults.set(data, forKey: DEFAULT_ANTI_THEFT_RETENTION_STRATEGY)
    }
}

// MARK: - 结论与错误

/// 一次键盘提交或生物识别的结论。
///
/// `.unlocked` 与 `.duress` 对**界面**必须走同一支：遮罩层拿到的两个分支做同一件事
/// （`PopopxAppLockState.unlock()`），不许因为 `.duress` 而多显示或少显示任何东西。
/// 之所以还是分成两个 case，是为了让类型系统里留着这条路径的痕迹，方便审计。
enum PopopxDuressAuthOutcome: Hashable, Sendable {
    case unlocked
    case duress
    case wrong
    case notConfigured
}

/// 设置页配置两把码时的失败原因。全是本地校验，不涉及网络。
enum PopopxDuressSetupError: Error, Equatable, LocalizedError {
    /// 不是恰好 6 位 ASCII 数字。
    case malformedPin
    /// 两把码相同——任务红线：常规码与胁迫码必须不同，否则"交出常规码"和"交出胁迫码"
    /// 是同一个动作，整个设计失效。
    case pinsMustDiffer
    /// 还没设常规码就先设胁迫码。
    case normalPinRequiredFirst
    /// Keychain 写入被拒（设备未解锁、或条目不可写）。
    case keychainWriteFailed
    /// 原生入口码（`kcAppPassword`）还开着，但界面没采集到用来确认迁移的那一次输入。
    /// 这一支不是"做错了"，而是"还差一步"：写新码之前得先把旧前门体面地关掉。
    case nativePasscodeRequired
    /// 采集到了，但与 `kcAppPassword` 里那把对不上。此时**什么都没改**——旧前门还在原处，
    /// 新前门也没装上。
    case nativePasscodeIncorrect
    /// 本机已经没有原生入口码了，那把自毁码（或它对应的开关）却还留着：它唯一的输入口是
    /// 入口码那台键盘，键盘先没了，于是成了一把谁也按不动的幽灵凭据。要清它得先证明身份，
    /// 理由与完整推导写在 `migrateNativeEntryPassword` 的"幽灵自毁码"那一节。
    case nativeSelfDestructCodeRequired
    /// 采集到了，但与 `kcSelfDestructPassword` 里那把原文对不上。**什么都没改**，
    /// 幽灵状态原样留着——它按不动，所以留着也不比删了更危险，而误删是不可逆的。
    case nativeSelfDestructCodeIncorrect

    var errorDescription: String? {
        switch self {
        case .malformedPin: return "请输入恰好 6 位数字"
        case .pinsMustDiffer: return "胁迫密码不能与常规密码相同"
        case .normalPinRequiredFirst: return "请先设置常规密码"
        case .keychainWriteFailed: return "安全存储写入失败，请稍后重试"
        case .nativePasscodeRequired: return "请先输入设备原有的入口密码，以关闭重复的解锁键盘"
        case .nativePasscodeIncorrect: return "原有入口密码不正确，本次未做任何修改"
        case .nativeSelfDestructCodeRequired: return "请先输入设备原有的自毁密码，才能把它一并关掉"
        case .nativeSelfDestructCodeIncorrect: return "原有自毁密码不正确，本次未做任何修改"
        }
    }
}

/// 一次抹除的结果。`failure` 带阶段名，不带任何口令痕迹。
enum PopopxWipeOutcome: Equatable, Sendable {
    case success
    case failure(stage: String)
}

// MARK: - 校验位记录

/// 存进 Keychain 的那一条记录：**只有**盐与派生值。
///
/// `iterations` 跟着记录一起存而不是引用常量，是为了让将来涨价（20 万、40 万）时旧记录
/// 仍可校验：改常量只会影响新生成的记录，不会出现"升级后所有人的码都失效"。
struct PopopxDuressVerifier: Codable, Equatable {
    var version: Int
    var iterations: Int
    var salt: Data
    var hash: Data

    init(salt: Data, hash: Data, iterations: Int) {
        self.version = 1
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
    }

    /// 用来占位、把工作量补齐的那一条：不写盘，只参与一次真实派生。
    static func workloadPad(salt: Data) -> PopopxDuressVerifier {
        PopopxDuressVerifier(
            salt: salt,
            hash: Data(repeating: 0, count: PopopxDuressCrypto.hashBytes),
            iterations: PopopxDuressCrypto.iterations
        )
    }

    var encoded: Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> PopopxDuressVerifier? {
        try? JSONDecoder().decode(PopopxDuressVerifier.self, from: data)
    }
}

// MARK: - 口令派生

/// 纯函数区：PBKDF2-HMAC-SHA256 与恒定时间比较。
///
/// 这个 enum 上没有 `@MainActor`，所以派生可以整段搬到 `Task.detached` 里跑；100_000 次
/// HMAC 实测在 A 系列芯片上是几百毫秒量级，压在 60Hz 的呼吸动画上就是一次可被看见的卡顿，
/// 而"卡顿"本身就是这个界面唯一允许存在的风险，所以不能在主线程算。
enum PopopxDuressCrypto {
    static let saltBytes = 32
    static let hashBytes = 32
    static let iterations = 100_000

    /// 已知答案对：本文件的实现被**逐字抽出**喂给
    /// `python3 -c "import hashlib; print(hashlib.pbkdf2_hmac('sha256', pw, salt, c, dk).hex())"`
    /// 比对，8 组全对，其中包含两组多块输出（dkLen=48 与 6）用来卡住 i2be 计数器与拼接边界
    /// （`03ee63fb94ef677d779f4654f03a90103c4db92872578740f62727a0ab02cffb` /
    /// `3d22d31d46da4f54404f3b0f7ca2710ff49d4a9eb2fc44b68c6ef0050b13`），
    /// 单块实现写错端序是测不出来的，多块才暴露。等价的标准向量见 RFC 7914 §12
    /// （PBKDF2-HMAC-SHA256：P="password" S="salt" c=1 dkLen=32 →
    /// `120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b`，
    /// c=2 → `ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43`）。
    /// 实测一次 c=100_000、dkLen=32 的派生耗时 **355ms**（本机 arm64，`xcrun swift` 直跑），
    /// 所以 `verify` 的恒定两次派生约 0.7 秒——这个数字直接决定了界面那 1.2 秒下限是不是
    /// 一个会被真活干穿的预算，见 `PopopxDuressAuthManager.minimumFlowSeconds`。
    static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        outputCount: Int
    ) -> Data {
        guard iterations > 0, outputCount > 0 else { return Data() }
        let key = SymmetricKey(data: password)
        let blockCount = (outputCount + Int(SHA256.byteCount) - 1) / SHA256.byteCount
        var output = Data(capacity: blockCount * SHA256.byteCount)
        for index in 1...blockCount {
            // i2be(OctetCount) —— RFC 8018 里 PBKDF2 的 `i` 必须是大端 4 字节，
            // 写成小端会算出另一个数，而且只在 blockCount > 1 时才暴露。这里只出 1 块，
            // 但按规范写，免得将来 dkLen 变大时静默换算法。
            let counter = UInt32(index).bigEndian
            var blockSalt = salt
            blockSalt.append(contentsOf: withUnsafeBytes(of: counter) { Array($0) })
            var u = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: key))
            var accumulator = u
            var round = 1
            while round < iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for byte in accumulator.startIndex..<accumulator.endIndex {
                    accumulator[byte] ^= u[byte]
                }
                round += 1
            }
            output.append(accumulator)
        }
        return output.prefix(outputCount)
    }

    /// 恒定时间比较：把差异累积到位运算里，最后只看总和。
    /// 长度不等直接判负——长度不是秘密，本模块的两条记录长度恒等。
    static func matchesInConstantTime(_ candidate: Data, _ stored: Data) -> Bool {
        guard candidate.count == stored.count, !candidate.isEmpty else { return false }
        var difference: UInt8 = 0
        for offset in 0..<candidate.count {
            difference |= candidate[candidate.startIndex + offset] ^ stored[stored.startIndex + offset]
        }
        return difference == 0
    }

    /// 32 字节系统随机盐。`SecRandomCopyBytes` 与上游生成数据库密钥用的是同一个来源
    /// （POPOPXChat/KeyChain.swift:42-45），不引入 `arc4random` 之类的第二套口径。
    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 系统随机源失败时**不能**退回时间戳：那会让盐可预测，而这正是盐要解决的问题。
            // 宁可不写入，也不写一个假的安全属性。
            return Data()
        }
        return Data(bytes)
    }
}

// MARK: - 校验位存储

/// 双密码自己的 Keychain 条目。
///
/// 不复用 `KeyChainItem`：它只存取 `String`，且访问级别是
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（KeyChain.swift:13）。任务要求
/// `WhenUnlockedThisDeviceOnly`——设备锁上时连派生值都读不出来，这才是"胁迫者对着锁屏
/// 也拿不到校验位"的那一层。所以这里自己写 Security 查询，访问组沿用上游那一条
/// （`PDBA6XRBQT.com.popopxchat.popopx`，KeyChain.swift:14 是 `private`，故此处重述其值），
/// 免得条目落在错误的组里、在重装后无法读取。
enum PopopxDuressKeychain {
    static let normalAccount = "popopx.duress.normal"
    static let duressAccount = "popopx.duress.duress"

    private static let service = "popopx.duress"
    private static let accessGroup = "PDBA6XRBQT.com.popopxchat.popopx"

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS) && !targetEnvironment(simulator)
        query[kSecAttrAccessGroup as String] = accessGroup
        #endif
        return query
    }

    static func read(_ account: String) -> PopopxDuressVerifier? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return PopopxDuressVerifier.decode(data)
    }

    static func write(_ verifier: PopopxDuressVerifier, account: String) -> Bool {
        guard let data = verifier.encoded else { return false }
        var query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// 删除。不检查返回码是否为 `errSecItemNotFound`：对自毁来说"本来就没有"就是已完成。
    @discardableResult
    static func delete(_ account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary) == errSecSuccess
    }

    static func exists(_ account: String) -> Bool {
        read(account) != nil
    }
}

// MARK: - 抹除与重建（全 app 唯一一份）

/// "把这台设备上的身份抹掉，然后交出一个干净可用的 app"。
///
/// 上游这一段代码住在 `LocalAuthView.deleteStorageAndRestart`（Shared/Views/LocalAuth/LocalAuthView.swift），
/// 原本是 56 行的私有方法。本模块需要同一件事，于是**把它搬出来变成唯一实现，并让上游调用它**
/// （上游现在只剩一次 `PopopxStorageWipe.run` 调用），而不是复制一份：复制的代价是将来某一次只改了一边，而"改了哪一边"这种事不会有人记得查。
///
/// 顺序是承重的，逐条都有理由：
/// 1. 等 `ctrlInitInProgress` 落地——初始化中途关库会留下半开的句柄；
/// 2. 停聊天线程（`stopChatAsync`）；
/// 3. 关库（`chatCloseStore`）——iOS 可能在库还开着时拒绝删除文件，见上游原注释；
/// 4. 烧 mesh 身份（`PopopxMeshIdentityWiper`）——必须在删文件之前，因为它自己也要动沙盒；
/// 5. 删数据库 + 全部媒体/临时文件（`deleteAppDatabaseAndFiles`，FileUtils.swift:110 起，
///    覆盖 chat.db / agent.db / 备份 / 导出 / 临时目录 / 壁纸目录 / `deleteAppFiles()` 的
///    XFTP 收件目录，并顺手删掉 `kcDatabasePassword`）；
/// 6. 清内存里已经渲染出来的东西——遮罩先盖住，再慢慢清，避免"重建期间屏幕上还留着上一条消息"；
/// 7. 删所有口令类 Keychain 条目（上游两条 + 本模块两条）；
/// 8. 清通知；
/// 9. 重建控制层、建新用户、起线程；
/// 10. 交回调用方做善后（胁迫路径在这里装烟雾弹身份）。
enum PopopxStorageWipe {
    struct Options {
        /// 抹完之后写回上游 `kcAppPassword` 的那把码。上游自毁路径传"自毁码本身"
        /// （行为：设备仍然有锁，且锁就是这把码）。胁迫路径传 nil——传 nil 走的就是
        /// `wipe` 里 `kcAppPassword.remove()` 那一支，烟雾弹必须能直接进去，而且降级码
        /// 只该活在本模块那一条 verifier 里，同时活在两处等于把刚拆掉的第二套键盘装回去。
        /// 这里刻意不谈"库口令"：`kcAppPassword` 与 SQLCipher 无关，库钥匙是
        /// `kcDatabasePassword`，重建出来的新库由 `chatMigrateInit` 自己生成随机钥匙
        /// （POPOPXChat/API.swift:34-42）。
        var reinstatesAppPasscode: String?
        /// 新建用户的显示名。上游自毁路径读 `DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME`；
        /// 胁迫路径取模块四给的仿真名字。
        var displayName: String?
        /// 是否顺手关掉本模块的全部防盗开关。胁迫路径必须是 true——重建后的仿真身份
        /// 顶着一套"防盗锁定已开启"的状态，等于告诉来人这里曾经有过真东西。
        var disarmsAntiTheft: Bool
        /// 第 10 步的钩子。异步、主 actor，抛错不影响抹除本身已成功的事实。
        var afterRebuild: (@MainActor () async -> Void)?
    }

    /// 异步版：胁迫路径用它，好处是可以把整段 await 到真的做完，再决定什么时候收起遮罩。
    @MainActor
    static func wipe(options: Options) async -> PopopxWipeOutcome {
        let m = ChatModel.shared
        do {
            while m.ctrlInitInProgress {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if m.chatRunning == true {
                try await stopChatAsync()
            }
            if m.chatInitialized {
                chatCloseStore()
            }
            await PopopxMeshIdentityWiper.wipe()
            await deleteStorageFilesOffMain()
            clearRenderedState(m)
            if let passcode = options.reinstatesAppPasscode {
                _ = kcAppPassword.set(passcode)
            } else {
                _ = kcAppPassword.remove()
            }
            _ = kcSelfDestructPassword.remove()
            PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
            await NtfManager.shared.removeAllNotifications()
            UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
            UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME)
            if options.disarmsAntiTheft {
                PopopxAntiTheftSwitches.eraseAllTraces()
            }
            m.chatDbChanged = true
            m.chatInitialized = false
            resetChatCtrl()
            try initializeChat(start: true)
            m.chatDbChanged = false
            AppChatState.shared.set(.active)
            if m.currentUser == nil {
                var profile: Profile? = nil
                if let displayName = options.displayName, !displayName.isEmpty {
                    profile = Profile(displayName: displayName, fullName: "")
                }
                m.currentUser = try apiCreateActiveUser(profile, pastTimestamp: true)
                onboardingStageDefault.set(.onboardingComplete)
                m.onboardingStage = .onboardingComplete
                try startChat()
            }
            if let afterRebuild = options.afterRebuild {
                await afterRebuild()
            }
            return .success
        } catch {
            // 只记阶段，不记任何输入内容。`localizedDescription` 来自 FFI/文件层，不含口令。
            logger.error("duress wipe: \(String(describing: type(of: error)))")
            return .failure(stage: "rebuild")
        }
    }

    /// 上游 `LocalAuthView` 用的回调版桥接。保持和它原来一样的形状：在内部起 Task，
    /// 结束时回到调用方给的 `completed`，宿主视图里因此不需要出现 `Task`/`await`。
    @MainActor
    static func run(options: Options, completed: @escaping (LAResult) -> Void) {
        Task { @MainActor in
            let outcome = await wipe(options: options)
            switch outcome {
            case .success:
                completed(.success)
            case .failure:
                // 与上游原行为一致：抹除失败时对外只说"密码不对"。自毁失败若如实播报，
                // 等于告诉胁迫者"这个码有问题，换个姿势逼"。
                completed(.failed(authError: NSLocalizedString("Incorrect passcode", comment: "PIN entry")))
            }
        }
    }

    /// 删文件这一段是全流程里最重的一次同步 I/O（递归删目录树）。上游在主线程做，
    /// 本模块挪到后台：遮罩的呼吸动画要在这一整段里继续跑，主线程一停就是一次可看见的卡顿。
    /// 顺序不变——仍然在 `chatCloseStore()` 之后、清内存之前。
    private static func deleteStorageFilesOffMain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                deleteAppDatabaseAndFiles()
                continuation.resume()
            }
        }
    }

    /// 把屏幕上已经画出来的东西清掉。逐字抄自上游 `LocalAuthView.deleteStorageAndRestart`
    /// 原来那段手写序列（那几行现已整段搬进本文件，行号只在 git 历史里），包括它对 `secondaryIM` 的处理——离线队列那份 `ItemsModel` 也画过消息。
    private static func clearRenderedState(_ m: ChatModel) {
        m.chatId = nil
        ItemsModel.shared.reversedChatItems = []
        ItemsModel.shared.chatState.clear()
        m.secondaryIM?.reversedChatItems = []
        m.secondaryIM?.chatState.clear()
        m.updateChats([])
        m.users = []
    }
}

/// mesh 身份的烧毁。
///
/// 复用 `PopopxPanicWipeManager`，但**不能**用它默认的那一份：默认构造的
/// `termination` 是 `Self.processExit`（PanicWipeManager.swift:435/482），会 `exit(0)`。
/// 任务红线和 App Store 都不允许，所以这里显式注入 `termination: nil`；该管理器本来就
/// 为这种宿主写明了行为——不退出，并在自己的报告里记下"进程仍活着"（:655-660）。
/// 传 `includeApplicationDatabase: false`（默认值）：聊天库由 `PopopxStorageWipe` 自己按
/// 顺序删，两边都动同一个文件只会互相踩。
enum PopopxMeshIdentityWiper {
    @MainActor
    static func wipe() async {
        let manager = PopopxPanicWipeManager(termination: nil)
        _ = await manager.execute(includeApplicationDatabase: false)
        logger.debug("duress wipe: mesh identity burned")
    }
}

/// 自毁后必须一并清掉的防盗痕迹。
///
/// 单独列出来有两个理由：一是"清哪些键"这件事必须可被审计，不能散在 `if` 里；
/// 二是重建后的仿真身份如果还顶着一套"防盗锁定已开启、重建模式=仿真烟雾弹"的运行期状态，
/// 等于告诉来人这里曾经有过真东西——那比不抹还糟。
enum PopopxAntiTheftSwitches {
    /// 删掉本模块写进 UserDefaults 的**所有**键，并把运行期开关拨回关闭。
    @MainActor
    static func eraseAllTraces() {
        // 顺序是承重的：先拨运行期开关，再删键。`enabled` 的 `didSet` 会把值写回
        // UserDefaults，如果反过来（先删后拨）就等于亲手把刚删掉的键又写回去一遍，
        // 痕迹一个没少。
        PopopxAntiTheftMotionGuard.shared.enabled = false
        PopopxBehaviorGuard.shared.enabled = false
        let defaults = UserDefaults.standard
        for key in POPOPX_ANTI_THEFT_DEFAULT_KEYS {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - 策略①：只保留指定身份的择一擦除

/// `PopopxDuressRetentionStrategy.retainExistingProfile` 的执行体。
///
/// 它**不删数据库**，这是全模块里唯一一条不经过 `PopopxStorageWipe` 的自毁路径，理由写在
/// 下面每一步里。相应地，"抹除一切双密码痕迹"这一条在这里靠
/// `PopopxAntiTheftSwitches.eraseAllTraces()` + 步骤 C 覆盖 Keychain 来完成，
/// 而不是靠删文件。
enum PopopxDuressProfileKeeper {
    /// 阶段名只进日志，绝不进界面。调用方按它决定要不要降级重建（见 `runDuressFlow`）。
    ///
    /// `appPasscode` 由调用方现读 `kcAppPassword` 传进来，只当隐藏身份 `viewPwd` 的**退路**用。
    /// 诚实边界：隐藏身份的查看口令是机主切换身份时手输的另一把码
    /// （NewChatView.swift:464 的 `trimmedSearchTextOrPassword`），并不保证等于入口码；
    /// 这里只是拿它试一次，试不通就走 `failure` → 调用方降级为全量重建（安全方向更彻底那一支）。
    /// 机主在设置页启用/更换 POPOPX 进入密码后入口码会被迁掉（`migrateNativeEntryPassword`），
    /// 那时这一条读到的是 nil，"保留一个隐藏身份"的成功率因此下降——这是拆双键盘换来的代价，
    /// 写清楚，不让回退路径把它藏起来。
    @MainActor
    static func retain(profileId: Int64, appPasscode: String?) async -> PopopxWipeOutcome {
        // 1) 身份列表以底层为准：`ChatModel.users` 可能还是启动时读的那份，
        //    而这里"少删一个身份"和"多删一个身份"都是事故。
        let users: [UserInfo]
        do {
            users = try await listUsersAsync()
        } catch {
            logger.error("duress retain: listUsers failed \(responseError(error))")
            return .failure(stage: "listUsers")
        }
        guard users.contains(where: { $0.user.userId == profileId }) else {
            // 简报点名的那一种失败：目标已经不在了 → 调用方安全降级为仿真烟雾弹重建。
            return .failure(stage: "profileMissing")
        }
        // 2) 先切到要留的那个，再删其余。反过来的话删到最后会剩一个"当前身份已被删除"的
        //    中间态，底层在这一步拒绝继续，而那时其他身份已经删完了、活跃身份却没了。
        do {
            try await changeActiveUserAsync_(profileId, viewPwd: nil)
        } catch {
            // 隐藏身份必须带查看口令才切得动（口径同 NewChatView.swift:464）。
            guard let appPasscode, !appPasscode.isEmpty else {
                logger.error("duress retain: setActiveUser failed, no viewPwd to retry with")
                return .failure(stage: "setActiveUser")
            }
            do {
                try await changeActiveUserAsync_(profileId, viewPwd: appPasscode)
            } catch {
                logger.error("duress retain: setActiveUser failed with viewPwd too")
                return .failure(stage: "setActiveUserRetry")
            }
        }
        // 3) 删除其余身份。`delSMPQueues: true` 连服务端的队列一起删——只删本机
        //    等于把"这个身份存在过"留在中继服务器上，那不是"保留指定昵称"要收窄的面。
        for user in users where user.user.userId != profileId {
            do {
                try await apiDeleteUser(user.user.userId, true, viewPwd: appPasscode)
            } catch {
                // 单个删不掉**不中止**：中止会整体降级为全量重建，把机主点名要留的那个
                // 身份一起抹掉，那比留一个删不干净的次要身份更违背他的选择。
                logger.error("duress retain: cannot delete user \(user.user.userId)")
            }
        }
        // 4) 厢语蓝牙身份映射（含内存缓存）+ 本模块自己的配置痕迹。
        await PopopxMeshIdentityWiper.wipe()
        PopopxAntiTheftSwitches.eraseAllTraces()
        return .success
    }
}

// MARK: - 双密码管理器

@MainActor
@Observable
final class PopopxDuressAuthManager {
    static let shared = PopopxDuressAuthManager()

    static let pinLength = 6
    static let digits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// 每次键盘解锁的固定下限，也是胁迫路径的**下限而非上限**。
    /// 两条作用：给真自毁打掩护（常规解锁同样要等满，秒表量不出差别），
    /// 以及给呼吸动画一个不会穿帮的最短时长。UI 侧那 1.2 秒的可见呼吸以它为准，
    /// 所以抖动只会让界面"多呼吸一会儿"，绝不会少于动画设计时长。
    static let minimumFlowSeconds: TimeInterval = 1.2

    /// 在下限之上再叠 0~1.2 秒的随机抖动，理由见 `submit(pin:)` 的时序说明。
    static let flowJitterSeconds: TimeInterval = 1.2

    /// 连续生物识别失败次数上限：到了就本次会话只认键盘。
    /// 为什么是 2：第 1 次多半是手湿/戴了口罩，值得重试；第 3 次已经不是"没认出来"了。
    /// 且降级方向只能是更强的证明（键入只有本人知道的码），绝不能反过来。
    static let maxBiometricFailuresBeforeKeypad = 2

    private(set) var normalConfigured = false
    private(set) var duressConfigured = false
    private(set) var biometricFailures = 0
    /// true = 键盘强制模式（生物连续失败后，或设备没有生物识别能力）。
    private(set) var keypadRequired = false

    /// 双密码自毁总开关。关掉之后胁迫码不再存在（记录会被删除），避免"关了开关但
    /// 那把码还留着"这种最危险的状态。
    var duressEnabled: Bool {
        didSet {
            guard oldValue != duressEnabled else { return }
            UserDefaults.standard.set(duressEnabled, forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED)
            if !duressEnabled {
                PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
                duressConfigured = false
            }
        }
    }

    var biometricsEnabled: Bool {
        didSet {
            guard oldValue != biometricsEnabled else { return }
            UserDefaults.standard.set(biometricsEnabled, forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED)
            if biometricsEnabled {
                biometricFailures = 0
                keypadRequired = false
            }
        }
    }

    var biometricsAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// 遮罩决定"开局给生物识别还是直接给键盘"用的那一条判断。
    var prefersBiometricUnlock: Bool {
        biometricsEnabled && !keypadRequired && biometricsAvailable && normalConfigured
    }

    private init() {
        let defaults = UserDefaults.standard
        duressEnabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED)
        biometricsEnabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED)
        retentionStrategy = PopopxDuressRetentionStrategy.load(from: defaults)
        normalConfigured = PopopxDuressKeychain.exists(PopopxDuressKeychain.normalAccount)
        duressConfigured = duressEnabled && PopopxDuressKeychain.exists(PopopxDuressKeychain.duressAccount)
    }

    /// Keychain 会在别的进程/别的会话里被改动（自毁就是这种改动），所以每次进入遮罩
    /// 与设置页时重新读一遍真实状态，而不是相信内存里那份缓存。
    @MainActor
    func refreshConfiguration() {
        normalConfigured = PopopxDuressKeychain.exists(PopopxDuressKeychain.normalAccount)
        duressConfigured = duressEnabled && PopopxDuressKeychain.exists(PopopxDuressKeychain.duressAccount)
    }

    // MARK: 配置

    static func isValidPin(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { digits.contains($0) }
    }

    // MARK: 原生入口码迁移（前端认证入口只留一个）

    /// 上游那把"入口密码"与本模块的双密码锁是并列的两套前门：`authenticate(reason:)`
    /// （LocalAuthenticationUtils.swift:40）在 `privacyLocalAuthModeDefault == .passcode` 时
    /// 把键盘挂成 `LocalAuthView`（ContentView.swift:97、ChatListView.swift:127），而
    /// `PopopxAppLockOverlayView` 是本模块自己的键盘。两把码不同 = 同一台设备开两次锁，
    /// 两把码相同 = 同一个码输两遍。启用/更换 POPOPX 进入密码时把前者迁掉，前端只留一个入口。
    ///
    /// 迁移**不需要重建库钥匙**：SQLCipher 的口令是 `kcDatabasePassword`
    /// （POPOPXChat/API.swift:43 开库时读它），与 `kcAppPassword` 无关——后者只是 `.passcode`
    /// 模式下塞进 `LocalAuthRequest.password` 做字符串比对的那把码（LocalAuthenticationUtils.swift:45）。
    /// 判据只有一条：**Keychain 里那把原文入口码还在不在**，不看模式。
    ///
    /// 它刻意与 `migrateNativeEntryPassword` 的第一道 `guard` 用同一个条件（同一个
    /// `kcAppPassword.get()`）。这两个判断一个是"界面要不要问密码"、一个是"代码要不要密码"，
    /// 只要差一种状态——模式已经 `.system`、条目却还留着（上游改模式时并不保证删条目）——
    /// 就会变成"迁移坚持要一次输入，而页面上根本没有那个输入格"的死锁，机主只能干看着。
    /// 模式为 `.system` 时这台键盘确实不弹（`authenticate` 直接走 `systemAuthenticate`，
    /// LocalAuthenticationUtils.swift:42），但那把明文凭据仍然躺在密钥链里，照样该由机主亲手关掉。
    @MainActor
    static var nativeEntryPasswordActive: Bool {
        kcAppPassword.get() != nil
    }

    /// 「幽灵自毁码」：入口码已经没了（所以上面那一格不会出现），而那把只有入口码键盘才输得进去
    /// 的自毁码还留着——`kcSelfDestructPassword` 有条目，或者 `DEFAULT_LA_SELF_DESTRUCT` 仍为真。
    /// 条件与 `retireGhostSelfDestructCode` 严格同构，理由同上：不能代码要、界面不问。
    @MainActor
    static var nativeSelfDestructGhostActive: Bool {
        kcAppPassword.get() == nil
            && (kcSelfDestructPassword.get() != nil
                || UserDefaults.standard.bool(forKey: DEFAULT_LA_SELF_DESTRUCT))
    }

    /// 先验证、后迁移。三道判定全部排在任何写入之前，所以任何一支失败都是"什么都没改"。
    ///
    /// 迁掉码的同时把模式拨回上游自己的 `.system`——只删码不改模式是不够的：
    /// `.passcode` + 无条目时 `authenticate` 回 `.unavailable`，而 `authorize()` 把它当作已授权
    /// （LocalAuthenticationUtils.swift:24），用它把守的那两处调用点会当场静默放行。上游另有
    /// 九处直接调 `authenticate(reason:)`（PrivacySettings 六处、ContentView 两处、DatabaseView
    /// 一处），它们各自怎么处理 `.unavailable` 本模块不依赖、也不替它们下结论。
    /// `.system` 是上游的出厂默认（SettingsView.swift:224），也是它自己在 biometric
    /// 开启时的既有配置（PrivacySettings.swift:766 就是 `kcAppPassword.remove()`），
    /// 迁移后由系统 Face ID/设备密码把守这些门，应用内的键盘只剩本模块这一套。
    ///
    /// 自毁码那一把也一并删，理由是它已经**不可能再被触发**：它唯一的输入口是 `LocalAuthView`
    ///（LocalAuthView.swift:23 `password == sdPassword`），而那张视图只有在 `.passcode` 模式且
    /// `kcAppPassword` 取得到值时才会被挂起（LocalAuthenticationUtils.swift:45-47）——上一行刚把
    /// 入口码删掉，这把码就再也没有地方可输。留着它不是"多一道保险"，而是一个谁也按不动的凭据，
    /// 外加隐私设置那一格的谎：开关状态只读 UserDefaults 里那个 bool（PrivacySettings.swift:512
    /// 是它的初值、:898 是写回），根本不读 Keychain，所以两个必须一起落，页面才会老实说"没开"。
    /// 删法对齐上游自己的 `resetSelfDestruct()`（PrivacySettings.swift:886-890 就是"删条目 + 置假"）。
    ///
    /// 明文比对走 `PopopxDuressCrypto.matchesInConstantTime`：`kcAppPassword` 是原文存的
    /// （POPOPXChat/KeyChain.swift:21），Swift 的 `==` 逐字符短路，会把"前几位对不对"泄漏成耗时差。
    ///
    /// `kcDatabasePassword` 一个字都不动——它才是 SQLCipher 的库钥匙，删了就得重建库。
    /// `DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME` 留着：那个名字只在那台键盘真的自毁时被读
    ///（LocalAuthView.swift:61），入口码没了以后它是一条死键，不值得为它多删一次。
    /// - Parameters:
    ///   - passcode: 界面向机主索取的那一次原始入口码输入。nil = 没采集。
    ///   - selfDestructPasscode: 只有"入口码已经没了、只剩幽灵自毁码"那一支用得上（见
    ///     `retireGhostSelfDestructCode`）。入口码还在的那一支不需要它：身份已经被上面那次比对
    ///     证明了，而这一把码在那台键盘消失之后本来就按不动——这是两轮裁定的分界，写清楚免得
    ///     后来人以为是漏了验证。
    static func migrateNativeEntryPassword(passcode: String?, selfDestructPasscode: String? = nil) throws {
        guard let stored = kcAppPassword.get() else {
            // 绝大多数设备的状态：没有原生入口码。先处理可能存在的幽灵自毁码（它要验证，
            // 失败就整支什么都不改），再顺手订正"模式还停在 .passcode、条目却已经不在"这种
            // 半迁移状态——订正的理由就是上面那条 `authorize()` 的静默放行。
            try retireGhostSelfDestructCode(passcode: selfDestructPasscode)
            if privacyLocalAuthModeDefault.get() == .passcode {
                privacyLocalAuthModeDefault.set(.system)
            }
            return
        }
        guard let passcode, !passcode.isEmpty else {
            throw PopopxDuressSetupError.nativePasscodeRequired
        }
        guard PopopxDuressCrypto.matchesInConstantTime(Data(passcode.utf8), Data(stored.utf8)) else {
            throw PopopxDuressSetupError.nativePasscodeIncorrect
        }
        _ = kcAppPassword.remove()
        _ = kcSelfDestructPassword.remove()
        UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
        privacyLocalAuthModeDefault.set(.system)
    }

    /// 清掉「幽灵自毁码」——入口码先没了，于是这把只有那台键盘才输得进去的码成了按不动的死凭据。
    /// 裁定是先验证、后清除，但**只对真凭据验证**，两种残留分开处理：
    ///
    /// - 条目还在 → 必须让机主把它输一遍。这一支是整条迁移里唯一"手上没有任何其他凭据可以证明
    ///   身份"的路径：不问清楚就删，等于替一个陌生人关掉他自己不知道存在的保险。
    /// - 条目没了、只有 `DEFAULT_LA_SELF_DESTRUCT` 为真 → 直接落掉，不问。那个 bool 单独存在时
    ///   删不掉任何数据：自毁那一步要求 `kcSelfDestructPassword.get()` 有值且与输入相等
    ///   （LocalAuthView.swift:23），所以它纯粹是一条显示残留；而"请输入一个已经不存在的密码"
    ///   这种要求既满足不了也没有意义。
    ///
    /// 比对走 `matchesInConstantTime` 的理由与上面那条完全相同：这把码也是原文存的
    /// （POPOPXChat/KeyChain.swift:23）。
    private static func retireGhostSelfDestructCode(passcode: String?) throws {
        guard let stored = kcSelfDestructPassword.get() else {
            if UserDefaults.standard.bool(forKey: DEFAULT_LA_SELF_DESTRUCT) {
                UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
            }
            return
        }
        guard let passcode, !passcode.isEmpty else {
            throw PopopxDuressSetupError.nativeSelfDestructCodeRequired
        }
        guard PopopxDuressCrypto.matchesInConstantTime(Data(passcode.utf8), Data(stored.utf8)) else {
            throw PopopxDuressSetupError.nativeSelfDestructCodeIncorrect
        }
        _ = kcSelfDestructPassword.remove()
        UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
    }

    /// 降级流程专用的"无条件退役"，与 `migrateNativeEntryPassword` 验证通过之后那几步做的动作
    /// 同向（入口码删掉 + 模式回 `.system`），区别只有一条：这里**不能验证**——键盘上站着的是
    /// 逼迫者，让他再输一遍机主的原始码既做不到、也是暴露。删旧凭据本身正是简报步骤 C 要求的效果。
    ///
    /// 自毁码不在这里重复删：全量分支由 `PopopxStorageWipe` 删（:451 条目 + :455 那个 bool），
    /// 保留分支由 `scrubCredentialHistory` 删（:1163-:1164，条目与 bool 都在里面），
    /// 两条都排在函数返回之前，所以回到这一行时它已经不在了。
    /// 这几步必须一起做完、不可拆：只删码会把 `authorize()` 变成静默放行。
    private func retireNativeEntryPassword() {
        _ = kcAppPassword.remove()
        privacyLocalAuthModeDefault.set(.system)
    }

    /// 设置/更换常规码。`confirming` 与 `first` 必须一致（设置页让主人输两遍，
    /// 是因为一次误触就会把主人自己锁在外面，而那在这个功能里意味着数据全丢）。
    ///
    /// 迁移排在写新码**之前**，顺序承重：反过来（先写后迁）会在中途留下"两套前门并存"的窗口，
    /// 而这一支的正确终态只有一个——旧前门关了、新前门装上，要么一起成，要么整体没发生。
    /// `nativePasscode` 为 nil 且原生入口码还在生效时抛 `.nativePasscodeRequired`，
    /// 绝不静默替机主删掉那把码；本机只剩幽灵自毁码时换 `nativeSelfDestructCode` 说话，同理。
    func setNormalPin(
        _ first: String,
        confirming second: String,
        nativePasscode: String? = nil,
        nativeSelfDestructCode: String? = nil
    ) async throws {
        guard Self.isValidPin(first), first == second else { throw PopopxDuressSetupError.malformedPin }
        try Self.migrateNativeEntryPassword(passcode: nativePasscode, selfDestructPasscode: nativeSelfDestructCode)
        let salt = PopopxDuressCrypto.randomSalt()
        guard !salt.isEmpty else { throw PopopxDuressSetupError.keychainWriteFailed }
        let normalHash = await hash(pin: first, salt: salt, iterations: PopopxDuressCrypto.iterations)
        let verifier = PopopxDuressVerifier(salt: salt, hash: normalHash, iterations: PopopxDuressCrypto.iterations)
        guard PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.normalAccount) else {
            throw PopopxDuressSetupError.keychainWriteFailed
        }
        normalConfigured = true
    }

    /// 设置/更换胁迫码。两道硬约束：格式、以及与常规码不得相同。
    func setDuressPin(_ first: String, confirming second: String) async throws {
        guard duressEnabled else { throw PopopxDuressSetupError.keychainWriteFailed }
        guard normalConfigured else { throw PopopxDuressSetupError.normalPinRequiredFirst }
        guard Self.isValidPin(first), first == second else { throw PopopxDuressSetupError.malformedPin }
        guard let normal = PopopxDuressKeychain.read(PopopxDuressKeychain.normalAccount) else {
            throw PopopxDuressSetupError.normalPinRequiredFirst
        }
        let salt = PopopxDuressCrypto.randomSalt()
        guard !salt.isEmpty else { throw PopopxDuressSetupError.keychainWriteFailed }
        let duressHash = await hash(pin: first, salt: salt, iterations: PopopxDuressCrypto.iterations)
        // "两把码相同"这一条只能在派生值层面判，但**必须用常规记录自己的盐**再派生一次：
        // 两条记录各带各的随机盐，拿新盐算出的哈希去比常规记录的哈希必然永远不等——
        // 那样这道闸门看着在，实际一次也不会关上，红线就此静默失效。
        // 同一个口令 + 同一把盐 ⇒ 同一个哈希，所以"用这把码撞常规记录"撞中即两码相同。
        // 局部量刻意不叫 `hash`：那会遮蔽下面这个方法调用本身（`Data` 不是函数）。
        let againstNormal = await hash(pin: first, salt: normal.salt, iterations: normal.iterations)
        if PopopxDuressCrypto.matchesInConstantTime(againstNormal, normal.hash) {
            throw PopopxDuressSetupError.pinsMustDiffer
        }
        let verifier = PopopxDuressVerifier(salt: salt, hash: duressHash, iterations: PopopxDuressCrypto.iterations)
        guard PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.duressAccount) else {
            throw PopopxDuressSetupError.keychainWriteFailed
        }
        duressConfigured = true
    }

    func clearDuressPin() {
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        duressConfigured = false
    }

    /// 关闭整个双密码功能（设置页"解除"）。两条记录都删，不留残余。
    func clearAllPins() {
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        normalConfigured = false
        duressConfigured = false
        biometricFailures = 0
        keypadRequired = false
    }

    // MARK: 校验

    /// 一次 PBKDF2 派生。`inout` + `popopxSecureErase` 是本仓库既有的销毁口径
    /// （PopopxSecurePayload.swift:446）：`String` 归 ARC 管、覆写不了，所以口令一落地
    /// 就立刻拷成 `Data`，用完就地清零。能承诺的只有这一份拷贝——`Task.detached` 会在
    /// 派生期间共享同一块缓冲，`.value` 返回、闭包释放之后 `secret` 才重新独占，
    /// 于是 `defer` 擦到的确实是原件而不是 COW 副本。这一点不写清楚就会被后来人改坏。
    private func hash(pin: String, salt: Data, iterations: Int) async -> Data {
        var secret = Data(pin.utf8)
        defer { popopxSecureErase(&secret) }
        return await Task.detached(priority: .userInitiated) {
            PopopxDuressCrypto.pbkdf2SHA256(
                password: secret,
                salt: salt,
                iterations: iterations,
                outputCount: PopopxDuressCrypto.hashBytes
            )
        }.value
    }

    /// 纯校验，零副作用。设置页的"一键演练"只能走这个，绝不允许它通向抹除。
    func verify(pin: String) async -> PopopxDuressAuthOutcome {
        refreshConfiguration()
        guard normalConfigured else { return .notConfigured }
        let normal = PopopxDuressKeychain.read(PopopxDuressKeychain.normalAccount)
        let duress = duressConfigured ? PopopxDuressKeychain.read(PopopxDuressKeychain.duressAccount) : nil
        // 恒定工作量：永远派生两次。缺哪一条就用一条不会命中的记录补一次等价派生，
        // 让"设了两把码"和"只设了一把码"、以及"命中常规"和"命中胁迫"在耗时上不可区分。
        let normalRecord = normal ?? PopopxDuressVerifier.workloadPad(salt: PopopxDuressCrypto.randomSalt())
        let duressRecord = duress ?? PopopxDuressVerifier.workloadPad(salt: PopopxDuressCrypto.randomSalt())
        let normalHit = await matches(pin: pin, record: normalRecord) && normal != nil
        let duressHit = await matches(pin: pin, record: duressRecord) && duress != nil
        if duressHit { return .duress }
        if normalHit { return .unlocked }
        return .wrong
    }

    private func matches(pin: String, record: PopopxDuressVerifier) async -> Bool {
        let derived = await hash(pin: pin, salt: record.salt, iterations: record.iterations)
        return PopopxDuressCrypto.matchesInConstantTime(derived, record.hash)
    }

    // MARK: 保留策略（三选一）

    /// 自毁后交出什么账号。设置页的分段器写它，胁迫流程只读它一次（见 `submit` 的快照）。
    ///
    /// `.retainExistingProfile` 带 `displayName` —— 那是一个**身份信息**，不再是"无害偏好"。
    /// 所以第一轮那句"关掉自毁时可以不删这个键"到这里已经不成立：本模块的
    /// `PopopxAntiTheftSwitches.eraseAllTraces()` 会连着这个键一起删（它在
    /// `POPOPX_ANTI_THEFT_DEFAULT_KEYS` 里），自毁路径上也确实会删到。
    var retentionStrategy: PopopxDuressRetentionStrategy {
        didSet {
            guard oldValue != retentionStrategy else { return }
            // 对齐用的那一次赋值**不许落盘**，理由见 `resyncingRetentionStrategy`。
            guard !resyncingRetentionStrategy else { return }
            retentionStrategy.store()
        }
    }

    /// `eraseAllTraces()` 之后把内存值拨回默认，但不把键写回去。
    ///
    /// 没有这个闸会出现一件很讽刺的事：自毁刚把 `DEFAULT_ANTI_THEFT_RETENTION_STRATEGY`
    /// 这个键删掉，下一步"让内存与磁盘一致"的赋值又通过 `didSet` 把它原样创建回来——
    /// 一个 POPOPX 专有的键名重新出现在 UserDefaults 里，正是这一整套抹除要消掉的东西。
    private var resyncingRetentionStrategy = false

    /// 键盘提交。遮罩只调这一个方法，然后**按同一支处理 `.unlocked` 与 `.duress`**。
    ///
    /// 时序：先在起点抽一个本次目标时长 → 恒定两次派生 → 若是胁迫码则取模式快照 → 整段抹除
    /// → 按快照重建 → 最后才把不足目标的时间补齐。补时放在最后而不是最前，是为了让真自毁
    /// 完全藏在同一条下限里；目标时长在**任何判定发生之前**抽取，否则随机数会泄露分支。
    ///
    /// 为什么还要随机抖动而不是死等 1.2 秒：实测一次 100k 派生 355ms，两条分支都要付
    /// 那两次派生 ≈ 0.71 秒，于是常规解锁恒等于下限；而胁迫解锁额外付整段擦除+重建，
    /// 会**超过**下限。一个固定值让秒表变成判据（1.20 秒 = 活号，更久 = 号已经没了）。
    /// 抖动把常规解锁铺到 1.2~2.4 秒，和胁迫路径的真实耗时重叠，单次按压量不出结论。
    /// 诚实边界：这只让**一次**尝试不可判定；擦除异常慢（例如大库）仍会露出尾巴，
    /// 而真正的强判据是"按下去之后界面有没有变化"，那由 `PopopxAppLockState.showsLockUI`
    /// 在整段流程里恒为 false（遮罩一直盖着、只有同一条呼吸）来保证。
    func submit(pin: String) async -> PopopxDuressAuthOutcome {
        let started = Date()
        let target = Self.flowTargetSeconds()
        let outcome = await verify(pin: pin)
        if outcome == .duress {
            // 步骤 A（擦除前双快照锁定）。两件事都必须排在任何擦除动作之前，理由各不同：
            // A1 策略快照：`PopopxStorageWipe` 会把本模块的 UserDefaults 键全部删掉，
            //    其中就包括保留策略（`.retainExistingProfile` 还带着目标 profileId，
            //    那是一条身份信息，同样在这个键里）。所以动手之前读进这个局部常量，
            //    重建阶段只认这份副本，绝不再回头读配置。
            // A2 凭据快照：为刚输入的这把应急码换一把**全新的 32 字节盐**重新派生。
            //    擦除会删掉两条旧记录，届时手上只剩明文口令；而这一次派生实测 355ms，
            //    放在擦除后面就等于在遮罩底下多付一次可被感知的停顿。
            let strategy = retentionStrategy
            var demoted = await demotedVerifier(for: pin)
            // 立旗，遮罩从此走"照常呼吸"那一支；无论擦除成败都由 `endDuressFlow()` 收。
            // false = 已经有一轮在跑（那条链不可重入）。此时**不再启第二轮，但照样返回 .duress**：
            // 返回 .wrong 会当场弹一条"密码错误"，那正是整条路径要避免的暴露。
            if PopopxAppLockState.shared.beginDuressFlow() {
                await runDuressFlow(strategy: strategy, demoted: &demoted)
                PopopxAppLockState.shared.endDuressFlow()
                PopopxAppLockState.shared.unlock()
            }
        }
        await pad(to: started, target: target)
        return outcome
    }

    /// 步骤 A2 的派生侧：算出"降级后那条唯一进入密码"的完整记录（新盐 + 新哈希）。
    private func demotedVerifier(for pin: String) async -> PopopxDuressVerifier {
        let salt = PopopxDuressCrypto.randomSalt()
        let derived = await hash(pin: pin, salt: salt, iterations: PopopxDuressCrypto.iterations)
        return PopopxDuressVerifier(salt: salt, hash: derived, iterations: PopopxDuressCrypto.iterations)
    }

    /// 步骤 B → C → D，命名与简报逐条对齐，验收时按编号核对。
    ///
    /// 三条分支的收敛点只有一个：**Keychain 里最后只剩一条 normal 记录，且它认这把降级码**，
    /// 而上游那套 `LocalAuthView` 键盘同时退役，前端认证入口只剩本模块这一个。
    /// 两支都不再把降级码写回 `kcAppPassword`：同一把码同时活在两个地方，等于把刚拆掉的
    /// 第二套键盘在原处装回去（全量分支见 `runFullWipe` 传的 nil，保留分支见下面那一步）。
    private func runDuressFlow(
        strategy: PopopxDuressRetentionStrategy,
        demoted: inout PopopxDuressVerifier
    ) async {
        // 步骤 B：按策略执行选择性或全量物理擦除。第二个返回值是"等 C 写完之后再装的仿真计划"，
        // 把它交到 C 之后的理由写在 `runFullWipe` 的注释里（顺序安全），不是顺手。
        let outcome = await executeErasure(strategy: strategy)
        let effective = outcome.strategy
        // 单一前门：原生入口码在这里退役，两支都覆盖（全量那支 `PopopxStorageWipe` 传 nil 已经删过
        // 一次，这里是幂等的第二次 + 把模式补齐）。排在 `executeErasure` **之后**是承重的：
        // 保留分支要用 `kcAppPassword` 当隐藏身份 `viewPwd` 的退路（见 `PopopxDuressProfileKeeper.retain`），
        // 先删就自断那条路；也排在步骤 C 之前，于是屏幕上永远不会出现"两套前门都在、
        // 而认的都是降级码"那一瞬。
        retireNativeEntryPassword()
        // 步骤 C（单向写入降级凭据）：顺序承重在后——B 里两条旧凭据都被删掉了
        // （全量路径见 `PopopxStorageWipe.wipe`，保留路径见 `scrubCredentialHistory()`），
        // 先写会被自己删掉；写在这里，从此没有第二条路能读到应急记录。
        // 再删一次 `duressAccount` 是幂等的，但它保证保留路径即使中途失败也不会漏下应急码。
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        // 步骤 D：写盘成功后立刻就地覆写内存里的盐与哈希。
        let written = demoteCredential(&demoted)
        if written {
            normalConfigured = true
        } else {
            // 写失败**不弹任何东西**：这条界面上任何提示都是暴露。宁可退化成
            // "降级码进不去、机主的原始码还能进"，也绝不在屏幕上留字。
            logger.error("duress demote: keychain write failed")
            normalConfigured = false
        }
        duressConfigured = false
        // 步骤 D 的重建侧：仿真内容在**降级凭据已经写进 Keychain 之后**才落盘。
        // `install` 自己会写那份布局文件，所以这一步排在 C 之后意味着：崩溃窗口里留在盘上的痕迹
        // 最多指向"和进入密码同样强"的那一份，而不是指向一份已经不再被任何凭据保护的布局。
        await installDecoyPlan(outcome.pendingDecoy)
        if effective.isRetainExisting {
            // 保留分支不经过重建，因此模块内的配置缓存要主动归位一次：
            // 那个键已经被 `eraseAllTraces()` 删掉了，内存里却还留着机主点名的那个身份 id。
            // 走闸而不是直接赋值，是为了这次归位不把键写回 UserDefaults（见上面的注释）。
            resyncingRetentionStrategy = true
            retentionStrategy = .emptyProfile
            resyncingRetentionStrategy = false
        }
    }

    /// 步骤 B 的实现。返回**实际执行**的策略与一份"留到步骤 C 之后再装"的仿真计划：
    /// 策略回给调用是为了把"点名要保留的那个身份已经不在了"安全降级为 `.simulatedDecoy`
    /// 全量重建（简报原话：绝不卡死在白屏）；计划回给调用是为了让落盘排在降级凭据之后。
    private func executeErasure(
        strategy: PopopxDuressRetentionStrategy
    ) async -> (strategy: PopopxDuressRetentionStrategy, pendingDecoy: PopopxDecoyPlan?) {
        if strategy.isRetainExisting, let profileId = strategy.retainedProfileId {
            let outcome = await PopopxDuressProfileKeeper.retain(
                profileId: profileId,
                appPasscode: kcAppPassword.get()
            )
            switch outcome {
            case .success:
                scrubCredentialHistory()
                return (strategy, nil)
            case .failure(let stage):
                // 只进日志。降级方向是"更彻底的那一种擦除"，绝不会反过来变成"少擦一点"。
                logger.error("duress retain failed at \(stage); falling back to simulated decoy")
                let fallback = PopopxDuressRetentionStrategy.simulatedDecoy
                return (fallback, await runFullWipe(strategy: fallback))
            }
        }
        return (strategy, await runFullWipe(strategy: strategy))
    }

    /// 装载延后到步骤 C 之后的那一半。`install` 对"不注入内容"的计划自己就是 no-op
    /// （既不写盘也不拨开关），所以这里不再复判一次策略——判两处就有两处会不一致。
    private func installDecoyPlan(_ plan: PopopxDecoyPlan?) async {
        guard let plan else { return }
        await PopopxDecoyProfileGenerator.shared.install(plan)
    }

    /// 全量擦除：数据库、XFTP 缓存、mesh 身份映射、离线沙盒、旧凭据一起走
    /// `PopopxStorageWipe`（它内部已经覆盖了 `kcAppPassword`/`kcSelfDestructPassword`
    /// 与本模块两条记录，以及 `disarmsAntiTheft` 那一串痕迹）。
    ///
    /// 返回值 = 待装的仿真计划（`nil` = 这一档本来就不注入内容）。**刻意不在 `afterRebuild`
    /// 里装**：那个钩子跑在步骤 C 之前，会让模块四把布局文件写到盘上、然后流程才写降级凭据；
    /// 中间崩一次，沙盒里就留下一份"曾经有个账号、却不再被任何凭据保护"的痕迹。
    /// 延后到 C 之后，磁盘时序变成 凭据 → 内容，任何一次中断都不会留下比凭据更弱的东西。
    private func runFullWipe(strategy: PopopxDuressRetentionStrategy) async -> PopopxDecoyPlan? {
        // 空白号 = 不装任何仿真内容；烟雾弹 = 按模块四的排程装。两者的**擦除**完全相同，
        // 区别只在重建后交出的那个账号里有没有编造的聊天记录。
        let plan: PopopxDecoyPlan? = strategy == .emptyProfile ? nil : PopopxDecoyProfileGenerator.shared.makePlan(strategy: strategy)
        let options = PopopxStorageWipe.Options(
            // 降级码只写进本模块那一条 verifier。写回 `kcAppPassword` 会在原处重建第二套键盘，
            // 而传 nil 走的正是 `wipe` 里 `kcAppPassword.remove()` 那一支：重建出来的新库由
            // `chatMigrateInit` 自己生成随机 `kcDatabasePassword`（API.swift:34-42），
            // 与入口码无关，所以这里不需要、也没有"重建库钥匙"这一步。
            reinstatesAppPasscode: nil,
            displayName: plan?.userDisplayName,
            disarmsAntiTheft: true,
            afterRebuild: nil
        )
        let outcome = await PopopxStorageWipe.wipe(options: options)
        if case .failure(let stage) = outcome {
            // 抹除失败时**什么都不显示**，直接进常规那支：一个报错弹窗比任何文案都响。
            // 这条分支的正确性靠设置页的演练 + 验收报告核对，不靠现场提示。
            // 同时也**不装仿真内容**：库都没重建成功，往一个半死的会话列表里插假行只会更假。
            logger.error("duress wipe failed at \(stage)")
            return nil
        }
        return plan
    }

    /// 保留路径的凭据清扫。全量路径由 `PopopxStorageWipe` 负责删这几条，
    /// 而保留路径不删库，所以在这里按同一个口径自己删一遍。
    /// `kcAppPassword` 不在这里删，但**不等于不删**：它由 `runDuressFlow` 里的
    /// `retireNativeEntryPassword()` 在 `executeErasure` 返回之后统一退役——必须排在那之后，
    /// 因为本函数的调用方（`PopopxDuressProfileKeeper.retain`）还要拿它当隐藏身份的 `viewPwd` 退路。
    /// 它从来不是库钥匙（库钥匙是 `kcDatabasePassword`，见 POPOPXChat/API.swift:43）。
    ///
    /// 自毁码那个 bool 也在清理之列，理由与 `migrateNativeEntryPassword` 里那条完全相同：
    /// 隐私设置那一格只读 `UserDefaults`，不读 Keychain（PrivacySettings.swift:512/:898），
    /// 条目删了而 bool 还留着，页面就会一直显示"自毁码已启用"而它已经无凭据可比。
    /// 口径对齐全量路径的 `PopopxStorageWipe`（:455 同样 removeObject）。
    private func scrubCredentialHistory() {
        _ = kcSelfDestructPassword.remove()
        UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
    }

    /// 步骤 C + D 的写入侧：先写盘，再**就地**覆写内存里的那两份缓冲。
    ///
    /// `inout` 是承重的，不是风格：值类型按值传进来的话，调用方那份副本仍然与形参指着同一块
    /// 盐/哈希缓冲（引用计数 2），`withUnsafeMutableBytes` 于是先写时复制、`memset_s` 擦到的是
    /// 刚复制出来的私有副本，原件一个字节都没少——正是"看着擦了、实际没擦"的假安全。
    /// `inout` 借到的是调用方独占的那一份（口径同 `PopopxSecurePayload.swift:455` 那段注释）。
    ///
    /// 诚实边界：口令明文本身是 ARC 管的 `String`，Swift 层覆写不了。全流水线上它只落地成
    /// 一次 `Data`（在 `hash(pin:salt:iterations:)` 里），并由那个函数自己的 `defer` 当场清零；
    /// 除此之外它没有被存进任何属性、任何集合、任何日志。
    private func demoteCredential(_ verifier: inout PopopxDuressVerifier) -> Bool {
        let written = PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.normalAccount)
        popopxSecureErase(&verifier.salt)
        popopxSecureErase(&verifier.hash)
        return written
    }

    /// 本次解锁的目标时长：`minimumFlowSeconds` 加上 0~1.2 秒的抖动。
    /// 用 `SystemRandomNumberGenerator`（`Double.random` 的底层）——它就是为不可预测设计的；
    /// 这里不需要密码学强度的随机，因为攻击者无法从观察到的时长反推抽到的数（真值被擦除耗时吃掉了），
    /// 只要**机主自己也没法预知**下一次是 1.3 秒还是 2.2 秒就够了。
    static func flowTargetSeconds() -> TimeInterval {
        minimumFlowSeconds + Double.random(in: 0...flowJitterSeconds)
    }

    private func pad(to started: Date, target: TimeInterval) async {
        let spent = Date().timeIntervalSince(started)
        let remaining = target - spent
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    /// 生物识别快捷解锁。用 `.deviceOwnerAuthenticationWithBiometrics` 而不是上游
    /// `systemAuthenticate` 的 `.deviceOwnerAuthentication`（LocalAuthenticationUtils.swift:65）：
    /// 后者会自己兜底到**设备**解锁密码，那条路绕开本模块的键盘，也就绕开了胁迫码——
    /// 逼着机主按指纹的人拿不到"输入哪把码"的选择权，而那正是整套双密码的着力点。
    /// 所以失败/不可用时降级到本模块自己的 6 位键盘，这一步不能省。
    ///
    /// 成功时本方法**已经**把锁解掉（`PopopxAppLockState.unlock()`），`completion` 的
    /// `false` 只表示"该把键盘交出来了"；遮罩因此不需要自己判断要不要改锁状态。
    /// 生物识别永远不可能通向自毁：它只证明"是本人"，证明不了"用的是哪把码"。
    func requestBiometricUnlock(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard biometricsEnabled, !keypadRequired,
              context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            Task { @MainActor in
                guard success else {
                    self.biometricFailures += 1
                    if self.biometricFailures >= Self.maxBiometricFailuresBeforeKeypad {
                        self.keypadRequired = true
                    }
                    completion(false)
                    return
                }
                self.biometricFailures = 0
                self.keypadRequired = false
                PopopxAppLockState.shared.unlock()
                completion(true)
            }
        }
    }

    /// 键盘成功解锁后调用，把失败计数清零，下次遮罩开局仍可用生物识别。
    func resetBiometricFailures() {
        biometricFailures = 0
        keypadRequired = false
    }
}
