//
//  PopopxDecoyProfileGenerator.swift
//  POPOPX (iOS)
//
//  [Dual-passphrase duress self-destruct - module four] After the storage wipe is finished, what the screen hands over is either a "freshly installed empty app" or
//  an account you can tell someone actually lives in. This branch is decided here: `makePlan(strategy:)` only produces a plan,
//  `install(_:)` is what puts that plan into the app's UI state and keeps it alive across one restart.
//
//  ### Why this layer is needed
//  Once `PopopxStorageWipe` has run its ten steps, the screen shows a brand new account: zero contacts, zero messages, and not necessarily even a profile name.
//  For a device that was just robbed and just self-destructed, handing over something like that is the most suspicious outcome of all: a real person's phone does not look like this - it has property management,
//  a parcel station, classmates, a mom, messages from last night and from this morning. Module four's job is to fill that screenful of "everyday" back in.
//
//  ### Why it can only be done in the app's UI state layer (the three routes were ruled out by measurement, not overlooked)
//  1. **Building a real SMP contact through the FFI is impossible.** `apiAddContact` only returns an invite QR code, and a contact
//     only comes into being once the peer is online and pairing completes; this device cannot give birth out of thin air to a ready-made contact row.
//  2. **Pushing rows in with direct SQL is impossible either.** There is no `import SQLite3` anywhere in the repo, the database is SQLCipher + a Keychain passphrase,
//     the schema lives on the Haskell side (`../../src/Popopx/Chat/Store/SQLite/Migrations/chat_schema.sql`),
//     the tables are `STRICT`, and they carry columns such as `item_content_tag` / `item_signatures` / `*_binding` that the core computes.
//  3. **Hand-rolling `ChatItem` structures yourself should not be done either.** The repo already has legitimate sample factories (`ChatItem.getSample`,
//     `CIMeta.getSample`, `ChatInfo.SampleData`, `Contact.sampleData`), and
//     `ChatView_Previews` in `Shared/Views/Chat/ChatView.swift` has already demonstrated drawing, purely from in-memory state, a whole screen of
//     Chinese chat history. This layer walks that same route, the one already verified to render.
//
//  ### Forensic limitations (this section is not to be prettified; it decides what this layer can promise and what it cannot)
//  The fake messages **exist in exactly two places**: the in-memory `ItemsModel.reversedChatItems` / `ChatModel.chats`,
//  and this layer's own JSON. **They are not in the SQLCipher database.** Hence:
//  - open the database and look at the tables: `chat` / `contact` / `chat_msg` are empty - seen through at a glance;
//  - check whether the messages carry SMP signatures, whether `itemId` is a sequential number issued by the core, whether the matching conn/queue rows exist - seen through;
//  - press send on this screen and the command lands on a chatId that does not exist, the core reports an error - exposed on the spot;
//  - the developer tools page (the `if developerTools` block inside ChatInfoView) shows `Local name` as the sample value
//    `alice` together with the Database ID - `Contact.localDisplayName` is internal inside the POPOPXChat module,
//    the app target cannot change it, and this one cannot be dodged; the only fallback is "it is a developer switch, off by default".
//  So the real goal of this layer is small: **a person reading the screen for three minutes finds no flaw**, not fooling forensics.
//  Anything stronger requires a real account (say, a backup account that genuinely has content), which is a different cost altogether; this does not pretend to have done it.
//
//  ### Why it has to reach the disk, and where it lands
//  If the takeover points only wrote memory, the first refresh after a cold start (`updateChats` / `loadChat` both re-fetch) would blow the cover,
//  which is a smoke bomb that lives 10 seconds. So the plan itself is written into a standalone JSON inside the sandbox (`Documents/POPOPXChatCache/`),
//  and the two takeover points **lazily load** it when nobody has called this layer, so "still there after a restart" depends on no launch hook.
//  ⚠️ Explicitly forbidden: fake messages must never be written into the chat database file itself - that would escalate "forensics can see through it" into
//  "the core layer being misled by invented data" (restore, backup, export and statistics all read it), which is a far bigger liability.
//  The directory name is deliberately cache-like: a directory called `DuressDecoy` would be painting a target on the sandbox. This only raises the bar,
//  it is not a promise of stealth. The file carries `.completeFileProtection`, and by `excludeAppDataFromBackup` Documents is
//  excluded from backup in its entirety, so this fake identity never leaves the device with iCloud and never comes back on a new machine through a restore.
//
//  ### How the plan survives "another self-destruct"
//  The snapshot records the display name **read back from the core** at install time (not the one I assumed was written in). The takeover point compares the current
//  `currentUser?.displayName`: if it differs, nothing is injected. So the upstream duress-code path (`disarmsAntiTheft: false`,
//  which does not touch this layer's files) leaves the new profile's random name unmatched and the old simulated content does not rise from the dead; and if the owner changes the display name themselves,
//  the result is only a fall back to the safe default of "no fake content". Both degenerate directions show less, never more.
//
//  ### Why `.emptyProfile` (and `.retainExistingProfile`) must be an explicit no-op
//  `.emptyProfile` is the default mode: a freshly installed empty app accounts for itself with no fabricated content at all, whereas the extra
//  three contacts are something that **needs to be explained**. So in this mode `makePlan` hands back `userDisplayName = nil` (so module three
//  takes the underlying app's native random profile), and `install` does nothing at all - no disk write, no takeover, no switch flipped.
//  `.retainExistingProfile` (the third slot module three added later) follows the same reasoning, and more strictly: that is an identity that **really exists**,
//  and spiking it with fake messages is wiring see-through fake data onto a real SMP connection; the name is one the owner kept themselves, which this layer may not change.
//
//  ### No feedback on the self-destruct path
//  This layer pops no toast, no haptic, no window, and logs no nicknames or message bodies. The log carries only stage names and the bare fact of a failure;
//  once the content of a fake identity is written into the log it becomes extra evidence of "what used to be here".
//
//  ### Host wiring (this file modifies no host file; the suggested locations and code are in the delivery report)
//  1. `PopopxDecoyProfileGenerator.hostTakeover(...)` - `loadChat` in `Shared/Model/POPOPXAPI.swift`.
//  2. `PopopxDecoyProfileGenerator.hostChatListRefreshed()` - the one in `Shared/Model/ChatModel.swift`,
//  `updateChats`. Without lines 1 and 2 this layer is valid only at the moment it is installed and cannot outlive one refresh.
//  3. `PopopxDecoyProfileGenerator.shared.refreshFromDisk()` - the callback that makes the module five switch (`$decoyEnabled`)
//  actually take effect. This layer does not subscribe to UserDefaults changes; without this line, turning the switch off waits for the next `updateChats` to show.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import Foundation
import POPOPXChat
import SwiftUI

