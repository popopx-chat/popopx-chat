//
//  PopopxDecoyProfileGenerator.swift
//  POPOPX (iOS)
//
//  【双密码胁迫自毁 · 模块四】抹完存储之后，交出的是一个"刚装好的空 app"，还是一个
//  "看得出有人在这儿生活"的账号。这一支由这里决定：`makePlan(strategy:)` 只产出一份计划，
//  `install(_:)` 负责把计划落进 app 的界面状态并且让它活过一次重启。
//
//  ### 为什么需要这一层
//  `PopopxStorageWipe` 走完十步之后，屏幕上是一个零联系人、零消息、档案名都不一定有的新号。
//  一个刚被抢过、刚自毁过的设备，交出这种东西是最可疑的：真人手机不会长这样——它会有物业、
//  有驿站、有同学、有妈妈，有昨晚和今天上午的消息。模块四的任务就是把这一屏"日常"补上。
//
//  ### 为什么只能做在 app 的界面状态层（三条路是实测否掉的，不是没想到）
//  1. **走 FFI 造一个真 SMP 联系人做不到。** `apiAddContact` 只会返回一个邀请二维码，联系人
//     必须等对端上线配对才成立；本机不可能凭空地"生出"一个已就绪的 contact 行。
//  2. **直连 SQL 往库里塞也做不到。** 全仓没有 `import SQLite3`，库是 SQLCipher + Keychain 口令，
//     schema 在 Haskell 侧（`../../src/Popopx/Chat/Store/SQLite/Migrations/chat_schema.sql`），
//     表是 `STRICT`，还带 `item_content_tag` / `item_signatures` / `*_binding` 这些由核心算的列。
//  3. **自己手搓 `ChatItem` 结构体也不该做。** 仓库里就有正当的样例工厂（`ChatItem.getSample`、
//     `CIMeta.getSample`、`ChatInfo.SampleData`、`Contact.sampleData`），而且
//     `Shared/Views/Chat/ChatView.swift` 的 `ChatView_Previews` 已经示范了"只靠内存状态把一屏
//     中文聊天记录画出来"。本层就照那条已被验证能画出来的路走。
//
//  ### 取证局限（这段不许美化，它决定这一层能承诺什么、不能承诺什么）
//  假消息**只存在于两个地方**：内存里的 `ItemsModel.reversedChatItems` / `ChatModel.chats`，
//  以及本层自己那份 JSON。**它们不在 SQLCipher 库里。** 于是：
//  - 打开数据库看表，`chat` / `contact` / `chat_msg` 是空的——一眼识破；
//  - 看消息有没有 SMP 签名、`itemId` 是不是核心发的连续号、有没有对应的 conn/queue 行——识破；
//  - 在这一屏里按发送，命令会打到不存在的 chatId 上，核心报错——当场露馅；
//  - 开发者工具页（ChatInfoView 里 `if developerTools` 那段）会显示 `Local name` 为样例值
//    `alice` 和 Database ID——`Contact.localDisplayName` 在 POPOPXChat 模块里是 internal，
//    app target 改不动它，这一条躲不掉，只能靠"那是个开发开关，默认关"来兜。
//  所以这一层的真实目标很小：**让一个人对着屏幕读三分钟读不出破绽**，不是骗过取证。
//  要更强只能走真账号（比如准备一个真有内容的备用号），那是另一套成本，这里不假称做到。
//
//  ### 为什么必须落盘，以及落在哪
//  接管点如果只写内存，冷启动后 app 一刷新（`updateChats` / `loadChat` 都会重新取）就穿帮，
//  等于烟雾弹只活 10 秒。所以计划本身写进沙盒里一个独立 JSON（`Documents/POPOPXChatCache/`），
//  两个接管点在没人调过本层的情况下会**懒加载**它，于是"重启后仍然在"不依赖任何启动钩子。
//  ⚠️ 明确禁止：绝不允许把假消息写进聊天数据库文件本身——那会把"取证能识破"升级成
//  "核心层可能被自己编造的数据误导"（恢复、备份、导出、统计都会读到它），后患大得多。
//  目录名故意取得像缓存：一个叫 `DuressDecoy` 的目录等于把靶子画在沙盒上。这只是抬高门槛，
//  不是隐蔽性承诺。文件带 `.completeFileProtection`，且 Documents 已被 `excludeAppDataFromBackup`
//  整体排除备份，所以这份假身份不会跟着 iCloud 离开设备，也不会跟着恢复回到新机器上。
//
//  ### 计划是怎么活过一次"另一次自毁"的
//  快照里记着装载当时**从核心读回来的**显示名（不是我以为写进去的那个）。接管点比对当前
//  `currentUser?.displayName`：不等就不注入。于是走上游自毁码那条路（`disarmsAntiTheft: false`，
//  不碰本层的文件）之后，新档案的随机名对不上，旧的仿真内容不会诈尸；而机主自己改了显示名，
//  结果也只是退回"没有假内容"这个安全默认值。两种退化方向都是"少显示"，不是"多显示"。
//
//  ### `.emptyProfile`（以及 `.retainExistingProfile`）为什么必须是明确的 no-op
//  `.emptyProfile` 是默认模式：一个刚装好的空 app 不需要任何伪造内容就能自圆其说，而凭空多出来的
//  三个联系人是**需要被解释**的东西。所以这个模式下 `makePlan` 交回 `userDisplayName = nil`（让模块三
//  走 SimpleX 原生随机档案），`install` 什么都不做——不落盘、不接管、不拨开关。
//  `.retainExistingProfile`（模块三后来加的第三格）同理，而且更硬：那是个**真实存在**的身份，
//  往它上面掺假消息等于把可识破的假数据接到真 SMP 连接上；名字也是机主自己留的，本层不许改。
//
//  ### 自毁路径上没有反馈
//  这一层不弹 toast、不震动、不开窗、不打日志记昵称与正文。日志只出现阶段名和失败事实；
//  假身份的内容一旦被记进日志，就变成"这里曾经有过什么"的额外痕迹。
//
//  ### 宿主接线（本文件不修改任何宿主文件；建议位置与代码见交付汇报）
//  1. `PopopxDecoyProfileGenerator.hostTakeover(...)` —— `Shared/Model/POPOPXAPI.swift` 的 `loadChat`。
//  2. `PopopxDecoyProfileGenerator.hostChatListRefreshed()` —— `Shared/Model/ChatModel.swift` 的
//  `updateChats`。没有 1、2 这两行，本层只在装载的那一刻有效，撑不过一次刷新。
//  3. `PopopxDecoyProfileGenerator.shared.refreshFromDisk()` —— 模块五那行开关（`$decoyEnabled`）的
//  生效回调。本层不订阅 UserDefaults 变更，少了这一行，关开关要等到下一次 `updateChats` 才见效。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import Foundation
import POPOPXChat
import SwiftUI

