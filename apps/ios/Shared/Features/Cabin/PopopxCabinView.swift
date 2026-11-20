//
//  PopopxCabinView.swift
//  POPOPX (iOS)
//
//  第四阶段 Tab 3「厢语」—— 这一栏现在有两屏，都在本文件里，都只讲物理射程内的事：广播流、
//  周边节点、总闸；没有公网、没有 relay、没有 SMP。
//  · `PopopxMeshPlazaRootView` = 这一栏的根，落地就是包内 `PopopxMeshUI/MeshPlazaView.swift`
//    那一屏全屏（本轮起它不再是"点左上角才去的一页"）。包内那份保留不动，全仓三个挂载点：
//    这一栏的根、本页的 `.plaza` 路由、`PopopxAddFriendView.swift:121`（`SettingsView.swift:396`
//    那句是注释，它自己的挂载早在 71001954f 摘掉了）。
//  · `PopopxCabinView` = 根顶栏**中间**那一枚胶囊唤起的满高抽屉，本地蓝牙状态的 app 侧重写版。
//    抽屉里那一屏的东西一样没少：总闸、射频、频道三行、周边节点、私聊与配对。（设置中心那一屏第 10 轮
//    起由根那一屏右上角那一枚直接摆出，抽屉顶栏那枚重复入口随之删干净 —— 见下面决定 2。）
//
//  真机第 8 轮 · 任务一（根那一屏顶栏三段式 + 全屏沉浸）：`.topBarLeading` = 回「消息」栏的返回键
//  （这一栏底部那四枚让开了，它是唯一出口，动作经宿主传进来的 `tabSelection` 绑定写 `MainTabView`
//  的选中栏）；`.principal` = 原先站在左上角的旧厢语面板那枚青绿胶囊（周边节点雷达与离线群聊都在
//  里面）；`.topBarTrailing` = 离线组网设置中心，位置不动，第 10 轮字样收成 "Settings"（宽度账见
//  `meshDiscoveryEntry` 上面那一段）。抽屉与它推上去的每一页的顶栏
//  一概不动。底栏那 49pt 的让开由根这一屏的内容自己声明 `.toolbar(.hidden, for: .tabBar)`，见
//  `PopopxMeshPlazaRootView.body` 里那一段的两条理由。
//
//  三条数据来源，全是包里的真对象，本文件不写第二条传输路径：
//  1. `PopopxMeshStateSource.shared.state` —— `radioState / peers / broadcasts / latestBroadcastAt`。
//     `@ObservedObject` 直接看这份镜像；body 里不 `await` 任何东西。
//  2. `BluetoothHealthMonitor`（actor）—— `allNodes()` 是节点表与跳数徽章的唯一来源，在线判定用
//     `PopopxPeerReachability.isReachable(now:radioOn:timeout:)`，窗口引模块 4 自己的常量
//     `PopopxMeshConfig.default.peerReachabilityTimeout`（15 秒；`BluetoothHealthMonitor.swift:63`
//     的 `defaultReachabilityTimeout` 就是它的别名）。actor 读数只在 `.task` 轮询与动作之后做。
//  3. `ManualPairingManager` + `IdentityMappingStore`（两个 actor）—— `allStates()` /
//     `pendingRequests()` / `initiatePairing(with:incognito:)` 给配对事实，`allMappings()` 给「已绑定」事实。
//
//  发包路径逐字照抄 `MeshPlazaView`：广播 = `PopopxMeshOutbound.sendBroadcast(text:)`，对象是
//  `PopopxMeshRuntime.shared.engineBackend`（`Shared/Model/POPOPXAPI.swift:3748`），也就是
//  `PopopxAddFriendView.swift:121-125` 挂载广场时传进去的同一个 backend；截断/上限/本机回声/去重的
//  规则照抄 `PopopxMeshPlazaModel.broadcastDraft()`（`MeshPlazaView.swift:168-186`）、
//  `rebuildPosts(from:)`（`:213-232`）与 `deduped(_:)`（`:255-265`）。昵称写入口 =
//  `PopopxMeshKillSwitch.setNickname(_:)`（包内 `saveNickname()` 最终也就是它）。
//  「点击直接开启蓝牙私聊」= `initiatePairing(with:incognito:)` 发一次离线建联邀请（这是唯一能让一条
//  Noise 私聊会话存在的动作），然后 push 包里那条私聊面 `PopopxMeshPrivateChatView`，四个依赖全部显式
//  给真对象——它的默认参数是 `PopopxMeshEngine.shared` / `.shared` 单例，会让总闸关着的一页顺手把引擎
//  与射频建出来（`POPOPXAPI.swift:3557` 之后那段注释说的就是这件事），所以一个默认值都不走。
//
//  频道命名（裁定；包内是英文 `#mesh`，全仓 `Shared/` 里 `#mesh` 出现 0 次）：
//  - 公共广播频道 = `Copy.hallRow`，第 10 轮起源文是 `#Cabin Hall`（品牌词同一口径走英文，zh 译本仍是
//    「#厢语大厅」）。保留 `#`：它是「一个频道」的视觉记号，不是 `#mesh` 这个词；
//    这条频道是无加密洪泛，只在蓝牙射程内，不经服务器，也不回显给发送者。
//  - 本地加密频道（`Copy.encryptedChannelsRow`）= 本机与单个蓝牙邻居已经建立的 Noise_XX 1:1 会话集合（判据 = 模块 1 有映射行，
//    或模块 3 报 `.paired`）。它走的是 mesh 而不是 SMP，所以整行只有青绿，不出现靛紫（§1.1）。
//
//  颜色纪律：青绿只出现在 mesh 事实的行上；`PopopxToggleRow` 的开关实底是原子库写死的
//  `PopopxPalette.brand`（`PopopxControls.swift:400`），所以总闸那一行不放青色徽标——同一控件里
//  紫青并存就是 §1.1 违规。青色徽章一律带跳数数字（§1.4 第 3 条）。本页那个 120% 签名细节是
//  附近节点的雷达；Reduce Motion 下退化成静态环 + 数字跳数，一次循环动画都不启动（§5）。
//
//  顶栏与设置中心（离线组网入口收口，七个决定）：
//  1. 左上角这一枚有两种去处，按挂法二选一（`leadingBarEntry`）：单独成页时仍是「发现」=
//     `path.append(.plaza)`，进包内那一份 `MeshPlazaView`，挂载写法与 `PopopxAddFriendView.swift:118-128`
//     逐字相同、标题共用同一个 Key（真机第 5 轮要求的就是"两个入口打开完全一致的功能页面"）；
//     作为「厢语」根之上的抽屉时换成收起抽屉 —— 根那一屏就是把广场当首页，抽屉不该再给一条
//     回到把自己唤出来的那一屏的回路。这一枚原先（第 5 轮之前）进的是本页自己写的「发现」页
//     （`PopopxCabinNearbyCard` + `groupsCard` 两张卡），那两张卡一件都没失去入口：雷达在大厅右上角
//     「发现模式」里（`discoveryEntry` 的开关态，读同一份 `nodes`），本机离线群与创建入口在内容区
//     「离线群聊」那一行里（`path.append(.groups)` → `MeshGroupsView`）。大厅本身归内容区
//     「附近频道」卡片 `channelsCard` 的第一行，与这两枚都互不顶掉；`.plaza` 路由与它的登记一起留着。
//  2. 「离线组网设置」= `PopopxCabinMeshSettingsSheet`，三张卡依次是总闸与配对策略、节点身份与
//     真实运行态、离线数据与清除。这四件事原先散在「我」页的离线组网分组与「全部设置」页的厢语卡片里，
//     摘除时逐条等效搬来：`requestFuse(_:)` / `setPairingPolicy(_:)` / `verifiedActivitySnapshot()` /
//     `emergencyWipeAllMappings()`，绑定一个都没换来源，也没有新增第二套状态存储；
//     真机第 10 轮起这张表由**根那一屏**在自己的 `.sheet` 里直接摆出，表里那九格数字的读数者跟着一起
//     搬过去（`PopopxMeshPlazaRootView.refreshMeshSettingsFacts(waitingForSettle:)`，只在表开着的那一段
//     跑）：呈现者与读数者仍然只有一个，只是不再是抽屉。抽屉这一屏顶栏那枚重复入口连同它那一套
//     `showsMeshSettings` / 身份 / 核验读数一起删干净，节点表两边共用 `PopopxCabinNodeFold` 这唯一一处折法。
//  3. 设置中心的视图内聚在本文件末尾，零新增文件、零 `project.pbxproj` 改动（铁律：不脚本改工程文件）；
//  4. 栈由本页自己持有：`NavigationStack(path: $path)` 在这里，`MainTabView` 只放裸的根
//     （本轮起是 `PopopxMeshPlazaRootView()`，它把本页整块压进抽屉，仍然不给外壳包栈）。
//     `path` 若不是绑定在栈上的那一份，四处 `path.append` 一次也推不动，见 `PopopxCabinRoute` 上面那段；
//     这条规则随本轮一起搬进抽屉：抽屉里那一页继续自己持有自己的栈，根栈一条都不碰它。
//  5. 第一轮那句"100% 承接"经真机复查并不成立，四处漏在这张表外面，本轮逐条补回：配对记录页的入口
//     （连同它行尾那枚随熔断改写的状态字）、总开关下面的动态副标题、翻闸后带 settle 窗口的二次核验、
//     配对策略的当前值与它自己的解释句。补回来仍然只经 `PopopxMeshRuntime` 写回包里唯一的那几个对象。
//  6. 配对记录页的入口住在这一张表里，所以它推的是根那一屏自己那条栈：行先收起这张表再 `append`。
//     包里那一页自己不带栈（整张 `List`），而它的开关是 `@AppStorage(PopopxMeshKillSwitch.enabledDefaultsKey)`
//     —— 与 runtime 镜像的同一个 key，所以两处翻的是同一道闸，没有第二份开关。
//  7. 表里新增的唯一一行是射频与权限诊断：读数只认 `BluetoothHealthMonitor` 的 `currentRadioState`，
//     与顶栏胶囊同一个读法（`PopopxTelemetryHeader.swift:177`），档位用词复用
//     `PopopxDualStatusCapsule.words(for:)`（`PopopxTelemetryHeader.swift:391`），一个字的第三种说法都不造。
//     只有档位落在 `unauthorized`/`poweredOff` 时这一行才给"打开系统设置"那一下：闸是好的时候按它
//     只会跳到一个没东西可改的页面。
//
//  本地化：这一屏的每一句源文都是英文原句、原句就是 Key，与 16 个译本目录的约定见下面 `Copy` 里那一节
//  （真机第 10 轮把 Phase 4 那批中文直写整页转成了 Key，屏面上不再有一个中文字符）。注释里的中文是另一轮的事。
//  品牌词同一口径：Key 的源文里写英文 Cabin，「厢语」不再出现在任何一句源文里（`Copy.tabTitle`、
//  `Copy.hallRow`、`cabinPanelEntryHint` 三处随本轮改名，旧 Key 的译本要跟着换）。
//  底栏那一格是另一码事：它住在 `MainTabView.swift:230`，本轮没动，也不归本文件。
//

import Foundation
import SwiftUI
import PopopxMeshKit
import PopopxMeshUI

// MARK: - Push routes

/// 栈由本页自己持有：`path` 必须是**绑定在栈上**的那一份 —— 本页作抽屉挂时也是同一份。
/// 2026-11-20 之前它挂在 `@State` 上、栈却由 `MainTabView` 裸包一层，那几处 `path.append`
/// 因此一次也推不动（绑定不存在）；把栈移进来才接上，第四阶段"消息栏自带栈"是同一写法。
private enum PopopxCabinRoute: Hashable {
    /// 「#厢语大厅」：完整广播流 + 广播输入 + 本机临时昵称。入口在内容区 `channelsCard` 第一行。
    case hall
    /// 包内那一份「厢语附近广场」（`PopopxMeshUI/MeshPlazaView`），与「添加朋友 → 进入厢语发现
    /// 附近群组/频道（BLE Mesh）」推的是同一个视图、同一份标题词条。本轮起这一栏的根直接就是
    /// 那一屏，所以只有单独成页那一档的左上角还会推进这里；登记照旧留着（见上面那条决定 1）。
    case plaza
    /// 本地加密频道：本机已与蓝牙邻居建立的 1:1 加密会话清单。
    case encryptedChannels
    /// 本地加密群聊（包内 `MeshGroupsView`）：群名 + 名单 + 32 字节群密钥只活在这些手机上，
    /// 成员资格由创建者的签名成立，不经服务器、不经中继、也没有口令。
    case groups
    /// 与某一个 mesh 公钥的私聊（包内 `PopopxMeshPrivateChatView`）。
    case privateChat(peerMeshPublicKeyHex: String)
}

// MARK: - Label

/// 公钥的读法：与包内横幅/私聊页同一规则，超过 16 位取前 16 位加省略号
/// （`PopopxMeshBannerModel.shorten`，`ManualPairingBannerView.swift:355`；`PopopxMeshPrivateChatModel
/// .peerLabel` 只是转发到它）。包内那两个宿主都是 `@MainActor` 类，非隔离的值类型里不能同步调，
/// 所以这里逐字复刻同一规则，保证全仓一个公钥只有一种拼法。
private enum PopopxCabinLabel {
    static func abbreviate(_ hex: String) -> String {
        hex.count > 16 ? "\(hex.prefix(16))…" : hex
    }
}

// MARK: - 顶栏那一栏的画法定数

/// 顶栏四枚胶囊共用的两个定数。写在值类型里而不是散在四段 view 代码里：同一栏的淡底必须是同一个
/// 不透明度，四枚各写一个数就是四种"淡青"。
private enum PopopxCabinBar {
    /// 淡一档的青绿底：`mesh` 抽 12% 压在导航条底上，承载 `meshInk` 的字仍过 AA
    /// （全仓这一档淡底的既有写法就是 `tint.opacity(0.10…0.12)`，与徽章胶囊、名片读法同一档）。
    static let softTintOpacity: Double = 0.12
}

// MARK: - Node snapshot

/// 一个周边节点在这一页上的全部事实：模块 4 的可达性 + 镜像的昵称/RSSI + 模块 1 的绑定 + 模块 3 的配对。
/// 值类型，`refresh()` 一次算完；行视图只读它，不再碰 actor。
private struct PopopxCabinNode: Identifiable, Hashable {
    /// 绑定事实的三档，直接来自 `PopopxMeshContactMapping` 的字段。
    enum Binding: Hashable {
        /// `contactId != nil`：这条 mesh 公钥背后是一个真的 POPOPX 联系人。
        case contact
        /// `contactId == nil` 且 `isPending`：离线建联已发出，还没成为联系人。
        case pending
        /// 映射表里没有这一行。
        case none
    }

    let peerIDHex: String
    /// announce 或握手解析出来的 64 位十六进制公钥；nil 时这一台还无法寻址，只能听到它的洪泛。
    let meshPublicKeyHex: String?
    let nickname: String?
    let hopCount: Int
    let lastSeenAt: Date
    let rssi: Int8?
    let isDirect: Bool
    let isReachable: Bool
    let binding: Binding
    let pairingState: MeshPairingState

    var id: String { peerIDHex }

    /// 名字的取法与包内私聊页一致：announce 昵称 → 公钥缩写 → 8 字节线 id 前缀。
    var label: String {
        if let nickname {
            let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        if let meshPublicKeyHex { return PopopxCabinLabel.abbreviate(meshPublicKeyHex) }
        return String(peerIDHex.prefix(8))
    }

    /// 能不能开私聊：没有公钥就组不出会话，`SYS_POPOPX_*` 帧无处可去。
    var canOpenChat: Bool { meshPublicKeyHex != nil }
    var isBound: Bool { binding == .contact }
    var isPaired: Bool {
        if case .paired = pairingState { return true }
        return false
    }
    /// 「本地加密频道」的判据 = 包内私聊页允许发一条消息的判据，逐字同源：模块 3 报 `.paired`
    /// 或者模块 1 里有这一行（`PopopxMeshPrivateChatView.swift:311-314` 的 `peerIsPaired`）。
    var hasEncryptedChannel: Bool { isBound || binding == .pending || isPaired }
}

// MARK: - 节点表的唯一折法

/// 模块 4 的表 + 镜像的 peers 表 + 模块 1 的绑定 + 模块 3 的配对，折成一次算完的一屏值。
///
/// 抽出来只为一条纪律：**全仓只有一套折法**。抽屉那一屏（`PopopxCabinView.refresh()`）与根那一屏的
/// 设置中心（`PopopxMeshPlazaRootView.refreshMeshSettingsFacts(waitingForSettle:)`，真机第 10 轮把表
/// 搬到了那里）读的都是这同一个 `load()`，谁都不许再自己拼一份 —— 两张表数字对不上是这一页最贵的一种错。
/// 只在 `.task` / `onChange` / 动作之后调用，绝不在 `body` 里问 actor。
@MainActor
private enum PopopxCabinNodeFold {
    struct Reading {
        let radio: PopopxBluetoothState
        /// 折的那一刻的总闸状态。调用方要在同一个瞬间上决定要不要清自己那格表，
        /// 不能在 await 之后再回头问 `isFuseOn` —— 中间翻了一次闸，表与判据就说的是两个时刻。
        let fuseOn: Bool
        let nodes: [PopopxCabinNode]
        let requests: [PopopxPairingRequest]
    }

