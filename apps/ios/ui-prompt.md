/swiftui-design /swiftui-expert-skill

# Role & Context
你是一位精通 Apple Human Interface Guidelines (HIG)、现代 SwiftUI (iOS 17+) 架构以及 CoreBluetooth / NearbyInteraction / MultipeerConnectivity 底层通信的资深 iOS 首席工程师。
目前项目（**popopx**，Fork 自 SimpleX Chat iOS）已完成底层蓝牙 Mesh 融合模块 `PopopxMeshKit/`（本地 Swift Package，包含蓝牙组网、`PopopxMessageRouter`、`IdentityMappingStore`、`PopopxOfflineBridge`、`ManualPairingManager`、`BluetoothHealthMonitor`、`PanicWipeManager`）。

请先加载并严格遵守已安装的 `swiftui-design` 和 `swiftui-expert-skill` 两个技能的规范，为 **popopx** 构建一套完整的现代 iOS 视觉架构、全量原子级 UI，以及**面对面双引擎物理近场加友（UWB 灵犀近场 + TapDrop 轻触密传）**，并与现有的 `PopopxMeshKit` 深度无缝绑定。

---

## 🛠️ Qoder CLI (`qoderclicn`) 本地工程执行约定

1. **前置扫描与 API 对齐（零重复造轮子）：**
   - 在编写任何代码前，请先扫描 `PopopxMeshKit/Sources/PopopxMeshKit/` 下的所有文件、`PopopxMeshKit/Package.swift`、`apps/ios/` 目录结构（定位 `.xcodeproj` / `.xcworkspace` 与主 Scheme 名称）、C Bridging Header 以及 `Info.plist` 配置。
   - **底层与 UI 职责边界：** 底层近场引擎（`PopopxProximityEngine` 等 UWB/MCSession/互斥与仲裁状态机）封装进本地 Swift Package `PopopxMeshKit/Sources/PopopxMeshKit/` 中；全量视觉组件与重写视图存放在 `apps/ios/` 对应的 Swift 源码目录中。**严禁重新编写或覆盖 `PopopxMeshKit/` 中已有的 BLE Mesh、路由或存储逻辑**。
2. **跨模块可见性硬性红线（`public` 访问控制）：**
   - 因为 `PopopxMeshKit` 是独立的 Swift Package，所有在 `PopopxMeshKit` 中新增或修改、且需要被 `apps/ios/` 主工程调用的类、结构体、枚举、属性、`init` 构造器及方法，**必须显式声明为 `public`**，严禁遗漏导致主工程报 `inaccessible due to 'internal' protection level` 错误。
3. **禁止脚本修改工程文件 & 资产保护：**
   - **严禁使用脚本直接修改 `.pbxproj` 工程文件**（极易导致工程损坏）。
   - **严禁修改、覆盖或删除** `apps/ios/` 目录下已经修改好的新版 **popopx 紫色 Logo** 图片资产。请先检索 Asset 目录确认其准确名称并在代码中直接引用。
4. **100% 彻底重构，零旧版极客样式残留：**
   - 彻底摈弃 POPOPX Chat 原版粗线条黑紫极客 UI。主界面、对话气泡、新建群聊、聊天详情以及所有全局与底层参数设置页，必须 100% 使用我们新建的 `PopopxControls` 原子控件库重写。
   - 重构 `ChatView` 时，必须完整保留 `PopopxMeshKit` 的消息时间线合并去重（`MergedTimelineModifier` 逻辑）、手动/自动建联横幅（`ManualPairingBannerView` 逻辑）及三击 Logo/顶栏触发 `PanicWipeManager` 紧急自毁的能力。
   - **第五阶段防参数丢失机制：** 重写旧视图文件前，必须先读取并列出目标旧视图的外部调用入口与环境对象依赖（如 `ChatModel`、环境绑定等），确保重写后的组件接口与现有上游调用方 100% 兼容。
