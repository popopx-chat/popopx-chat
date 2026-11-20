//
//  PopopxDuressAuthManager.swift
//  POPOPX (iOS)
//
//  【双密码胁迫自毁 · 模块三】两把 6 位码（常规 + 胁迫）、PBKDF2-HMAC-SHA256 校验位、
//  Keychain 只存派生值、Face ID/Touch ID 快捷解锁与连续失败降级、12 词 BIP-39 恢复短语、
//  仿 iOS 原生锁屏的渐进式冷却（含第 10 次可选抹除），以及**全 app 唯一一份**
//  "抹掉存储并重建"的例程 `PopopxStorageWipe`。
//
//  ### 为什么校验位走 PBKDF2，而上游自毁码走明文比对
//  上游把自毁码原文存进 Keychain（`kcSelfDestructPassword`，POPOPXChat/KeyChain.swift:23），
//  校验是 `password == sdPassword`（LocalAuthView.swift:23）。Keychain 本身是加密的，所以这不是
//  一个明显的洞，但它有两个后果：一是拿到密钥链转储（越狱设备 + iKeyDB）就等于拿到码本身，
//  二是没有可加价的余地——想让它变贵只能整个换掉表示方式。本模块按任务要求换成
//  salt + PBKDF2-HMAC-SHA256(100_000)，从此**磁盘上不存在口令**，只有派生值。
//  ⚠️ 这不等于"上游那两个 Keychain 条目消失了"：`kcAppPassword`/`kcSelfDestructPassword`
//  仍是独立的、以原文存储的凭据，仍然被上游的 LA 门使用。`kcSelfDestructPassword` 有四个删除点
//  （`PopopxStorageWipe.wipe`、`scrubCredentialHistory`、`migrateNativeEntryPassword`、
//  `retireGhostSelfDestructCode`）：全量与保留两条自毁路径各一次，迁移那两支各一次。
//  迁移顺带删它的理由是它唯一的输入口
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
//  ### 助记词是本模块唯一一处"明文可恢复"的存储，这是查看功能换来的
//  简报同时要了两件事：「设置页随时查看」与「规范化后经 PBKDF2 派生哈希存入 Keychain」。
//  哈希是单向的，查看不了。所以这里存**两条**记录：`mnemonicAccount` 存派生哈希——重置时
//  唯一参与比对的就是这一条，走常量时间，与两把码完全同构；`mnemonicPhraseAccount` 存规范化后的
//  明文，只为"查看/备份"这一件事存在。明面代价写清楚，不做掩盖：拿到密钥链转储的人能读回短语，
//  而两把码仍然只是哈希。这不是新引入的攻击面——上游的 `kcAppPassword`/`kcSelfDestructPassword`
//  连同存着库钥匙的 `kcDatabasePassword` 全是原文存的（POPOPXChat/KeyChain.swift:21-23），
//  那种转储到手时先输掉的本来就是整个库。补偿三条：查看前必须先过一次身份门
//  （`verifyEntryPin` 或 `verifyIdentityWithBiometrics`，应急码不算通过；同一对门也管着
//  「重新生成一组」那一问）、两条记录都带 `WhenUnlockedThisDeviceOnly`
//  （锁屏即不可读、不随设备备份走）、自毁/重置/解除三条路径都把这两条一起删。
//
//  ### 冷却计数为什么不放 UserDefaults
//  `failedAttemptCount` 与解冻时刻落在 `lockoutAccount` 那一条 Keychain 记录里。存 UserDefaults
//  的话，"杀掉 App 进程重开"就是一次免费的清零——而杀进程重开恰恰是胁迫者最先试的那件事。
//  读不到时**保留内存值**而不是当作零（见 `PopopxDuressKeychain.readLockout`）。
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
//     `termination: nil`（该参数允许 nil，见 PanicWipeManager.swift:474 的注释），并在报告里
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
    /// 正在冷却：`remaining` = 还剩多少秒。**这一支必须在任何派生之前返回**，
    /// 否则"锁定期"里每次按压仍然要付 0.71 秒，界面看起来像还在接受输入。
    case lockedOut(remaining: TimeInterval)
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
    /// 还没生成过助记词，却要查看或用它重置。与"助记词不对"分开是有必要的：前者是
    /// 机主少做了一步设置（该告诉他去做），后者是一次真实的失败（该进冷却计数）。
    case mnemonicMissing
    /// 格式就不对：不是 12 个词、有词不在 BIP-39 表内、或校验和重算不回来。
    /// **这一支不吃冷却计数**，理由是它根本还没进入"比口令"这一步——本地就能判定的
    /// 手滑（把 `watch` 抄成 `wach`）如果也扣一次机会，机主抄错三次就被锁 15 分钟，
    /// 而那个惩罚是给"有人在猜"准备的，不是给"有人在抄"准备的。
    case mnemonicMalformed
    /// 12 个词全部合法，但与存下来的那条对不上。这是一次真实的错误尝试，吃计数。
    case mnemonicIncorrect
    /// 验证进入密码那一道门（`verifyEntryPin`）没交来密码。这道门同时管着「查看助记词」与
    /// 「重新生成一组」两问，所以那句"没交来密码"对两问都成立。
    case entryPinRequired
    /// 验证进入密码那一道门（`verifyEntryPin`）收到的不是当前进入密码（应急码也算错，理由见那条方法）。
    case entryPinIncorrect
    /// Face ID 那一道门（`verifyIdentityWithBiometrics`）没通过：系统判不出可用、开关关着、
    /// 已被降级到键盘，或机主没认出来。这一句同样对「查看」与「重新生成」两问生效。
    /// 四种情况合并成一句，是因为对拿着手机的人来说它们的区别没有意义——词组没有显示、
    /// 词组也没有换掉；而对机主，区分"Face ID 坏了"和"Face ID 没认我"要走的是系统设置那一面，不是这一格。
    case biometricDenied
    /// 冷却期内试图验证：什么都不做，把剩余秒数回给界面。
    case lockedOut(remaining: TimeInterval)

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
        case .mnemonicMissing: return "还没有生成恢复助记词，请先生成并抄存"
        case .mnemonicMalformed: return "助记词需要 12 个标准英文词，请逐字核对后重试"
        case .mnemonicIncorrect: return "助记词不正确"
        case .entryPinRequired: return "请先输入当前进入密码"
        case .entryPinIncorrect: return "进入密码不正确，未显示助记词"
        case .biometricDenied: return "Face ID 未通过，未显示助记词"
        case let .lockedOut(remaining): return "尝试过多，请 \(PopopxLockoutSchedule.phrase(remaining))后再试"
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
        randomBytes(count: saltBytes)
    }

    /// 任意长度的系统随机字节。失败时返回**空 Data**而不是退回时间戳：那会让随机值可预测，
    /// 而可预测的盐与可预测的助记词熵源是同一个错误。调用方必须把空值当作"这次不写盘"。
    static func randomBytes(count: Int) -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 系统随机源失败时**不能**退回时间戳：那会让盐可预测，而这正是盐要解决的问题。
            // 宁可不写入，也不写一个假的安全属性。
            return Data()
        }
        return Data(bytes)
    }
}

// MARK: - BIP-39 助记词

/// 标准 BIP-39 英文词表与 12 词助记词的生成/校验。
///
/// ### 为什么用真词表、真校验和，而不是"随便 12 个英文单词"
/// 简报要的是「12 个标准英文助记词」。标准这件事不是装饰：词表把每个词钉成 11 bit 索引，
/// 12 个词正好是 132 bit = 128 bit 熵 + 4 bit SHA-256 校验和。校验和让"抄错一个词"在
/// **本地**就能被判出来（`validate` 返回 false），而不是等到 PBKDF2 比完才发现整串不对——
/// 后者会把一次手滑也算进锁屏那十次机会里。
///
/// ### 词表来源与可复算性
/// 词表逐字取自 bitcoin/bips 的 `bip-0039/english.txt`，2048 行、字典序、唯一、`[a-z]{3,8}`，
/// 源文件 sha256 = `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`。
/// 下面那段字面量是脚本按 16 词一行切出来的（不是手抄），回读后与源文件逐项相等——
/// 索引 = 词表位置，所以顺序错一个词，整个词的编号就都错了，这条必须可复算。
enum PopopxBIP39 {
    /// 12 词 = 128 bit 熵 + 4 bit 校验和 = 132 bit = 12 × 11 bit。
    static let wordCount = 12
    /// 熵的字节数：128 bit。BIP-39 里 12 词那一档就是这个数，不是"随便取 16 字节"。
    static let entropyBytes = 16