    /// 射频档位先读、读到就回：设置中心那一格诊断行在总闸关着时也要说得出当下的读数，不能被下面
    /// 那个空表挡掉。这一跳只是问 actor 要它已经记着的那个值，不替谁把蓝牙叫醒。
    /// `isUsable` 的出处是 `BluetoothHealthMonitor.swift:204`，所以一次读回来两用，
    /// 诊断行与节点行说的必然是同一时刻的蓝牙。
    static func load() async -> Reading {
        let runtime = PopopxMeshRuntime.shared
        let radio = await runtime.healthMonitor.currentRadioState
        let fuseOn = runtime.isFuseOn
        guard fuseOn else {
            // 总闸关闭：不扫描、不广播、不中继，所以这两格只能是空的。留着旧表就是「看起来还活着」。
            return Reading(radio: radio, fuseOn: false, nodes: [], requests: [])
        }
        let radioOn = radio.isUsable
        let observed = await runtime.healthMonitor.allNodes()
        let states = await runtime.pairing.allStates()
        let requests = await runtime.pairing.pendingRequests()
        let mappings = await runtime.mappingStore.allMappings()

        var pairingByHex: [String: MeshPairingState] = [:]
        pairingByHex.reserveCapacity(states.count)
        for entry in states { pairingByHex[entry.peerMeshPublicKeyHex] = entry.state }

        var bindingByHex: [String: PopopxCabinNode.Binding] = [:]
        bindingByHex.reserveCapacity(mappings.count)
        for row in mappings {
            if row.contactId != nil {
                bindingByHex[row.meshPublicKeyHex] = .contact
            } else if row.isPending {
                bindingByHex[row.meshPublicKeyHex] = .pending
            } else {
                bindingByHex[row.meshPublicKeyHex] = PopopxCabinNode.Binding.none
            }
        }

        // 镜像的 peers 表按 8 字节线 id 提供昵称与 RSSI；模块 4 的表才是跳数与在线的裁判。
        let mirrorPeers = PopopxMeshStateSource.shared.state.peers
        var peerByID: [String: PopopxMeshPeer] = [:]
        for peer in mirrorPeers { peerByID[peer.peerID.hex] = peer }

        let window = PopopxMeshConfig.default.peerReachabilityTimeout
        var built: [PopopxCabinNode] = []
        built.reserveCapacity(observed.count)
        for entry in observed {
            let peer = peerByID[entry.peerIDHex]
            let hex = entry.meshPublicKeyHex ?? peer?.meshPublicKey?.popopxHex
            built.append(
                PopopxCabinNode(
                    peerIDHex: entry.peerIDHex,
                    meshPublicKeyHex: hex,
                    nickname: peer?.nickname,
                    hopCount: entry.hopCount,
                    lastSeenAt: entry.lastSeenAt,
                    rssi: peer?.rssi,
                    isDirect: entry.isDirect,
                    isReachable: entry.isReachable(now: .now, radioOn: radioOn, timeout: window),
                    binding: hex.flatMap { bindingByHex[$0] } ?? PopopxCabinNode.Binding.none,
                    pairingState: hex.flatMap { pairingByHex[$0] } ?? .unlinked
                )
            )
        }
        // 模块 4 没记到的邻居也要出现：镜像的 `peers` 表是连接层的真值。在线判定用与包内私聊页
        // `peerIsInRange`（`PopopxMeshPrivateChatView.swift:317-321`）完全相同的公式——射频可用、
        // 且静默不超过同一个窗口；跳数与静默时长按镜像自己的读数说（本机持有链路时 hopCount = 0）。
        var listed: Set<String> = Set(observed.map(\.peerIDHex))
        for peer in mirrorPeers where !listed.contains(peer.peerID.hex) {
            listed.insert(peer.peerID.hex)
            let hex = peer.meshPublicKey?.popopxHex
            built.append(
                PopopxCabinNode(
                    peerIDHex: peer.peerID.hex,
                    meshPublicKeyHex: hex,
                    nickname: peer.nickname,
                    hopCount: peer.hopCount,
                    lastSeenAt: peer.lastSeenAt,
                    rssi: peer.rssi,
                    isDirect: peer.isDirect,
                    isReachable: radioOn && Date.now.timeIntervalSince(peer.lastSeenAt) <= window,
                    binding: hex.flatMap { bindingByHex[$0] } ?? PopopxCabinNode.Binding.none,
                    pairingState: hex.flatMap { pairingByHex[$0] } ?? .unlinked
                )
            )
        }
        return Reading(radio: radio, fuseOn: true, nodes: sortedForDisplay(built), requests: requests)
    }

    /// 在线的在前，然后跳数近的，最后按听到的时间。`allNodes()` 里被 `sweep()` 清掉之前的旧行不会
    /// 消失，所以每行都还要过一次 `isReachable`，用「超出射程」明说，而不是假装它不在了。
    private static func sortedForDisplay(_ nodes: [PopopxCabinNode]) -> [PopopxCabinNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isReachable != rhs.isReachable { return lhs.isReachable }
            if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.peerIDHex < rhs.peerIDHex
        }
    }
}

/// 根栈上的两跳：左上角那枚「群组」胶囊 → 周边蓝牙 Mesh 群组；设置中心里那一行「配对记录」→
/// 包内配对记录与离线绑定页。
///
/// 刻意不复用 `PopopxCabinRoute`：抽屉里那一页必须继续持有自己的 `path`（见下面那个视图的口径 4 ——
/// 私聊那一跳是发出离线建联邀请之后再推一页，动作 async，只有绑在它自己栈上的 path 在那之后还推得动）。
/// 根栈只登记自己真要去的这两格，不会把抽屉那五 case 的语义一起拖进来。
private enum PopopxMeshPlazaRoute: Hashable {
    case nearbyGroups
    case privacyRecords
}

// MARK: - Tab 3 根（全屏广场 + 满高抽屉里的旧面板）

/// 第四阶段 Tab 3「厢语」的落地页：一进来就是包内那一份全屏 `MeshPlazaView`，旧厢语面板收成中间
/// 那一枚胶囊唤起的满高抽屉，离线组网设置中心由右上角那一枚在**这一屏**直接摆出（真机第 10 轮起
/// 不再先开抽屉再摆表），左上角是回「消息」的返回键。
/// 类型写在本文件而不是新文件（铁律：不脚本改 `project.pbxproj`），与 `PopopxCabinMeshSettingsSheet`
/// 同一个办法。
///
/// 四条挂载口径：
/// 1. 广场按"首页"那一档给两个新参数：`hidesTabBar: false` 说清这一屏的角色是首页、不是推进去的一页
///    （因此离开时不 `stop()`），`keepsRunningWhenHidden: true` 让切栏不再清空广播历史 ——
///    `PopopxMeshPlazaModel.stop()` 会清 `posts`（包内 `MeshPlazaView.swift:159-163`），
///    本机喊出去的话不会因为按了「消息」就收回。⚠️ 本轮起**底部那四枚仍然让开**，但不是这两个参数
///    申请的：底栏的隐藏由本视图在根栈那一屏的内容上单独声明 `.toolbar(.hidden, for: .tabBar)`
///    （见 `body` 里那一段），包内 `hidesTabBar` 只管"这一屏是不是推进去的一页"这一件事。
/// 2. 模型由本视图 `@StateObject` 持有，再走 `MeshPlazaView(model:)`：那条便利 init 每次 body 重算
///    都会 new 一个 `PopopxMeshPlazaModel`，而 `@ObservedObject` 会跟着换成新那一份 —— 首页的 body
///    比推上去的一页重算得勤（开一次抽屉就是两次），换模型等于把时间线换成空的且再没人 `start()`。
///    对象身份要活下来只有 `@StateObject` 这一条路。三个依赖仍然逐字给 `PopopxMeshRuntime` 的真对象
///    （与 `.plaza` 路由、`PopopxAddFriendView.swift:121-125` 同一份），一个默认值都不走 —— 默认值是
///    `PopopxMeshEngine.shared`，总闸关着时也会被它把引擎与射频建出来（文件头那段红线）。
/// 3. 不设标题：这条栏四个槽已经站满（左上角两枚 + 中间那枚青绿胶囊 + 右边一枚），393pt（iPhone 15
///    Pro）上再叠一个居中标题就要开始截断 —— 中间那一槽本轮就是标题的位置，站的是旧厢语面板那枚胶囊。
///    宽度账逐笔写在 `meshDiscoveryEntry` 上面（四枚全算）。这一屏的名字由底栏「厢语」与列表段头
///    `#mesh` 说；`Copy.plazaTitle` 继续在 `.plaza` 那一处用，两处不会是两屏不一样的东西。
/// 4. 抽屉里那一页自己持有 `NavigationStack(path:)`（文件头决定 4），所以整块压在根栈外面：挂成根栈
///    的一页要么两条导航条，要么让那一个文件里四处 `path.append` 全部落空 —— 私聊那一跳是发出离线
///    建联邀请之后再推一页，动作 async，只有绑在它自己栈上的 `path` 在那之后还推得动。
@MainActor
struct PopopxMeshPlazaRootView: View {
    @ObservedObject private var meshRuntime: PopopxMeshRuntime
    @StateObject private var plazaModel: PopopxMeshPlazaModel

    /// `MainTabView` 选中栏的绑定，由宿主在挂载点给（`MainTabView.swift` 那一栏）。
    /// 顶栏全屏沉浸之后，这一栏底下没有任何横切导航，唯一出口就是左上角那枚返回键 —— 它要写的
    /// 就是这一份。走 `@Binding` 而不是新造一个 `@Observable` 路由对象注进环境：`MainTabView` 的
    /// `selection` 本来就是那一份唯一事实（决定 3 的 `onChange(of: chatModel.chatId)` 写的也是它），
    /// 再包一层就是第二个持有者；而 init 必填 ⇒ 少挂一个宿主直接编译不过，比"点了不动"好查
    /// （同 `PopopxSettingsNavTrack` 刻意不给默认值那条理由）。
    @Binding private var tabSelection: PopopxTab

    /// 旧厢语面板那一张满高抽屉（默认档 = 整屏，盖住底部四枚）。
    @State private var showsCabinPanel = false
    /// 「厢语离线组网设置中心」：右上角那一枚直接在这一屏摆出这张表，中间不再经过抽屉。
    @State private var showsMeshSettings = false
    // 表里那九格数字。呈现者搬到这一屏，读数者就跟着搬到这一屏 —— 抽屉顶栏那枚重复入口与它那一套
    // 读数一起删掉，全仓仍然只有一套折法：节点表走 `PopopxCabinNodeFold`（抽屉那一屏读的是同一个
    // 实现），身份三格与核验只在表开着的那一段问。本视图之外没有第二个读数者。
    @State private var meshSettingsNodes: [PopopxCabinNode] = []
    @State private var verifiedSnapshot: PopopxMeshActivitySnapshot?
    @State private var localKeyHex = ""
    @State private var bindingCount = 0
    @State private var queuedCount = 0
    /// 模块 4 亲口报的射频档位；nil = 这一次运行还没读到过任何读数（不替它猜一个"未知"显示）。
    @State private var monitorRadioState: PopopxBluetoothState?
    /// 抹除那一下的回执（清干净了 / 还有几项没清掉）由这一屏的 toast 说，与抽屉那一屏同一个控件。
    @State private var meshSettingsToast = PopopxToastModel()

    /// 表开着时的那一拍。档位与抽屉那一屏同一个 2 秒：模块 4 的静默窗口是 15 秒，2 秒一次足够让
    /// 「最近听到」这类读数不撒谎，又不会把三个 actor 的 hop 变成每秒几十次。
    private static let meshSettingsRefreshInterval: Duration = .seconds(2)

    /// 抽屉里那一页自己的 path —— 根栈不借用它，理由见 `PopopxMeshPlazaRoute` 上面那一段。
    @State private var rootPath: [PopopxMeshPlazaRoute] = []

    @MainActor init(tabSelection: Binding<PopopxTab>) {
        _tabSelection = tabSelection
        let runtime = PopopxMeshRuntime.shared
        _meshRuntime = ObservedObject(wrappedValue: runtime)
        _plazaModel = StateObject(
            wrappedValue: PopopxMeshPlazaModel(
                outbound: runtime.engineBackend,
                source: runtime.stateSource,
                nicknameApplier: runtime.killSwitch
            )
        )
    }