// MARK: - Public data

/// One simulated chat: contact display name + messages in ascending time order.
struct PopopxDecoyChat: Hashable, Sendable, Codable {
    var contactDisplayName: String
    var messages: [PopopxDecoyMessage]

    /// The time of the newest message. The order of chats in the list is decided by it.
    var newestSentAt: Date {
        messages.map(\.sentAt).max() ?? .distantPast
    }
}

/// One simulated message. `incoming` means "sent by the other side" and decides which side the bubble sits on.
struct PopopxDecoyMessage: Hashable, Sendable, Codable {
    var text: String
    var sentAt: Date
    var incoming: Bool
}

// This layer does not declare its own enum for "how things are presented after the wipe": it is module three's
// `PopopxDuressRetentionStrategy` (`PopopxDuressAuthManager.swift`), a choice of three,
// with associated values, Codable-persisted. This layer only uses its three cases, and the parameter is spelled `strategy` all the way through
// rather than `mode` - after the second round of rework it is no longer "two modes", so calling it mode would lie.

/// The complete plan for one rebuild. **A pure value**: `makePlan` only computes it and performs no side effect, so the settings page can rehearse with it.
struct PopopxDecoyPlan: Hashable {
    var strategy: PopopxDuressRetentionStrategy
    /// nil under both strategies that inject no content - module three uses that to take the underlying app's native random profile.
    var userDisplayName: String?
    /// An empty array under both strategies that inject no content.
    var chats: [PopopxDecoyChat]

    /// Whether this plan actually puts anything on screen. `strategy` does not decide it, the content does:
    /// a plan that is `.simulatedDecoy` but whose content is empty (say, hand-built test data) is treated as a no-op.
    var injectsAnything: Bool {
        strategy == .simulatedDecoy && !chats.isEmpty && userDisplayName != nil
    }
}

// MARK: - The content itself (nonisolated, pure functions: real generation and rehearsal/tests share the same code)