    static let englishWords: [String] = {
        let packed = """
        abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid
        acoustic acquire across act action actor actress actual adapt add addict address adjust admit adult advance
        advice aerobic affair afford afraid again age agent agree ahead aim air airport aisle alarm album
        alcohol alert alien all alley allow almost alone alpha already also alter always amateur amazing among
        amount amused analyst anchor ancient anger angle angry animal ankle announce annual another answer antenna antique
        anxiety any apart apology appear apple approve april arch arctic area arena argue arm armed armor
        army around arrange arrest arrive arrow art artefact artist artwork ask aspect assault asset assist assume
        asthma athlete atom attack attend attitude attract auction audit august aunt author auto autumn average avocado
        avoid awake aware away awesome awful awkward axis baby bachelor bacon badge bag balance balcony ball
        bamboo banana banner bar barely bargain barrel base basic basket battle beach bean beauty because become
        beef before begin behave behind believe below belt bench benefit best betray better between beyond bicycle
        bid bike bind biology bird birth bitter black blade blame blanket blast bleak bless blind blood
        blossom blouse blue blur blush board boat body boil bomb bone bonus book boost border boring
        borrow boss bottom bounce box boy bracket brain brand brass brave bread breeze brick bridge brief
        bright bring brisk broccoli broken bronze broom brother brown brush bubble buddy budget buffalo build bulb
        bulk bullet bundle bunker burden burger burst bus business busy butter buyer buzz cabbage cabin cable
        cactus cage cake call calm camera camp can canal cancel candy cannon canoe canvas canyon capable
        capital captain car carbon card cargo carpet carry cart case cash casino castle casual cat catalog
        catch category cattle caught cause caution cave ceiling celery cement census century cereal certain chair chalk
        champion change chaos chapter charge chase chat cheap check cheese chef cherry chest chicken chief child
        chimney choice choose chronic chuckle chunk churn cigar cinnamon circle citizen city civil claim clap clarify
        claw clay clean clerk clever click client cliff climb clinic clip clock clog close cloth cloud
        clown club clump cluster clutch coach coast coconut code coffee coil coin collect color column combine
        come comfort comic common company concert conduct confirm congress connect consider control convince cook cool copper
        copy coral core corn correct cost cotton couch country couple course cousin cover coyote crack cradle
        craft cram crane crash crater crawl crazy cream credit creek crew cricket crime crisp critic crop
        cross crouch crowd crucial cruel cruise crumble crunch crush cry crystal cube culture cup cupboard curious
        current curtain curve cushion custom cute cycle dad damage damp dance danger daring dash daughter dawn
        day deal debate debris decade december decide decline decorate decrease deer defense define defy degree delay
        deliver demand demise denial dentist deny depart depend deposit depth deputy derive describe desert design desk
        despair destroy detail detect develop device devote diagram dial diamond diary dice diesel diet differ digital
        dignity dilemma dinner dinosaur direct dirt disagree discover disease dish dismiss disorder display distance divert divide
        divorce dizzy doctor document dog doll dolphin domain donate donkey donor door dose double dove draft
        dragon drama drastic draw dream dress drift drill drink drip drive drop drum dry duck dumb
        dune during dust dutch duty dwarf dynamic eager eagle early earn earth easily east easy echo
        ecology economy edge edit educate effort egg eight either elbow elder electric elegant element elephant elevator
        elite else embark embody embrace emerge emotion employ empower empty enable enact end endless endorse enemy
        energy enforce engage engine enhance enjoy enlist enough enrich enroll ensure enter entire entry envelope episode
        equal equip era erase erode erosion error erupt escape essay essence estate eternal ethics evidence evil
        evoke evolve exact example excess exchange excite exclude excuse execute exercise exhaust exhibit exile exist exit
        exotic expand expect expire explain expose express extend extra eye eyebrow fabric face faculty fade faint
        faith fall false fame family famous fan fancy fantasy farm fashion fat fatal father fatigue fault
        favorite feature february federal fee feed feel female fence festival fetch fever few fiber fiction field
        figure file film filter final find fine finger finish fire firm first fiscal fish fit fitness
        fix flag flame flash flat flavor flee flight flip float flock floor flower fluid flush fly
        foam focus fog foil fold follow food foot force forest forget fork fortune forum forward fossil
        foster found fox fragile frame frequent fresh friend fringe frog front frost frown frozen fruit fuel
        fun funny furnace fury future gadget gain galaxy gallery game gap garage garbage garden garlic garment
        gas gasp gate gather gauge gaze general genius genre gentle genuine gesture ghost giant gift giggle
        ginger giraffe girl give glad glance glare glass glide glimpse globe gloom glory glove glow glue
        goat goddess gold good goose gorilla gospel gossip govern gown grab grace grain grant grape grass
        gravity great green grid grief grit grocery group grow grunt guard guess guide guilt guitar gun
        gym habit hair half hammer hamster hand happy harbor hard harsh harvest hat have hawk hazard
        head health heart heavy hedgehog height hello helmet help hen hero hidden high hill hint hip
        hire history hobby hockey hold hole holiday hollow home honey hood hope horn horror horse hospital
        host hotel hour hover hub huge human humble humor hundred hungry hunt hurdle hurry hurt husband
        hybrid ice icon idea identify idle ignore ill illegal illness image imitate immense immune impact impose
        improve impulse inch include income increase index indicate indoor industry infant inflict inform inhale inherit initial
        inject injury inmate inner innocent input inquiry insane insect inside inspire install intact interest into invest
        invite involve iron island isolate issue item ivory jacket jaguar jar jazz jealous jeans jelly jewel
        job join joke journey joy judge juice jump jungle junior junk just kangaroo keen keep ketchup
        key kick kid kidney kind kingdom kiss kit kitchen kite kitten kiwi knee knife knock know
        lab label labor ladder lady lake lamp language laptop large later latin laugh laundry lava law
        lawn lawsuit layer lazy leader leaf learn leave lecture left leg legal legend leisure lemon lend
        length lens leopard lesson letter level liar liberty library license life lift light like limb limit
        link lion liquid list little live lizard load loan lobster local lock logic lonely long loop
        lottery loud lounge love loyal lucky luggage lumber lunar lunch luxury lyrics machine mad magic magnet
        maid mail main major make mammal man manage mandate mango mansion manual maple marble march margin
        marine market marriage mask mass master match material math matrix matter maximum maze meadow mean measure
        meat mechanic medal media melody melt member memory mention menu mercy merge merit merry mesh message
        metal method middle midnight milk million mimic mind minimum minor minute miracle mirror misery miss mistake
        mix mixed mixture mobile model modify mom moment monitor monkey monster month moon moral more morning
        mosquito mother motion motor mountain mouse move movie much muffin mule multiply muscle museum mushroom music
        must mutual myself mystery myth naive name napkin narrow nasty nation nature near neck need negative
        neglect neither nephew nerve nest net network neutral never news next nice night noble noise nominee
        noodle normal north nose notable note nothing notice novel now nuclear number nurse nut oak obey
        object oblige obscure observe obtain obvious occur ocean october odor off offer office often oil okay
        old olive olympic omit once one onion online only open opera opinion oppose option orange orbit
        orchard order ordinary organ orient original orphan ostrich other outdoor outer output outside oval oven over
        own owner oxygen oyster ozone pact paddle page pair palace palm panda panel panic panther paper
        parade parent park parrot party pass patch path patient patrol pattern pause pave payment peace peanut
        pear peasant pelican pen penalty pencil people pepper perfect permit person pet phone photo phrase physical
        piano picnic picture piece pig pigeon pill pilot pink pioneer pipe pistol pitch pizza place planet
        plastic plate play please pledge pluck plug plunge poem poet point polar pole police pond pony
        pool popular portion position possible post potato pottery poverty powder power practice praise predict prefer prepare
        present pretty prevent price pride primary print priority prison private prize problem process produce profit program
        project promote proof property prosper protect proud provide public pudding pull pulp pulse pumpkin punch pupil
        puppy purchase purity purpose purse push put puzzle pyramid quality quantum quarter question quick quit quiz
        quote rabbit raccoon race rack radar radio rail rain raise rally ramp ranch random range rapid
        rare rate rather raven raw razor ready real reason rebel rebuild recall receive recipe record recycle
        reduce reflect reform refuse region regret regular reject relax release relief rely remain remember remind remove
        render renew rent reopen repair repeat replace report require rescue resemble resist resource response result retire
        retreat return reunion reveal review reward rhythm rib ribbon rice rich ride ridge rifle right rigid
        ring riot ripple risk ritual rival river road roast robot robust rocket romance roof rookie room
        rose rotate rough round route royal rubber rude rug rule run runway rural sad saddle sadness
        safe sail salad salmon salon salt salute same sample sand satisfy satoshi sauce sausage save say
        scale scan scare scatter scene scheme school science scissors scorpion scout scrap screen script scrub sea
        search season seat second secret section security seed seek segment select sell seminar senior sense sentence
        series service session settle setup seven shadow shaft shallow share shed shell sheriff shield shift shine
        ship shiver shock shoe shoot shop short shoulder shove shrimp shrug shuffle shy sibling sick side
        siege sight sign silent silk silly silver similar simple since sing siren sister situate six size
        skate sketch ski skill skin skirt skull slab slam sleep slender slice slide slight slim slogan
        slot slow slush small smart smile smoke smooth snack snake snap sniff snow soap soccer social
        sock soda soft solar soldier solid solution solve someone song soon sorry sort soul sound soup
        source south space spare spatial spawn speak special speed spell spend sphere spice spider spike spin
        spirit split spoil sponsor spoon sport spot spray spread spring spy square squeeze squirrel stable stadium
        staff stage stairs stamp stand start state stay steak steel stem step stereo stick still sting
        stock stomach stone stool story stove strategy street strike strong struggle student stuff stumble style subject
        submit subway success such sudden suffer sugar suggest suit summer sun sunny sunset super supply supreme
        sure surface surge surprise surround survey suspect sustain swallow swamp swap swarm swear sweet swift swim
        swing switch sword symbol symptom syrup system table tackle tag tail talent talk tank tape target
        task taste tattoo taxi teach team tell ten tenant tennis tent term test text thank that
        theme then theory there they thing this thought three thrive throw thumb thunder ticket tide tiger
        tilt timber time tiny tip tired tissue title toast tobacco today toddler toe together toilet token
        tomato tomorrow tone tongue tonight tool tooth top topic topple torch tornado tortoise toss total tourist
        toward tower town toy track trade traffic tragic train transfer trap trash travel tray treat tree
        trend trial tribe trick trigger trim trip trophy trouble truck true truly trumpet trust truth try
        tube tuition tumble tuna tunnel turkey turn turtle twelve twenty twice twin twist two type typical
        ugly umbrella unable unaware uncle uncover under undo unfair unfold unhappy uniform unique unit universe unknown
        unlock until unusual unveil update upgrade uphold upon upper upset urban urge usage use used useful
        useless usual utility vacant vacuum vague valid valley valve van vanish vapor various vast vault vehicle
        velvet vendor venture venue verb verify version very vessel veteran viable vibrant vicious victory video view
        village vintage violin virtual virus visa visit visual vital vivid vocal voice void volcano volume vote
        voyage wage wagon wait walk wall walnut want warfare warm warrior wash wasp waste water wave
        way wealth weapon wear weasel weather web wedding weekend weird welcome west wet whale what wheat
        wheel when where whip whisper wide width wife wild will win window wine wing wink winner
        winter wire wisdom wise wish witness wolf woman wonder wood wool word work world worry worth
        wrap wreck wrestle wrist write wrong yard year yellow you young youth zebra zero zone zoo
        """
        return packed.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }()