    var body: some View {
        NavigationStack(path: $rootPath) {
            MeshPlazaView(
                model: plazaModel,
                hidesTabBar: false,
                keepsRunningWhenHidden: true
            )
            // 底与另两处挂载同一句（`PopopxCabinView` 的 `.plaza`、`PopopxAddFriendView.swift:127`）：
            // 广场自己不带背景，宿主给一次分组底，三屏才是同一块布。
            .modifier(ThemedBackground(grouped: true))
            // 本轮（真机第 8 轮）：这一栏全屏沉浸 —— 底部那四枚在根这一屏让开，49pt 还给内容。
            // 挂在根栈的这一屏内容上，而不是挂在 `MainTabView` 的 `TabView` 上，两条理由：
            // ① 深度与真机验证过的 `ChatsListView.swift:405` 那一处一致（同一栏、同一栈、同一层内容）
            //    —— 底栏的可见性由 `TabView` 读它**选中那一栏的内容子树**递上来的偏好，写在
            //    `TabView` 自己那一层就在这份读取的外侧，是赌一个没验过的口径；
            // ② 声明在内容这一层，"这一屏可见"就是它的有效期：切到别的栏时这一屏不再可见，偏好
            //    自动收回，另外三栏那一条栏不会被这一栏带走。挂在 `TabView` 上就得自己按 `selection`
            //    算一个值，那又会压到 `ChatsListView.swift:268/275/285/405` 那四处按页声明的 `.hidden`。
            // `hidesTabBar: false` 保持不动：那两个参数说的是这一屏在包里的**角色**（首页 ≠ 推进去的
            // 一页，切栏不得清空广播流），不是底栏开关；底栏这一格现在由宿主自己申请让开。两处不冲突
            // —— 包内 `meshHallTabBarHidden(_:)` 的 `false` 那一档刻意什么都不声明，不写
            // `.toolbar(.visible, for: .tabBar)`（`MeshPlazaView.swift:516-531`），正是为了不把宿主
            // 这一句顶掉。可见性重载本身是 iOS 16 起，app 的地板是 17.0，不需要 gate。
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                // 三段式：左 = 发现（周边离线群组）+ 返回「消息」，中 = 旧厢语面板（周边节点雷达与离线
                // 群聊都在那一屏里），右 = 离线组网设置中心。工具条项仍然只属于声明它的那一层内容，抽屉
                // 与它推上去的每一页有自己的条。四枚的宽度账逐笔写在 `meshDiscoveryEntry` 上面那一段。
                ToolbarItem(placement: .topBarLeading) { meshDiscoveryEntry }
                ToolbarItem(placement: .topBarLeading) { backToChatsEntry }
                ToolbarItem(placement: .principal) { cabinPanelEntry }
                ToolbarItem(placement: .topBarTrailing) { meshSettingsEntry }
            }
            .navigationDestination(for: PopopxMeshPlazaRoute.self) { route in
                switch route {
                case .nearbyGroups:
                    // 与抽屉 `.groups` 那一处（本文件 `PopopxCabinRoute.groups` 的登记）逐字相同：
                    // 同一个 `MeshGroupsView`、同样三个真依赖、同一个标题 Key。两个入口不可能翻出
                    // 两屏不一样的东西。三个依赖不能走默认值：默认是 `PopopxMeshEngine.shared`，
                    // 总闸关着时也会被它把引擎与射频建出来（红线）。
                    MeshGroupsView(
                        outbound: meshRuntime.engineBackend,
                        source: meshRuntime.stateSource,
                        hub: PopopxMeshGroupEventHub.shared
                    )
                    .navigationTitle(Copy.groupsRow)

                case .privacyRecords:
                    // 设置中心里那一行「配对记录」的去处：包内唯一的配对记录与离线绑定页。三个对象
                    // 全部来自 runtime，与抽屉那一屏此前递给它的完全是同一份；它自己不带栈，所以套在
                    // 根栈这一层里（`MeshPrivacySettingsView` 整张 `List`，没有自己的 `NavigationStack`）。
                    MeshPrivacySettingsView(
                        store: meshRuntime.mappingStore,
                        pairing: meshRuntime.pairing,
                        killSwitch: meshRuntime.killSwitch
                    )
                    .navigationTitle(Copy.privacyRecordsRow)
                    .modifier(ThemedBackground(grouped: true))
                }
            }
            .popopxToast(meshSettingsToast)
            .sheet(isPresented: $showsCabinPanel) {
                PopopxCabinView(hostedAsCabinPanel: true)
                    .presentationDragIndicator(.visible)
            }
        }
        // 设置中心挂在外层这一条栈上，与抽屉那一张分属两层内容：两张表各自 present 自己那一张，
        // 同一次事务里连着摆两张表只落地第一张那条限制就不会碰到这一处。
        .sheet(isPresented: $showsMeshSettings) {
            PopopxCabinMeshSettingsSheet(
                fuseOn: meshRuntime.isFuseOn,
                pairingPolicy: meshRuntime.pairingPolicy,
                snapshot: verifiedSnapshot,
                radioState: monitorRadioState,
                nodes: meshSettingsNodes,
                localKeyHex: localKeyHex,
                bindingCount: bindingCount,
                queuedCount: queuedCount,
                onToggleFuse: { meshRuntime.requestFuse($0) },
                onSelectPolicy: { meshRuntime.setPairingPolicy($0) },
                onVerify: { await refreshMeshSettingsVerification(waitingForSettle: false) },
                onWipe: { await clearOfflineIdentity() },
                onOpenPrivacyRecords: {
                    // 先收表再推页：这一行的目的地是栈上的一页，不是第二层模态。
                    showsMeshSettings = false
                    rootPath.append(.privacyRecords)
                },
                onClose: { showsMeshSettings = false }
            )
        }
        // 九格数字的节奏只在表开着的那一段跑：这一栏挂在 `TabView` 上长期存活，无期限的轮询会把
        // 三个 actor 每 2 秒问一遍。表抬起来的那一次带 settle 窗口问核验（`starting`/`stopping`
        // 期间拿到的快照说的是"上一刻"），之后每一拍只问当下。
        .task(id: showsMeshSettings) {
            guard showsMeshSettings else { return }
            await refreshMeshSettingsFacts(waitingForSettle: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meshSettingsRefreshInterval)
                if Task.isCancelled { break }
                await refreshMeshSettingsFacts(waitingForSettle: false)
            }
        }
        // 表开着的时候翻闸：那几百毫秒里读到的运行态最想说实话，带 settle 窗口重问一次。
        .onChange(of: meshRuntime.isFuseOn) { _, _ in
            guard showsMeshSettings else { return }
            Task { @MainActor in await refreshMeshSettingsFacts(waitingForSettle: true) }
        }
    }

    // MARK: 设置中心的事实

    /// 表里那九格数字的唯一一次折法：节点表（射程内 / 经中继 / 最远跳三格读它）、身份三格、真实运行态。
    /// 只在表开着的那一拍与翻闸、抹除之后调用，`body` 一次都不问 actor。
    @MainActor private func refreshMeshSettingsFacts(waitingForSettle: Bool) async {
        let reading = await PopopxCabinNodeFold.load()
        meshSettingsNodes = reading.nodes
        monitorRadioState = reading.radio
        await refreshMeshSettingsIdentityFacts()
        await refreshMeshSettingsVerification(waitingForSettle: waitingForSettle)
    }

    /// 设置中心那三格身份事实：绑定表行数、离线队列条数、本机 mesh 静态公钥。三次 actor hop。
    @MainActor private func refreshMeshSettingsIdentityFacts() async {
        bindingCount = await meshRuntime.mappingStore.allMappings().count
        queuedCount = await meshRuntime.router.pendingMessageCount
        // 引擎没起来时这一格是空串（`PopopxMeshEngineBackend` 不替谁造引擎），而空串不是
        // "公钥没了"——它只是"这台机器还没答过"。所以只在读到真东西时改写，抹除也不动它：
        // 抹除删的是 模块 1 的绑定表与缓存文件，本机自己的静态密钥在 Keychain 的另一个 service 里
        // （`PopopxMeshEngine.swift:120-139`），删了它反而会让对方下次认不出这台。
        let hex = await meshRuntime.engineBackend.localMeshPublicKeyHex
        if !hex.isEmpty { localKeyHex = hex }
    }

    /// 核验一次真实运行态。`waitingForSettle` 时给过渡态最多 5 × 250 ms 的等待窗口。
    @MainActor private func refreshMeshSettingsVerification(waitingForSettle: Bool) async {
        var snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
        if waitingForSettle {
            for _ in 0..<5 where snapshot.phase == .starting || snapshot.phase == .stopping {
                try? await Task.sleep(for: .milliseconds(250))
                snapshot = await meshRuntime.killSwitch.verifiedActivitySnapshot()
            }
        }
        verifiedSnapshot = snapshot
    }

    /// 清除离线身份绑定与本机 mesh 缓存。唯一一次调用是 模块 1 的 `emergencyWipeAllMappings()`：
    /// 它逐行清 Keychain 绑定、删两个开关偏好，并 `removeMeshCacheFiles()` 删掉
    /// `Documents/popopx_mesh/` 里的每一个文件 —— 未确认队列（`unacknowledged_mesh.json`）、
    /// 发件箱与本机昵称都在里面。包里没有任何"只清队列"的公开 API，所以这一格说的是整包删除，
    /// 不假装能只删一半；报告里 `failures` 非空就照实报数，绝不粉饰成"已清除干净"。
    @MainActor private func clearOfflineIdentity() async {
        // 顺序照包内 `MeshPrivacySettingsView.swift:211-214`：先拉闸再删。反过来会让还在跑的
        // 组件把手上的队列重新写回磁盘，那一格"已清除"就是假话。
        if meshRuntime.isFuseOn { await meshRuntime.setFuse(false) }
        let report = await meshRuntime.mappingStore.emergencyWipeAllMappings()
        await refreshMeshSettingsFacts(waitingForSettle: true)
        if report.isClean {
            PopopxHaptics.notice(.success)
            meshSettingsToast.show(Copy.wipeCleanToast, kind: .mesh)
        } else {
            PopopxHaptics.notice(.error)
            meshSettingsToast.show(Copy.wipeFailedToast(report.failures.count), kind: .danger)
        }
    }

    // MARK: 顶栏三个入口

    /// 左上角：回「消息」栏。这一栏全屏沉浸之后，屏幕底下没有任何横切导航，这一枚就是唯一的出口，
    /// 所以它必须一直在、且一眼认得出。画法与抽屉的收起键同档（`cabinPanelCloseEntry`）：中性底、
    /// 只有图标不带文字 —— 这一栏四枚的宽度账逐笔写在 `meshDiscoveryEntry` 上面，返回键那一枚
    /// 只占 35pt 就是这么来的；再给它配一个字就是第四个截断点。`chevron.left` 是系统返回的方向词，
    /// VoiceOver 读 `.accessibilityLabel` 那一句，不读图标。
    private var backToChatsEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            tabSelection = .chats
        } label: {
            Image(systemName: "chevron.left")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.meshInk)
                .accessibilityHidden(true)
                .padding(.horizontal, PopopxMetrics.spaceS)
                .frame(minHeight: PopopxMetrics.minHitTarget)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(Copy.backToMessages))
        .accessibilityIdentifier("popopx.cabin.backToChats")
    }

    /// 左上角第一枚：周边蓝牙 Mesh 群组。
    ///
    /// 「添加朋友 → 更多方式 → 进入厢语发现附近群组/频道（BLE Mesh）」推的是包内 `MeshPlazaView`
    /// （`PopopxAddFriendView.swift:118-128`），而这一栏的根直接就是那一屏（口径 3），从根上再推一次
    /// 就是把自己这一屏推给自己。所以这一枚接的是那条入口缺的另一半 —— 群：同一个包内
    /// `MeshGroupsView`、同一份 `Copy.groupsRow` 标题、抽屉里那一行同样的三个真依赖。
    ///
    /// 画法：与这一栏另两枚同一个骨架（`PopopxMetrics.radiusControl` 底、`PopopxPressButtonStyle`、
    /// `contentShape`、`lineLimit(1)` + `minimumScaleFactor` + `PopopxMetrics.minHitTarget`），底换成
    /// 淡一档的青绿 `mesh.opacity(0.12)` + `meshInk` 字（§"mesh 自己不能裸着承载文字"：`mesh` 在白卡上
    /// 只有 2.98:1，`meshInk` 6.03:1）。刻意不是中间那一枚的实底青绿 —— 一栏里两枚一模一样的青绿胶囊，
    /// 一眼分不出哪个是面板、哪个是群组；淡底把它降到"次要入口"那一档，图标仍是 `person.3.fill`，
    /// 与抽屉内容区「离线群聊」那一行同一个记号、同一个去处。
    ///
    /// 这一栏的宽度账（iPhone 15 Pro 393pt，默认字号；英文字宽是 CoreText 在 SF 15pt（= `PopopxType.meta`
    /// = `.subheadline`）上逐串量出来的 typographic bounds，macOS/iOS 同一款字形，取整；图标按
    /// `.caption` 12pt + `imageScale(.medium)` 估，档位在 11–20pt 之间。英文档 = 四枚里最坏的那一档）。
    /// 可用宽度 = 393 − 导航条左右边距 16×2 = **361pt**，再留同组两枚之间那道 ≈8pt 间距
    /// ⇒ 四枚合计的上限 **≈353pt**：
    /// · 本枚：内边距 8×2 = 16 + 图标 ≈ 20 + 间距 4 + "Groups" 49.9 = **≈ 90pt**
    ///   （zh 档这条 Key 目录里已有值是「群」14.9 → ≈ 55pt）；
    /// · `backToChatsEntry`：内边距 12×2 = 24 + `chevron.left` ≈ 11 = **≈ 35pt**；
    /// · `cabinPanelEntry`（`.principal`）：内边距 8×2 = 16 + 图标 ≈ 13 + 间距 4 + "Cabin" 39.5 = **≈ 73pt**
    ///   （zh 档「厢语」29.8 → ≈ 63pt）；
    /// · `meshSettingsEntry`：内边距 12×2 = 24 + 图标 ≈ 15 + 间距 4 + 圆点 8 + 间距 4 + "Settings" 56.6
    ///   = **≈ 112pt**（zh 档这条 Key 目录里已有值是「设置」29.8 → ≈ 85pt）；
    /// · 合计 90 + 35 + 73 + 112 = **310pt**，加同组那道 8pt = **318 ≤ 361 ⇒ 富余 43pt（12%）**，
    ///   这一份富余就是留给 Dynamic Type 与最长译本的：字号再大一档（约 +20%）整栏就到 372pt，
    ///   越线，所以四枚每一枚都带 `lineLimit(1)` + `minimumScaleFactor(0.85)`，先缩字再让位。
    /// 右边那一枚本轮从「离线组网设置」（"Offline mesh settings" 实测 145.8pt，那一枚就要 201pt）收成
    /// "Settings"：整栏原本已经吃到 389pt，不加这一下就是左上角这枚图标 + 字样无处可放。
    /// 完整说法一个字没丢 —— 屏面上短词，VoiceOver 读 `.accessibilityLabel` 那一句完整的
    /// 「离线组网设置」，表头 `PopopxSheetContainer` 仍是完整那句。
    /// `.fixedSize()` 让本枚在挤的时候守住内在宽度、由 `minimumScaleFactor` 先缩字，
    /// 缩不动才轮到左右让位；去处另有 `.accessibilityHint`。
    private var meshDiscoveryEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            rootPath.append(.nearbyGroups)
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "person.3.fill")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.groupsPill)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PopopxPalette.meshInk)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(
                PopopxPalette.mesh.opacity(PopopxCabinBar.softTintOpacity),
                in: .rect(cornerRadius: PopopxMetrics.radiusControl)
            )
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
            .fixedSize()
        }
        .buttonStyle(PopopxPressButtonStyle())
        // VoiceOver 读的是去处（`Copy.groupsRow` = 推进去那一屏的标题本身），不是屏上那一个短词：
        // 胶囊上只剩 "Groups"，把完整说法放在 label 里，Apple 那条「label 要以可见文字开头」也仍然成立。
        .accessibilityLabel(Text(Copy.groupsRow))
        .accessibilityHint(Text(Copy.meshGroupsHint))
        .accessibilityIdentifier("popopx.cabin.discovery")
    }

    /// 中间（`.principal`）：旧厢语面板 —— 周边节点雷达与离线群聊都在那一屏里。原先站在左上角，
    /// 真机第 8 轮把左上角让给返回键，它挪到中间，青色与图标一个都不改（同一枚入口换位置不换身份）。
    /// 这一槽就是这条栏的"标题位"：整栏四枚的宽度账逐笔写在 `meshDiscoveryEntry` 上面，本枚占 73pt。
    /// `.fixedSize()` 让它在挤的时候**自己缩**而不是被压断：守住内在宽度，`lineLimit(1)` 与
    /// `minimumScaleFactor(0.85)` 再兜一层（大字号档下先缩字，缩不动才轮到左右让位）。
    /// 完整说法在 `.accessibilityHint` 里，VoiceOver 不必挤在这一个词上。
    private var cabinPanelEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            showsCabinPanel = true
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "square.grid.2x2")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.tabTitle)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.spaceXS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
            .fixedSize()
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(Copy.cabinPanelEntryHint))
        .accessibilityIdentifier("popopx.cabin.panel")
    }

    /// 右上角：离线组网设置中心 —— 在这一屏直接摆出 `PopopxCabinMeshSettingsSheet`，不再经过抽屉。
    /// 那颗点是运行态，不是装饰：熔断关着就换成中性色，与表里第一张卡说的同一句话。
    /// 屏面上只有 "Settings" 一个词（宽度账见 `meshDiscoveryEntry` 上面），完整说法在
    /// `.accessibilityLabel` 里，VoiceOver 与表头都读到那一句全的。
    private var meshSettingsEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            showsMeshSettings = true
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "slider.horizontal.3")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Circle()
                    .fill(meshRuntime.isFuseOn ? PopopxPalette.mesh : PopopxPalette.labelHint)
                    .frame(width: PopopxMetrics.spaceXS, height: PopopxMetrics.spaceXS)
                    .accessibilityHidden(true)
                Text(Copy.meshSettingsPill)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
            .fixedSize()
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityLabel(Text(Copy.meshSettingsEntry))
        .accessibilityValue(Text(verbatim: meshRuntime.isFuseOn ? Copy.meshRowOn : Copy.meshRowFusedOff))
        .accessibilityIdentifier("popopx.cabin.root.meshSettings")
    }
}

// MARK: - Tab page