// MARK: - 对外数据

/// 一个仿真会话：联系人显示名 + 按时间升序的消息。
struct PopopxDecoyChat: Hashable, Sendable, Codable {
    var contactDisplayName: String
    var messages: [PopopxDecoyMessage]

    /// 最新一条消息的时间。会话在列表里的先后按它排。
    var newestSentAt: Date {
        messages.map(\.sentAt).max() ?? .distantPast
    }
}

/// 一条仿真消息。`incoming` 是"对方发的"，决定气泡在哪一侧。
struct PopopxDecoyMessage: Hashable, Sendable, Codable {
    var text: String
    var sentAt: Date
    var incoming: Bool
}

// 本层不自己声明"抹完之后怎么呈现"那套枚举：它是模块三的
// `PopopxDuressRetentionStrategy`（`PopopxDuressAuthManager.swift`），三选一，
// 带关联值、Codable 持久化。本层只用到它的三个分支，参数名一路写 `strategy`
// 而不是 `mode`——第二轮改造之后它不再是"两种模式"，叫 mode 会骗人。

/// 一次重建的完整计划。**纯值**：`makePlan` 只算它，不做任何副作用，所以设置页可以拿它演练。
struct PopopxDecoyPlan: Hashable {
    var strategy: PopopxDuressRetentionStrategy
    /// 不注入内容的两种策略下都是 nil —— 模块三据此走 SimpleX 原生随机档案。
    var userDisplayName: String?
    /// 不注入内容的两种策略下都是空数组。
    var chats: [PopopxDecoyChat]

    /// 这份计划到底要不要往界面上放东西。`strategy` 说了不算，内容说了才算：
    /// 一个 `.simulatedDecoy` 但内容为空的计划（比如手工构造的测试数据）按 no-op 处理。
    var injectsAnything: Bool {
        strategy == .simulatedDecoy && !chats.isEmpty && userDisplayName != nil
    }
}

// MARK: - 内容本体（非隔离、纯函数：真实生成与演练/测试共用同一段代码）

/// 词汇表与生成算法。
///
/// 为什么不挂在 `@MainActor` 类上：`@MainActor` 类的 `static let` 是 main-actor 隔离的，
/// 非隔离的测试和演练入口引用不到，只能整类拉到主线程才能测。门限和数据放进一个普通 enum，
/// 它们天然 nonisolated——先例见模块一的 `PopopxMotionCriteria`。
enum PopopxDecoyContent {
    /// 中英一对。中文名交给档案显示名；英文名**出现在别人叫你的话里**（`%CALL%`），
    /// 于是"一个人有两个名字"这件事在屏幕上是自洽的，而不是数据里存着第二个名字却没人用。
    struct NicknamePair: Hashable, Sendable {
        let chinese: String
        let english: String

        /// 英文名里的"名"。`english` 是 "Alex Lin" 这种，取第一段。
        var callName: String {
            english.split(separator: " ").first.map(String.init) ?? english
        }
    }

    /// 剧本里的一轮。约定：**下标偶数=对方先开口，奇数=我接话**，整段是若干个"一问一答"接起来的。
    /// 这条约定是 `exchangeStarts` 能保证"任意截出来的 3–5 条都上下成对"的唯一依据。
    struct Turn: Hashable, Sendable {
        let incoming: Bool
        let text: String
    }