    /// 规范化：去首尾空白、转小写、任意连续空白收成单个空格。
    /// `lowercased()` 用的是 Unicode 不变量映射（不是 `lowercased(with:)` 那一种），
    /// 所以土耳其语区域下的 `I` 不会被折成 `ı`——那会让一条抄对的助记词永远比不中。
    static func normalize(_ phrase: String) -> String {
        phrase.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedWords(_ phrase: String) -> [String] {
        let normalized = normalize(phrase)
        return normalized.isEmpty ? [] : normalized.components(separatedBy: " ")
    }

    /// 取第 `offset` 个 bit 起的 11 bit，MSB 优先。
    private static func elevenBits(atBit offset: Int, in bytes: [UInt8]) -> Int {
        var value = 0
        for step in 0..<11 {
            let position = offset + step
            let byte = bytes[position / 8]
            let bit = Int((byte >> (7 - position % 8)) & 1)
            value = (value << 1) | bit
        }
        return value
    }

    /// 生成：128 bit 系统随机熵 → 4 bit SHA-256 校验和 → 12 个词。
    /// 熵源失败（返回空）时**不降级**、直接返回 nil，让调用方明确失败。
    static func generate() -> [String]? {
        let entropy = PopopxDuressCrypto.randomBytes(count: entropyBytes)
        guard entropy.count == entropyBytes else { return nil }
        // 摘要先落成 `[UInt8]` 再取首字节：`SHA256Digest` 上的裸 `.first` 会被解析成
        // `first(where:)` 那个函数值（编译器报的是"条件绑定不是可选类型"，两句都指不到字节上），
        // 而数组的 `first` 就是它字面上的意思。SHA-256 恒定 32 字节，这一句实际上不会走 nil。
        let digest = [UInt8](SHA256.hash(data: entropy))
        guard let checksum = digest.first else { return nil }
        var stream = [UInt8](entropy)
        // 校验和只取前 CS(=4) bit，放在下一个字节的**高**四位，读的时候按位读，多余的低四位不会被碰到。
        stream.append(checksum & 0xF0)
        return (0..<wordCount).map { elevenBits(atBit: $0 * 11, in: stream) }.map { englishWords[$0] }
    }

    /// 校验：词数、每个词是否在表内、校验和是否重算得回。三分之一的输入错误都能在这里挡住。
    static func validate(_ words: [String]) -> Bool {
        guard words.count == wordCount else { return false }
        var indices = [Int]()
        indices.reserveCapacity(wordCount)
        for word in words {
            guard let index = englishWords.firstIndex(of: word) else { return false }
            indices.append(index)
        }
        // 12 × 11 bit 回填成 17 字节（最后一字节只有低 4 bit 是校验和，其余留空）。
        var stream = [UInt8](repeating: 0, count: (wordCount * 11 + 7) / 8)
        for (slot, index) in indices.enumerated() {
            for step in 0..<11 {
                let bit = (index >> (10 - step)) & 1
                let position = slot * 11 + step
                if bit & 1 == 1 { stream[position / 8] |= 1 << (7 - position % 8) }
            }
        }
        let entropy = Data(stream.prefix(entropyBytes))
        let expected = [UInt8](SHA256.hash(data: entropy)).first.map { $0 & 0xF0 } ?? 0
        let got = stream[entropyBytes] & 0xF0
        return expected == got
    }

    static func validate(phrase: String) -> Bool {
        validate(normalizedWords(phrase))
    }
}

// MARK: - 渐进式冷却时间表

/// 仿 iOS 原生锁屏的那张冷却表。**纯函数**，好让它能被单测逐格核对。
///
/// 为什么冷却次数与"是不是同一种输入"无关：简报把密码错误与助记词错误并进同一个计数器，
/// 这是对的——胁迫者拿到的是一张表，不两条表；两条表等于告诉他"输 12 个词更划算"。
enum PopopxLockoutSchedule {
    /// 前 4 次只报错、不锁。
    static let freeAttempts = 4
    /// 第 10 次：开关开着就抹数据。
    static let wipeThreshold = 10
    /// 第 8 次以后的默认锁定时长，也是"未开抹除"时第 10 次及以后每次的锁定时长。
    static let finalLockSeconds: TimeInterval = 3_600