5. **现代 SwiftUI API 与性能红线：**
   - **状态管理：** 新建状态统一使用 iOS 17+ `@Observable` 和 `@Bindable`。
   - **现代修饰符：** 强制使用 `.foregroundStyle(...)` 替代 `.foregroundColor(...)`；强制使用 `.clipShape(.rect(cornerRadius: ...))` 替代 `.cornerRadius(...)`；使用 `NavigationStack` 替代 `NavigationView`。
   - **无障碍与动态字体：** 自适应 Dynamic Type，并响应 `@Environment(\.accessibilityReduceMotion)`。
   - **零占位符原则：** 严禁输出 `// TODO`、`// 省略其余代码` 等偷懒注释，所有文件必须逻辑完整、可直接编译运行。
6. **分阶段门禁与终端自动化编译验证（Automated `xcodebuild` Gate）：**
   - 每次仅执行并写入当前阶段的完整文件。
   - **第二阶段和第三阶段完成后的自动编译闭环：**
     1. 写入文件后，请直接调用终端工具执行编译校验（等效于 Xcode `Cmd + B`）：
        - 针对 `PopopxMeshKit` 包，运行：
          `xcodebuild build -scheme PopopxMeshKit -destination 'generic/platform=iOS Simulator' -quiet`（或 `swift build`）
        - 针对主工程，使用前置扫描定位到的 `apps/ios/` 下的 `.xcodeproj` / `.xcworkspace` 及主 Scheme，运行：
          `xcodebuild build -project <定位到的工程路径> -scheme <主Scheme名> -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
     2. **自愈修复：** 若编译器输出任何 `error:`（例如类型不匹配、缺少 `public` 修饰符等），请**自动分析错误堆栈并立即修改代码重新编译**，直到输出 `** BUILD SUCCEEDED **`。
     3. **例外处理：** 如果终端报错显示主工程因 `.pbxproj` 未索引到本阶段新建的 Swift 文件而编译失败（且我们严禁脚本修改 `.pbxproj`），请立即停止反复重试，清晰列出需要我手动拖入 Xcode Target 的新建文件夹清单，并暂停等待我拖入确认后再继续。

---

## ⚙️ 五阶段开发与重构蓝图

### 第一阶段：工程扫描、双模视觉规范与全局主题系统
**目标文件：** `Docs/popopx-brand-spec.md`、`Theme/PopopxTheme.swift`
1. **前置扫描汇报：** 扫描 `PopopxMeshKit` 暴露的公开接口（尤其是 `PopopxOfflineBridge`、`IdentityMappingStore`、BLE 控制器的挂起/恢复方法）、`apps/ios/` 现有视图路径、`.xcodeproj`/Scheme 信息以及 `Info.plist` 当前配置，输出简要对齐清单。
2. **自适应双模色板（满足 WCAG 2.1 AA 对比度 >= 4.5:1）：**
   - **主品牌色（在线加密态 / SMP）：** 现代深靛紫（Light `#5856D6` / Dark `#7D7AFF`），用于主按钮、Tab 选中态、发送方在线气泡（配纯白文字 `#FFFFFF`）。
   - **离线蓝牙 Mesh 态（厢语专属色）：** 雷达青绿（Light `#00A896` / Dark `#00D2B8`），专用于 BLE Mesh 节点、1–7 跳信号徽章与“厢语 / #mesh”离线频道。
   - **警戒危险色：** 原生系统红（Light `#FF3B30` / Dark `#FF453A`），用于清除记录与 `PanicWipeManager` 紧急自毁。
   - **表面与材质层级：** Light Mode 使用 `#F2F2F7` 底色配 `#FFFFFF` 纯白卡片；Dark Mode 使用 `#000000` OLED 纯黑底色配 `#1C1C1E` 二级深灰卡片与 `0.5pt` 极细高光内描边。