@MainActor
struct PopopxCabinView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// 熔断真值与四个 actor 句柄都在 runtime 上；`PopopxMeshStateSource` 是包里的镜像单例。
    @ObservedObject private var meshRuntime: PopopxMeshRuntime
    @ObservedObject private var meshState: PopopxMeshStateSource

    @State private var toast = PopopxToastModel()
    @State private var path: [PopopxCabinRoute] = []
    @State private var nodes: [PopopxCabinNode] = []
    @State private var pendingRequests: [PopopxPairingRequest] = []
    /// 本机发出去的广播：mesh 不会把洪泛回声给发送者，所以这一份要自己留着（包内同款）。
    @State private var localBroadcasts: [PopopxMeshPlazaPost] = []
    @State private var nicknameText = ""
    @State private var showsPairingRequests = false
    /// 正在开私聊的那一台的 `peerIDHex`：只让那一行显示进度，不把整页变灰。
    @State private var openingNodeID: String?

    /// 本机已加入的离线群，来自 `PopopxGroupStore` 的一次本地读。顶栏「发现」那一页的群表、
    /// 「离线群聊」那一行的数值格，读的都是这一份；总闸关着时引擎从未存在，这里就是空表。
    @State private var groups: [PopopxMeshGroup] = []

    /// 轮询节奏：模块 4 的静默窗口是 15 秒，2 秒一次足够让「最近听到」这类读数不撒谎，
    /// 又不会把三个 actor 的 hop 变成每秒几十次。
    private static let refreshInterval: Duration = .seconds(2)

    /// 挂法：`true` = 作为「厢语」根之上的满高抽屉。左上角那一枚随之从"进广场"换成"收起抽屉"
    /// （`leadingBarEntry`），其余一张不少。`false` = 单独成页，即预览与本轮之前的那一档。
    private let hostedAsCabinPanel: Bool

    @MainActor init(hostedAsCabinPanel: Bool = false) {
        _meshRuntime = ObservedObject(wrappedValue: PopopxMeshRuntime.shared)
        _meshState = ObservedObject(wrappedValue: PopopxMeshStateSource.shared)
        self.hostedAsCabinPanel = hostedAsCabinPanel
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    header
                    statusCard
                    channelsCard
                    nearbyCard
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.top, PopopxMetrics.spaceS)
                .padding(.bottom, PopopxMetrics.space2XL)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PopopxPalette.base)
            .navigationTitle(Copy.tabTitle)
            .toolbar {
                // 左上角 = 广场 / 收起抽屉，按挂法二选一，这一栏只有它一枚。离线组网设置中心不在
                // 这一栏 —— 它由根那一屏右上角那一枚直接摆出（真机第 10 轮），这里再放一枚就是同一张
                // 表两个入口。工具条项只属于声明它的那一层内容，推进大厅或私聊页就由那一页自己的条接管。
                ToolbarItem(placement: .topBarLeading) { leadingBarEntry }
            }
            .navigationDestination(for: PopopxCabinRoute.self) { route in
                switch route {
                case .hall:
                    PopopxCabinHallView(
                        fuseOn: meshRuntime.isFuseOn,
                        radioState: radioState,
                        nickname: $nicknameText,
                        posts: mergedBroadcastPosts,
                        nodes: nodes,
                        openingNodeID: openingNodeID,
                        directPeerCount: directPeerCount,
                        onBroadcast: { text in await sendBroadcast(text) },
                        onSaveNickname: { await saveNickname() },
                        onTurnOnFuse: {
                            await meshRuntime.setFuse(true)
                            await refresh()
                        },
                        onOpenChat: { node in await openBluetoothChat(with: node) },
                        onSendFriendRequest: { node in await sendFriendRequest(to: node) },
                        onRescan: { await refresh() }
                    )
                    .navigationTitle(Copy.hallRow)

                case .plaza:
                    // 单独成页时顶栏左上角的去处（抽屉那一档不再给它回路，见 `leadingBarEntry`），
                    // 留着是因为 `PopopxCabinRoute.plaza` 与这一处登记是一个整体。这一整块与
                    // `PopopxAddFriendView.swift:118-128` 逐字相同：同一个 `MeshPlazaView`、同样三个
                    // 依赖全给 runtime 的真对象（一个默认值都不走）、同一个标题 Key、同一个
                    // `ThemedBackground(grouped: true)`；两个参数走默认值，所以这一屏仍然按"推进去的一页"
                    // 那一档行事（隐藏四枚 Tab、离开即清）。两个入口因此不可能翻出两屏不一样的东西
                    // —— 真机第 5 轮要求的就是这一条。
                    MeshPlazaView(
                        outbound: meshRuntime.engineBackend,
                        source: meshRuntime.stateSource,
                        killSwitch: meshRuntime.killSwitch
                    )
                    .navigationTitle(Copy.plazaTitle)
                    .modifier(ThemedBackground(grouped: true))

                case .encryptedChannels:
                    PopopxCabinChannelsView(
                        fuseOn: meshRuntime.isFuseOn,
                        nodes: nodes,
                        openingNodeID: openingNodeID,
                        pendingCount: pendingRequests.count,
                        onOpenChat: { node in await openBluetoothChat(with: node) },
                        onShowPending: { showsPairingRequests = true }
                    )
                    .navigationTitle(Copy.encryptedChannelsRow)

                case .groups:
                    // 包内唯一的离线群聊面（创建者签名的群 + 群消息）。三个依赖全给真对象：默认值是
                    // `PopopxMeshEngine.shared`，总闸关着时也会被它建出来，红线不允许。`engineBackend`
                    // 在引擎从未起来时答"没有签名身份"，这一页就只显示空列表，不会凭空建出一个群。
                    MeshGroupsView(
                        outbound: meshRuntime.engineBackend,
                        source: meshRuntime.stateSource,
                        hub: PopopxMeshGroupEventHub.shared
                    )
                    .navigationTitle(Copy.groupsRow)

                case let .privateChat(peerMeshPublicKeyHex):
                    // 包里唯一的那条 1:1 离线私聊面。四个依赖全给真对象，一个默认值都不走：默认值是
                    // `PopopxMeshEngine.shared` / `PopopxMeshKillSwitch.shared`，总闸关着时也会被建出来。
                    PopopxMeshPrivateChatView(
                        peerMeshPublicKeyHex: peerMeshPublicKeyHex,
                        outbound: meshRuntime.engineBackend,
                        source: meshRuntime.stateSource,
                        store: meshRuntime.mappingStore,
                        killSwitch: meshRuntime.killSwitch
                    )
                    .navigationTitle(Copy.privateChatTitle)
                }
            }
            .sheet(isPresented: $showsPairingRequests) {
                PopopxCabinPairingRequestsSheet(
                    requests: pendingRequests,
                    nodes: nodes,
                    onApprove: { request in await approve(request) },
                    onDecline: { request in await decline(request) }
                )
            }
            .popopxToast(toast)
            .task {
                // 只有总闸开着才订阅镜像：`PopopxMeshStateSource` 是 kill switch 的组件，关着时由它启停；
                // 本页在关闭态去 `start()` 会留下「开关关着但有人在订阅」的状态。
                if meshRuntime.isFuseOn { meshState.start() }
                nicknameText = currentNickname()
                await refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval)
                    if Task.isCancelled { break }
                    await refresh()
                }
            }
            // 总闸一翻就重算：OFF 要清掉节点表（模块 4 的表在 stop 之后仍然留着旧数据，继续显示就是撒谎），
            // ON 要立刻订阅并读一次，不等下一个 2 秒。
            .onChange(of: meshRuntime.isFuseOn) { _, isOn in
                nicknameText = currentNickname()
                Task { @MainActor in
                    if isOn { meshState.start() }
                    await refresh()
                }
            }
            // 射频刚翻面时镜像里只有广播，可达性还没算出来；补一次 actor 读数。
            .onChange(of: meshState.state.radioState) { _, _ in
                Task { @MainActor in await refresh() }
            }
        }
    }

    // MARK: 顶栏那一枚入口

    /// 左上角这一枚按挂法二选一，位置与尺寸同一档，换的只是去处与配色：抽屉不该给一条回到
    /// "把自己唤出来的那一屏"的回路（那一屏就是这一栏的根），所以抽屉那一档换成收起。
    @ViewBuilder private var leadingBarEntry: some View {
        if hostedAsCabinPanel {
            cabinPanelCloseEntry
        } else {
            nearbyDiscoveryEntry
        }
    }

    /// 抽屉的收起键。中性底：它是一条导航动作，不是一条 mesh 事实，青色只给内容区那些 mesh 事实
    /// 那一档（§1.1）。抽屉还有 `.presentationDragIndicator(.visible)` 与下滑两条退路。
    private var cabinPanelCloseEntry: some View {
        Button {
            PopopxHaptics.selection()
            dismiss()
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "xmark")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Text(Copy.close)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityIdentifier("popopx.cabin.panelClose")
    }

    /// 单独成页时左上角「发现」：包内那一份厢语附近广场，与「添加朋友 → 进入厢语发现附近群组/频道」
    /// 同一屏。真机第 3 轮之前这一枚写的是"附近厢语广场"、按下去进大厅；大厅归内容区那一行之后，
    /// 这一枚改开广场页。第 5 轮把它自己的那屏「发现」页（节点雷达 + 本机群两张卡）撤了：那两张卡
    /// 在别处都还在 —— 雷达在大厅右上角「发现模式」里，群在内容区「离线群聊」那一行里，
    /// 而广场页本身同时有广播流与周边节点，两个入口不该给出两个去处。
    /// 本轮起这一栏的根直接就是那一屏，所以这一枚只在单独成页（默认挂法）时出现。
    private var nearbyDiscoveryEntry: some View {
        Button {
            PopopxHaptics.impact(.light)
            path.append(.plaza)
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "radar")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.discoveryEntry)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityHint(Text(Copy.plazaEntryHint))
        .accessibilityIdentifier("popopx.cabin.discovery")
    }

    // MARK: 派生事实（纯计算，不碰 actor）

    /// 跳数上限：引 `PopopxMeshConfig` 的常量，不写死 7（§1.1 记的就是这条出处）。
    private var relayHopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }
    /// 广播实际用的 TTL 上限，同样是常量。
    private var broadcastTTL: Int { Int(PopopxMeshConfig.default.ttlDefault) }
    /// 在线判定的静默窗口，模块 4 的同一个常量。
    private var reachabilityWindow: TimeInterval { PopopxMeshConfig.default.peerReachabilityTimeout }

    private var radioState: PopopxBluetoothState { meshState.state.radioState }
    private var radioUsable: Bool { meshState.state.radioState.isUsable }
    private var directPeerCount: Int { meshState.state.peers.filter(\.isDirect).count }

    /// 大厅的一屏流：mesh 收到的广播 + 本机发出去的回声，按全局 `messageId` 严格去重、旧的在前。
    /// 字段映射照抄 `PopopxMeshPlazaModel.rebuildPosts(from:)`，去重规则照抄 `deduped(_:)`。
    private var mergedBroadcastPosts: [PopopxMeshPlazaPost] {
        var incoming: [PopopxMeshPlazaPost] = []
        incoming.reserveCapacity(meshState.state.broadcasts.count + localBroadcasts.count)
        for message in meshState.state.broadcasts where !message.isControlSignal {
            incoming.append(
                PopopxMeshPlazaPost(
                    id: message.messageID,
                    text: message.text,
                    timestamp: message.timestamp,
                    author: .neighbour(
                        nickname: message.senderNickname,
                        peerIDHex: message.senderPeerIDHex ?? message.messageID
                    ),
                    hopCount: message.channel.hopCount ?? 0
                )
            )
        }
        incoming.append(contentsOf: localBroadcasts)

        var seen: Set<String> = []
        var kept: [PopopxMeshPlazaPost] = []
        for post in incoming where seen.insert(post.id).inserted {
            kept.append(post)
        }
        return kept.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(Copy.pageTitle)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
            Text(Copy.pageExplainer(relayHopCap, broadcastTTL))
                .font(PopopxType.secondary)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 总闸 + 射频 + 最近一次在本机射程内听到广播的时间。三行都是事实，没有装饰。
    private var statusCard: some View {
        PopopxSectionCard(
            Copy.statusTitle,
            footnote: meshRuntime.isFuseOn
                ? Copy.statusFootnote(Int(reachabilityWindow))
                : Copy.fuseOffFootnote
        ) {
            // 这一行不放青色徽标：`PopopxToggleRow` 的开关实底是原子库写死的 brand（紫），
            // 同控件里紫青并存就是 §1.1 违规。mesh 的青色语义在下面两行与雷达上说话。
            PopopxToggleRow(
                Copy.fuseRowTitle,
                note: meshRuntime.isFuseOn ? Copy.fuseOnNote : Copy.fuseOffNote,
                isOn: fuseBinding
            )
            rowSeparator
            HStack(spacing: PopopxMetrics.spaceS) {
                PopopxIconBadgeView(
                    systemName: radioUsable ? "antenna.radiowaves.left.and.right" : "wifi.slash",
                    tint: radioUsable ? .mesh : .neutral
                )
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(Copy.radioWords(radioState))
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                    Text(radioFootnote)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
            }
            .padding(.vertical, PopopxMetrics.spaceXS)
            .popopxAnimation(PopopxSpring.fluid, value: radioState, reduceMotion: reduceMotion)
        }
    }

    private var radioFootnote: String {
        guard meshRuntime.isFuseOn else { return Copy.fuseOffRadioNote }
        guard let latest = meshState.state.latestBroadcastAt else { return Copy.noBroadcastYet }
        return Copy.lastBroadcastWords(PopopxCabinClock.since(latest))
    }

    /// 熔断只有一个落点：`killSwitch.setEnabled(_:)`（POPOPXAPI.swift:3883 的 `setFuse` 是它唯一的生产调用者）。
    /// Binding 的 setter 不能 await，所以开关一律走同步的 `requestFuse(_:)`（:3771，它转手起一个 `setFuse`）；
    /// 而本页两个"开启总闸"按钮（:181、:417）本来就在 async 上下文里，直接 `await setFuse(true)` 再刷新。
    /// 两条路都不是本页自己写 `UserDefaults`，否则会出现「开关是关的但蓝牙还在跑」或者反过来。
    private var fuseBinding: Binding<Bool> {
        Binding(
            get: { meshRuntime.isFuseOn },
            set: { meshRuntime.requestFuse($0) }
        )
    }

    // MARK: 两个频道入口

    private var channelsCard: some View {
        PopopxSectionCard(Copy.channelsTitle, footnote: Copy.channelsFootnote) {
            PopopxPickerRow(
                Copy.hallRow,
                value: hallRowValue,
                systemImage: "bubble.left.and.bubble.right.fill",
                tint: .mesh
            ) {
                path.append(.hall)
            }
            rowSeparator
            PopopxPickerRow(
                Copy.encryptedChannelsRow,
                value: Copy.encryptedChannelsValue(channelNodes.count),
                systemImage: "lock.circle.fill",
                tint: .mesh
            ) {
                path.append(.encryptedChannels)
            }
            rowSeparator
            // 离线群聊的数值只来自 `PopopxGroupStore` 的一次本地读；总闸关着时引擎从未存在，那一格
            // 说的就是既有的"总闸关闭"，不另造第三种说法。
            PopopxPickerRow(
                Copy.groupsRow,
                value: meshRuntime.isFuseOn ? Copy.groupsValue(groups.count) : Copy.fuseOffValue,
                systemImage: "person.3.fill",
                tint: .mesh
            ) {
                path.append(.groups)
            }
        }
    }

    private var hallRowValue: String {
        guard meshRuntime.isFuseOn else { return Copy.fuseOffValue }
        let posts = mergedBroadcastPosts.count
        return posts == 0 ? Copy.hallEmpty : Copy.hallCount(posts)
    }

    private var channelNodes: [PopopxCabinNode] { nodes.filter(\.hasEncryptedChannel) }
    private var strangerNodes: [PopopxCabinNode] { nodes.filter { !$0.hasEncryptedChannel } }

    // MARK: 周边节点（本页唯一的 120% 细节）

    /// 这一屏整块交给 `PopopxCabinNearbyCard`：大厅的「发现模式」要挂的是同一个视图、同一份 `nodes`，
    /// 在这里留第二份写法就等于允许两处说不一样。
    private var nearbyCard: some View {
        PopopxCabinNearbyCard(
            nodes: nodes,
            fuseOn: meshRuntime.isFuseOn,
            radioState: radioState,
            directPeerCount: directPeerCount,
            openingNodeID: openingNodeID,
            onOpenChat: { node in await self.openBluetoothChat(with: node) },
            onRescan: { await refresh() },
            onTurnOnFuse: {
                await meshRuntime.setFuse(true)
                await refresh()
            }
        )
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }

    // MARK: - actor 读数

    /// 把这一屏要的读数折成一屏值。只在 `.task` / `onChange` / 动作之后调用，绝不在 body 里。
    /// 节点表与配对请求两格走 `PopopxCabinNodeFold` —— 根那一屏的设置中心读的是同一个折法，
    /// 全仓只有这一处（那一屏只多要一份 `groups` 以外的数，都在它自己那边）。
    @MainActor private func refresh() async {
        let reading = await PopopxCabinNodeFold.load()
        nodes = reading.nodes
        pendingRequests = reading.requests
        // 总闸关闭：不扫描、不广播、不中继，所以这一页也不许留任何「看起来还活着」的旧表 ——
        // `load()` 在这种情形下已经答空表与空请求，这里只补它不管的那一格群表。
        guard reading.fuseOn else {
            groups = []
            return
        }
        // 群的数量来自 `PopopxGroupStore` 的一次本地读，不碰射频；引擎从未起来时后端直接答空表，
        // 于是这一格读到的 0 与"这台手机还没有群"是同一件事。
        groups = await meshRuntime.engineBackend.meshGroups()
    }

    // MARK: - 动作

    /// 「点击直接开启蓝牙私聊」的全部含义：先经模块 3 发一次离线建联邀请（唯一能让一条 Noise 私聊
    /// 会话存在的动作），再把包里那条私聊页压进栈。每条失败都有中文实话说出来；只有「这个公钥还
    /// 解析不出来」和「邀请链接本身不合法」两种情况不进私聊页——那里除了失败说明没有别的东西。
    @MainActor private func openBluetoothChat(with node: PopopxCabinNode) async {
        guard meshRuntime.isFuseOn else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.fuseOffToast, kind: .danger)
            return
        }
        guard let hex = node.meshPublicKeyHex else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.noKeyToast(node.label), kind: .danger)
            return
        }
        guard openingNodeID == nil else { return }
        openingNodeID = node.id
        defer { openingNodeID = nil }

        if node.isPaired {
            // 模块 3 已经证明配对：不再重发邀请（`initiatePairing` 对已配对会抛 `.alreadyPaired`），直接进会话。
            path.append(.privateChat(peerMeshPublicKeyHex: hex))
            return
        }

        var refusedWithoutSession = false
        do {
            _ = try await meshRuntime.pairing.initiatePairing(with: hex, incognito: false)
            PopopxHaptics.notice(.success)
            toast.show(Copy.pairingSentToast(node.label), kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            toast.show(Copy.pairingWords(for: pairingError, label: node.label), kind: .danger)
            switch pairingError {
            case .peerKeyRejected, .inviteLinkRejected:
                refusedWithoutSession = true
            case .alreadyPaired, .declinedRecently, .requestUnknown, .requestSuperseded,
                 .sendFailed, .offlineBridge, .mappingStoreFailed:
                // 会话仍然值得打开：私聊页自己会重读绑定与配对证据，并把发不出去的原因逐条说清楚。
                break
            }
        }
        await refresh()
        guard !refusedWithoutSession else { return }
        path.append(.privateChat(peerMeshPublicKeyHex: hex))
    }

    /// 大厅里点说话人名字的第二条出口：只发一次离线建联邀请，不把私聊页压进栈。调的还是模块 3 那一个
    /// `initiatePairing(with:incognito:)` —— 全 app 只有这一条路能让一条离线好友关系存在，所以这里
    /// 不写第二份"加好友"实现；两条路的每一句失败回执也是同一批词条，不会两处说两套。
    @MainActor private func sendFriendRequest(to node: PopopxCabinNode) async {
        guard meshRuntime.isFuseOn else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.fuseOffToast, kind: .danger)
            return
        }
        guard let hex = node.meshPublicKeyHex else {
            PopopxHaptics.notice(.warning)
            toast.show(Copy.noKeyToast(node.label), kind: .danger)
            return
        }
        do {
            _ = try await meshRuntime.pairing.initiatePairing(with: hex, incognito: false)
            PopopxHaptics.notice(.success)
            toast.show(Copy.pairingSentToast(node.label), kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            toast.show(Copy.pairingWords(for: pairingError, label: node.label), kind: .danger)
        }
        await refresh()
    }

    /// 大厅的发送。语义逐字照抄 `PopopxMeshPlazaModel.broadcastDraft()`：先截断到上限，
    /// 无论成败本机都留一行（洪泛不回声给发送者），失败只把一句话交回大厅显示。
    @MainActor private func sendBroadcast(_ raw: String) async -> PopopxMeshSendFailure? {
        let text = String(raw.prefix(PopopxMeshPlazaModel.maxDraftCharacters))
        var failure: PopopxMeshSendFailure?
        do {
            try await meshRuntime.engineBackend.sendBroadcast(text: text)
        } catch let sendError {
            PopopxMeshLog.route.warning(
                "📡 Cabin hall broadcast rejected: \(String(describing: sendError.failure), privacy: .public)"
            )
            failure = sendError.failure
        }
        appendLocalBroadcast(text)
        return failure
    }

    private func appendLocalBroadcast(_ text: String) {
        guard !text.isEmpty else { return }
        var posts = localBroadcasts
        posts.append(
            PopopxMeshPlazaPost(
                id: "local:\(UUID().uuidString.lowercased())",
                text: text,
                timestamp: .now,
                author: .local,
                hopCount: 0
            )
        )
        // 上限与包内状态镜像同一个常量，超出的从头部丢。
        if posts.count > PopopxMeshStateSource.defaultCapacity {
            posts.removeFirst(posts.count - PopopxMeshStateSource.defaultCapacity)
        }
        localBroadcasts = posts
    }

    private func currentNickname() -> String {
        meshRuntime.killSwitch.nickname
            ?? PopopxMeshNicknameStore().read()
            ?? ""
    }

    /// 昵称唯一写入口 = 熔断开关自己（它 clamp、写沙盒文件、发布 `nickname`，开着时顺带重启本机 mesh）。
    @MainActor private func saveNickname() async {
        await meshRuntime.killSwitch.setNickname(nicknameText)
        nicknameText = currentNickname()
        PopopxHaptics.notice(.success)
        toast.show(Copy.nicknameSavedToast, kind: .mesh)
    }

    @MainActor private func approve(_ request: PopopxPairingRequest) async {
        let label = PopopxCabinLabel.abbreviate(request.peerMeshPublicKeyHex)
        do {
            _ = try await meshRuntime.pairing.approve(request, incognito: false)
            PopopxHaptics.notice(.success)
            toast.show(Copy.approveToast, kind: .mesh)
        } catch let pairingError {
            PopopxHaptics.notice(.error)
            toast.show(Copy.pairingWords(for: pairingError, label: label), kind: .danger)
        }
        await refresh()
    }

    @MainActor private func decline(_ request: PopopxPairingRequest) async {
        // `decline` 不抛：它只把请求丢掉并记下 60 秒冷却（`ManualPairingManager.swift:229-235`）。
        await meshRuntime.pairing.decline(request)
        PopopxHaptics.impact(.light)
        toast.show(Copy.declineToast, kind: .mesh)
        await refresh()
    }
}

// MARK: - 周边节点那一屏（雷达 + 逐台行）

/// 「周边 1–N 跳活跃设备」整屏：雷达、溢出说明、总闸关着时那一个真的开启按钮、逐台行。
///
/// 抽成一个视图而不是在两处各写一遍，是为了大厅的「发现模式」——它要挂的就是这一屏，节点表仍然只有
/// 宿主折出来的那一份（`PopopxCabinNode`），大厅不自建第二份列表。跳数上限、TTL、静默窗口、密集网络
/// 阈值这四件事是 `PopopxMeshConfig` 的常量，所以视图自己引，不由调用方传数（传了就等于允许两处传歪）。
@MainActor
private struct PopopxCabinNearbyCard: View {
    let nodes: [PopopxCabinNode]
    let fuseOn: Bool
    /// 射频档位由宿主给（镜像的那一份），不在这里另问一次单例：两处问，就会有两处说不一样的时候。
    let radioState: PopopxBluetoothState
    /// 直连邻居数取镜像的 `peers` 表（连接层的真值），不是这张表折出来的节点行，所以只能由宿主给。
    let directPeerCount: Int
    let openingNodeID: String?
    let onOpenChat: (PopopxCabinNode) async -> Void
    let onRescan: () async -> Void
    let onTurnOnFuse: () async -> Void

    /// 雷达一屏最多画这么多个点；多出来的仍然全列在下面的行里，一个都不藏。
    static let markerLimit = 12