    /// 第 5/6/7 次各锁一档，第 8、9 次都锁到上限。
    static func lockoutSeconds(afterAttemptCount count: Int) -> TimeInterval {
        switch count {
        case ..<(freeAttempts + 1): return 0
        case 5: return 60
        case 6: return 300
        case 7: return 900
        default: return finalLockSeconds
        }
    }

    /// 把剩余秒数读成「4 分 59 秒」这一类人话。**三处共用这一个函数**：遮罩中央的倒计时、
    /// `PopopxDuressSetupError.lockedOut` 那句说明、设置页那张递增表。同一个剩余时长在三个
    /// 地方读出三种样子（"300 秒" / "5 分钟" / "05:00"），比统一读得粗一点更糟——
    /// 机主会怀疑这三个数字说的不是同一件事。
    ///
    /// 向上取整：倒计时不许出现「0 秒后再试」这种还在锁着却说已经到点的话。
    static func phrase(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let rest = whole % 60
        if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时" }
        if minutes > 0 { return rest > 0 ? "\(minutes) 分 \(rest) 秒" : "\(minutes) 分钟" }
        return "\(rest) 秒"
    }
}

/// 落进 Keychain 的那一条冷却记录。
///
/// `lockoutEndTimestamp` 是**墙钟**时间戳而不是单调时钟：本条记录的唯一存在理由就是
/// "杀掉进程再打开还在"，而 `DispatchTime` 一出进程就没意义了。诚实边界——机主可以把
/// 系统时间往前调来提前解冻，这一层挡不住；挡得住的是另一半：`failedAttempts` 同样落盘，
/// 所以调完时间接着猜只会一路走到第 10 次那一道。
struct PopopxLockoutRecord: Codable, Equatable {
    var failedAttempts: Int
    var lockoutEndTimestamp: Double?
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
    /// 12 词助记词的派生哈希。与 `normalAccount` **互相独立**：清掉进入码不会连带清掉恢复能力，
    /// 反过来用助记词换一把进入码也不会让这条短语失效（机主纸上抄的那一份继续有效）。
    /// **比对只认这一条**，绝不读 `mnemonicPhraseAccount`——见下面那一条的理由。
    static let mnemonicAccount = "popopx.duress.mnemonic"
    /// 助记词的明文（规范化后的那 12 个词），**只为设置页"查看"存在**。
    /// 文件头「助记词是本模块唯一一处明文可恢复的存储」那一节写了这笔交换的全部内容、
    /// 以及为什么它不比上游已有的原文条目更弱。
    static let mnemonicPhraseAccount = "popopx.duress.mnemonic-phrase"
    /// 冷却记录：连续失败次数 + 解冻时刻。**不**走 `UserDefaults`，理由见 `PopopxLockoutRecord`。
    static let lockoutAccount = "popopx.duress.lockout"

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

