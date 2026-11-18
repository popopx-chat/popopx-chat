# 角色与任务目标
你现在是一名资深的 iOS 系统架构师与密码学通信工程师。我们需要在当前仓库（Fork 自 SimpleX Chat iOS 客户端的项目 **popopx**）中，非侵入式地融合 **Bitchat** 的离线蓝牙低功耗网状网络（BLE Mesh）能力。

---

## 一、 前置资源与防偏差执行铁律（必须严格遵守）

1. **Bitchat 源码目录与彻底剔除 Nostr**：
   - 完整的 Bitchat 官方源码已下载至 `/Users/elliot/popopx-chat/bitchat`。
   - 请先遍历 `/Users/elliot/popopx-chat/bitchat` 下的所有 `.swift` 文件。**彻底忽略并删除所有与 `Nostr`、`Relay`、`npub`、WebSocket 公网回退以及基于 Nostr 实现的 Geohash 同城公网频道代码**（公网通讯全部走原生 POPOPX SMP 服务器，不需要任何 Nostr 依赖）。
   - 只提取纯本地 `CoreBluetooth` 网状组网（双角色并发、7 跳 TTL 泛洪、布隆过滤器去重、分片重组）、物理半径内的 `#mesh` 本地离线广场频道，以及 `Noise_XX` 加密协议逻辑。

2. **采用 Local Swift Package 避免损坏 Xcode 工程**：
   - **严禁直接用脚本修改 `.pbxproj` 工程文件**（极易导致工程损坏）。
   - 请在当前仓库下创建标准的本地 Swift Package 目录 `PopopxMeshKit/`（包含 `Package.swift` 及 `Sources/PopopxMeshKit/`），将所有蓝牙 Mesh 与路由逻辑封装在该 Package 中，方便我在 Xcode 中一次性安全拖入关联。

3. **对齐当前仓库真实符号（禁止凭空捏造函数名）**：
   - 在编写任何调用底层 C 库或现有 `ChatModel` 的代码前，**必须先读取当前仓库中的 C Bridging Header 头文件及核心 Swift 源码**，严格对齐当前仓库真实的 C FFI 函数签名（如发送 JSON 指令和释放内存的函数名）、邀请链接 URI 前缀（`popopx:` 或 `simplex:`）以及现有聊天控制器类名。
   - 所有新增 Swift 类与文件统一采用 `Popopx` 大驼峰命名（如 `PopopxOfflineBridge`、`PopopxEventObserver`、`PopopxMessageRouter`），严禁大小写混用。

4. **杜绝加密库符号冲突**：
   - `PopopxMeshKit` 中的 `Noise_XX` 握手与加解密**必须 100% 使用 Apple 原生 `CryptoKit`（`Curve25519`、`ChaChaPoly`、`SHA256`）实现**，严禁引入任何第三方 C 语言加密库（如 `libsodium`、`OpenSSL` 或 `secp256k1`），避免与 `libpopopx.a` 产生 `Duplicate Symbol` 链接错误。

5. **保护 POPOPX 原有功能红线（100% 零破坏）**：
   - **零数据库修改**：严禁修改原有 SQLCipher 数据库表结构，严禁重新编译或修改 `libpopopx.a`。新增的离线消息缓存必须存放在独立沙盒目录（`Documents/popopx_mesh/`）。
   - **仅接管纯文本断网降级**：图片、视频、大文件（XFTP）、语音、音视频通话、群组聊天等功能**一律不做任何蓝牙拦截**，100% 透传执行原生代码路径。有网状态下发送普通文本直接走原有逻辑。
   - **UI 零破坏挂载**：**严禁重写或删除原有的聊天主视图（`ChatView`）**。请通过扩展（Extension）与顶部叠加层（Overlay Banner）的方式挂载蓝牙状态提示与手动建联横幅，并单独新增 `#mesh` 本地广场视图。
   - **全局熔断开关**：提供“启用离线蓝牙 Mesh 网络”总开关，关闭时彻底停止蓝牙运行，使 App 回退为 100% 纯净的原版 POPOPX 行为。

---

## 二、 需要生成的核心模块与具体实现要求