    struct Script: Hashable, Sendable {
        let contactName: String
        let turns: [Turn]
    }

    /// 20 组生活化昵称对。中文做 displayName，英文做"别人叫你"的称呼。
    static let nicknamePairs: [NicknamePair] = [
        NicknamePair(chinese: "林默", english: "Alex Lin"),
        NicknamePair(chinese: "陈远", english: "Owen Chen"),
        NicknamePair(chinese: "周宁", english: "Nina Zhou"),
        NicknamePair(chinese: "赵一鸣", english: "Ethan Zhao"),
        NicknamePair(chinese: "孙晓晴", english: "Sunny Sun"),
        NicknamePair(chinese: "李振宇", english: "Ryan Li"),
        NicknamePair(chinese: "黄静怡", english: "Grace Huang"),
        NicknamePair(chinese: "吴桐", english: "Tony Wu"),
        NicknamePair(chinese: "郑文清", english: "William Zheng"),
        NicknamePair(chinese: "何佳", english: "Jessica He"),
        NicknamePair(chinese: "徐子航", english: "Oliver Xu"),
        NicknamePair(chinese: "马晓岚", english: "Lauren Ma"),
        NicknamePair(chinese: "高志远", english: "Sean Gao"),
        NicknamePair(chinese: "罗雪", english: "Zoe Luo"),
        NicknamePair(chinese: "梁思远", english: "Dylan Liang"),
        NicknamePair(chinese: "宋雨桐", english: "Terry Song"),
        NicknamePair(chinese: "韩婧", english: "Anna Han"),
        NicknamePair(chinese: "曹逸", english: "Evan Cao"),
        NicknamePair(chinese: "邓慧心", english: "Helen Deng"),
        NicknamePair(chinese: "谢明轩", english: "Kevin Xie"),
    ]

    /// 6 份剧本，随机抽 2–3 份。内容全部是无害日常：挪车、取快递、约球、例会、家里人。
    /// 每条剧本 8 轮 = 4 个问答，因此 3–5 条的窗口一定落在问答内部，读起来是"话说到一半"，
    /// 不是"同一句复制五遍"。
    static let scripts: [Script] = [
        Script(contactName: "物业管家-王姐", turns: [
            Turn(incoming: true, text: "您好，本周六上午 9 点到 11 点地下车库冲洗地面，麻烦周五晚上把车挪到地面车位～"),
            Turn(incoming: false, text: "收到，我周五下班就开上去"),
            Turn(incoming: true, text: "好的。另外您家阳台下水有点返味，师傅说下周上门检修，方便的话家里留个人"),
            Turn(incoming: false, text: "下周一下午我在，那天可以吗"),
            Turn(incoming: true, text: "那就定周一下午两点，师傅到了我给您开门。对了电梯广告续约的单子我放您信箱了"),
            Turn(incoming: false, text: "好，晚上回去拿，麻烦您了🙏"),
            Turn(incoming: true, text: "不客气。顺便提醒下，本月物业费 15 号前缴，小程序上可以直接交"),
            Turn(incoming: false, text: "知道了，今天下班就交"),
        ]),
        Script(contactName: "快递驿站通知", turns: [
            Turn(incoming: true, text: "您的生鲜包裹已放至丰巢柜 3 号箱，取件码 8642，请在 12 小时内取出"),
            Turn(incoming: false, text: "好的，下班去取"),
            Turn(incoming: true, text: "另外昨天那箱是冷链，需要的话先放我们冰柜，今天 20 点前取"),
            Turn(incoming: false, text: "不用啦，我 6 点到家直接取"),
            Turn(incoming: true, text: "收到，柜门我帮您关好了。您有一件退货已经寄出，单号在小程序里"),
            Turn(incoming: false, text: "看到了，辛苦"),
            Turn(incoming: true, text: "不客气。今天到货比较集中，取件高峰在 18 点到 20 点，可以错峰"),
            Turn(incoming: false, text: "行，那我明天上午去"),
        ]),
        Script(contactName: "老同学张伟", turns: [
            Turn(incoming: true, text: "在吗，好久不见！下个月我出差路过你那边，有空聚聚不"),
            Turn(incoming: false, text: "在，方便啊，你哪天到"),
            Turn(incoming: true, text: "周五晚上落地，周六周日都空。对了 %CALL%，上次你说想看的那本书我带来了"),
            Turn(incoming: false, text: "那周六中午吧，我定个餐厅发你"),
            Turn(incoming: true, text: "行，还叫上李响他们不？"),
            Turn(incoming: false, text: "叫上，人多热闹，我拉个群"),
            Turn(incoming: true, text: "好，那就这么定，你周六提前把位置发我"),
            Turn(incoming: false, text: "没问题，到时候提前订位"),
        ]),
        Script(contactName: "周末球局-刘哥", turns: [
            Turn(incoming: true, text: "周末一起打球吗？周六上午 9 点老地方，现在还差两个人"),
            Turn(incoming: false, text: "算我一个，我带球"),
            Turn(incoming: true, text: "刘哥说他新球拍到了要试试。记得穿胶底鞋，3 号场已经订好"),
            Turn(incoming: false, text: "那我们 8 点半到，先把场占了"),
            Turn(incoming: true, text: "行。%CALL% 你上次说腰不舒服，别打太久"),
            Turn(incoming: false, text: "打两局就歇，放心"),
            Turn(incoming: true, text: "那说定了，周六见。我带水，你们谁带点水果"),
            Turn(incoming: false, text: "我带两个橙子"),
        ]),
        Script(contactName: "部门助理-小陈", turns: [
            Turn(incoming: true, text: "%CALL%，下周三例会改到上午十点，会议室换成 5 号，麻烦确认下时间"),
            Turn(incoming: false, text: "十点可以，我没问题"),
            Turn(incoming: true, text: "好的，通知已发群里。另外您上周交的报销单，财务说要补一张发票"),
            Turn(incoming: false, text: "我明天上午补给你"),
            Turn(incoming: true, text: "谢谢。还有个事，周五团建要不要带家属？"),
            Turn(incoming: false, text: "带，两个人"),
            Turn(incoming: true, text: "收到，我按三位报名。您周五要的季度材料我今晚发您邮箱"),
            Turn(incoming: false, text: "辛苦，明早我看"),
        ]),
        Script(contactName: "妈妈", turns: [
            Turn(incoming: true, text: "吃了吗，这两天降温，多穿点"),
            Turn(incoming: false, text: "吃了，妈你那边冷不冷"),
            Turn(incoming: true, text: "不冷，就是下雨。周末回家不？我给你炖汤"),
            Turn(incoming: false, text: "回的，周六下午到"),
            Turn(incoming: true, text: "路上慢点，坐地铁别打车。上次那个护膝你带了没"),
            Turn(incoming: false, text: "带了，在衣柜第二层"),
            Turn(incoming: true, text: "好。你爸的血压最近在吃药控制，不用惦记"),
            Turn(incoming: false, text: "知道了，回去看他"),
        ]),
    ]