    /// 读一条原文（助记词明文用）。与 `read(_:)` 分开而不是复用，是因为后者解的是
    /// `PopopxDuressVerifier` 的 JSON：把明文短语塞进那个类型会让"这一条是哈希"这件事
    /// 在类型上看不出来，而这个区别正是本模块最需要被看见的。
    static func readString(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写一条原文，可访问性与校验位那两条**同一档**（`WhenUnlockedThisDeviceOnly`）：
    /// 这一条装的是可以还原成秘密的明文，把它降档到 `AfterFirstUnlock` 是拿错东西换便宜。
    @discardableResult
    static func writeString(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: 冷却记录

    /// 读冷却记录。**读不到就返回 nil**，由调用方保留内存里的值——把"读失败"当成"没有失败过"
    /// 等于一次 Keychain 抖动就白送爆破者 4 次免费机会，所以这一侧宁可锁着也不放行。
    static func readLockout() -> PopopxLockoutRecord? {
        var query = baseQuery(lockoutAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let record = try? JSONDecoder().decode(PopopxLockoutRecord.self, from: data)
        else { return nil }
        return record
    }

    /// 写冷却记录，走"先改后加"：先清后加会让任何一次写入失败都变成**把旧记录一起删掉**，
    /// 而这一条记的是"这个人已经猜错了几次"——抹掉它等于送还那几次机会。
    ///
    /// 用的可访问性是 `AfterFirstUnlock`，**与三条凭据故意不同**：那三条只在用户正在输入时
    /// 才被读，解锁前读不到毫无影响；这一条是倒计时本身，App 被挂起后重新拉起时
    /// （界面此刻可能还没解锁）必须还能把"还剩几分钟"读出来，否则
    /// `errSecInteractionNotAllowed` 会让一次 60 分钟的冷却看起来像已经结束。
    /// 它不含任何凭据，只有次数与时刻。
    static func writeLockout(_ record: PopopxLockoutRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let query = baseQuery(lockoutAccount)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            logger.error("duress lockout: keychain update failed \(status)")
            return false
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return true }
        logger.error("duress lockout: keychain add failed \(added)")
        return false
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
/// 7. 删所有口令类 Keychain 条目（上游两条 + 本模块五条：两把码、助记词的哈希与明文、
///    冷却记录）。助记词那两条必须和码一起死：抹除的承诺是"这台设备上再也没有可恢复的身份"，
///    留一张能重置出进入密码的备份 = 承诺当场作废；冷却记录同理，它本身就是"这里启用过
///    防爆破"的指纹。
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
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
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
/// `termination` 是 `Self.processExit`（PanicWipeManager.swift:437/482），会 `exit(0)`。
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

    /// 连续失败次数。进入码与助记词**共用这一张表**（简报原话），两条表等于告诉来人
    /// "输 12 个词更划算"。落 Keychain 的 `lockoutAccount`，这里是它的内存副本，理由写在
    /// 文件头「冷却计数为什么不放 UserDefaults」那一节。
    private(set) var failedAttemptCount = 0

    /// 解冻时刻。nil = 当前不在冷却（也包括"错 1~4 次"那一档：只报错，不上锁）。
    private(set) var lockoutEndsAt: Date?

    /// 助记词是否可用 = **两条记录都在**。半新一旧（哈希认 A、查看显示 B）比没有更糟：
    /// 设置页会显示一条永远通不过重置的短语，而机主手上那张纸已经作废了。
    private(set) var mnemonicConfigured = false

    /// 剩余冷却秒数。只用 `Date` 与一个存下来的时刻做减法，所以遮罩那条每秒一跳的计时器
    /// 可以直接调它，不需要谁去"刷新"它。
    var lockoutRemainingSeconds: TimeInterval {
        lockoutEndsAt.map { max(0, $0.timeIntervalSinceNow) } ?? 0
    }

    var isLockedOut: Bool { lockoutRemainingSeconds > 0 }

    /// 距离第 10 次还剩几次，给设置页那格红色警戒用。**它是算出来的**，不是另一个计数：
    /// 多一个状态就多一处会和 `failedAttemptCount` 说假话的地方。
    var strikesUntilWipe: Int {
        max(0, PopopxLockoutSchedule.wipeThreshold - failedAttemptCount)
    }

    /// 第 10 次连续错误是否抹数据。默认关闭，且必须由机主在设置页明确打开：这一条把
    /// "猜错十次"的代价从"锁一小时"换成"这台设备上的身份没了"，而误触的代价（家人乱按键盘、
    /// 自己抄错助记词）必须由一次明确的、看得见说明的动作来承担。
    var wipeOnTenthFailure: Bool {
        didSet {
            guard oldValue != wipeOnTenthFailure, !resyncingTenStrikeSwitch else { return }
            UserDefaults.standard.set(wipeOnTenthFailure, forKey: DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE)
        }
    }

    /// 与 `resyncingRetentionStrategy` 同一个理由、同一副闸：`eraseAllTraces()` 刚把这个键删掉，
    /// 紧接着"让内存归位"的那一次赋值如果不走闸，就会亲手把键重新创建出来——
    /// 抹除要消掉的痕迹由抹除流程自己写回去。
    private var resyncingTenStrikeSwitch = false

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
    /// `!isLockedOut` 是简报那条硬要求（冷却期内 Face ID 不许弹）在这里的第一次落点；
    /// `requestBiometricUnlock` 里还有第二道，因为调用方可能自己拼条件。
    var prefersBiometricUnlock: Bool {
        biometricsEnabled && !keypadRequired && !isLockedOut && biometricsAvailable && normalConfigured
    }

    private init() {
        let defaults = UserDefaults.standard
        duressEnabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED)
        biometricsEnabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED)
        // 这一条不玩"读不到就当真开着"：抹数据是把十次误触变成不可逆动作的那一档，
        // 键不存在时只能是 false。
        wipeOnTenthFailure = defaults.bool(forKey: DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE)
        retentionStrategy = PopopxDuressRetentionStrategy.load(from: defaults)
        // 凭据、助记词、冷却三条状态都由同一处读盘（`didSet` 已经在上面把三个开关属性
        // 初始化完了，这里不会再触发写回）。
        refreshConfiguration()
    }

    /// Keychain 会在别的进程/别的会话里被改动（自毁就是这种改动），所以每次进入遮罩
    /// 与设置页时重新读一遍真实状态，而不是相信内存里那份缓存。
    @MainActor
    func refreshConfiguration() {
        normalConfigured = PopopxDuressKeychain.exists(PopopxDuressKeychain.normalAccount)
        duressConfigured = duressEnabled && PopopxDuressKeychain.exists(PopopxDuressKeychain.duressAccount)
        mnemonicConfigured = PopopxDuressKeychain.read(PopopxDuressKeychain.mnemonicAccount) != nil
            && PopopxDuressKeychain.readString(PopopxDuressKeychain.mnemonicPhraseAccount) != nil
        // 冷却记录**只在读到时才覆盖内存**。读失败与"确实没有这条记录"在 Keychain 层是同一个
        // nil，而猜错的代价不对称：当成"没有失败过"等于白送 4 次免费机会，
        // 当成"还在冷却"最多是让机主多等一次他已经等过的时间。所以宁可锁着。
        if let record = PopopxDuressKeychain.readLockout() {
            failedAttemptCount = record.failedAttempts
            lockoutEndsAt = record.lockoutEndTimestamp.map { Date(timeIntervalSince1970: $0) }
        }
    }

    // MARK: 配置

    static func isValidPin(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { digits.contains($0) }
    }

    // MARK: 原生入口码迁移（前端认证入口只留一个）

    /// 上游那把"入口密码"与本模块的双密码锁是并列的两套前门：`authenticate(reason:)`
    /// （LocalAuthenticationUtils.swift:40）在 `privacyLocalAuthModeDefault == .passcode` 时
    /// 把键盘挂成 `LocalAuthView`（ContentView.swift:97、ChatListView.swift:133），而
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
    /// `.system` 是上游的出厂默认（Shared/Views/UserSettings/SettingsView.swift:224，
    /// 与本页同名的另一个文件），也是它自己在 biometric
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
    /// 自毁码不在这里重复删：全量分支由 `PopopxStorageWipe` 删（:870 条目 + :877 那个 bool），
    /// 保留分支由 `scrubCredentialHistory` 删（:1989-:1990，条目与 bool 都在里面），
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
    ///
    /// 返回值 = 简报要求的"设置进入密码时一并生成 12 词助记词"那一份新短语，
    /// 交给设置页显示一次让机主抄存；**nil 有两种意思**，调用方用 `mnemonicConfigured` 分辨：
    /// 已经有一条（绝不覆盖——机主手上那张纸抄的是旧的，静默换一份等于让他的备份在他不知情
    /// 的情况下作废），或者这一次随机源/写盘失败（他去助记词卡片自己按"生成"）。
    /// 这里不额外抛错：进入码已经写成功了，为一个辅助恢复手段回滚主凭据是更坏的结果。
    @discardableResult
    func setNormalPin(
        _ first: String,
        confirming second: String,
        nativePasscode: String? = nil,
        nativeSelfDestructCode: String? = nil
    ) async throws -> [String]? {
        guard Self.isValidPin(first), first == second else { throw PopopxDuressSetupError.malformedPin }
        try Self.migrateNativeEntryPassword(passcode: nativePasscode, selfDestructPasscode: nativeSelfDestructCode)
        let salt = PopopxDuressCrypto.randomSalt()
        guard !salt.isEmpty else { throw PopopxDuressSetupError.keychainWriteFailed }
        let normalHash = await derive(secret: first, salt: salt, iterations: PopopxDuressCrypto.iterations)
        let verifier = PopopxDuressVerifier(salt: salt, hash: normalHash, iterations: PopopxDuressCrypto.iterations)
        guard PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.normalAccount) else {
            throw PopopxDuressSetupError.keychainWriteFailed
        }
        normalConfigured = true
        guard !mnemonicConfigured else { return nil }
        return await generateMnemonic()
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
        let duressHash = await derive(secret: first, salt: salt, iterations: PopopxDuressCrypto.iterations)
        // "两把码相同"这一条只能在派生值层面判，但**必须用常规记录自己的盐**再派生一次：
        // 两条记录各带各的随机盐，拿新盐算出的哈希去比常规记录的哈希必然永远不等——
        // 那样这道闸门看着在，实际一次也不会关上，红线就此静默失效。
        // 同一个口令 + 同一把盐 ⇒ 同一个哈希，所以"用这把码撞常规记录"撞中即两码相同。
        // 局部量刻意不叫 `hash`：那会遮蔽下面这个方法调用本身（`Data` 不是函数）。
        let againstNormal = await derive(secret: first, salt: normal.salt, iterations: normal.iterations)
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

    /// 关闭整个双密码功能（设置页"解除"）。两条码、助记词的一对记录、冷却记录全删，不留残余：
    /// 机主已经明确不要这套锁了，而"功能已关但那张纸还能重置出一个进入密码"是比留着码
    /// 更糟的状态——它会凭空造出一把没人设置过的进入密码。
    func clearAllPins() {
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
        normalConfigured = false
        duressConfigured = false
        mnemonicConfigured = false
        failedAttemptCount = 0
        lockoutEndsAt = nil
        biometricFailures = 0
        keypadRequired = false
    }

    // MARK: 助记词（12 词 BIP-39 恢复）

    /// 生成一组新的 12 词助记词、落盘，并把明文词组返回给界面显示一次让机主抄存。
    ///
    /// 熵来自 `SecRandomCopyBytes`，校验和位按 BIP-39 由 SHA-256 算出，所以这一条短语是
    /// **标准钱包格式**：机主将来可以拿任何 BIP-39 工具核对自己抄没抄对，不必信任本 app 的显示。
    ///
    /// 已有旧词组时覆盖。`storeMnemonic` 任一半失败就整对回滚，因此"重新生成"要么整套换掉、
    /// 要么仍是旧的，不会留下"哈希认 A、查看显示 B"这种 `mnemonicConfigured` 报真却永远
    /// 重置不通过的半成品。
    @discardableResult
    func generateMnemonic() async -> [String]? {
        guard let words = PopopxBIP39.generate() else { return nil }
        return await storeMnemonic(words) ? words : nil
    }

    /// 把一组词同时写成"派生校验记录"与"可回看明文"两条。
    ///
    /// 写之前先 `validate` 一次自己的生成结果：这不是防御用户输入，而是防御词表与位切分
    /// 在后来被改坏——一份校验和算错的助记词一旦落盘，机主手上那张纸就成了打不开的备份，
    /// 而且**没人会知道**，直到他真的忘记密码那天。宁可这里返回 nil。
    private func storeMnemonic(_ words: [String]) async -> Bool {
        let phrase = PopopxBIP39.normalize(words.joined(separator: " "))
        let salt = PopopxDuressCrypto.randomSalt()
        guard PopopxBIP39.validate(phrase: phrase), !salt.isEmpty else {
            logger.error("duress mnemonic: generated phrase failed self-validation, nothing stored")
            return false
        }
        let hash = await derive(secret: phrase, salt: salt, iterations: PopopxDuressCrypto.iterations)
        let verifier = PopopxDuressVerifier(salt: salt, hash: hash, iterations: PopopxDuressCrypto.iterations)
        guard
            PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.mnemonicAccount),
            PopopxDuressKeychain.writeString(phrase, account: PopopxDuressKeychain.mnemonicPhraseAccount)
        else {
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
            mnemonicConfigured = false
            logger.error("duress mnemonic: store failed, pair rolled back")
            return false
        }
        mnemonicConfigured = true
        return true
    }