### 模块 1：`IdentityMappingStore.swift`（身份映射与硬件级安全存储）
- 实现 `MeshPairingPolicy` 枚举（`.manualConfirm` 手动确认模式为默认，`.autoSilent` 自动静默模式）及总开关状态持久化。
- 实现 `POPOPX_ContactID <---> Bitchat_MeshPublicKey` 双向映射管理。
- **安全要求**：映射表序列化为 JSON 后，必须存入 **iOS Keychain**，访问控制属性强制设为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（禁止随 iCloud 备份同步）。
- 提供 `upgradePendingConnection(tempConnId:toFinalContactId:)` 方法，支持将离线建联产生的临时 `connId` 原子升级为正式数字 `contactId`。
- 提供 `emergencyWipeAllMappings()` 方法供恐慌模式调用。

### 模块 2：`PopopxOfflineBridge.swift`（纯离线 C FFI 封装）
- 封装调用底层 C FFI 的异步 `async/await` 方法（自动释放 C 字符串内存）：
  1. `generateOfflineInviteLink()`：调用离线建联指令（对齐当前仓库真实命令，如 `/_connect 1`）在飞行模式下本地生成邀请链接及临时 `connId`，并立即绑定到本地 `IdentityMappingStore`。
  2. `acceptOfflineInviteLink(_ inviteLink: String)`：校验前缀后调用接收入库指令，在离线状态下生成待激活联系人记录。

### 模块 3：`ManualPairingManager.swift`（手动/自动双模式蓝牙建联）
- 定义蓝牙控制帧前缀：`SYS_POPOPX_REQ:<inviteLink>` 和 `SYS_POPOPX_ACK:<meshPublicKey>`。
- 维护每个蓝牙节点的 `MeshPairingState`（`.unlinked`、`.requestSent`、`.requestReceived(String)`、`.paired`）。
- 根据 `IdentityMappingStore.shared.pairingPolicy` 控制行为：手动模式下，收到请求仅更新状态触发聊天框顶部横幅，需用户点击“同意”后才调用 `PopopxOfflineBridge` 接受链接并回传 `ACK`；自动模式下，蓝牙私聊建立时静默完成交换。

### 模块 4：`BluetoothHealthMonitor.swift`（蓝牙异常监听与 ACK 超时守护）
- 监听 `CBCentralManager` 状态变化（`.poweredOff`、`.unauthorized`、`.resetting`）及外设断连（`didDisconnectPeripheral`），维护每个蓝牙节点的 `lastSeenTimestamp` 与 `hopCount`。
- 实现 `isPeerReachable(publicKey:timeout:)`：节点超过 **15 秒**无心跳/中继包响应，或本机蓝牙关闭，即判定为“蓝牙不可达”。
- **BLE ACK 投递超时守护**：为每条发出的蓝牙私聊消息（携带全局唯一 `messageId`）启动 **5 秒超时定时器**。若 5 秒内未收到 `BLE_ACK:<messageId>` 回执，或底层抛出断链异常，立即触发 `onBluetoothDeliveryFailed(messageId:peerMeshKey:)` 回调通知路由器接管。

### 模块 5：`NetworkStateMonitor.swift` & `PopopxMessageRouter.swift`（全向无缝切换与 SMP 重路由中枢）
- 使用 `NWPathMonitor` 实时监听公网状态，并与 `BluetoothHealthMonitor` 联动，实现**双向无感切换**与**全局唯一 `MessageID` 幂等去重**（公网通道统一走原生 POPOPX SMP 服务器，绝不走 Nostr）：
  1. **场景 A（有网 -> 断网 / 弱网降级）**：有网默认走 POPOPX SMP；一旦断网，自动查询 `IdentityMappingStore` 切换至 Bitchat 蓝牙 Mesh 发送；若公网发送超 **3 秒**未收到 SMP 服务器 ACK 且蓝牙可达，自动触发蓝牙并发补发。
  2. **场景 B（蓝牙聊天 -> 蓝牙不通自动转 SMP 有网通道）**：
     - **事前预判**：发消息时若 `BluetoothHealthMonitor` 判定对方已离开蓝牙范围（超 15 秒无响应）或蓝牙关闭，且本机有网并已完成身份绑定，直接跳过蓝牙，改走 POPOPX SMP 公网发送。
     - **事中超时重路由**：蓝牙发出后若触发 `onBluetoothDeliveryFailed`（5 秒未收到 `BLE ACK` 或中继断链），路由器立即检查网络状态：若当前有网且已绑定身份，**自动通过 POPOPX SMP 公网无缝补发该消息**（保持原 `messageId` 不变）。
     - **纯离线兜底与网络恢复冲刷**：若蓝牙不通且本机也无网，消息存入 `unacknowledgedMeshMessages` 待发队列；一旦 `NWPathMonitor` 检测到网络恢复，立即调用 `flushPendingMessagesOnNetworkRestore()` 自动通过 SMP 服务器冲刷所有积压消息。
     - **未绑定陌生人提示**：若尚未交换名片且蓝牙断开，在界面状态栏明确提示“蓝牙已断开，尚未交换公网名片（重新靠近后可继续发送）”。