    private var radioUsable: Bool { radioState.isUsable }
    private var hopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }
    private var broadcastTTL: Int { Int(PopopxMeshConfig.default.ttlDefault) }
    private var denseHopCap: Int { Int(PopopxMeshConfig.default.denseBroadcastTtlCap) }
    private var highDegreeThreshold: Int { PopopxMeshConfig.default.highDegreeThreshold }
    private var reachabilityWindow: TimeInterval { PopopxMeshConfig.default.peerReachabilityTimeout }

    var body: some View {
        PopopxSectionCard(Copy.nearbyTitle(hopCap), footnote: footnote) {
            PopopxCabinRadar(
                nodes: nodes,
                hopCap: hopCap,
                markerLimit: Self.markerLimit,
                scanning: fuseOn && radioUsable
            )
            .padding(.bottom, nodes.count > Self.markerLimit ? PopopxMetrics.spaceXS : PopopxMetrics.spaceM)
            if nodes.count > Self.markerLimit {
                Text(Copy.radarOverflow(nodes.count, Self.markerLimit))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, PopopxMetrics.spaceXS)
            }

            if !fuseOn {
                // 总闸关着就老实说没有扫描：这一屏只剩一个真的、能干活的开启按钮。
                PopopxButton(Copy.fuseTurnOn, systemImage: "antenna.radiowaves.left.and.right") {
                    await onTurnOnFuse()
                }
            } else if nodes.isEmpty {
                emptyBlock
            } else {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    PopopxCabinNodeRow(
                        node: node,
                        busy: openingNodeID == node.id,
                        open: { await onOpenChat(node) }
                    )
                    if index < nodes.count - 1 { rowSeparator }
                }
            }
        }
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
            Text(radioUsable ? Copy.nearbyEmptyScanning : Copy.radioWords(radioState))
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PopopxButton(Copy.rescan, systemImage: "arrow.clockwise", role: .secondary, fullWidth: false) {
                PopopxHaptics.impact(.light)
                await onRescan()
            }
        }
    }

    private var footnote: String {
        guard fuseOn else { return Copy.fuseOffFootnote }
        if directPeerCount > highDegreeThreshold {
            return Copy.denseNetworkNote(highDegreeThreshold, denseHopCap)
        }
        return Copy.nearbyFootnote(
            Int(reachabilityWindow),
            Int(PopopxMeshReachEstimate.metresPerHop),
            broadcastTTL,
            PopopxCabinClock.metres(PopopxMeshReachEstimate.metres(hops: broadcastTTL))
        )
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 雷达（本页的签名细节）

/// 周边节点的同心雷达。静态部分是「环 + 数字跳数」，动的那圈只是一道由内向外的青色脉冲。
/// Reduce Motion 下只画静止环与数字，一次循环动画都不启动（§5 对雷达/脉冲类动画的明确要求）。
@MainActor
private struct PopopxCabinRadar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let nodes: [PopopxCabinNode]
    let hopCap: Int
    let markerLimit: Int
    let scanning: Bool

    @State private var pulseOutward = false

    /// 尺寸只用 token 表达：一边 = 48 × 3。
    private static let side: CGFloat = PopopxMetrics.space2XL * 3
    private static let dotSide: CGFloat = PopopxMetrics.spaceM + PopopxMetrics.space2XS

    var body: some View {
        ZStack {
            rings
            if scanning && !reduceMotion {
                pulse
            }
            markers
            core
        }
        .frame(width: Self.side, height: Self.side)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.radarLabel(onlineCount, nodes.count))
        .popopxAnimation(PopopxSpring.fluid, value: nodes.count, reduceMotion: reduceMotion)
        .onAppear { startPulse() }
        .onChange(of: scanning) { _, isScanning in
            if isScanning {
                startPulse()
            } else {
                pulseOutward = false
            }
        }
    }

    private var onlineCount: Int { nodes.filter(\.isReachable).count }
    private var shownNodes: [PopopxCabinNode] { Array(nodes.prefix(markerLimit)) }

    /// 三圈同心环：线宽用 §4 的 `stroke`（1.5pt），越外圈越实，最外一圈就是跳数上限那一圈。
    private var rings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(
                        PopopxPalette.mesh.opacity(0.16 + Double(index) * 0.10),
                        lineWidth: PopopxMetrics.stroke
                    )
                    .padding(Self.side * (0.055 + 0.135 * CGFloat(2 - index)))
            }
        }
    }

    private var pulse: some View {
        Circle()
            .strokeBorder(PopopxPalette.mesh, lineWidth: PopopxMetrics.stroke)
            .scaleEffect(pulseOutward ? 1 : 0.18)
            .opacity(pulseOutward ? 0.06 : 0.6)
    }

    /// 点的位置只由两个真数决定：半径 = 跳数 / 上限，角度 = 序号均分。没有任何假数据。
    private var markers: some View {
        ZStack {
            ForEach(Array(shownNodes.enumerated()), id: \.element.id) { index, node in
                marker(node: node, index: index)
            }
        }
    }

    /// 位置只由两个真数决定：半径 = 跳数 / 上限（0 跳的那一台落在最内圈），角度 = 序号在圆上均分。
    /// 三角函数一律在 `Double` 上算，再显式转回 `CGFloat`：不依赖任何隐式转换。
    private func marker(node: PopopxCabinNode, index: Int) -> some View {
        let hops = Double(min(max(node.hopCount, 0), max(hopCap, 1)))
        let radius = Double(Self.side / 2) * (0.18 + 0.74 * (hops / Double(max(hopCap, 1))))
        let degrees = Double(index) / Double(max(shownNodes.count, 1)) * 360 - 90
        let radians = degrees * .pi / 180
        return PopopxCabinHopDot(hops: node.hopCount, online: node.isReachable)
            .offset(
                x: CGFloat(radius * cos(radians)),
                y: CGFloat(radius * sin(radians))
            )
    }

    /// 中心是本机：青色 `meshInk` 描的语义（本机自己在 mesh 里），不是 SMP 的紫。
    private var core: some View {
        ZStack {
            Circle()
                .fill(PopopxPalette.meshInk.opacity(0.16))
                .frame(
                    width: Self.dotSide + PopopxMetrics.spaceXS,
                    height: Self.dotSide + PopopxMetrics.spaceXS
                )
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(PopopxType.microTag)
                .imageScale(.medium)
                .foregroundStyle(PopopxPalette.meshInk)
        }
    }

    private func startPulse() {
        guard scanning, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
            pulseOutward = true
        }
    }
}

/// 青色节点点一律打印跳数数字（§1.4 第 3 条）：掉线的点退成灰圈，数字还在。
@MainActor
private struct PopopxCabinHopDot: View {
    let hops: Int
    let online: Bool

    var body: some View {
        Text("\(hops)")
            .font(PopopxType.metricSmall)
            .foregroundStyle(online ? PopopxPalette.onMesh : PopopxPalette.labelSecondary)
            .frame(width: PopopxMetrics.spaceM + PopopxMetrics.space2XS,
                   height: PopopxMetrics.spaceM + PopopxMetrics.space2XS)
            .background(online ? PopopxPalette.mesh : Color.clear, in: Circle())
            .overlay(
                Circle().strokeBorder(
                    online ? Color.clear : PopopxPalette.labelHint,
                    lineWidth: PopopxMetrics.stroke
                )
            )
            .accessibilityHidden(true)
    }
}

// MARK: - 徽章与节点行

/// 跳数徽章：`mesh` 实底 + `onMesh` 数字，永远带「N 跳」两个字（§2.2）。
@MainActor
private struct PopopxCabinHopBadge: View {
    let hops: Int

    var body: some View {
        Text(Copy.hopsWords(hops))
            .font(PopopxType.metricSmall)
            .foregroundStyle(PopopxPalette.onMesh)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .padding(.vertical, PopopxMetrics.space2XS / 2)
            .background(PopopxPalette.mesh, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

/// 关系徽章：只说绑定/配对事实，一律中性色，不与青色的跳数语义抢色。
@MainActor
private struct PopopxCabinStateBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PopopxType.microTag)
            .foregroundStyle(PopopxPalette.labelSecondary)
            .padding(.horizontal, PopopxMetrics.space2XS)
            .padding(.vertical, PopopxMetrics.space2XS / 2)
            .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
    }
}

@MainActor
private struct PopopxCabinNodeRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: PopopxCabinNode
    let busy: Bool
    let open: () async -> Void

    var body: some View {
        Button(action: { Task { await open() } }) {
            HStack(spacing: PopopxMetrics.spaceS) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            node.isReachable ? PopopxPalette.mesh : PopopxPalette.labelHint,
                            lineWidth: PopopxMetrics.stroke
                        )
                        .frame(width: PopopxMetrics.spaceM, height: PopopxMetrics.spaceM)
                    if node.isReachable {
                        Circle()
                            .fill(PopopxPalette.mesh)
                            .frame(
                                width: PopopxMetrics.space2XS,
                                height: PopopxMetrics.space2XS
                            )
                    }
                }
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(node.label)
                        .font(PopopxType.sectionHeader)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    Text(detail)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                VStack(alignment: .trailing, spacing: PopopxMetrics.space2XS) {
                    PopopxCabinHopBadge(hops: node.hopCount)
                    if let relationshipWords {
                        PopopxCabinStateBadge(text: relationshipWords)
                    }
                }
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PopopxPalette.meshInk)
                } else {
                    Image(systemName: "chevron.right")
                        .font(PopopxType.microTag)
                        .imageScale(.medium)
                        .foregroundStyle(PopopxPalette.labelHint)
                }
            }
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopopxPressButtonStyle())
        .disabled(busy)
        .opacity(node.canOpenChat ? 1 : 0.72)
        .popopxAnimation(PopopxSpring.fluid, value: node.isReachable, reduceMotion: reduceMotion)
        .accessibilityLabel(Copy.rowLabel(node.label, detail, relationshipWords))
    }

    /// 一行里的每个数字都来自模块 4 或镜像：直连/中继、静默时长、RSSI，以及「超出射程」这种难听话。
    private var detail: String {
        var parts: [String] = [
            node.isDirect ? Copy.directLink : Copy.relayLink,
            Copy.lastSeenWords(node.lastSeenAt)
        ]
        if let rssi = node.rssi { parts.append(Copy.rssiWords(Int(rssi))) }
        if !node.isReachable { parts.append(Copy.outOfRangeMark) }
        if !node.canOpenChat { parts.append(Copy.noKeyMark) }
        return parts.joined(separator: " · ")
    }

    private var relationshipWords: String? {
        switch node.binding {
        case .contact: return Copy.boundBadge
        case .pending: return Copy.pendingBadge
        case .none:
            switch node.pairingState {
            case .unlinked: return nil
            case .requestSent, .requestReceived, .paired: return Copy.pairingStateWords(node.pairingState)
            }
        }
    }
}

// MARK: - #厢语大厅

/// 「#厢语大厅」整屏：完整广播流 + 广播输入 + 本机临时昵称。总闸关着时这一屏只读，
/// 并给出一个真的开启按钮，不画任何看起来能发的输入框。
///
/// 两件事住在这一个页面里，都不另建第二份数据：
/// - 右上角「发现模式」开关的是主页面那一屏 `PopopxCabinNearbyCard`（同一个视图、同一份 `nodes`）；
/// - 气泡上的说话人名字是一枚 `Menu`，两条动作分别落到既有的 `openBluetoothChat(with:)` 与
///   `sendFriendRequest(to:)`，公钥的换算只认节点表那一份（见 `node(for:)`）。
@MainActor
private struct PopopxCabinHallView: View {
    let fuseOn: Bool
    /// 整份档位传进来而不是一个 `Bool`：composer 只问"能不能发"，发现模式那一屏还要说得出"为什么不能"。
    let radioState: PopopxBluetoothState
    @Binding var nickname: String
    let posts: [PopopxMeshPlazaPost]
    let nodes: [PopopxCabinNode]
    let openingNodeID: String?
    let directPeerCount: Int
    let onBroadcast: (String) async -> PopopxMeshSendFailure?
    let onSaveNickname: () async -> Void
    let onTurnOnFuse: () async -> Void
    let onOpenChat: (PopopxCabinNode) async -> Void
    let onSendFriendRequest: (PopopxCabinNode) async -> Void
    let onRescan: () async -> Void

    @State private var draft = ""
    /// 在途标记：`send()` 期间草稿仍留在框里（失败不吞字），所以按钮必须靠自己关门，
    /// 而不是靠 `trimmedDraft` 变假 —— 后者在 await 之前那一帧就把点击丢掉了。
    @State private var sending = false
    @State private var failureNote: String?
    /// 发现模式默认收着：大厅是说话的地方，看周边是另一件事，但右上角一键就能翻上来。
    @State private var showsDiscovery = false

    private var radioUsable: Bool { radioState.isUsable }

    private var trimmedDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // 容器结构与正式聊天页同构：`ChatView.swift:205` 的 `VStack(spacing: 0)` 里，消息列表是
        // 唯一可伸缩的成员，输入栏是最后一名（同文件 `:237` 挂 `ComposeView`，而 `ComposeView.swift:575`
        // 把 `popopxComposerBar(...)` 排在它自己那条 `VStack` 的末尾）。键盘升起时 SwiftUI 把安全区
        // 往上收，列表自己变矮，输入栏原样贴在键盘上沿 —— 主聊天页多年来就是这么贴合的。
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    if showsDiscovery {
                        PopopxCabinNearbyCard(
                            nodes: nodes,
                            fuseOn: fuseOn,
                            radioState: radioState,
                            directPeerCount: directPeerCount,
                            openingNodeID: openingNodeID,
                            onOpenChat: { node in await onOpenChat(node) },
                            onRescan: { await onRescan() },
                            onTurnOnFuse: { await onTurnOnFuse() }
                        )
                    }

                    PopopxSectionCard(Copy.hallChannel(posts.count), footnote: Copy.hallFootnote) {
                        feed
                    }