    /// `%CALL%`：装填时换成昵称对里的英文名，让"这个账号叫什么"在别人的话里也一致。
    static let callPlaceholder = "%CALL%"

    /// 相邻两条消息的间隔候选（分钟）。**重尾**：多数很短、偶尔一大段，所以不需要额外抖动
    /// 就已经不是等间隔了——真实聊天的节奏就是这样（连着几句，然后消失两小时）。
    static let gapPoolMinutes: [Int] = [2, 3, 4, 6, 9, 14, 22, 38, 65, 110, 190]

    /// 全部历史都落在过去 24 小时以内（任务口径）。
    static let historyWindow: TimeInterval = 24 * 60 * 60
    /// 最新一条也不许贴着"现在"：4 分钟到 3 小时之前，像一个刚放下手机的人。
    static let newestMinimumAge: TimeInterval = 4 * 60
    static let newestMaximumAge: TimeInterval = 3 * 60 * 60

    /// 会话条数：2–3。
    static let chatCountRange: ClosedRange<Int> = 2...3
    /// 每个会话的消息条数：3–5。
    static let turnCountRange: ClosedRange<Int> = 3...5

    /// 生成一份计划。**纯函数**：不碰 UserDefaults、不碰文件、不碰任何界面状态，
    /// 所以设置页的演练可以放心调它，`now` 给死还能当回归测试用。
    static func makePlan(strategy: PopopxDuressRetentionStrategy, now: Date = Date()) -> PopopxDecoyPlan {
        switch strategy {
        case .emptyProfile:
            // 不注入任何内容，`userDisplayName = nil` 让模块三走 SimpleX 原生随机档案。
            return PopopxDecoyPlan(strategy: .emptyProfile, userDisplayName: nil, chats: [])
        case .retainExistingProfile(let profileId, let displayName):
            // 机主选的是"留下某个已有的匿名身份"。那一格的名字是他自己留的，本层不许改名，
            // 也绝不能往里塞假会话——往一个**真实存在**的身份里掺假消息，等于把可识破的假数据
            // 接到真 SMP 连接上，比空号坏得多。所以这一支与 `.emptyProfile` 同为 no-op，
            // 只把策略原样带回，方便调用方打日志/演练时看清"本层为什么什么都没做"。
            return PopopxDecoyPlan(strategy: .retainExistingProfile(profileId: profileId, displayName: displayName),
                                   userDisplayName: nil,
                                   chats: [])
        case .simulatedDecoy:
            let pair = nicknamePairs.randomElement() ?? nicknamePairs[0]
            return PopopxDecoyPlan(
                strategy: .simulatedDecoy,
                userDisplayName: pair.chinese,
                chats: makeChats(pair: pair, now: now)
            )
        }
    }

    static func makeChats(pair: NicknamePair, now: Date) -> [PopopxDecoyChat] {
        let count = Int.random(in: chatCountRange)
        let chosen = scripts.indices.shuffled().prefix(count)
        return chosen
            .map { index in makeChat(scripts[index], pair: pair, now: now) }
            .sorted { $0.newestSentAt > $1.newestSentAt }
    }