    /// 第一道门：只证明"当场知道当前进入密码"，不交出任何东西。
    ///
    /// 这一半同时是「查看助记词」与「重新生成一组」那两问的门——同一件事不许有两套放行条件，
    /// 所以两处都调这里，而不是各写一遍比对。三条刻意的取舍：
    /// 1. 只与常规记录比对。应急擦除密码是另一条条目，拿它派生必然比不中 →
    ///    `.entryPinIncorrect`、什么都不发生。这不是漏了一条路：交出胁迫码的人换来的是
    ///    "当场自毁"，不该再多赚一份可读的备份或一次改词组的权利。
    /// 2. **不吃冷却计数**（不调 `settleWrongAttempt`）。键盘是胁迫者手上唯一的门，所以那
    ///    张表长在那里；设置页这两格如果也接上去，等于给了来人第二个可以尝试的入口、
    ///    也给机主一个"抄错三遍就被锁 60 分钟"的拒服务把手。这里失败的代价已经够明确：
    ///    什么都不发生。
    /// 3. 比对走同一个 `matches(pin:record:)`，同 100_000 轮、同样恒定时间，所以
    ///    "看一次助记词"与"解一次锁"耗时一致，秒表量不出这里发生过一次查看或一次重新生成。
    ///
    /// 常规记录不在了 = 没有任何"当前进入密码"可供比对。真出现这种状态（手动清过
    /// Keychain、或 `clearAllPins` 与一次落盘的助记词交错）时当作没通过，
    /// 而不是"没有密码就免验"——这一格的放行条件必须是证明机主知道进入密码。
    func verifyEntryPin(_ pin: String) async throws {
        guard Self.isValidPin(pin) else { throw PopopxDuressSetupError.entryPinRequired }
        guard let normal = PopopxDuressKeychain.read(PopopxDuressKeychain.normalAccount) else {
            throw PopopxDuressSetupError.entryPinRequired
        }
        guard await matches(pin: pin, record: normal) else {
            throw PopopxDuressSetupError.entryPinIncorrect
        }
    }

    /// 查看助记词：先用**当前进入密码**换出明文词组。
    /// 证明本身在 `verifyEntryPin(_:)`，那里的三条取舍一条不改地适用于这里。
    func revealMnemonic(unlockingWith pin: String) async throws -> [String] {
        refreshConfiguration()
        guard mnemonicConfigured else { throw PopopxDuressSetupError.mnemonicMissing }
        try await verifyEntryPin(pin)
        return try readRevealedMnemonic()
    }