                    if fuseOn {
                        nicknameCard
                    } else {
                        PopopxSectionCard(Copy.fuseOffHeadline, footnote: Copy.fuseOffFootnote) {
                            PopopxButton(Copy.fuseTurnOn, systemImage: "antenna.radiowaves.left.and.right") {
                                await onTurnOnFuse()
                            }
                        }
                    }
                }
                .padding(.horizontal, PopopxMetrics.gutter)
                .padding(.top, PopopxMetrics.spaceS)
                // 真机第 6 轮的根因：上一版把收起层挂在 `.background` 上，而那一层只有内容 `VStack`
                // 那么大。屏幕下半截那块空白属于 `ScrollView` 自己（`UIScrollView` 对整块视口命中并把
                // 点击吃掉），背景层够不着；卡片里那点留白同样被 `PopopxSectionCard` 自己的圆角底吃掉。
                // 于是"点空白"点了个空 —— 不是手势没装，是那一块从来不是这层的。
                // 现在把内容层本身撑满视口（顶部对齐，短内容时下方空白就落在这层上），`contentShape`
                // 才有东西可命中；收起动作留在这一层。
                // 用 `.onTapGesture` 而不是 `.simultaneousGesture`：后代控件优先命中，昵称那个 `Menu`
                // （`authorControl`）与卡片里的按钮一律照常，不会出现"开菜单顺带把键盘也收了"；
                // simultaneousGesture 恰恰会在那一枚昵称上一起触发，正是要避开的冲突。
                // 收起走 `hideKeyboard()`：`PopopxTextArea` 的 `@FocusState` 是控件私有的
                // （`Shared/Components/PopopxControls.swift:260`、`:272`，红线文件不动），宿主拿不到
                // 那份绑定，只能走标准 responder 链，与主聊天页 `ChatView.swift:1094` 同一个调用。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { hideKeyboard() }
            }
            // 真机第 9 轮：输入栏从"VStack 末位"改成贴在列表的下沿安全区内。上一版依赖键盘升起时
            // SwiftUI 把整条栈往上收 —— 大厅是从抽屉里推进去、抽屉又挂在一层 sheet 上（见
            // `PopopxCabinMeshSettingsSheet` 那条链），sheet 那一侧的贴合规则与根栈不同，实测就是
            // 「广播」被键盘盖住半截。`.safeAreaInset` 让输入栏占的是下沿安全区，键盘抬高那一区时
            // 它跟着抬，列表自己变矮，不再和"整条栈平移"这件事耦合。
            // `if fuseOn` 留在 inset 内部：保险丝断开时这一格是空的， inset 不占位，列表照常到边。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if fuseOn {
                    VStack(spacing: 0) {
                        Divider()
                        composer
                    }
                }
            }
        }
        // 拖动列表即收起键盘。位置照正式聊天页：挂在整块内容上而不是某个 `ScrollView` 上
        // （`ChatView.swift:159`，那边用的是 `.immediately`；这里按本轮要求用 `.interactively`，
        // 键盘跟着手指走，松手才决定收起还是留下，与 `PopopxCabinView` 主页面的 :388 同档）。
        // 点空白收起与它同行：`hideKeyboard()` 走 UIKit 的 resignFirstResponder 广播，不持有也不
        // 争抢 SwiftUI 的焦点绑定，所以那条"与 `.focused` 同用会冻住"的上游警告在这里不适用 ——
        // 这一页从头到尾没有第二份 `.focused`。
        .scrollDismissesKeyboard(.interactively)
        // 进了大厅就是说话的地方：底部那四枚 Tab 必须整条让开，退出这一页回厢语主页自动回来。
        // 口径与消息页推入 `ChatView` 那一处相同（`ChatsListView.swift:405`）—— 声明在推进去的那
        // 一层，不是声明在列表页上；主页自己不挂，所以主页那四枚一直是好的。
        // 本轮起大厅只从抽屉里推进去，抽屉本来就盖住整块底栏，这一句在那条栈里落不到东西上：
        // inert 而非有害（与包内 `meshHallTabBarHidden(_:)` 同一句判据），留着是因为这条规则
        // 声明在"推进去的那一层"才成立，摘掉它就等于允许下一个把大厅挂进根栈的人漏掉它。
        // 真机第 8 轮之后这一句更是落不到东西上：根那一屏自己把底栏让开了，抽屉里这条栈头顶着的是
        // 一块本来就没有底栏的区域。
        .toolbar(.hidden, for: .tabBar)
        .background(PopopxPalette.base)
        .toolbar {
            // 工具条项跟着"声明它的那一层内容"走，所以主页面那两个入口不会跟到这一层来，这一枚也不会
            // 留在主页面上 —— 与 `PopopxCabinView.meshSettingsEntry` 上面那条注释是同一个规则。
            ToolbarItem(placement: .topBarTrailing) { discoveryEntry }
        }
    }

    /// 发现模式的开关。整枚芯片就是状态本身：开着的时候填青色（mesh 事实），收着的时候只留描边底色。
    private var discoveryEntry: some View {
        Button {
            PopopxHaptics.selection()
            showsDiscovery.toggle()
        } label: {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "radar")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                Text(Copy.discoveryMode)
                    .font(PopopxType.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(showsDiscovery ? PopopxPalette.onMesh : PopopxPalette.meshInk)
            .padding(.horizontal, PopopxMetrics.spaceS)
            .frame(minHeight: PopopxMetrics.minHitTarget)
            .background(
                showsDiscovery ? PopopxPalette.mesh : PopopxPalette.card,
                in: .rect(cornerRadius: PopopxMetrics.radiusControl)
            )
            .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
        }
        .buttonStyle(PopopxPressButtonStyle())
        .accessibilityValue(Text(verbatim: showsDiscovery ? Copy.switchOn : Copy.switchOff))
        .accessibilityHint(Text(verbatim: Copy.discoveryHint))
        .accessibilityIdentifier("popopx.cabin.hall.discovery")
    }

    @ViewBuilder private var feed: some View {
        if posts.isEmpty {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(Copy.hallEmptyHeadline)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                Text(Copy.hallEmptyDetail)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.spaceXS)
        } else {
            let shown = Array(posts.suffix(60))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, post in
                bubble(post)
                if index < shown.count - 1 { rowSeparator }
            }
        }
    }

    private func bubble(_ post: PopopxMeshPlazaPost) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                HStack(spacing: PopopxMetrics.space2XS) {
                    authorControl(post)
                    // 本机自己发的没有跳数可言；收到的每一条都必须带上它走了几跳。
                    if case .neighbour = post.author {
                        PopopxCabinHopBadge(hops: post.hopCount)
                    }
                }
                Text(post.text)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    // 整条气泡仍然一次读完 —— 但合并不再挂在最外层：外层一 `combine`，
                    // 里面的说话人按钮就被读屏吞掉了，那一枚名字于是只剩下"按钮"两个字。
                    .accessibilityLabel(Copy.bubbleLabel(authorWords(post), post.text, post.hopCount))
            }
            Spacer(minLength: PopopxMetrics.spaceS)
            Text(PopopxCabinClock.clock(post.timestamp))
                .font(PopopxType.metricSmall)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .padding(.vertical, PopopxMetrics.space2XS)
    }

    /// 说话人名字 = 这一条广播的唯一入口。本机自己那一行没有什么可加的，所以只有邻居那一行是控件。
    /// 用 `Menu` 而不是直接动作：同一个人身上有两条路（进私聊 / 只发一次加好友请求），点了才知道要哪条。
    /// 公钥解析不出来时两条动作一律 `disabled` 并写出原因，而不是把空页推进栈。
    @ViewBuilder private func authorControl(_ post: PopopxMeshPlazaPost) -> some View {
        let name = authorWords(post)
        if case .neighbour = post.author {
            let node = node(for: post)
            Menu {
                if let node, node.canOpenChat {
                    Button(Copy.authorChat, systemImage: "lock.circle.fill") {
                        Task { await onOpenChat(node) }
                    }
                    Button(Copy.authorPair, systemImage: "person.badge.plus") {
                        Task { await onSendFriendRequest(node) }
                    }
                } else {
                    Text(Copy.authorNoKey)
                    Button(Copy.authorChat, systemImage: "lock.circle.fill") {}
                        .disabled(true)
                    Button(Copy.authorPair, systemImage: "person.badge.plus") {}
                        .disabled(true)
                }
            } label: {
                Text(name)
                    .font(PopopxType.meta)
                    .foregroundStyle(node?.canOpenChat == true ? PopopxPalette.meshInk : PopopxPalette.labelSecondary)
                    .frame(minHeight: PopopxMetrics.minHitTarget)
                    .contentShape(.rect(cornerRadius: PopopxMetrics.radiusChip))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityHint(Text(verbatim: Copy.authorMenuHint))
        } else {
            Text(name)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.label)
        }
    }

    /// 广播的作者只带 8 字节线 id，而私聊与配对两条路都要 mesh 公钥。换算只认节点表那一份：它就是
    /// 模块 4 `allNodes()` 与镜像 `peers` 表折出来的 `PopopxCabinNode.meshPublicKeyHex`，与雷达、
    /// 节点行同源。包里那个 `meshPublicKeyHex(forPeerIDHex:)`（`PopopxMeshEngine.swift:322`）住在
    /// `PopopxMeshEngine` 这个 actor 上，而 app 侧只许 `PopopxMeshEngineBackend` 让那个单例存在
    /// （`POPOPXAPI.swift:3587`）—— 在本页问它一次，就等于替总闸关着的机器造出引擎。
    private func node(for post: PopopxMeshPlazaPost) -> PopopxCabinNode? {
        guard case let .neighbour(_, peerIDHex) = post.author else { return nil }
        return nodes.first { $0.peerIDHex == peerIDHex }
    }

    /// 包内 `PopopxMeshPlazaPost.Author.displayName` 是英文的 "You"；这一页的中文自己说。
    private func authorWords(_ post: PopopxMeshPlazaPost) -> String {
        switch post.author {
        case .local:
            return Copy.localAuthor
        case let .neighbour(nickname, peerIDHex):
            if let nickname {
                let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
            return PopopxCabinLabel.abbreviate(peerIDHex)
        }
    }

    /// 广播输入栏：正式聊天页那条底栏的同构体（见 `body` 里 `VStack(spacing: 0)` 那段注释）。
    /// 一排 = 输入框 + 「广播」按钮，不带标题与脚注：上一轮那整张 `PopopxSectionCard` 有标题、
    /// 脚注、字数行和按钮行四层，键盘一抬就把最底下那层按钮顶到键盘后面去，而 `ChatView.swift:237`
    /// 挂的 `ComposeView`/`PopopxInputBar.swift:632-642` 从来只是一条贴着键盘上沿的横排。
    /// 只保留两种"必须当场说"的行：射频不可用与上一次发送失败。
    private var composer: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            if !radioUsable {
                Text(Copy.composerRadioOff)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failureNote {
                Text(failureNote)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.count > PopopxMeshPlazaModel.maxDraftCharacters {
                // 字数只在越界时出现：底栏常驻一行计数，是把"编辑器"的负担摊到每一次喊话上；
                // 越界本身才是需要提前说的事（`send()` 也会拒绝，但那一跳要先按下按钮才知道）。
                Text(Copy.draftCount(draft.count, PopopxMeshPlazaModel.maxDraftCharacters))
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.dangerInk)
            }
            HStack(alignment: .bottom, spacing: PopopxMetrics.spaceXS) {
                PopopxTextArea(Copy.composerField, prompt: Copy.composerPrompt, text: $draft)
                PopopxButton(Copy.broadcastSend, systemImage: "paperplane.fill", fullWidth: false) {
                    await send()
                }
                .disabled(!trimmedDraft || sending)
            }
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.vertical, PopopxMetrics.spaceS)
        .background(PopopxPalette.base)
    }

    private var nicknameCard: some View {
        PopopxSectionCard(
            Copy.nicknameTitle,
            footnote: Copy.nicknameFootnote(
                PopopxMeshNicknameStore.defaultNickname,
                PopopxMeshNicknameStore.maxCharacters
            )
        ) {
            HStack(spacing: PopopxMetrics.spaceXS) {
                PopopxTextField(
                    Copy.nicknameField,
                    prompt: Copy.nicknamePrompt,
                    text: $nickname,
                    systemImage: "person.text.rectangle"
                )
                PopopxButton(Copy.nicknameSave, role: .secondary, fullWidth: false) {
                    await onSaveNickname()
                }
            }
        }
    }

    /// 发送：先广播，**成功之后**才清空草稿；失败时刚打的字留在框里，改一个字就能重发。
    /// 顺序反过来会同时踩两个坑：清空在 await 之前 ⇒ `trimmedDraft` 同一帧变假，在途期间的
    /// 点击被 `.disabled` 吞掉（连触觉都没有）；失败路径又会把用户的话销毁，而邻居那边
    /// 本地广播气泡已经贴上去了（`appendLocalBroadcast`），屏幕上剩一条谁也没收到过的消息。
    /// `sending` 是必须的：草稿现在会在途保留，`trimmedDraft` 就不再替我们关门。
    @MainActor private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        let failure = await onBroadcast(text)
        if let failure {
            failureNote = Copy.broadcastWords(for: failure)
            PopopxHaptics.notice(.error)
        } else {
            draft = ""
            failureNote = nil
            PopopxHaptics.notice(.success)
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 本地加密频道

/// 本机已经与蓝牙邻居建立的 1:1 加密会话。未绑定的邻居另开一段，说清楚点它会发生什么。
@MainActor
private struct PopopxCabinChannelsView: View {
    let fuseOn: Bool
    let nodes: [PopopxCabinNode]
    let openingNodeID: String?
    let pendingCount: Int
    let onOpenChat: (PopopxCabinNode) async -> Void
    let onShowPending: () -> Void

    private var channels: [PopopxCabinNode] { nodes.filter(\.hasEncryptedChannel) }
    private var strangers: [PopopxCabinNode] { nodes.filter { !$0.hasEncryptedChannel } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                PopopxSectionCard(Copy.channelListTitle(channels.count), footnote: Copy.channelFootnote(fuseOn)) {
                    if channels.isEmpty {
                        Text(Copy.channelEmpty(fuseOn))
                            .font(PopopxType.meta)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, PopopxMetrics.spaceXS)
                    } else {
                        rows(channels)
                    }
                }

                if fuseOn, !strangers.isEmpty {
                    PopopxSectionCard(Copy.strangerTitle(strangers.count), footnote: Copy.strangerFootnote) {
                        rows(strangers)
                    }
                }

                PopopxSectionCard(Copy.pendingTitle, footnote: Copy.pendingFootnote) {
                    PopopxPickerRow(
                        Copy.pendingRow,
                        value: Copy.pendingValue(pendingCount),
                        systemImage: "envelope.badge.fill",
                        tint: .mesh,
                        action: onShowPending
                    )
                }
            }
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.top, PopopxMetrics.spaceS)
            .padding(.bottom, PopopxMetrics.space2XL)
        }
        .background(PopopxPalette.base)
    }

    private func rows(_ list: [PopopxCabinNode]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, node in
            PopopxCabinNodeRow(node: node, busy: openingNodeID == node.id) {
                await onOpenChat(node)
            }
            if index < list.count - 1 { rowSeparator }
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}


// MARK: - 待决定的建联

/// 收到的建联请求：同意/拒绝都直接落到模块 3 的真方法上，与包内顶部横幅共用同一份状态，
/// 两处决定互相看得见。
@MainActor
private struct PopopxCabinPairingRequestsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let requests: [PopopxPairingRequest]
    let nodes: [PopopxCabinNode]
    let onApprove: (PopopxPairingRequest) async -> Void
    let onDecline: (PopopxPairingRequest) async -> Void

    var body: some View {
        PopopxSheetContainer(Copy.pendingSheetTitle, subtitle: Copy.pendingSheetSubtitle) {
            if requests.isEmpty {
                Text(Copy.pendingSheetEmpty)
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(requests) { request in
                    PopopxSectionCard(
                        label(request),
                        footnote: Copy.pendingSince(PopopxCabinClock.since(request.receivedAt))
                    ) {
                        Text(Copy.pendingInviteHint)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: PopopxMetrics.spaceS) {
                            PopopxButton(Copy.approve, systemImage: "checkmark.seal.fill") {
                                await onApprove(request)
                            }
                            PopopxButton(Copy.decline, systemImage: "xmark.circle.fill", role: .secondary, fullWidth: false) {
                                await onDecline(request)
                            }
                        }
                        .padding(.top, PopopxMetrics.spaceS)
                    }
                }
            }
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { dismiss() }
                .padding(PopopxMetrics.spaceM)
        }
        .presentationDragIndicator(.visible)
    }

    private func label(_ request: PopopxPairingRequest) -> String {
        if let node = nodes.first(where: { $0.meshPublicKeyHex == request.peerMeshPublicKeyHex }) {
            return node.label
        }
        return PopopxCabinLabel.abbreviate(request.peerMeshPublicKeyHex)
    }
}

// MARK: - 厢语离线组网设置中心