    static func makeChat(_ script: Script, pair: NicknamePair, now: Date) -> PopopxDecoyChat {
        let turnCount = Int.random(in: turnCountRange)
        let starts = exchangeStarts(available: script.turns.count, taking: turnCount)
        let start = starts.randomElement() ?? 0
        let slice = Array(script.turns[start..<start + turnCount])
        let times = messageTimes(count: slice.count, now: now)
        let messages = zip(slice, times).map { turn, at in
            PopopxDecoyMessage(
                text: substitute(turn.text, callName: pair.callName),
                sentAt: at,
                incoming: turn.incoming
            )
        }
        return PopopxDecoyChat(contactDisplayName: script.contactName, messages: messages)
    }

    /// 合法的切片起点：只取偶数下标，保证切出来的第一条是"对方开口"，最后一条落在问答的
    /// 任意一半都读得通。剧本不够长时退回到 0——不越界，也不为了凑数把同一条重复一遍。
    static func exchangeStarts(available: Int, taking: Int) -> [Int] {
        guard taking > 0, available >= taking else { return [0] }
        return Array(stride(from: 0, through: available - taking, by: 2))
    }

    /// 时间铺排：先定"最新一条在 4 分钟到 3 小时之前"，再往前按重尾间隔走，
    /// 走超了 24 小时窗口就把**所有**间隔按比例压小（等比缩放保留非均匀性，不会压成等间隔）。
    /// 不变量：严格递增；最旧一条不早于 `now - 24h`；最新一条不早于 `now - 4min`。
    static func messageTimes(count: Int, now: Date) -> [Date] {
        guard count > 0 else { return [] }
        let newest = now.addingTimeInterval(-Double.random(in: newestMinimumAge...newestMaximumAge))
        guard count > 1 else { return [newest] }
        let available = newest.timeIntervalSince(now.addingTimeInterval(-historyWindow))
        var gaps = (1..<count).map { _ in Double(gapPoolMinutes.randomElement() ?? 12) * 60 }
        let span = gaps.reduce(0, +)
        if span > available, span > 0 {
            let factor = available / span
            gaps = gaps.map { $0 * factor }
        }
        var times: [Date] = []
        times.reserveCapacity(count)
        var cursor = newest.addingTimeInterval(-min(span, available))
        times.append(cursor)
        for gap in gaps {
            cursor = cursor.addingTimeInterval(gap)
            times.append(cursor)
        }
        return times
    }

    static func substitute(_ text: String, callName: String) -> String {
        text.replacingOccurrences(of: callPlaceholder, with: callName)
    }
}

// MARK: - 本层自己的落盘

/// 快照 = 计划 + 装载时刻 + **当时从核心读回来的**档案显示名。
private struct PopopxDecoySnapshot: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var userDisplayName: String?
    var installedAt: Date
    var chats: [PopopxDecoyChat]
}

/// `Documents/POPOPXChatCache/` 下一个 JSON。整层只有一个文件，卸载 = 删目录。
///
/// 读写都是 nonisolated 的普通静态函数：`install` 在胁迫路径上跑，落盘那一下不该压在主线程，
/// 而 `loadChat` 的接管点可能来自任何线程，读文件也必须能在隔离之外调。
private enum PopopxDecoyStore {
    private static let directoryName = "POPOPXChatCache"
    private static let fileName = "layout-prefs.json"

    /// 拿不到 Application Support / Documents 时退回临时目录：**宁可不落永久区，也不 `!` 一个可能为
    /// nil 的 URL**（先例见 ProfileStorageManager.swift:143-147 对 `FileUtils.swift:59` 那种写法的批评）。
    static var rootDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return (documents ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static var snapshotURL: URL { rootDirectory.appendingPathComponent(fileName) }

    static func save(_ snapshot: PopopxDecoySnapshot) -> Bool {
        let url = snapshotURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try applyCompleteProtection(at: url.deletingLastPathComponent())
            let data = try encoder().encode(snapshot)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try applyCompleteProtection(at: url)
            return true
        } catch {
            // 只记阶段：这一句里没有任何昵称、正文或身份信息。
            logger.error("decoy rebuild: persistence write failed")
            return false
        }
    }