    /// 第二道门：只证明"Face ID 当场认出了机主本人"，不交出任何东西。
    ///
    /// 「用 Face ID 查看」与「用 Face ID 验证并重新生成」共用这一半，所以两问得到的必须是
    /// 同一个判断，而不是"看词组那一问严一点、改词组这一问松一点"。
    ///
    /// 三道前置门一律**关而不放**：总开关关着、刚被"连续失败两次"降级到键盘、系统判不出可用，
    /// 全部直接抛错。这是与上游 `authorize()` 相反的选择（它对 `.unavailable` 直接放行，
    /// 见 LocalAuthenticationUtils.swift:20-24）：那一层管的是"设备解锁的便利性"，
    /// 而这两问交出去的是一张能重置进入密码的明文、以及作废那张纸的权利，
    /// 问不出结果时只能当作没通过。
    ///
    /// 冷却表故意不在这里问：那张表拦的是锁屏遮罩上的三个输入口，而这两问不吃失败计数
    /// （理由写在设置页那一格的说明里），也就没有可归零的东西。
    ///
    /// 也故意**不**复用 `requestBiometricUnlock`：那一条路成功时顺手 `unlock()` 遮罩并清计数，
    /// 把"看一眼词组"变成"解一次锁"，是完全不同的两件事。
    func verifyIdentityWithBiometrics(reason: String) async throws {
        guard biometricsEnabled, !keypadRequired, biometricsAvailable else {
            throw PopopxDuressSetupError.biometricDenied
        }
        let context = LAContext()
        let granted = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in
                resume.resume(returning: ok)
            }
        }
        guard granted else { throw PopopxDuressSetupError.biometricDenied }
    }

    /// 「用 Face ID 查看」那一条路（简报原文："查看前需验证当前进入密码**或 FaceID**"）。
    /// 证明方式换成 `verifyIdentityWithBiometrics(reason:)`，其余与 `revealMnemonic(unlockingWith:)`
    /// 逐字相同——要交出去的是同一份东西，两道门的收尾不许有差别。
    func revealMnemonicWithBiometrics(reason: String) async throws -> [String] {
        refreshConfiguration()
        guard mnemonicConfigured else { throw PopopxDuressSetupError.mnemonicMissing }
        try await verifyIdentityWithBiometrics(reason: reason)
        return try readRevealedMnemonic()
    }

    /// 词组读回来那一半，两条证明路径共用。Keychain 里那条明文必须仍然过得了 BIP-39 的
    /// 结构校验，否则宁可说"没有助记词"——把一串坏字节显示成"你的 12 个词"，
    /// 机主会照着一张坏纸去重置，然后在下一道门前彻底进不去。
    private func readRevealedMnemonic() throws -> [String] {
        guard
            let stored = PopopxDuressKeychain.readString(PopopxDuressKeychain.mnemonicPhraseAccount),
            PopopxBIP39.validate(phrase: stored)
        else {
            throw PopopxDuressSetupError.mnemonicMissing
        }
        return PopopxBIP39.normalizedWords(stored)
    }

    /// 只做结构校验（12 个词、都在表内、校验和重算得回），不碰 Keychain、不派生、不计失败。
    ///
    /// 给输入过程中的"要不要禁用提交按钮"用。派生一次 355 ms，每改一个字符跑一次既慢，
    /// 又会把"前几个词已经对了"这种信息在真正校验之前泄漏成耗时差。
    func verifyMnemonic(_ phrase: String) -> Bool {
        PopopxBIP39.validate(phrase: phrase)
    }

    /// 用助记词重置进入密码：校验词组 → 写入新进入密码 → **应急擦除密码置为未设置** →
    /// 冷却计数清零。
    ///
    /// 与键盘共用同一条 `settleWrongAttempt`，这是简报"同一张表同时适用于密码错误与
    /// 助记词错误"的落点；但只有**结构合法而派生不匹配**才计次，把 `watch` 抄成 `wach`
    /// 走 `.mnemonicMalformed` 直接抛（见那条 case 上的理由）。
    ///
    /// 重置**不消耗**助记词：成功后这条词组仍可用来做下一次重置。机主刚丢过一次密码，
    /// 此时让唯一的备份失效只会把他第二次关在门外；要"用后即焚"就自己按"重新生成"。
    ///
    /// 应急擦除密码必定被删，**与它原来设没设无关**——"重置后自毁码归零"这句断言的落点。
    /// 真机验收：先设好自毁码 → 用助记词重置 → 再拿重置前那把自毁码去解锁，
    /// 应当得到一次普通失败（计数 +1），而不是静默自毁。
    func resetEntryPinWithMnemonic(
        phrase: String,
        newPin: String,
        confirmingPin: String
    ) async throws {
        refreshConfiguration()
        guard !isLockedOut else {
            throw PopopxDuressSetupError.lockedOut(remaining: lockoutRemainingSeconds)
        }
        guard mnemonicConfigured else { throw PopopxDuressSetupError.mnemonicMissing }
        let normalized = PopopxBIP39.normalize(phrase)
        guard PopopxBIP39.validate(phrase: normalized) else {
            throw PopopxDuressSetupError.mnemonicMalformed
        }
        guard Self.isValidPin(newPin), newPin == confirmingPin else {
            throw PopopxDuressSetupError.malformedPin
        }
        guard let record = PopopxDuressKeychain.read(PopopxDuressKeychain.mnemonicAccount) else {
            throw PopopxDuressSetupError.mnemonicMissing
        }
        guard await matches(pin: normalized, record: record) else {
            // 一次真实的猜测。返回值在这里没用：这条路径的界面已经切到重置表单，
            // 冷却由 `isLockedOut` / `lockoutRemainingSeconds` 把状态带回去。
            _ = await settleWrongAttempt()
            throw PopopxDuressSetupError.mnemonicIncorrect
        }
        let salt = PopopxDuressCrypto.randomSalt()
        guard !salt.isEmpty else { throw PopopxDuressSetupError.keychainWriteFailed }
        let pinHash = await derive(secret: newPin, salt: salt, iterations: PopopxDuressCrypto.iterations)
        guard PopopxDuressKeychain.write(
            PopopxDuressVerifier(salt: salt, hash: pinHash, iterations: PopopxDuressCrypto.iterations),
            account: PopopxDuressKeychain.normalAccount
        ) else {
            throw PopopxDuressSetupError.keychainWriteFailed
        }
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        normalConfigured = true
        duressConfigured = false
        clearFailures()
    }

    // MARK: 校验

    /// 一次 PBKDF2 派生。参数叫 `secret` 而不是 `pin`：进这一行的有两种秘密——6 位数字，
    /// 以及规范化后的 12 词短语。派生口径完全相同（同 100_000 轮、同 32 字节输出），
    /// 所以助记词的比对与两把码的比对一样贵、一样常量时间。
    ///
    /// `popopxSecureErase` 是本仓库既有的销毁口径（PopopxSecurePayload.swift:446）：
    /// `String` 归 ARC 管、覆写不了，所以秘密一落地就立刻拷成 `Data`，用完就地清零。
    /// 能承诺的只有这一份拷贝——`Task.detached` 会在派生期间共享同一块缓冲，
    /// `.value` 返回、闭包释放之后 `bytes` 才重新独占，于是 `defer` 擦到的确实是原件而不是
    /// COW 副本。这一点不写清楚就会被后来人改坏。
    private func derive(secret: String, salt: Data, iterations: Int) async -> Data {
        var bytes = Data(secret.utf8)
        defer { popopxSecureErase(&bytes) }
        return await Task.detached(priority: .userInitiated) {
            PopopxDuressCrypto.pbkdf2SHA256(
                password: bytes,
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
        let derived = await derive(secret: pin, salt: record.salt, iterations: record.iterations)
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

    /// 键盘提交。遮罩只调这一个方法，然后**按同一支处理 `.unlocked`、`.duress` 与 `.lockedOut`
    /// 之外的所有结论**——冷却那一支也只渲染倒计时，不弹"错误"。
    ///
    /// 时序：先查冷却（**排在任何派生之前**）→ 抽本次目标时长 → 恒定两次派生 → 按结论分支
    /// （胁迫命中 → 双快照 + 整段抹除重建；错误 → 计数与冷却；第 10 次且开关开着 → 静默抹除）
    /// → 最后才把不足目标的时间补齐。补时放在最后而不是最前，是为了让真自毁
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
        refreshConfiguration()
        // 冷却期内一次派生都不付。这不是省 CPU：付掉那 0.71 秒的界面看起来仍在"核验"，
        // 而它其实什么都不会放行——简报要的是键盘、Face ID、助记词三个入口一起禁用。
        guard !isLockedOut else { return .lockedOut(remaining: lockoutRemainingSeconds) }
        let started = Date()
        let target = Self.flowTargetSeconds()
        var outcome = await verify(pin: pin)
        switch outcome {
        case .unlocked:
            // 「任意一次正确验证成功后，立即清零 failedAttemptCount」。
            clearFailures()
        case .duress:
            clearFailures()
            await runDuressUnlock(pin: pin)
        case .wrong:
            outcome = await settleWrongAttempt()
        case .notConfigured:
            break
        case .lockedOut:
            // `verify` 永远不返回这一支（它是纯校验），只为穷尽 switch 留个诚实的落点。
            break
        }
        await pad(to: started, target: target)
        return outcome
    }

    /// 命中应急码时的那一条静默流水线（简报步骤 A → B → C → D）。
    /// 从 `submit` 里拆出来只为了让 `submit` 的分支形状一眼可核；顺序、快照、立旗全部保持原样。
    private func runDuressUnlock(pin: String) async {
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
        // false = 已经有一轮在跑（那条链不可重入）。此时**不再启第二轮，但结论仍是 .duress**：
        // 改成 `.wrong` 会当场弹一条"密码错误"，那正是整条路径要避免的暴露。
        guard PopopxAppLockState.shared.beginDuressFlow() else { return }
        await runDuressFlow(strategy: strategy, demoted: &demoted)
        PopopxAppLockState.shared.endDuressFlow()
        PopopxAppLockState.shared.unlock()
    }

    /// 步骤 A2 的派生侧：算出"降级后那条唯一进入密码"的完整记录（新盐 + 新哈希）。
    private func demotedVerifier(for pin: String) async -> PopopxDuressVerifier {
        let salt = PopopxDuressCrypto.randomSalt()
        let derived = await derive(secret: pin, salt: salt, iterations: PopopxDuressCrypto.iterations)
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
        resyncErasedSwitches()
    }

    /// 抹除之后把"内存里还留着、盘上已被 `eraseAllTraces()` 删掉"的那两项归位：
    /// 助记词状态与第 10 次开关。两条分支都覆盖（全量那支经 `disarmsAntiTheft`、保留那支经
    /// `PopopxDuressProfileKeeper.retain` 第 4 步，两处都调了同一个清扫）。
    ///
    /// 开关那一项**走闸赋值**，理由与 `resyncingRetentionStrategy` 一字不差：不归位则设置页
    /// 继续显示"已开启"（而键已经没了，下次冷启动就变回关闭——同一台设备对同一件事说两种话），
    /// 归位时不走闸则亲手把刚删掉的键创建回来。
    ///
    /// 助记词两条记录本身由擦除删（全量见 `PopopxStorageWipe` 第 7 步，保留见
    /// `scrubCredentialHistory`），这里只把内存状态拨平。恢复能力跟着身份一起没了是**故意的**：
    /// 一个 `popopx.duress.mnemonic` 条目本身就是"这台设备装过防盗双密码"的指纹。
    /// 代价写清楚：降级码从此没有离线恢复手段，忘了就只能再自毁一次；机主要恢复能力，
    /// 得在设置页重新生成一条并重新抄存。
    private func resyncErasedSwitches() {
        mnemonicConfigured = false
        resyncingTenStrikeSwitch = true
        wipeOnTenthFailure = false
        resyncingTenStrikeSwitch = false
    }

    /// 第 10 次连续错误 + 开关开着：跑**与应急码那条完全相同**的擦除与重建流水线
    /// （B → 退役原生入口码 → 装仿真内容 → 归位），只有一步不同：**不做步骤 C 的凭据降级**。
    ///
    /// 那一步的输入是"刚被证明正确的那把码"，而这里刚刚被证明的是"这把码不对"。降级下去
    /// 等于把来人猜错的第 10 次输入升格成设备的唯一进入密码——那是本模块最不该发生的一件事。
    /// 于是终态是"双密码未设置"：抹完之后交出一个刚装好的空 app，连那台键盘都不再出现
    /// （`PopopxAppLockOverlayModel.begin()` 走 `normalConfigured == false` 那一支）。
    /// 这一条与简报「与应急擦除密码完全相同的自毁与重建流程」的差别是刻意的，已写进验收报告。
    private func runTenStrikeWipe() async {
        let strategy = retentionStrategy
        let outcome = await executeErasure(strategy: strategy)
        retireNativeEntryPassword()
        // 凭据在这里再删一次：全量分支的 `PopopxStorageWipe` 与保留分支的
        // `scrubCredentialHistory` 都已经删过，这一对是幂等的第三次，但它保证"擦除中途失败"
        // 也不会漏下一条还能进门的凭据——这一次连降级码都没有，留着旧凭据等于留着真身份。
        // 助记词那一对算在同一个"还能进门"的集合里：那张纸能重置出进入密码，
        // 所以它和两把码一样必须在这里第三次落掉。冷却记录不在这列——它由下面的
        // `clearFailures()` 负责，那里同时把内存里的 `lockoutEndsAt` 一起归零。
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
        normalConfigured = false
        duressConfigured = false
        // 计数器与冷却一起清：设备已经空了，"你已经猜错 10 次"这件事不再有保护对象，
        // 而留着它会让下一次锁屏直接弹一小时倒计时（那是给机主看的假警报）。
        clearFailures()
        await installDecoyPlan(outcome.pendingDecoy)
        if outcome.strategy.isRetainExisting {
            resyncingRetentionStrategy = true
            retentionStrategy = .emptyProfile
            resyncingRetentionStrategy = false
        }
        resyncErasedSwitches()
    }

    // MARK: 渐进式冷却（仿 iOS 原生锁屏）

    /// 一次错误验证的结算：计数 +1、按表上锁，第 10 次在开关开着时改走静默抹除。
    ///
    /// 键盘那条路（`submit`）拿返回值当本次结论；助记词那条路（`resetEntryPinWithMnemonic`）
    /// 忽略返回值、只管往外抛错——它那边界面已经切到重置表单，冷却由 `isLockedOut` 与
    /// `lockoutRemainingSeconds` 两个只读属性把状态带回去。两条路共用同一个结算，
    /// 于是"同一张表"这件事在代码里只有一处实现。
    @discardableResult
    private func settleWrongAttempt() async -> PopopxDuressAuthOutcome {
        let strikes = registerFailure()
        guard strikes >= PopopxLockoutSchedule.wipeThreshold, wipeOnTenthFailure else {
            return isLockedOut ? .lockedOut(remaining: lockoutRemainingSeconds) : .wrong
        }
        guard PopopxAppLockState.shared.beginDuressFlow() else {
            // 已经有一轮在跑：不启第二轮，也不回 `.wrong`（那会在自毁进行中的遮罩上
            // 弹一条"密码错误"，而这条界面的任何异常反馈都是暴露）。回 `.duress` 让 UI
            // 继续走"照常呼吸"那一支，与 `runDuressUnlock` 的不可重入完全同构。
            return .duress
        }
        await runTenStrikeWipe()
        // 计数与冷却一起归零。三条理由叠在这一句上：
        // 1. 简报要求这条路「与应急擦除密码完全相同的自毁与重建流程」——命中应急码那一支
        //    在 `submit` 里就是 `clearFailures()` 先行，不清就不叫完全相同。
        // 2. 抹除之后常规码记录已经不存在（`PopopxStorageWipe` 第 7 步连着它一起删），
        //    这道表已经没有要保护的东西；留着它只会让遮罩在一台"根本没有密码"的设备上
        //    显示一小时倒计时，而那是机主最难自证的一格。
        // 3. 盘上那条记录已经被抹除删掉了，内存这一份若不清就成了只有本次会话知道的
        //    幽灵状态——重启即消失，与"防爆破挡得住杀进程重开"这句承诺正好相反。
        clearFailures()
        PopopxAppLockState.shared.endDuressFlow()
        PopopxAppLockState.shared.unlock()
        return .duress
    }

    /// 记一次失败，并按 `PopopxLockoutSchedule` 上锁。返回本次是第几次。
    ///
    /// 顺序：先改内存、再落盘。反过来（先落盘）会在写失败时留下"盘上有 5、内存里是 4"的
    /// 分裂，而内存值才是这一次界面读的那一份；写失败的后果只有"杀进程重开会退回 4 次"，
    /// 这是一次降级，不是一次绕过——而且它已经在 `logger` 里留了痕（不含任何凭据）。
    @discardableResult
    private func registerFailure() -> Int {
        let strikes = failedAttemptCount + 1
        failedAttemptCount = strikes
        let seconds = PopopxLockoutSchedule.lockoutSeconds(afterAttemptCount: strikes)
        lockoutEndsAt = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
        if !PopopxDuressKeychain.writeLockout(
            PopopxLockoutRecord(
                failedAttempts: strikes,
                lockoutEndTimestamp: lockoutEndsAt?.timeIntervalSince1970
            )
        ) {
            logger.error("duress lockout: persistence failed at strike \(strikes)")
        }
        return strikes
    }

    /// 清零：内存与盘上一起。**删条目**而不是写一个 0 进去——留一条"0 次"的记录等于
    /// 在密钥链里长期保存"这台设备启用过防爆破"这个事实，而自毁那一路要清的就是它
    /// （`PopopxStorageWipe` 第 7 步与 `scrubCredentialHistory` 也按同一个口径删）。
    private func clearFailures() {
        failedAttemptCount = 0
        lockoutEndsAt = nil
        PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
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
    /// 口径对齐全量路径的 `PopopxStorageWipe`（:877 同样 removeObject）。
    ///
    /// 助记词那一对与冷却记录也在这里删，"同口径"指的就是 `PopopxStorageWipe` 第 7 步那五条：
    /// 保留路径不删库，如果只删两把码，机主手上那张纸就还能重置出一把能打开**真身份**的
    /// 进入密码——那是这条路径上唯一一条没有关掉的门。冷却记录是"这里启用过防爆破"的指纹。
    private func scrubCredentialHistory() {
        _ = kcSelfDestructPassword.remove()
        UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
    }

    /// 步骤 C + D 的写入侧：先写盘，再**就地**覆写内存里的那两份缓冲。
    ///
    /// `inout` 是承重的，不是风格：值类型按值传进来的话，调用方那份副本仍然与形参指着同一块
    /// 盐/哈希缓冲（引用计数 2），`withUnsafeMutableBytes` 于是先写时复制、`memset_s` 擦到的是
    /// 刚复制出来的私有副本，原件一个字节都没少——正是"看着擦了、实际没擦"的假安全。
    /// `inout` 借到的是调用方独占的那一份（口径同 `PopopxSecurePayload.swift:455` 那段注释）。
    ///
    /// 诚实边界：口令明文本身是 ARC 管的 `String`，Swift 层覆写不了。全流水线上它只落地成
    /// 一次 `Data`（在 `derive(secret:salt:iterations:)` 里），并由那个函数自己的 `defer` 当场清零；
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
    ///
    /// `!isLockedOut` 是简报"冷却期内 Face ID 不许弹"的第二道闸（第一道在
    /// `prefersBiometricUnlock`）。放在这里而不是只放那里：调用方可以自己拼条件，
    /// 而这一条的性质是"任何入口都不给冷却期开后门"，所以要在离动作最近的地方再挡一次。
    /// 挡下时回 `completion(false)`——语义就是"该把键盘交出来了"，而键盘同样被
    /// `isLockedOut` 禁着，于是界面停在倒计时上，这正是设计要的样子。
    ///
    /// 成功那一路顺带 `clearFailures()`：简报写的是"任意一次正确的验证后立即清零"，
    /// 而生物识别是一次正确的验证。不接的话会出现一种荒谬状态——机主本人脸解锁进来，
    /// 下次锁屏却仍然对着他播一小时倒计时，因为来人猜错过 5 次。
    func requestBiometricUnlock(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard biometricsEnabled, !keypadRequired, !isLockedOut,
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
                self.clearFailures()
                PopopxAppLockState.shared.unlock()
                completion(true)
            }
        }
    }

    /// 键盘成功解锁后调用，把失败计数清零，下次遮罩开局仍可用生物识别。
    ///
    /// 冷却计数不在这里清——`submit(pin:)` 命中常规码那一支已经调过 `clearFailures()`，
    /// 那才是这张表的归零点；这个函数只管生物识别自己的"连续失败 2 次改走键盘"，
    /// 两者是两张不同的表，混在一起会让一次 Face ID 手滑看起来像一次猜码。
    func resetBiometricFailures() {
        biometricFailures = 0
        keypadRequired = false
    }
}