/// 「我」页的离线组网分组与「全部设置」页的厢语卡片整块搬进这里，落点一个都不换来源：
/// 总闸 = `PopopxMeshRuntime.requestFuse(_:)`、配对策略 = `MeshPairingPolicy` 的两个 case 经
/// `setPairingPolicy(_:)` 写进 `IdentityMappingStore`、运行态 = `PopopxMeshKillSwitch.verifiedActivitySnapshot()`、
/// 清除 = `IdentityMappingStore.emergencyWipeAllMappings()`、配对记录页 = 包内 `MeshPrivacySettingsView`
/// 的三个 runtime 对象。本视图只读宿主算好的事实、只回调，自己一次 actor 都不碰 —— 这样这张卡开着的
/// 时候，页面那份 2 秒节奏仍然是唯一的读数来源。
@MainActor
private struct PopopxCabinMeshSettingsSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let fuseOn: Bool
    let pairingPolicy: MeshPairingPolicy
    let snapshot: PopopxMeshActivitySnapshot?
    /// 模块 4 亲口报的射频档位，由宿主每 2 秒读一次；nil = 这一次运行还没读到过（不替它猜一个档位）。
    let radioState: PopopxBluetoothState?
    let nodes: [PopopxCabinNode]
    let localKeyHex: String
    let bindingCount: Int
    let queuedCount: Int
    let onToggleFuse: (Bool) -> Void
    let onSelectPolicy: (MeshPairingPolicy) -> Void
    let onVerify: () async -> Void
    let onWipe: () async -> Void
    let onOpenPrivacyRecords: () -> Void
    let onClose: () -> Void

    @State private var confirmsWipe = false

    var body: some View {
        PopopxSheetContainer(Copy.meshSettingsEntry, subtitle: Copy.sheetSubtitle) {
            switchCard
            identityCard
            dangerCard
        } footer: {
            PopopxButton(Copy.close, role: .secondary) { onClose() }
                .padding(PopopxMetrics.spaceM)
        }
        .presentationDragIndicator(.visible)
        .confirmationDialog(Copy.wipeQuestion, isPresented: $confirmsWipe, titleVisibility: .visible) {
            Button(Copy.wipeAction, role: .destructive) {
                confirmsWipe = false
                Task { @MainActor in await onWipe() }
            }
            Button(Copy.cancel, role: .cancel) { confirmsWipe = false }
        } message: {
            Text(Copy.wipeDetail)
        }
    }

    // MARK: 卡 1 · 总闸与配对策略

    private var switchCard: some View {
        PopopxSectionCard(Copy.cardSwitch, footnote: Copy.meshFootnote) {
            // 这一行同样不给青色徽标：`PopopxToggleRow` 的开关实底是原子库写死的 brand 紫，
            // 同一控件里紫青并存就是 §1.1 违规（与本页状态卡那行同一个理由）。
            // 副标题随熔断改写，是「全部设置」页那张厢语卡原本的说法：闸关着的时候再说"扫描、广播与
            // 中继都在运行"就是撒谎。哪一句都没必要静态地说两遍 —— 静态那句已经在这张卡的脚注里。
            PopopxToggleRow(
                Copy.fuseRow,
                note: fuseOn ? Copy.fuseRowNoteOn : Copy.fuseRowNoteOff,
                isOn: Binding(get: { fuseOn }, set: { onToggleFuse($0) })
            )
            // 开关的回执归调用方：原子库那枚 `Toggle` 里没有触觉，翻闸这种动作必须有手感。
            .onChange(of: fuseOn) { _, _ in PopopxHaptics.selection() }
            rowSeparator
            // 这一行在设置树里本来就带着"当前是哪一档"那一格值，第一轮收进来时内联成了单选，
            // 那一格值连同它自己的解释句一起掉了。单选继续内联（这一层已经是一张表，不多开一层），
            // 值与解释句在这里补回。
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
                Text(Copy.pairingPolicy)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                Text(policyTitle(pairingPolicy))
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .lineLimit(1)
            }
            Text(Copy.pairingSheetSubtitle)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, PopopxMetrics.space2XS)
            // 只枚举 `MeshPairingPolicy` 真实存在的两个 case（IdentityMappingStore.swift:24-30）；
            // 内联单选而不是再开一张表：这一层已经是一张表了。
            ForEach(Array(MeshPairingPolicy.allCases.enumerated()), id: \.element) { _, policy in
                PopopxRadioRow(
                    policyTitle(policy),
                    note: policyNote(policy),
                    selected: pairingPolicy == policy
                ) {
                    PopopxHaptics.selection()
                    onSelectPolicy(policy)
                }
            }
            rowSeparator
            // 配对记录页的入口 —— 第一轮唯一整行漏掉的那一个。行尾那枚状态字是它当时就有的那一格，
            // 两个词条都沿用「我」页早已发布的同一批 Key，所以这一行不必新写一句中文。
            PopopxPickerRow(
                Copy.privacyRecordsRow,
                value: fuseOn ? Copy.meshRowOn : Copy.meshRowFusedOff,
                systemImage: "lock.shield.fill",
                tint: .mesh,
                action: onOpenPrivacyRecords
            )
        }
        // 翻闸的这一下要改写这一张卡里的三处文字与行尾标签；Reduce Motion 下直接落位，不做过渡。
        // 这是「全部设置」那张卡原本就有的绑定，第一轮迁移时漏在门外。
        .popopxAnimation(PopopxSpring.fluid, value: fuseOn, reduceMotion: reduceMotion)
    }

    // MARK: 卡 2 · 节点身份与真实运行态

    private var identityCard: some View {
        PopopxSectionCard(Copy.cardIdentity, footnote: Copy.keyFootnote) {
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(Copy.localKeyRow)
                    .font(PopopxType.body)
                    .foregroundStyle(PopopxPalette.label)
                // 整串 64 位十六进制照原样写出来并可选中：指纹要能拿到别的信道上去比对，
                // 缩写过的串比对不出任何东西。空串说的是"这台机器还没跑过厢语"，不是"密钥丢了"。
                Text(localKeyHex.isEmpty ? Copy.localKeyAbsent : localKeyHex)
                    .font(PopopxType.metric)
                    .foregroundStyle(localKeyHex.isEmpty ? PopopxPalette.labelHint : PopopxPalette.labelSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PopopxMetrics.space2XS)
            .accessibilityElement(children: .combine)
            rowSeparator
            // 五行数字是同一张账，行内不再画分隔线；只在与上面那串十六进制、下面那块核验之间画。
            VStack(spacing: PopopxMetrics.space2XS) {
                factRow(Copy.bindingRow, "\(bindingCount)")
                factRow(Copy.queueRow, "\(queuedCount)")
                factRow(Copy.inReachRow, "\(onlineCount) / \(nodes.count)")
                factRow(Copy.relayRow, "\(relayedCount)")
                factRow(Copy.farthestRow, "\(farthestHop) / \(relayHopCap)")
            }
            .padding(.vertical, PopopxMetrics.space2XS)
            rowSeparator
            radioDiagnosisRow
            rowSeparator
            verificationBlock
        }
    }

    // MARK: 射频与权限诊断（本轮新增的唯一一行）

    /// 只有档位落在 `unauthorized`/`poweredOff` 时这一行才是按钮：那两种情况下系统设置里确实有一项可改。
    /// 档位好的时候给它一个能按的入口，跳过去只会让人对着一页没什么可动的设置发愣，所以那一格
    /// 诚实地停在"不可点"。读数只有一个来源 —— 模块 4 亲口报的 `currentRadioState`，
    /// 与顶栏胶囊同一个读法（`PopopxTelemetryHeader.swift:177`），档位用词复用
    /// `PopopxDualStatusCapsule.words(for:)`（`PopopxTelemetryHeader.swift:391`）。
    @ViewBuilder private var radioDiagnosisRow: some View {
        let state = radioState
        let needsSettings = state == .unauthorized || state == .poweredOff
        HStack(spacing: PopopxMetrics.spaceS) {
            PopopxIconBadgeView(
                systemName: needsSettings ? "wifi.slash" : "antenna.radiowaves.left.and.right",
                tint: needsSettings ? .neutral : .mesh
            )
            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                Text(Copy.radioDiagnosisRow)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Text(radioDiagnosisNote(state))
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PopopxMetrics.spaceXS)
            if needsSettings {
                Button {
                    PopopxHaptics.impact(.light)
                    UIApplication.shared.open(appSettingsURL)
                } label: {
                    Text(Copy.radioOpenSettings)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.meshInk)
                        .padding(.horizontal, PopopxMetrics.spaceS)
                        .frame(minHeight: PopopxMetrics.minHitTarget)
                        .background(PopopxPalette.separator, in: .rect(cornerRadius: PopopxMetrics.radiusControl))
                        .contentShape(.rect(cornerRadius: PopopxMetrics.radiusControl))
                }
                .buttonStyle(PopopxPressButtonStyle())
                .accessibilityIdentifier("popopx.cabin.mesh.openSettings")
            } else {
                // 不可点的那一格只说话，不装成控件：一个档位，没有 chevron。勾只给"确实是好的"那一档 ——
                // 给 `unknown` 画勾就是把"没读过"说成"读过了而且是好的"。
                VStack(alignment: .trailing, spacing: PopopxMetrics.space2XS) {
                    Text(verbatim: radioDiagnosisWords(state))
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .lineLimit(1)
                    if state == .poweredOn {
                        Image(systemName: "checkmark.circle.fill")
                            .font(PopopxType.microTag)
                            .imageScale(.medium)
                            .foregroundStyle(PopopxPalette.meshInk)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: PopopxMetrics.minHitTarget)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
        .popopxAnimation(PopopxSpring.fluid, value: state, reduceMotion: reduceMotion)
    }

    /// 档位两个字直接引顶栏胶囊那一份词表，一个字的第三种说法都不在这里造。
    private func radioDiagnosisWords(_ state: PopopxBluetoothState?) -> String {
        guard let state else { return Copy.radioUnknown }
        return PopopxDualStatusCapsule.words(for: state)
    }

    /// 三句实话：好、要去系统设置里改、以及"这一次运行还没读到过任何读数"。最后这一档必须存在，
    /// 因为总闸关着时模块 4 收不到任何射频事件，那一格只能停在它最后一次读到的值上 —— 说"未知"
    /// 比替它编一个"蓝牙已关闭"诚实。
    private func radioDiagnosisNote(_ state: PopopxBluetoothState?) -> String {
        switch state {
        case nil: return Copy.radioDiagnosisPending
        case .unauthorized: return Copy.radioDiagnosisUnauthorized
        case .poweredOff: return Copy.radioDiagnosisPoweredOff
        case .poweredOn: return Copy.radioDiagnosisHealthy
        case .unknown, .resetting, .unsupported: return Copy.radioDiagnosisQuiet
        }
    }

    /// 射程内 / 经中继 / 最远跳：全部由页面已经折好的 `PopopxCabinNode` 现算，不再问任何 actor。
    /// 判据与本页雷达与节点行完全同一份（`isReachable` 是模块 4 的 `PopopxPeerReachability` 结论）。
    private var onlineCount: Int { nodes.filter(\.isReachable).count }
    private var relayedCount: Int { nodes.filter { $0.isReachable && !$0.isDirect }.count }
    private var farthestHop: Int { nodes.filter(\.isReachable).map(\.hopCount).max() ?? 0 }
    /// 跳数上限引配置常量，不写死 7（与本页 `relayHopCap` 同一出处）。
    private var relayHopCap: Int { Int(PopopxMeshConfig.default.fragmentRelayTtlCap) }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceS) {
            Text(title)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
            Spacer(minLength: PopopxMetrics.spaceXS)
            Text(value)
                .font(PopopxType.metric)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
    }

    /// 熔断开关只是"意愿"。这一块写的是运行态：phase、真在跑的蓝牙/界面组件数、事件订阅数，
    /// 全部来自 `PopopxMeshKillSwitch.verifiedActivitySnapshot()`（包里唯一的权威答案）。
    /// 逐字承接「我」页原来那一块，事实来源与说法都没改。
    private var verificationBlock: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            HStack(spacing: PopopxMetrics.space2XS) {
                Image(systemName: "waveform.path")
                    .font(PopopxType.microTag)
                    .imageScale(.medium)
                    .foregroundStyle(PopopxPalette.meshInk)
                    .accessibilityHidden(true)
                Text(Copy.verifyHeadline)
                    .font(PopopxType.sectionHeader)
                    .foregroundStyle(PopopxPalette.label)
                Spacer(minLength: PopopxMetrics.spaceXS)
                PopopxButton(Copy.verifyAgain, systemImage: "arrow.clockwise", role: .ghost, fullWidth: false) {
                    await onVerify()
                }
            }
            Text(verifiedSentence)
                .font(PopopxType.caption)
                .foregroundStyle(PopopxPalette.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PopopxMetrics.space2XS)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Copy.verifyHeadline))
    }

    /// 开关说的话与蓝牙真实状态的关系，全在这里说清楚：宁可写"仍在运行"也不粉饰。
    private var verifiedSentence: String {
        guard let snapshot else { return Copy.verifyPending }
        var text: String
        switch snapshot.phase {
        case .off: text = Copy.phaseOff
        case .starting: text = Copy.phaseStarting
        case .on: text = Copy.phaseOn
        case .stopping: text = Copy.phaseStopping
        }
        if snapshot.isActive {
            text += String(
                format: Copy.busySuffixFormat,
                snapshot.runningRadioWork.count,
                snapshot.runningInterfaceWork.count
            )
        } else {
            text += Copy.quietSuffix
        }
        if let subscribers = snapshot.eventHubSubscribers {
            text += String(format: Copy.subscribersSuffixFormat, subscribers)
        }
        // 磁盘开关说"开"而 phase 不是 on（或反过来）就是一次没走完的启停，也可能是崩在中间。
        if snapshot.persistedSwitch != (snapshot.phase == .on) {
            text += Copy.mismatchSuffix
        }
        return text
    }

    // MARK: 卡 3 · 离线数据与清除

    private var dangerCard: some View {
        PopopxSectionCard(Copy.cardDanger, footnote: Copy.wipeDetail) {
            // 按钮只做一件事：把二次确认抬起来。删除在那之后由宿主执行，结果由宿主的 toast 说。
            // 这里不写"已清除"，也不在取消时说任何话；`PopopxButton` 那一下绿色回执是原子库按
            // "这次 async 动作跑完了"给的，改不了（红线文件），而它被同一帧抬起来的确认框盖住。
            PopopxButton(Copy.wipeAction, systemImage: "trash", role: .destructive) {
                confirmsWipe = true
            }
        }
    }

    // MARK: 策略文案

    private func policyTitle(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManual
        case .autoSilent: return Copy.policyAuto
        }
    }

    private func policyNote(_ policy: MeshPairingPolicy) -> String {
        switch policy {
        case .manualConfirm: return Copy.policyManualNote
        case .autoSilent: return Copy.policyAutoNote
        }
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

// MARK: - 时间

/// 时间只有两种说法：气泡上的 `HH:mm`（模板与包内 plaza 一致）与说明行里的相对时间。
private enum PopopxCabinClock {
    /// 每次现建一个 formatter：`DateFormatter` 不是 `Sendable`，包内 `MeshPlazaView.clock(_:)`
    /// （`MeshPlazaView.swift:448-453`）就是同样写法，这一页不把它变成 static 存属性。
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }

    private static func dated(_ date: Date) -> String {
        let formatter = DateFormatter()
        // 模板一律写 locale 中性的 Unicode 模式（`MMM d HH:mm`），中文那档由
        // `setLocalizedDateFormatFromTemplate` 自己排成「M月d日 HH:mm」。原先这里直接写
        // `"M月d日 HH:mm"`：`月`/`日` 对 ICU 是字面量，于是英文档位也照样吐出中文来。
        formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
        return formatter.string(from: date)
    }

    static func since(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return Copy.justNow
        case ..<60: return Copy.secondsAgo(seconds)
        case ..<3_600: return Copy.minutesAgo(seconds / 60)
        case ..<86_400: return Copy.hoursAgo(seconds / 3_600)
        default: return dated(date)
        }
    }

    /// 米说一遍：公里以上换单位，跟包内 `PopopxMeshReachEstimate.radius` 同一分界。
    static func metres(_ value: Int) -> String {
        value >= 1_000 ? Copy.kilometresWords(Double(value) / 1_000) : Copy.metresWords(value)
    }
}

// MARK: - 图标徽章

/// `PopopxIconBadge` 是 `PopopxControls.swift:315` 里的 `private` 类型，页面外拿不到；
/// 这里按同一套 token 逐字复刻（32pt 方块 / `radiusChip` / `microTag` + `imageScale(.medium)` / `.ink`），
/// 不另立第三种画法。
@MainActor
private struct PopopxIconBadgeView: View {
    let systemName: String
    let tint: PopopxIconTint

    var body: some View {
        Image(systemName: systemName)
            .font(PopopxType.microTag)
            .imageScale(.medium)
            .foregroundStyle(tint.ink)
            .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
            .background(tint.fill, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
            .accessibilityHidden(true)
    }
}

// MARK: - Copy

/// 这一页的每一句用户可见的话只在这里出现一次；源文是英文原句、原句就是 Key（约定见下面 `key(_:)`
/// 那一节）。失败路径的每一条都有实话，穷尽三个枚举的全部 case。
///
/// 带数字的句子一律走 `String(format:)`。参数次序与句子次序不一致时（`pageExplainer`、`radarLabel`
/// 这几处）占位符写成位置的 `%1$lld` / `%2$lld`，译文把数字挪到句子里别的位置就只改序号、不改个数；
/// 次序一致的直接写 `%lld` / `%@`，与 `PopopxTelemetryHeader.swift:625` 那条口径同一条。
private enum Copy {
    static let tabTitle = key("Cabin")
    static let pageTitle = key("Cabin · Local Bluetooth")

    static func pageExplainer(_ hopCap: Int, _ ttl: Int) -> String {
        String(format: key("Everything on this page is inside this device's Bluetooth reach: broadcasts spread unencrypted through the Cabin hall, while private chat runs over the encrypted Noise link with a neighbour. A broadcast travels at most %2$lld hops, relaying caps at %1$lld hops, and none of it crosses the public internet."), hopCap, ttl)
    }

    static let statusTitle = key("Master switch and radio")
    static let fuseRowTitle = key("Cabin offline mesh")
    static let fuseOnNote = key("When it is open this device scans, advertises itself and relays for other devices")
    static let fuseOffNote = key("When it is closed there is no scanning, no advertising and no relaying, and every number below is empty")
    static let fuseOffFootnote = key("The master switch is closed: this device has not sent a single byte over Bluetooth.")
    static let fuseOffRadioNote = key("While the master switch is closed the radio is never started, so this row has no reading.")
    static let fuseOffValue = key("Master switch closed")
    static let fuseTurnOn = key("Turn on Cabin")
    static let noBroadcastYet = key("No broadcast has been heard within this device's reach yet.")
    static func lastBroadcastWords(_ words: String) -> String { String(format: key("Last broadcast heard: %@"), words) }
    static func statusFootnote(_ window: Int) -> String {
        String(format: key("Online means this device heard from that device within the last %lld seconds. The master switch row only names where its truth comes from; this page keeps no state of its own."), window)
    }

    static let channelsTitle = key("Channels")
    static let channelsFootnote = key("The hall is an unencrypted flood; a local encrypted channel is the Noise link between this device and one neighbour. Neither of them goes through a server.")
    static let hallRow = key("#Cabin Hall")
    static let hallEmpty = key("No broadcasts yet")
    static func hallCount(_ posts: Int) -> String { String(format: key("%lld broadcasts"), posts) }
    static let encryptedChannelsRow = key("Local encrypted channels")
    static func encryptedChannelsValue(_ count: Int) -> String { String(format: key("%lld established"), count) }

    static func nearbyTitle(_ hopCap: Int) -> String { String(format: key("Active devices within 1–%lld hops"), hopCap) }
    static func nearbyFootnote(_ window: Int, _ metresPerHop: Int, _ ttl: Int, _ radius: String) -> String {
        String(format: key("Hops = the limit set when the frame was sent minus the value left when it was received; %1$lld seconds of silence counts as offline. One ring assumes about %2$lld metres per hop, so %3$lld hops reach roughly %4$@."), window, metresPerHop, ttl, radius)
    }
    static func denseNetworkNote(_ threshold: Int, _ cap: Int) -> String {
        String(format: key("More than %1$lld direct neighbours: the broadcast hop cap tightens itself to %2$lld hops, and the covered area shrinks with it."), threshold, cap)
    }
    static let nearbyEmptyScanning = key("There is nothing to hear inside this reach right now. Walk closer to a device that has Cabin switched on, then scan again.")
    static let rescan = key("Scan again")
    static func radarLabel(_ online: Int, _ total: Int) -> String {
        String(format: key("Radar: %2$lld devices known, %1$lld of them online. The number inside each dot is that device's hop count."), online, total)
    }

    static let directLink = key("Direct")
    static let relayLink = key("Relayed")
    static func lastSeenWords(_ date: Date) -> String { String(format: key("Last heard %@"), PopopxCabinClock.since(date)) }
    static func rssiWords(_ value: Int) -> String { "\(value) dBm" }
    /// 相对时间的四档。`PopopxCabinClock.since(_:)` 是它们唯一的调用者：那是个纯静态工具，够不着
    /// `Text`，只能拿到已经译好的串，所以句子在这里成文、由它挑档。
    static let justNow = key("just now")
    static func secondsAgo(_ seconds: Int) -> String { String(format: key("%lld seconds ago"), seconds) }
    static func minutesAgo(_ minutes: Int) -> String { String(format: key("%lld minutes ago"), minutes) }
    static func hoursAgo(_ hours: Int) -> String { String(format: key("%lld hours ago"), hours) }
    /// 距离两档：分界与包内 `PopopxMeshReachEstimate.radius` 同一条（公里以上换单位）。
    static func metresWords(_ value: Int) -> String { String(format: key("%lld metres"), value) }
    static func kilometresWords(_ value: Double) -> String { String(format: key("%.1f kilometres"), value) }
    static let outOfRangeMark = key("Out of reach")
    static let noKeyMark = key("Key not resolved")
    static let boundBadge = key("Bound")
    static let pendingBadge = key("Pending")

    static let privateChatTitle = key("Bluetooth private chat")

    // 大厅那一屏
    static func hallChannel(_ posts: Int) -> String { String(format: key("#Cabin Hall · %lld posts"), posts) }
    static let hallFootnote = key("The flood is not encrypted and not acknowledged, and it never leaves Bluetooth reach; the same text relayed by several devices is still shown once.")
    static let hallEmptyHeadline = key("Nobody has spoken inside this reach yet.")
    static let hallEmptyDetail = key("Anything sent here floods only to devices on the same mesh. It does not go through a server and it never stays on the public internet.")
    static let localAuthor = key("This device")
    static let composerField = key("Broadcast text")
    static let composerPrompt = key("Say something; it goes only to devices inside Bluetooth reach")
    static let broadcastSend = key("Broadcast")
    /// 底栏只留这一句短提示：上一版的标题与脚注（`对这一屋子人喊话` / `超过 N 字的部分会被截断…`）
    /// 已经随整张卡片一起撤下，"洪泛不确认"那条事实在上面那屏的 `hallFootnote` 里一直都在。
    static let composerRadioOff = key("The radio is not usable right now")
    static func draftCount(_ current: Int, _ limit: Int) -> String { "\(current) / \(limit)" }
    static let fuseOffHeadline = key("The master switch is closed, so the hall is read-only")

    static let nicknameTitle = key("This device's temporary nickname")
    static let nicknameField = key("Nickname")
    static let nicknamePrompt = key("The name shown on this device's broadcast bubbles")
    static let nicknameSave = key("Save")
    static func nicknameFootnote(_ fallback: String, _ limit: Int) -> String {
        String(format: key("It lives in the mesh sandbox folder and it is not a key; leave it empty to fall back to %@, and keep it under %lld characters. Changing it restarts the mesh on this device."), fallback, limit)
    }
    /// 徽章永远带数字（§1.4 第 3 条）；0 跳就是本机持有这条链路，把「直连」一起写出来。
    static func hopsWords(_ hops: Int) -> String { hops == 0 ? key("0 hops · direct") : String(format: key("%lld hops"), hops) }
    static func radarOverflow(_ total: Int, _ drawn: Int) -> String {
        String(format: key("The radar draws only %2$lld dots on this screen; the %1$lld rows below still list every one of them."), total, drawn)
    }
    static func bubbleLabel(_ author: String, _ text: String, _ hops: Int) -> String {
        String(format: key("%1$@, received on hop %2$lld: %3$@"), author, hops, text)
    }