    static func load() -> PopopxDecoySnapshot? {
        let url = snapshotURL
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            logger.error("decoy rebuild: persisted snapshot unreadable")
            return nil
        }
        guard let snapshot = try? decoder().decode(PopopxDecoySnapshot.self, from: data) else {
            logger.error("decoy rebuild: persisted snapshot not decodable")
            return nil
        }
        guard snapshot.version == PopopxDecoySnapshot.currentVersion else {
            // 版本不对时删掉：留着只会用旧格式的内容冒充新格式的行为。
            discard()
            return nil
        }
        return snapshot
    }

    static func discard() {
        do {
            try FileManager.default.removeItem(at: rootDirectory)
        } catch {
            logger.error("decoy rebuild: snapshot removal failed")
        }
    }

    private static func applyCompleteProtection(at url: URL) throws {
        try FileManager.default.setAttributes(
            [FileAttributeKey.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    /// `.secondsSince1970`：消息时间是这一层最要紧的数据，不能受 locale/时区格式影响。
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - 运行时：把快照变成能画出来的东西

/// 一个仿真会话在界面上的那一份：`ChatInfo` + 已排好序的 `ChatItem`。
///
/// 造联系人**不**走 FFI（做不到，见文件头），而是拿 `Contact.sampleData` 改公共可变字段：
/// `contactId` 决定 chatId（`"@\(contactId)"`），`profile.displayName` 决定所有界面上显示的名字
/// （`Contact.displayName` 在 `localAlias == ""` 时就是它）。
private struct PopopxDecoyRuntime {
    let chatId: ChatId
    let chatInfo: ChatInfo
    /// 旧→新，和 `apiGetChat(.initial)` 的口径一致：会话列表那一行取的是 `chatItems.last`。
    let chatItems: [ChatItem]
    /// 新→旧，`ItemsModel.reversedChatItems` 要的次序。
    let reversedItems: [ChatItem]
    let chatStats: ChatStats
    let newestSentAt: Date
}

@MainActor
@Observable
final class PopopxDecoyProfileGenerator {
    static let shared = PopopxDecoyProfileGenerator()

    /// 仿真联系人的 id 起点。放在真实账号永远不会用到的号段：真 contactId 从 1 往上长，
    /// 撞上就会让两个会话在列表里同 id。写死在这里，不藏进公式。
    private static let contactIdBase: Int64 = 90_000_001
    /// 每个会话预留的 itemId 数量（剧本最长 8 条，翻倍留余量）。
    private static let itemIdBase: Int64 = 90_000_001
    private static let itemsPerChat: Int64 = 1_000

    // MARK: 对外可观测状态

    /// 这一层现在**在不在屏幕上**。它是唯一的观测口径，描述的是界面事实，不是文件是否存在：
    /// 关掉模块五那行开关、或者当前档案已经不是装载时那一个，它都会跟着变 false。
    private(set) var isInstalled = false

    /// 装载时刻（来自快照）。设置页可以拿来解释"这一层什么时候装的"。
    private(set) var installedAt: Date?

    /// 会话条数。**故意不暴露昵称与正文**：这一层的状态随时可能被读进日志或界面，
    /// 把假身份当真身份记一次，就留下一条"曾经有过什么"的痕迹。
    private(set) var injectedChatCount = 0

    /// 落盘是否成功。false 表示本次会话看着是真的，但冷启动后会退回没有假内容的状态——
    /// 演练时必须能把这一格看清楚，不许用"看起来成功了"糊过去。
    private(set) var survivesRestart = false

    // MARK: 内部

    private var snapshot: PopopxDecoySnapshot?
    private var orderedRuntimes: [PopopxDecoyRuntime] = []
    private var runtimesById: [ChatId: PopopxDecoyRuntime] = [:]
    /// "已经看过磁盘了"。只有一个写点：真的读过一次盘，或者本进程刚刚自己装/卸过。
    private var diskChecked = false

    private init() {}

    // MARK: 计划

    /// 算一份计划，零副作用。模块三在**动手擦之前**调它，并把结果留在内存里。
    func makePlan(strategy: PopopxDuressRetentionStrategy) -> PopopxDecoyPlan {
        PopopxDecoyContent.makePlan(strategy: strategy, now: Date())
    }

    // MARK: 装载

    /// 把计划装进界面。
    ///
    /// `.emptyProfile`、`.retainExistingProfile`（以及任何 `.simulatedDecoy` 但内容为空的计划）
    /// **必须原样返回**：那几个模式的语义就是"什么都不做"——一个刚装好的空 app 不需要伪造内容
    /// 也能自圆其说，而多出来的联系人和消息是需要被解释的东西。此时既不写盘也不拨开关，
    /// 于是本层在沙盒和 UserDefaults 里都不留任何痕迹，取证面与装载前完全一致。
    func install(_ plan: PopopxDecoyPlan) async {
        guard plan.injectsAnything else {
            return
        }
        // 先清掉本层可能已经存在的那一份（演练完再来一次真实自毁时，不许留下上一批假会话）。
        removeInjectedChats()
        clearOpenChatIfInjected()

        let snapshot = PopopxDecoySnapshot(
            version: PopopxDecoySnapshot.currentVersion,
            // 绑**核心读回来**的那个名字，而不是我以为写进去的那个：两者不一致时（核心的
            // displayName 规范化改过、或档案压根没建成）以现值为准，才不会出现"自己把自己挡在门外"。
            userDisplayName: ChatModel.shared.currentUser?.displayName ?? plan.userDisplayName,
            installedAt: Date(),
            chats: plan.chats
        )
        let written = await Task.detached(priority: .userInitiated) {
            PopopxDecoyStore.save(snapshot)
        }.value

        survivesRestart = written
        adopt(snapshot)
        UserDefaults.standard.set(true, forKey: DEFAULT_ANTI_THEFT_DECOY_ENABLED)
        assertChatList()
        // 列表先落定，再补当前那一屏：中间让出一轮，SwiftUI 才能把"会话出现了"和
        // "点进去有消息"按正常次序画出来，而不是在同一帧里既插行又换内容。
        await Task.yield()
        assertOpenChatItems()
    }

    /// 把这一层彻底卸载/清干净：摘掉假会话行、清掉已经画出来的假消息、删掉自己那份文件、
    /// 把总开关拨回关闭。设置页的演练收尾、以及自毁之后想恢复干净时都调这一个。
    ///
    /// 卸载是本层唯一允许"往回走"的动作，所以它必须把状态一次清完——留着半份计划
    /// （文件在、开关开、界面上没有）是最坏的中间态：下一次接管会莫名其妙把它又画出来。
    func uninstall() {
        removeInjectedChats()
        clearOpenChatIfInjected()
        PopopxDecoyStore.discard()
        snapshot = nil
        orderedRuntimes = []
        runtimesById = [:]
        diskChecked = true
        isInstalled = false
        installedAt = nil
        injectedChatCount = 0
        survivesRestart = false
        UserDefaults.standard.set(false, forKey: DEFAULT_ANTI_THEFT_DECOY_ENABLED)
    }

    /// 冷启动后由接管点懒加载：不需要任何启动钩子。
    ///
    /// 这也是本层唯一的"重新对齐"入口：它按"盘上那份 + 总开关 + 当前档案"三个条件重判一次，
    /// 成立就把假会话补上、不成立就把它们从屏幕上收回去。模块五那行开关的 action、
    /// 设置页演练的收尾都该调它——不调的话，开关只在下一次 `updateChats` 才生效。
    func refreshFromDisk() {
        ensureLoadedFromDisk()
        if armed {
            assertChatList()
            assertOpenChatItems()
            isInstalled = true
            injectedChatCount = orderedRuntimes.count
        } else {
            withdrawFromScreens()
        }
    }

    /// 把这一层在界面上留下的东西收回去，但**不动盘上那份文件**，也不动总开关。
    ///
    /// 区分得很刻意：不成立只意味着"此刻不该显示"，不意味着"这套假身份作废"。
    /// 号改回装载时那个名字、或开关被重新打开，同一份内容还能用；
    /// 而"看到不匹配就毁证"不是本层的判断权，那是 `uninstall()` 的活。
    private func withdrawFromScreens() {
        guard isInstalled else { return }
        removeInjectedChats()
        clearOpenChatIfInjected()
        isInstalled = false
        injectedChatCount = 0
    }

    // MARK: 宿主接线点

    /// `loadChat` 的接管点。返回 true = 这一屏由本层负责，宿主**必须**直接 return，
    /// 不许再走 `apiLoadMessages`（它会把 `reversedChatItems` 清空再从库里取，一取就把假消息抹掉了）。
    ///
    /// `nonisolated async`：宿主那个函数不是 main-actor 隔离的，这里显式跳一次主 actor，
    /// 免得将来并发检查调严时这一行变成编译错误。
    nonisolated static func hostTakeover(
        chatId: ChatId,
        im: ItemsModel,
        contentTag: MsgContentTag?,
        search: String,
        openAroundItemId: ChatItem.ID?
    ) async -> Bool {
        // 只接管"整屏首次加载"。筛选、搜索、跳到某条消息都是拿真实 chatId 去核心问的，
        // 本层没有那种视图，硬接只会接出更假的东西。
        guard contentTag == nil, search.isEmpty, openAroundItemId == nil else { return false }
        return await PopopxDecoyProfileGenerator.shared.takeoverFromHost(
            chatId: chatId,
            im: im
        )
    }

    /// `ChatModel.updateChats` 末尾的那一行：核心刚把会话列表刷成"空账号"的样子，
    /// 本层把假会话补回去。异步到主 actor，不阻塞调用方，也不管调用方在哪个 actor 上。
    nonisolated static func hostChatListRefreshed() {
        Task { @MainActor in
            PopopxDecoyProfileGenerator.shared.refreshFromDisk()
        }
    }

    // MARK: 注入本体

    private func takeoverFromHost(chatId: ChatId, im: ItemsModel) -> Bool {
        ensureLoadedFromDisk()
        guard armed, let runtime = runtimesById[chatId] else { return false }
        inject(runtime, into: im)
        return true
    }

    /// 照 `apiLoadMessages` 的 `.initial` 那一支的样子填状态（ChatItemsLoader.swift:48-68）。
    /// `chatState.clear()` 已经把 `splits`、`totalAfter`、`unreadAfter`、`unreadAfterNewestLoaded`
    /// 归到"没有更早的消息可翻"这一组默认值，本层需要的正是那一组，所以只再赋两个非默认字段。
    private func inject(_ runtime: PopopxDecoyRuntime, into im: ItemsModel) {
        im.reversedChatItems = runtime.reversedItems
        im.chatState.clear()
        im.chatState.unreadAfterItemId = runtime.chatItems.last?.id ?? -1
        im.chatState.unreadTotal = runtime.chatStats.unreadCount
        im.preloadState.clear()
    }

    /// 三个条件同时成立才注入：有内容、总开关开着、当前档案就是装载时那一个。
    ///
    /// 总开关 `DEFAULT_ANTI_THEFT_DECOY_ENABLED` 是模块五那行"仿真烟雾弹内容"的键。
    /// 在这里读它，那一行才从"只存了"变成"真生效"：关掉它，`armed` 当场变 false，
    /// 假会话与假消息由 `refreshFromDisk()` 撤出屏幕。本层不订阅 UserDefaults 的变更通知——
    /// 那一行的 action 必须调 `refreshFromDisk()`，否则效果要等到下一次 `updateChats`。
    private var armed: Bool {
        guard !runtimesById.isEmpty else { return false }
        guard UserDefaults.standard.bool(forKey: DEFAULT_ANTI_THEFT_DECOY_ENABLED) else { return false }
        guard let bound = snapshot?.userDisplayName,
              let user = ChatModel.shared.currentUser else { return false }
        return user.displayName == bound
    }

    private func ensureLoadedFromDisk() {
        guard !diskChecked else { return }
        // 档案还没读出来时**不裁定、也不落旗**：这一层的成败要看盘上那份和现在这个号配不配，
        // 号还没到就说"不配"，等于把烟雾弹在自己手里掐灭。
        guard let user = ChatModel.shared.currentUser else { return }
        diskChecked = true
        guard let snapshot = PopopxDecoyStore.load(), snapshot.userDisplayName == user.displayName else { return }
        adopt(snapshot)
    }

    private func adopt(_ snapshot: PopopxDecoySnapshot) {
        self.snapshot = snapshot
        let runtimes = Self.makeRuntimes(from: snapshot.chats)
        orderedRuntimes = runtimes
        runtimesById = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.chatId, $0) })
        installedAt = snapshot.installedAt
        injectedChatCount = runtimes.count
        isInstalled = !runtimes.isEmpty
        diskChecked = true
    }

    private static func makeRuntimes(from chats: [PopopxDecoyChat]) -> [PopopxDecoyRuntime] {
        chats.enumerated().map { offset, chat in
            let chatInfo = Self.directChatInfo(
                contactId: contactIdBase + Int64(offset),
                displayName: chat.contactDisplayName
            )
            let base = itemIdBase + Int64(offset) * itemsPerChat
            let items = chat.messages.enumerated().map { position, message in
                ChatItem.getSample(
                    base + Int64(position) + 1,
                    message.incoming ? .directRcv : .directSnd,
                    message.sentAt,
                    message.text,
                    message.incoming ? .rcvRead : .sndRcvd(msgRcptStatus: .ok, sndProgress: .complete)
                )
            }
            // 多语句闭包必须写 return，末表达式不会被隐式返回。
            return PopopxDecoyRuntime(
                chatId: chatInfo.id,
                chatInfo: chatInfo,
                chatItems: items,
                reversedItems: items.reversed(),
                // 全部已读。这一层没有"读过了"的上报路径，留一个永远清不掉的未读点，
                // 比一个未读都没有更像假的。
                chatStats: ChatStats(),
                newestSentAt: chat.newestSentAt
            )
        }
    }

    /// `Contact.localDisplayName` 在 POPOPXChat 里是 internal，app target 够不着，
    /// 所以只能改够得着的那些：`contactId`（决定 chatId）与 `profile`（决定所有界面显示的名字）。
    private static func directChatInfo(contactId: Int64, displayName: String) -> ChatInfo {
        var contact = Contact.sampleData
        contact.contactId = contactId
        var profile = contact.profile
        profile.displayName = displayName
        // `fullName` 留空：ChatInfoToolbar 在 `fullName != "" && displayName != fullName` 时
        // 会在名字下面多画一行，那里没有第二个名字可给它。`localAlias` 必须是空，
        // 否则 `Contact.displayName` 会改成取 alias，上面那行赋值就白写了。
        profile.fullName = ""
        profile.localAlias = ""
        contact.profile = profile
        return ChatInfo.direct(contact: contact)
    }

    private func assertChatList() {
        guard armed else { return }
        let model = ChatModel.shared
        // 旧→新依次插到 0：转完一遍，最新的自然停在列表最前，其余按时间降序跟着。
        for runtime in orderedRuntimes.sorted(by: { $0.newestSentAt < $1.newestSentAt }) {
            if model.hasChat(runtime.chatId) { continue }
            model.addChat_(
                Chat(chatInfo: runtime.chatInfo, chatItems: runtime.chatItems, chatStats: runtime.chatStats),
                at: 0
            )
        }
    }

    /// 当前正好开着某个仿真会话时（例如从设置页重装、或自毁时前台还停在那一屏）补一次消息。
    private func assertOpenChatItems() {
        guard armed, let chatId = ChatModel.shared.chatId, let runtime = runtimesById[chatId] else { return }
        inject(runtime, into: ItemsModel.shared)
    }

    private func removeInjectedChats() {
        let model = ChatModel.shared
        for chatId in runtimesById.keys where model.hasChat(chatId) {
            model.removeChat(chatId)
        }
    }

    private func clearOpenChatIfInjected() {
        guard let chatId = ChatModel.shared.chatId, runtimesById[chatId] != nil else { return }
        ItemsModel.shared.reversedChatItems = []
        ItemsModel.shared.chatState.clear()
        ItemsModel.shared.preloadState.clear()
    }
}