3. **排版与物理弹簧常量：** 定义支持 Dynamic Type 的字体阶梯与 Apple 级物理弹簧参数（`snappy: response 0.3, damping 0.85` / `fluid: response 0.4, damping 1.0`）。

### 第二阶段：原子级基础 UI 控件库与多模态交互反馈（触发首次自动编译门禁）
**目标文件：** `Components/PopopxHaptics.swift`、`Components/PopopxToast.swift`、`Components/PopopxControls.swift`
1. **三重同步交互反馈引擎：**
   - 瞬时按压缩放（`PopopxPressButtonStyle`，pointer-down 瞬间 `scaleEffect(0.97)` 弹簧微缩）+ 原生触觉引擎（`PopopxHaptics` 同帧触发）+ 顶部毛玻璃回执胶囊（`PopopxToast`，支持队列与手势上滑打断）。
2. **全量标准化原子控件：**
   - `PopopxButton`（`primary` / `secondary` / `ghost` / `destructive` + `isLoading` + 成功瞬时绿勾）、`PopopxTextField`、`PopopxTextArea`、`PopopxToggle`、`PopopxToggleRow`（带圆角彩色 SF Symbol 徽章）、`PopopxCheckbox`、`PopopxRadioRow`、`PopopxPickerRow`、`PopopxSegmentedControl`（带 `matchedGeometryEffect` 滑块）、`PopopxSliderRow`、`PopopxSectionCard`（`16pt` 圆角分组卡片）、`PopopxSheetContainer`。
3. **阶段验收：** 严格执行第 6 条的终端自动化编译与自愈修复闭环，确认编译通过或按例外处理提示我手动关联新建文件夹后，暂停等待确认。

### 第三阶段：顶部三段式导航、微信式 `+` 号菜单与「面对面双引擎物理近场加友」（触发二次自动编译门禁）
**目标文件：**
- `PopopxMeshKit/Sources/PopopxMeshKit/PopopxProximityEngine.swift`（底层 UWB + MCSession 双引擎状态机与蓝牙互斥逻辑）
- `Navigation/PopopxTelemetryHeader.swift`
- `Features/AddFriend/PopopxAddFriendView.swift`
- `Features/AddFriend/PopopxProximityAddContactView.swift`（面对面双引擎近场弹窗视图）
- `Features/AddFriend/PopopxQRCardSheet.swift`
- `Info.plist`（权限与 Bonjour 服务追加）

1. **顶部三段式遥测导航栏（`PopopxTelemetryHeader`）：**
   - **左侧：** POPOPX 多匿名身份切换胶囊 + `popopx` 紫色 Logo（**连续点击 3 次**直接调用 `PanicWipeManager` 触发强震动与紧急自毁确认弹窗）。
   - **中间：** 双模通信状态动态胶囊（实时监听 `NetworkStateMonitor` 与 `BluetoothHealthMonitor`：紫色锁盾 `SMP 在线加密` / 青绿脉冲雷达 `厢语无网组网中`）。
   - **右侧（微信式 `+` 号聚合菜单）：** 原生 `Menu` 下拉菜单（`plus` 图标），含 ① **添加朋友**、② **发起群聊 / 加密频道**、③ **扫一扫**、④ **生成一次性连接链接**。
2. **类微信“添加朋友”专属页面（`PopopxAddFriendView`）：**
   - **顶部搜索框：** 支持输入或解析 `popopx:` / `simplex:` 加密邀请链接。
   - **并排快捷双按钮（完整三重反馈）：**
     - **粘贴加友：** 自动检测剪贴板有效链接（有则亮起青绿呼吸光点），点击调用 `PopopxOfflineBridge.acceptOfflineInviteLink(_:)` 或在线建连。
     - **面对面加友（统一唯一入口）：** 主标题 `面对面加友`，副标题 `靠近自动感应，或顶部轻触连接`，图标 `dot.radiowaves.left.and.right`。点击弹出 `PopopxProximityAddContactView`。
   - **我的加密名片微标条：** 居中展示当前匿名身份名 + 紫色二维码按钮（点击弹出 Apple Wallet 质感渐变紫二维码卡片 `PopopxQRCardSheet`）。
   - **下方功能卡片列表：** “进入厢语发现附近群组/频道（BLE Mesh）”、“扫一扫”、“分享我的安全邀请链接”。