    // 大厅气泡上的说话人菜单。2026-11-20 真机第 2 轮起转 Key：这四处是本轮新增的动作，红线四要求
    // 新增文案全语种落地，所以它们不再走文件头"本页其余字面量是 Phase 4 中文直写"那条豁免。
    static let authorChat = key("Initiate an offline Bluetooth chat")
    static let authorPair = key("Send a face-to-face or offline friend request")
    /// 只带线 id、公钥还没解析出来的那一档：两条动作都 disabled，这一句就是它的原因。
    static let authorNoKey = key("This device has not resolved this peer's mesh key yet; both actions need it first")
    static let authorMenuHint = key("Open this person's offline actions")

    // 本地加密频道
    static func channelListTitle(_ count: Int) -> String { String(format: key("Private chats established · %lld"), count) }
    static func channelFootnote(_ fuseOn: Bool) -> String {
        fuseOn
            ? key("One channel = this device has a row for it in the binding table, or the pairing state reports paired. Tap a row to go straight into the Bluetooth private chat.")
            : key("While the master switch is closed the binding table is not read and no channel is listed.")
    }
    /// 原文里那个「1–7」是 `nearbyTitle(hopCap)` 抄下来的第二份数字：跳数上限一改它就说谎，
    /// 而这一屏拿不到 hopCap。指名字不抄数字。
    static func channelEmpty(_ fuseOn: Bool) -> String {
        fuseOn
            ? key("This device has no encrypted channel with any Bluetooth neighbour yet. Tap a device in the nearby list and it sends an offline pairing invitation first.")
            : key("The master switch is closed, so this page has no session that could be opened.")
    }
    static func strangerTitle(_ count: Int) -> String { String(format: key("Unbound neighbours · %lld"), count) }
    static let strangerFootnote = key("These devices were only heard inside reach and there is no contact behind them yet; tapping a row first sends an offline pairing invitation, then opens the private chat page.")
    static let pendingTitle = key("Pairing invitations waiting for your decision")
    static let pendingRow = key("Pairing requests received")
    static func pendingValue(_ count: Int) -> String { count == 0 ? key("None") : String(format: key("%lld waiting"), count) }
    static let pendingFootnote = key("This reads the same pairing state as the banner at the top of the page, so the two places see each other's decision.")
    /// 与 `pendingRow` 同一句 Key（原文两处本来就是同一句话），不是第二个词条。
    static let pendingSheetTitle = key("Pairing requests received")
    static let pendingSheetSubtitle = key("Accepting is what binds this mesh key as an offline contact; declining keeps this device quiet about the peer for 60 seconds.")
    static let pendingSheetEmpty = key("Nothing is waiting for your decision right now.")
    static let pendingInviteHint = key("Accept takes the invitation link and binds the peer's mesh key; decline only drops the request and deletes no existing contact.")
    static func pendingSince(_ words: String) -> String { String(format: key("Received %@"), words) }
    static let approve = key("Accept")
    static let decline = key("Decline")
    static let close = key("Close")
    static let approveToast = key("Pairing accepted; the peer is now an offline contact")
    static let declineToast = key("This pairing request was declined")

    // 动作回执
    static func pairingSentToast(_ label: String) -> String { String(format: key("Offline pairing invitation sent to %@"), label) }
    static func noKeyToast(_ label: String) -> String { String(format: key("%@ has no resolved mesh key yet, so this device cannot start a private chat with it"), label) }
    static let fuseOffToast = key("The Cabin master switch is closed, so nothing goes out over Bluetooth")
    static let nicknameSavedToast = key("The nickname was written into this device's mesh sandbox")

    /// VoiceOver 那一行是把三段既有说法串起来的，串法本身也是句子：分隔符交给译本，不硬写全角逗号。
    static func rowLabel(_ name: String, _ detail: String, _ relationship: String?) -> String {
        if let relationship { return String(format: key("%1$@, %2$@, %3$@"), name, detail, relationship) }
        return String(format: key("%1$@, %2$@"), name, detail)
    }

    /// 射频六态，穷尽 `PopopxBluetoothState`。
    static func radioWords(_ state: PopopxBluetoothState) -> String {
        switch state {
        case .unknown: return key("Bluetooth status unknown")
        case .resetting: return key("Bluetooth is resetting")
        case .unsupported: return key("This device has no usable Bluetooth mesh")
        case .unauthorized: return key("Bluetooth permission is not granted")
        case .poweredOff: return key("Bluetooth is switched off")
        case .poweredOn: return key("Bluetooth is on and listening inside reach")
        }
    }

    /// 配对四态，穷尽 `MeshPairingState`。
    static func pairingStateWords(_ state: MeshPairingState) -> String {
        switch state {
        case .unlinked: return key("Not paired")
        case .requestSent: return key("Invitation sent, waiting for the peer to accept")
        case .requestReceived: return key("The peer is asking to pair")
        case .paired: return key("Paired")
        }
    }

    /// 洪泛失败六态，穷尽 `PopopxMeshSendFailure`（包内 `MeshPlazaView.words(for:)` 是 internal，
    /// 这一处够不着它，说的仍是同一批事实）。
    static func broadcastWords(for failure: PopopxMeshSendFailure) -> String {
        switch failure {
        case .noLinkToPeer: return key("No link to use: no device inside reach picked this broadcast up")
        case .linkDropped: return key("The link dropped: the content never made it onto Bluetooth")
        case .ttlExhausted: return key("Hops exhausted: this broadcast spent its whole hop limit before any device picked it up")
        case let .oversized(payloadBytes, limitBytes):
            return String(format: key("Over the single-frame limit (%1$lld > %2$lld bytes), so this content was not sent in fragments."), payloadBytes, limitBytes)
        case .noSessionWithPeer: return key("There is no encrypted session with this device yet, so the private message cannot go out")
        case let .radioUnavailable(state): return String(format: key("The radio is not usable: %@"), radioWords(state))
        }
    }

    /// 建联九态全给出路，穷尽 `PopopxPairingError`。`requestUnknown` / `requestSuperseded` 只有
    /// `approve` 会抛（`ManualPairingManager.swift:189-215`），发邀请那条路只会遇到前七种。
    static func pairingWords(for error: PopopxPairingError, label: String) -> String {
        switch error {
        case .peerKeyRejected:
            return key("This mesh key is not valid; this device will not send anything to it")
        case .alreadyPaired:
            return String(format: key("%@ is already a bound contact, so just open the private chat"), label)
        case .declinedRecently:
            return String(format: key("A pairing invitation to %@ was declined just now, and the 60 second cooldown blocks another one"), label)
        case .requestUnknown:
            return key("This request is no longer on the waiting list")
        case .requestSuperseded:
            return key("The peer replaced this invitation with a new link, so the old one is not bound")
        case .inviteLinkRejected:
            return key("The invitation link does not match this device's offline gate format, and it was dropped")
        case let .sendFailed(failure):
            return String(format: key("The invitation was created but never made it onto Bluetooth: %@"), broadcastWords(for: failure))
        case let .offlineBridge(reason):
            return String(format: key("This device could not create the offline invitation: %@"), reason)
        case let .mappingStoreFailed(reason):
            return String(format: key("Writing the binding table failed: %@. The session exists, but this device cannot yet tell whose it is"), reason)
        }
    }

    // MARK: 顶栏入口与离线组网设置中心
    //
    // 上面这一段在本轮之前还是中文直写字面量（Phase 4 那一版的写法），现在整段转成了 Key：这一屏的
    // 源文与 Key 同句，屏面上不再有一个中文字符（口径见文件头那两条）。从这里起是更早几轮新增的入口
    // 与设置中心，写法本来就已经是 Key。`en.lproj` 按约定不写（读不到词条就回落 Key 本身，那就是英文）。
    // 从「我」页整块迁来的那几行刻意复用「我」页早已发布的同一批 Key：同一个 Key 由目录里已有的
    // 译法决定说法，两处永远同一句，这也是这次迁移唯一能保证「摘掉的那行与留下的那行说的是同一件事」的办法。
    private static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX cabin offline mesh settings")
    }

    /// 顶栏左上角那一枚。2026-11-20 真机第 3 轮起它不再是大厅；第 5 轮起它进包内广场页。
    /// 旧的提示句（`Lists the devices within Bluetooth reach…`，说的是那一屏两张卡）Swift 引用为 0，
    /// 随本轮从 16 个目录里删掉；发现页那三条（建群入口、成员数、群脚注）同批删除。
    static let discoveryEntry = key("Discover")
    static let plazaEntryHint = key("Opens the nearby square: the broadcast stream and the nodes within Bluetooth reach")
    /// 「厢语」根那一屏左上角那一枚：面上只有两个字（面板的名字就是这一栏的名字，复用 `Copy.tabTitle`，
    /// 不另造第三种说法），这一句把它实际开出来的东西说全。抽屉的收起键同理只用既有那句「关闭」。
    /// 品牌词按既有口径写英文 Cabin：第 10 轮起「厢语」不再出现在任何 Key 的源文里 —— Key 里夹中文，
    /// `en` 那一档读到的是没译过的字，16 个目录里也没人能照着一条中英混排的 Key 写译法。
    /// 底栏那一格（`MainTabView.swift:230`，本轮没动、也不归本文件）是另一码事。
    static let cabinPanelEntryHint = key("Opens the Cabin panel: the master switch, the channels and the nearby nodes")
    /// 顶栏左上角那枚返回键的 VoiceOver 说法（屏面上只有图标，一个字都不占宽度）。这一栏全屏沉浸之后
    /// 它就是这一栏唯一的出口，所以这一句说的是去处，不是动作方向。
    static let backToMessages = key("Back to messages")
    /// 与 `PopopxAddFriendView.swift:718` 同一个 Key：两个入口的标题因此必然是同一句。
    static let plazaTitle = key("Nearby mesh plaza")
    static let meshSettingsEntry = key("Offline mesh settings")
    /// 顶栏两枚胶囊屏面上那几个短词。两条都是**既有 Key**（`Groups`、`Settings` 在 16 个目录里早就有
    /// 译法，口径同 `PopopxMeView.swift` 那一处 "Settings"），本轮不新增词条：胶囊只放得下一个词，
    /// 完整说法在 VoiceOver 里 —— 左那枚读 `.accessibilityLabel(meshGroupsHint)`、右那枚读
    /// `.accessibilityLabel(meshSettingsEntry)`，设置中心表头仍是全句那一条。宽度账见
    /// `meshDiscoveryEntry` 上面那一段。
    static let groupsPill = key("Groups")
    static let meshSettingsPill = key("Settings")
    static let meshRowOn = key("Fuse is open")
    static let meshRowFusedOff = key("Closed by the fuse")
    /// 大厅右上角那一枚开关。它开与关的是主页面已有的那一屏，不是第二份清单，所以话只说这一层。
    static let discoveryMode = key("Discovery mode")
    static let discoveryHint = key("Shows or hides the nearby radar and its node list above the hall")
    static let groupsRow = key("Offline groups")
    /// 左上角那一枚「发现」的无障碍说明：说清这一按下去的是周边蓝牙 Mesh 群组，不是公网频道。
    static let meshGroupsHint = key("Discover nearby groups and channels over the Bluetooth mesh")
    static func groupsValue(_ groups: Int) -> String { String(format: key("%lld groups"), groups) }
    /// 复用既有词条：这两个 Key 在 16 个目录里都已经有译法（「我」页那一串开关用的就是它们）。
    static let switchOn = key("Turned on")
    static let switchOff = key("Turned off")
    static let sheetSubtitle = key("The switch, the pairing policy, this device's mesh identity and the data it keeps, in one place.")
    /// 复用既有词条：这个 Key 在 16 个目录里都已经有译法（口径同 `PopopxMeView.swift` 的 `"Settings"`）。
    static let cancel = NSLocalizedString("Cancel", comment: "Cabin: cancelling the offline mesh wipe")

    static let cardSwitch = key("Mesh switch and pairing")
    static let meshFootnote = key("Closing the master switch stops Bluetooth scanning, advertising and relaying all at once; the other rows on this page stay readable but start no Bluetooth object.")
    static let fuseRow = key("Offline mesh master switch")
    /// 总开关那行的副标题随熔断改写。静态那一句"关闭即熔断"由上面这张卡的脚注说，两处分文不重复占格。
    static let fuseRowNoteOn = key("Running: Bluetooth scanning, advertising and relaying are all live on this device.")
    static let fuseRowNoteOff = key("Closed by the fuse: every mesh component stopped together and Bluetooth is scanning nothing.")
    static let pairingPolicy = key("Nearby pairing policy")
    /// 配对策略的解释句：原「我」页与「全部设置」页那张策略 Sheet 的副标题，同一个 Key，同一句译法。
    static let pairingSheetSubtitle = key("Decides whether a nearby device's Bluetooth pairing needs your confirmation.")
    static let privacyRecordsRow = key("Offline mesh privacy and pairings")
    static let policyManual = key("Ask me before pairing")
    static let policyManualNote = key("A nearby pairing request shows a confirmation; nothing connects until you tap it.")
    static let policyAuto = key("Pair silently")
    static let policyAutoNote = key("Pairing completes on its own once the private Bluetooth session is up, without asking.")

    // 射频与权限诊断（本轮新增的唯一一行：读数只有一个来源，档位用词复用顶栏胶囊那一份词表）
    static let radioDiagnosisRow = key("Bluetooth permission and radio")
    static let radioOpenSettings = key("Open Settings")
    static let radioUnknown = key("Not read yet")
    static let radioDiagnosisHealthy = key("The radio is on and this app is allowed to use Bluetooth, so there is nothing to change in the Settings app.")
    static let radioDiagnosisUnauthorized = key("This app is not allowed to use Bluetooth. Allow it in the Settings app, then open the master switch again.")
    static let radioDiagnosisPoweredOff = key("Bluetooth is switched off on this device. Turn it on, then open the master switch again.")
    static let radioDiagnosisQuiet = key("The mesh's own Bluetooth monitor has not reported a usable radio yet. With the master switch closed no Bluetooth object is created at all, so this row can only repeat the last reading it was given.")
    static let radioDiagnosisPending = key("This device has not asked the Bluetooth monitor for a reading yet in this run. Turn the master switch on once and this row reports the real state.")

    static let cardIdentity = key("Node identity and actual state")
    static let localKeyRow = key("This device's mesh key")
    static let localKeyAbsent = key("Not created on this device yet")
    static let bindingRow = key("Bound offline contacts")
    static let queueRow = key("Messages queued for a link")
    static let inReachRow = key("In reach now")
    static let relayRow = key("Reached through a relay")
    static let farthestRow = key("Farthest hop in use")
    static let keyFootnote = key("The fingerprint is this device's Noise static public key: 64 hex characters held in the keychain from the first time mesh ran on this device, unchanged by restarts. It is not your POPOPX address.")
    static let verifyHeadline = key("Actual Bluetooth state")
    static let verifyAgain = key("Verify actual state")
    static let verifyPending = key("Not verified yet in this run. Tap Verify to read the real state.")
    static let phaseOff = key("Stopped")
    static let phaseStarting = key("Starting")
    static let phaseOn = key("Running")
    static let phaseStopping = key("Stopping")
    static let quietSuffix = key(", with no component running")
    static let busySuffixFormat = NSLocalizedString(", still running %1$d Bluetooth component(s) and %2$d interface component(s)", comment: "Cabin: verified activity counts")
    static let subscribersSuffixFormat = NSLocalizedString(", %d event subscriptions", comment: "Cabin: verified event hub subscribers")
    static let mismatchSuffix = key("; the switch and the running state do not agree yet")

    static let cardDanger = key("Offline data and clearing")
    static let wipeAction = key("Clear offline bindings and cache")
    static let wipeQuestion = key("Clear offline bindings and cache on this device?")
    static let wipeDetail = key("Removes this device's offline contact bindings, both mesh switches and every file in the mesh cache folder, including the queue waiting for a link and the local nickname. This device's own mesh key stays, so neighbours already paired with it still recognise it.")
    static let wipeCleanToast = key("Offline bindings and mesh cache cleared")
    static func wipeFailedToast(_ count: Int) -> String {
        String(format: NSLocalizedString("%d items could not be cleared", comment: "Cabin: mesh wipe report failures"), count)
    }
}

// MARK: - Previews

#if DEBUG
// mesh 的类型（`PopopxMeshPeer`、`PopopxPeerReachability`）没有 public init，伪造不出数据；
// 下面每个预览都挂真单例，`bootstrap()` 就是 `Shared/POPOPXApp.swift` 启动时走的那条路径。
struct PopopxCabinView_Previews: PreviewProvider {
    static var previews: some View {
        // 栈由本页自己持有（文件头决定 4），这里再包一层就是第二个栈，`path.append` 会推到错的上面去。
        PopopxCabinView()
            .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}

// Reduce Motion 那条预览删了：`EnvironmentValues.accessibilityReduceMotion` 在这个 SDK 里是只读的
// （SwiftUICore.swiftinterface:23758 `public var … : Bool { get }`），`.environment(\.…)` 要的是
// WritableKeyPath，写不进去，也没有受支持的替身。本页三处雷达/徽章动效都读同一个环境值
// （:127、:690、:856），要验证静态雷达就把系统的开关打开：设置 → 辅助功能 → 动态效果 → 减少动态效果。

struct PopopxCabinHallView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxCabinHallView(
                fuseOn: true,
                radioState: .poweredOn,
                nickname: .constant(PopopxMeshNicknameStore().read() ?? ""),
                posts: [],
                nodes: [],
                openingNodeID: nil,
                directPeerCount: 0,
                onBroadcast: { _ in nil },
                onSaveNickname: {},
                onTurnOnFuse: {},
                onOpenChat: { _ in },
                onSendFriendRequest: { _ in },
                onRescan: {}
            )
            .navigationTitle(Copy.hallRow)
        }
        .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}

struct PopopxCabinChannelsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PopopxCabinChannelsView(
                fuseOn: PopopxMeshRuntime.shared.isFuseOn,
                nodes: [],
                openingNodeID: nil,
                pendingCount: 0,
                onOpenChat: { _ in },
                onShowPending: {}
            )
            .navigationTitle(Copy.encryptedChannelsRow)
        }
        .task { await PopopxMeshRuntime.shared.bootstrap() }
    }
}
#endif