/// The vocabulary lists and the generation algorithm.
///
/// Why it is not hung off a `@MainActor` class: a `static let` on a `@MainActor` class is main-actor isolated,
/// so nonisolated test and rehearsal entry points cannot reference it and the whole class has to be pulled onto the main thread before it can be tested. Thresholds and data go into a plain enum,
/// which makes them nonisolated by nature - the precedent is module one's `PopopxMotionCriteria`.
enum PopopxDecoyContent {
    /// A Chinese-English pair. The Chinese name becomes the profile display name; the English name **appears in what other people call you** (`%CALL%`),
    /// so "one person has two names" is self-consistent on screen, instead of a second name sitting in the data that nobody ever uses.
    struct NicknamePair: Hashable, Sendable {
        let chinese: String
        let english: String

        /// The given name inside the English name. `english` is of the form "Alex Lin", so this takes the first part.
        var callName: String {
            english.split(separator: " ").first.map(String.init) ?? english
        }
    }

    /// One round of a script. The convention: **even index = the other side opens, odd index = I reply**, so the whole passage is several "one question, one answer" units joined together.
    /// This convention is the only basis on which `exchangeStarts` can guarantee that any 3–5 messages cut out pair up top and bottom.
    struct Turn: Hashable, Sendable {
        let incoming: Bool
        let text: String
    }

    struct Script: Hashable, Sendable {
        let contactName: String
        let turns: [Turn]
    }

    /// 20 everyday nickname pairs. Chinese becomes the displayName, English the way "other people call you".
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

    /// 6 scripts, 2–3 of them drawn at random. All content is harmless everyday life: moving a car, picking up a parcel, a ball game, the regular meeting, family.
    /// Every script has 8 turns = 4 question-and-answer pairs, so a window of 3–5 messages always lands inside a pair and reads as "a sentence half spoken",
    /// not "the same line copied five times".
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

    /// `%CALL%`: replaced at install time with the English name from the nickname pair, so "what this account is called" stays consistent inside other people's lines too.
    static let callPlaceholder = "%CALL%"

    /// Candidate gaps between adjacent messages (minutes). **Heavy tailed**: mostly short, occasionally a long stretch, so no extra jitter is needed
    /// for the spacing to be uneven already - that is how real chat cadence works (a few lines in a row, then two hours of silence).
    static let gapPoolMinutes: [Int] = [2, 3, 4, 6, 9, 14, 22, 38, 65, 110, 190]

    /// The whole history stays within the past 24 hours (the task's stated terms).
    static let historyWindow: TimeInterval = 24 * 60 * 60
    /// The newest message must not sit right at "now" either: between 4 minutes and 3 hours ago, like someone who just put the phone down.
    static let newestMinimumAge: TimeInterval = 4 * 60
    static let newestMaximumAge: TimeInterval = 3 * 60 * 60

    /// Number of chats: 2–3.
    static let chatCountRange: ClosedRange<Int> = 2...3
    /// Number of messages per chat: 3–5.
    static let turnCountRange: ClosedRange<Int> = 3...5