3. **面对面双引擎物理近场加友（`PopopxProximityEngine` & `PopopxProximityAddContactView`）：**
   - **蓝牙资源互斥保护（真实底层释放）：** 页面 `onAppear` 时自动临时挂起 Bitchat 常规 BLE 扫描与广播，避免底层射频信道抢占；页面 `onDisappear` 释放 `NISession` 与 `MCSession` 后自动恢复 `PopopxMeshKit` 蓝牙状态（前提是总开关开启）。
   - **硬件检测与自适应上下分层 UI：** 检测 `NISession.deviceCapabilities.supportsPreciseDistanceMeasurement`。支持 UWB 的设备采用上下分层布局：上半部分默认自动运行**「灵犀近场」UWB 雷达动效主舞台**，下半部分常驻**「轻触密传」**胶囊按钮；不支持 UWB 的老款设备自动隐藏雷达动画，居中放大显示**「轻触密传」**主按钮。
   - **引擎 A「灵犀近场」（UWB + MultipeerConnectivity）：**
     - 启动 `MCNearbyServiceAdvertiser` 与 `MCNearbyServiceBrowser`（服务类型 `"popopx-uwb"`），建立加密 `MCSession` 并交换 `NIDiscoveryToken`。
     - 启动 `NISession` 测距，检测到 `distance < 0.15`（15 厘米内）时触发重击触觉反馈（`UIImpactFeedbackGenerator(style: .heavy)`）。
     - **字典序单向发包仲裁（防重复建连）：** 对比 `myPeerID.displayName > remotePeer.displayName`，仅字典序较大的一方作为发信方发送包含本机一次性邀请链接（优先复用 `PopopxOfflineBridge` 生成以支持飞行模式建连及自定义 Scheme 直接唤醒）与本机 `Bitchat_MeshPublicKey` 的 JSON 载荷（前缀 `POPOPX_PROXIMITY:`）；较小的一方静默接收，解析后自动写入 `IdentityMappingStore` 完成“加友 + 离线 Mesh 身份绑定”一步到位，触发成功震动并自动关闭弹窗建连。
   - **引擎 B「轻触密传」（TapDrop — iOS 17+ 原生顶部轻触 AirDrop）：**
     - 点击「轻触密传（顶部贴一贴发送）」按钮时，立即挂起并销毁 UWB 与 `MCSession` 进程（`stopProximityLinkEngine()`）防止双通道同时发包，随后调起 `UIActivityViewController` 传入生成的 POPOPX 邀请 `URL`；关闭分享面板后自动恢复 UWB 雷达。
4. **安全更新 `Info.plist` 权限配置：**
   - 检查并安全追加（合并而非覆盖）：`NSNearbyInteractionUsageDescription`、`NSBluetoothAlwaysUsageDescription`、`NSLocalNetworkUsageDescription`，以及 `NSBonjourServices` 数组中追加 `_popopx-uwb._tcp`（**严禁添加**受限的 `com.apple.developer.networking.multicast` 权限）。