### 模块 6：`PopopxEventObserver.swift`（联网后会话自动升级）
- 作为只读旁路观察者挂载在原有事件总线上（绝不吞掉或阻断原有事件分发），监听 `contactConnected` / `contactSndReady` 事件。
- 提取 `connId` 与正式 `contactId`，调用 `IdentityMappingStore` 完成原子升级，并通知 `PopopxMessageRouter` 将挂载在临时 `connId` 下的离线消息记录与待发队列无缝迁移至正式 `contactId`，同时发送 `NotificationCenter` 通知让当前聊天页面平滑升级状态栏。

### 模块 7：SwiftUI 界面组件与全局恐慌擦除（`PanicWipeManager.swift`）
- **合并渲染组件（`MergedTimelineModifier` & `ManualPairingBannerView`）**：
  - 使用 `Combine` 合并原有历史消息流与离线消息流，过滤控制信令，严格以全局唯一 `messageId` 幂等去重并按时间排序。
  - 气泡角标区分通道（蓝色盾牌 = SMP 公网，橙色波纹+跳数 = Bitchat 离线，灰色时钟 = 待中继）；顶部嵌入手动/自动建联横幅。
- **本地 `#mesh` 广场视图（`MeshPlazaView.swift`）**：纯蓝牙局部广播的离线广场入口（不含任何 Nostr 逻辑）。
- **设置页（`MeshPrivacySettingsView.swift`）**：提供“启用离线蓝牙 Mesh 网络”总开关、建联策略选择器（手动确认 vs 自动静默）以及清除身份绑定按钮。
- **全局三击恐慌擦除（`PanicWipeManager.swift`）**：顶层绑定三击手势（带极简防误触确认），按顺序执行：停止蓝牙扫描广播 -> 清空内存 Noise 密钥与离线缓存 -> 抹除 Keychain 映射 -> 覆写删除本地数据库文件后安全退出。

---

## 三、 分阶段执行流程（严格防截断）

**请严格按以下两阶段执行，每个文件都必须输出完整可编译代码，严禁使用 `// TODO` 或省略号占位符：**

- **【第一阶段】**：
  1. 扫描 `/Users/elliot/popopx-chat/bitchat` 与当前工程目录，向我简要汇报扫描到的核心文件路径、现有 C FFI 函数名及邀请链接前缀。
  2. 创建 `PopopxMeshKit` 本地 Swift Package，完成底层蓝牙 Mesh 引擎（纯 `CryptoKit` 实现、无 Nostr）及 **模块 1 ~ 模块 4** 的全部代码文件。
  3. 完成后**立即暂停**，等待我检查并回复“继续第二阶段”。

- **【第二阶段】**：
  1. 在我确认后，生成 **模块 5 ~ 模块 7** 的全部代码文件，并将挂接点集成到现有 POPOPX 入口视图与事件循环中。
  2. 更新 `Info.plist`（补充 `NSBluetoothAlwaysUsageDescription` 及后台模式 `bluetooth-central`、`bluetooth-peripheral`）。
  3. 输出一份《Xcode 手动拖入 Package 与真机双机联调检查清单》。