    /// Generates a plan. **A pure function**: it touches no UserDefaults, no file and no UI state,
    /// so the settings page rehearsal can call it without worry, and pinning `now` even makes it usable as a regression test.
    static func makePlan(strategy: PopopxDuressRetentionStrategy, now: Date = Date()) -> PopopxDecoyPlan {
        switch strategy {
        case .emptyProfile:
            // Injects nothing; `userDisplayName = nil` lets module three take the underlying app's native random profile.
            return PopopxDecoyPlan(strategy: .emptyProfile, userDisplayName: nil, chats: [])
        case .retainExistingProfile(let profileId, let displayName):
            // The owner chose "keep some existing anonymous identity". The name in that slot is one they kept themselves, so this layer may not rename it,
            // and it must never stuff fake chats into it - spiking an identity that **really exists** with fake messages is the same as wiring
            // see-through fake data onto a real SMP connection, far worse than an empty account. So this branch, like `.emptyProfile`, is a no-op,
            // carrying the strategy back unchanged so the caller can see clearly in the log or the rehearsal "why this layer did nothing".
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

    /// Legal slice start points: only even indices are taken, which guarantees the first sliced message is "the other side opening", and the last one falling on
    /// either half of a question and answer still reads. If the script is not long enough it falls back to 0 - never out of range, and never repeating one line just to pad the count.
    static func exchangeStarts(available: Int, taking: Int) -> [Int] {
        guard taking > 0, available >= taking else { return [0] }
        return Array(stride(from: 0, through: available - taking, by: 2))
    }

    /// Time layout: first fix "the newest message is between 4 minutes and 3 hours ago", then walk backwards over heavy-tailed gaps;
    /// if that runs past the 24 hour window **all** gaps are scaled down proportionally (geometric scaling preserves the unevenness instead of flattening it into equal spacing).
    /// Invariants: strictly increasing; the oldest message no earlier than `now - 24h`; the newest no earlier than `now - 4min`.
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

// MARK: - This layer's own disk persistence

/// A snapshot = the plan + the install time + the profile display name **read back from the core at that moment**.
private struct PopopxDecoySnapshot: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var userDisplayName: String?
    var installedAt: Date
    var chats: [PopopxDecoyChat]
}

/// One JSON under `Documents/POPOPXChatCache/`. The whole layer is a single file, so uninstalling = deleting the directory.
///
/// Read and write are both plain nonisolated static functions: `install` runs on the duress path, so the disk write should not be pushed onto the main thread,
/// and the `loadChat` takeover point may come from any thread, so reading the file must also be callable outside the isolation.
private enum PopopxDecoyStore {
    private static let directoryName = "POPOPXChatCache"
    private static let fileName = "layout-prefs.json"

    /// Falls back to the temporary directory when Application Support / Documents cannot be obtained: **better never to land in permanent storage than to `!` a URL that may be
    /// nil** (for the precedent see ProfileStorageManager.swift:143-147 criticising the `FileUtils.swift:59` style of writing).
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
            // Logs only the stage: this sentence contains no nickname, no message body and no identity information.
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
            // Deleted when the version does not match: keeping it would only let old-format content impersonate new-format behaviour.
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

    /// `.secondsSince1970`: message times are this layer's most critical data and must not be at the mercy of locale/timezone formatting.
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

// MARK: - Runtime: turning the snapshot into something that can be drawn

/// The on-screen half of a simulated chat: `ChatInfo` + the `ChatItem` list, already sorted.
///
/// Creating the contact does **not** go through the FFI (impossible, see the file header); instead `Contact.sampleData` is taken and its public mutable fields changed:
/// `contactId` decides the chatId (`"@\(contactId)"`), `profile.displayName` decides the name shown on every screen
/// (when `localAlias == ""` that is exactly what `Contact.displayName` returns).
private struct PopopxDecoyRuntime {
    let chatId: ChatId
    let chatInfo: ChatInfo
    /// Old to new, the same convention as `apiGetChat(.initial)`: the chat list row reads `chatItems.last`.
    let chatItems: [ChatItem]
    /// New to old, the order `ItemsModel.reversedChatItems` wants.
    let reversedItems: [ChatItem]
    let chatStats: ChatStats
    let newestSentAt: Date
}

@MainActor
@Observable
final class PopopxDecoyProfileGenerator {
    static let shared = PopopxDecoyProfileGenerator()

    /// The starting id of simulated contacts, placed in a range a real account will never reach: real contactIds grow upward from 1,
    /// and a collision would give two chats the same id in the list. Hard-coded here rather than hidden inside a formula.
    private static let contactIdBase: Int64 = 90_000_001
    /// The number of itemIds reserved per chat (the longest script has 8 messages, doubled for headroom).
    private static let itemIdBase: Int64 = 90_000_001
    private static let itemsPerChat: Int64 = 1_000

    // MARK: Externally observable state

    /// Whether this layer is **on screen** right now. It is the only observable, and it describes a UI fact, not whether a file exists:
    /// turn the module five switch off, or move to a profile that is no longer the one from install time, and it follows by becoming false.
    private(set) var isInstalled = false

    /// The install time (from the snapshot). The settings page can use it to explain "when this layer was installed".
    private(set) var installedAt: Date?

    /// The number of chats. **Deliberately exposes no nicknames and no message bodies**: this layer's state may be read into a log or a view at any time,
    /// and recording a fake identity as if it were a real one leaves one more trace of "what used to be here".
    private(set) var injectedChatCount = 0

    /// Whether the disk write succeeded. false means this session looks real but after a cold start it falls back to having no fake content -
    /// the rehearsal must be able to see this cell clearly, and "it looked like it worked" is not allowed to paper over it.
    private(set) var survivesRestart = false

    // MARK: Internal

    private var snapshot: PopopxDecoySnapshot?
    private var orderedRuntimes: [PopopxDecoyRuntime] = []
    private var runtimesById: [ChatId: PopopxDecoyRuntime] = [:]
    /// "The disk has already been consulted". It has exactly one write point: a real read from disk, or this process having just installed/uninstalled itself.
    private var diskChecked = false

    private init() {}

    // MARK: Plan

    /// Computes a plan with zero side effects. Module three calls it **before anything is erased** and keeps the result in memory.
    func makePlan(strategy: PopopxDuressRetentionStrategy) -> PopopxDecoyPlan {
        PopopxDecoyContent.makePlan(strategy: strategy, now: Date())
    }

    // MARK: Installation

    /// Installs the plan into the UI.
    ///
    /// `.emptyProfile`, `.retainExistingProfile` (and any `.simulatedDecoy` plan whose content is empty)
    /// **must return as they are**: the semantics of those modes is "do nothing" - a freshly installed empty app needs no fabricated content
    /// to account for itself, while extra contacts and messages are things that need explaining. In that case the layer neither writes to disk nor flips a switch,
    /// so it leaves no trace at all in the sandbox or in UserDefaults, and the forensic surface is exactly what it was before installation.
    func install(_ plan: PopopxDecoyPlan) async {
        guard plan.injectsAnything else {
            return
        }
        // First clear whatever copy of this layer may already exist (when a real self-destruct follows a rehearsal, the previous batch of fake chats must not be left behind).
        removeInjectedChats()
        clearOpenChatIfInjected()

        let snapshot = PopopxDecoySnapshot(
            version: PopopxDecoySnapshot.currentVersion,
            // Bind the name **read back from the core**, not the one I assumed was written in: when the two disagree (the core's
            // displayName normalisation changed it, or the profile was never created at all) the current value wins, otherwise the layer locks itself out.
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
        // The list settles first, then the current screen is filled: yielding one turn in between is what lets SwiftUI draw "a chat appeared" and
        // "opening it shows messages" in the normal order, instead of inserting rows and swapping content inside the same frame.
        await Task.yield()
        assertOpenChatItems()
    }

    /// Uninstalls this layer completely and cleans it up: removes the fake chat rows, clears the fake messages already drawn, deletes its own file,
    /// and flips the master switch back to off. Both the end of a settings-page rehearsal and wanting a clean state after a self-destruct call this one.
    ///
    /// Uninstalling is the only action this layer is allowed to "walk back", so it must clear the state in one pass - keeping half a plan
    /// (file present, switch on, nothing on screen) is the worst intermediate state: the next takeover would redraw it for no visible reason.
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

    /// After a cold start the takeover points load it lazily: no launch hook is needed.
    ///
    /// This is also the layer's only "re-align" entry point: it re-judges the three conditions "the copy on disk + the master switch + the current profile",
    /// adding the fake chats back when they hold and withdrawing them from the screen when they do not. The action of the module five switch
    /// and the end of the settings-page rehearsal should both call it - without that call the switch only takes effect at the next `updateChats`.
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

    /// Withdraws everything this layer left on screen, but **does not touch the file on disk** and does not touch the master switch.
    ///
    /// The distinction is deliberate: conditions not holding only means "this should not be shown right now", not "this fake identity is void".
    /// Change the account back to the name it had at install time, or turn the switch back on, and the same content is usable again;
    /// while "see a mismatch and destroy the evidence" is not this layer's call to make - that is `uninstall()`'s job.
    private func withdrawFromScreens() {
        guard isInstalled else { return }
        removeInjectedChats()
        clearOpenChatIfInjected()
        isInstalled = false
        injectedChatCount = 0
    }

    // MARK: Host wiring points

    /// The takeover point of `loadChat`. Returning true = this screen is this layer's responsibility, and the host **must** return directly,
    /// must not go on to `apiLoadMessages` (it clears `reversedChatItems` and then fetches from the database, which would erase the fake messages).
    ///
    /// `nonisolated async`: the host function is not main-actor isolated, so this hops to the main actor explicitly once,
    /// so that tightening the concurrency checks later does not turn this line into a compile error.
    nonisolated static func hostTakeover(
        chatId: ChatId,
        im: ItemsModel,
        contentTag: MsgContentTag?,
        search: String,
        openAroundItemId: ChatItem.ID?
    ) async -> Bool {
        // Only "the first load of a whole screen" is taken over. Filtering, searching and jumping to a message all ask the core with a real chatId,
        // and this layer has no such view; forcing those through would only produce something even faker.
        guard contentTag == nil, search.isEmpty, openAroundItemId == nil else { return false }
        return await PopopxDecoyProfileGenerator.shared.takeoverFromHost(
            chatId: chatId,
            im: im
        )
    }

    /// The line at the end of `ChatModel.updateChats`: the core has just refreshed the chat list into its "empty account" shape,
    /// and this layer adds the fake chats back. Async onto the main actor: it does not block the caller and does not care which actor the caller is on.
    nonisolated static func hostChatListRefreshed() {
        Task { @MainActor in
            PopopxDecoyProfileGenerator.shared.refreshFromDisk()
        }
    }

    // MARK: The injection itself

    private func takeoverFromHost(chatId: ChatId, im: ItemsModel) -> Bool {
        ensureLoadedFromDisk()
        guard armed, let runtime = runtimesById[chatId] else { return false }
        inject(runtime, into: im)
        return true
    }

    /// Fills the state the way the `.initial` branch of `apiLoadMessages` does (ChatItemsLoader.swift:48-68).
    /// `chatState.clear()` has already set `splits`, `totalAfter`, `unreadAfter` and `unreadAfterNewestLoaded`
    /// to the default group meaning "no earlier messages left to page back to", which is exactly the group this layer needs, so only two non-default fields are assigned.
    private func inject(_ runtime: PopopxDecoyRuntime, into im: ItemsModel) {
        im.reversedChatItems = runtime.reversedItems
        im.chatState.clear()
        im.chatState.unreadAfterItemId = runtime.chatItems.last?.id ?? -1
        im.chatState.unreadTotal = runtime.chatStats.unreadCount
        im.preloadState.clear()
    }

    /// Injection needs all three conditions at once: there is content, the master switch is on, and the current profile is the one from install time.
    ///
    /// The master switch `DEFAULT_ANTI_THEFT_DECOY_ENABLED` is the key of the module five row "simulated smoke bomb content".
    /// Reading it here is what turns that row from "only stored" into "actually in force": switch it off and `armed` becomes false on the spot,
    /// and `refreshFromDisk()` withdraws the fake chats and fake messages from the screen. This layer does not subscribe to UserDefaults change notifications -
    /// the action on that row must call `refreshFromDisk()`, otherwise the effect waits for the next `updateChats`.
    private var armed: Bool {
        guard !runtimesById.isEmpty else { return false }
        guard UserDefaults.standard.bool(forKey: DEFAULT_ANTI_THEFT_DECOY_ENABLED) else { return false }
        guard let bound = snapshot?.userDisplayName,
              let user = ChatModel.shared.currentUser else { return false }
        return user.displayName == bound
    }

    private func ensureLoadedFromDisk() {
        guard !diskChecked else { return }
        // While the profile has not been read out yet **nothing is judged and no flag is lowered**: whether this layer works depends on whether the copy on disk matches the current account,
        // and saying "it does not match" before the account has arrived is defusing the smoke bomb in your own hand.
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
            // A multi-statement closure must write return; the last expression is not returned implicitly.
            return PopopxDecoyRuntime(
                chatId: chatInfo.id,
                chatInfo: chatInfo,
                chatItems: items,
                reversedItems: items.reversed(),
                // All read. This layer has no reporting path for "already read", and leaving an unread dot that can never be cleared
                // looks more fake than having no unread at all.
                chatStats: ChatStats(),
                newestSentAt: chat.newestSentAt
            )
        }
    }

    /// `Contact.localDisplayName` is internal in POPOPXChat and out of reach for the app target,
    /// so only the reachable ones change: `contactId` (decides the chatId) and `profile` (decides the name shown on every screen).
    private static func directChatInfo(contactId: Int64, displayName: String) -> ChatInfo {
        var contact = Contact.sampleData
        contact.contactId = contactId
        var profile = contact.profile
        profile.displayName = displayName
        // `fullName` stays empty: when `fullName != "" && displayName != fullName` ChatInfoToolbar
        // draws an extra line under the name, and there is no second name to give it. `localAlias` must be empty,
        // otherwise `Contact.displayName` starts taking the alias and the assignment above was written for nothing.
        profile.fullName = ""
        profile.localAlias = ""
        contact.profile = profile
        return ChatInfo.direct(contact: contact)
    }

    private func assertChatList() {
        guard armed else { return }
        let model = ChatModel.shared
        // Insert old to new at 0 one after another: after one pass the newest naturally sits at the front of the list and the rest follow in descending time order.
        for runtime in orderedRuntimes.sorted(by: { $0.newestSentAt < $1.newestSentAt }) {
            if model.hasChat(runtime.chatId) { continue }
            model.addChat_(
                Chat(chatInfo: runtime.chatInfo, chatItems: runtime.chatItems, chatStats: runtime.chatStats),
                at: 0
            )
        }
    }

    /// When a simulated chat happens to be the one open (for example reinstalling from the settings page, or the foreground still sitting on that screen during a self-destruct), top the messages up once more.
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