5. **【第三阶段专用强制自检与自动编译闭环】（写入代码后必须逐项核验执行）：**
   - **框架与平台检查：** 确认 `PopopxMeshKit/Package.swift` 支持 `.iOS(.v17)`，且 `PopopxProximityEngine.swift` 顶部已正确导入 `NearbyInteraction` 和 `MultipeerConnectivity`。
   - **跨模块可见性检查：** 逐行核对 `PopopxProximityEngine` 及其状态模型、委托/回调属性、构造器均已标记 `public`，确保主工程视图零访问权限报错。
   - **底层射频真释放检查：** 确认挂起 BLE Mesh 的函数内部**真正调用了底层 `CBCentralManager.stopScan()` 和 `CBPeripheralManager.stopAdvertising()`**（而非仅修改布尔标志位），防止蓝牙射频占用导致 `MCNearbyServiceBrowser` 发现超时。
   - **终端自动编译与自愈：** 严格执行第 6 条，依次自动运行 `PopopxMeshKit` 与主工程的 `xcodebuild` 编译校验并自愈修复所有代码报错，通过后向我汇报双机真机（U1/U2 芯片设备）15cm 靠拢震动与单向建连验证步骤，暂停等待确认。

### 第四阶段：底部四栏经典导航（深度绑定 `PopopxMeshKit`）
**目标文件：** `Navigation/MainTabView.swift`、`Features/Chats/ChatsListView.swift`、`Features/Contacts/PopopxContactsView.swift`、`Features/Cabin/PopopxCabinView.swift`、`Features/Me/PopopxMeView.swift`
- **Tab 1 消息（`ChatsListView`）：** 集成 `PopopxTelemetryHeader`，配备 `全部 / 在线加密 / 厢语离线` 胶囊过滤器，会话列表行根据 `IdentityMappingStore` 与路由状态展示紫锁或青绿跳数徽章。
- **Tab 2 通讯录（`PopopxContactsView`）：** 顶部置顶功能卡片（“新的加密连接（含未读与 `ManualPairingManager` 待确认角标）”、“我的加密群组”、“按匿名身份分组”），下方为带 `.searchable`、右侧 A–Z 索引及 `8pt` 圆角头像的现代联系人列表。
- **Tab 3 厢语（`PopopxCabinView`，重构升级原 `MeshPlazaView`）：** 绑定 `PopopxMeshKit` 的纯本地蓝牙广场与周边节点列表，展示 `#厢语大厅` 公共广播频道、本地加密频道入口及周边 1–7 跳活跃设备（显示 `BluetoothHealthMonitor` 的 `hopCount` 跳数徽章与在线状态，点击直接开启蓝牙私聊）。
- **Tab 4 我（`PopopxMeView`）：** 当前匿名身份大卡片 + 分类设置入口。

### 第五阶段：现代对话流气泡、毛玻璃输入栏与全量二级设置页彻底重写
**目标文件：** `Features/ChatRoom/ChatView.swift`、`Features/ChatRoom/PopopxMessageBubble.swift`、`Features/ChatRoom/PopopxInputBar.swift`、`Features/Group/CreateGroupView.swift`、`Features/ChatRoom/ChatInfoView.swift`、`Features/Settings/PopopxSettingsViews.swift`
1. **入参对齐前置检查：** 先读取并输出现有 `ChatView`、`CreateGroupView`、`ChatInfoView`、`Settings` 的外部初始化参数及环境对象签名，确保无缝替换不破坏上游调用。
2. **现代对话流与输入栏（完整承接 `PopopxMeshKit` 路由能力）：**
   - `PopopxMessageBubble`：左白/深灰 `#1C1C1E`、右现代深靛紫气泡，连续消息内侧圆角收紧为 `4pt`、外侧 `16pt`；完整保留消息去重与通道角标（深靛紫盾锁 = SMP 公网，青绿波纹+跳数 = Bitchat 离线，灰色时钟 = 待中继队列），并在顶部内嵌全新视觉风格的 `ManualPairingBannerView` 手动建联同意横幅。
   - `PopopxInputBar`：底部 `.ultraThinMaterial` 毛玻璃输入栏，集成语音键、自适应高度输入框、表情与 `+` 号功能面板（阅后即焚开关等）及发送按钮（文本消息发送统一走 `PopopxMessageRouter` 智能路由）。
3. **全量重写所有二级页面与底层参数设置（100% 原子化重构，0 旧版残留）：**
