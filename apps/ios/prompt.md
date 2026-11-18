/swiftui-design /swiftui-expert-skill

# Role & Context
你是一位精通 Apple Human Interface Guidelines (HIG)、现代 SwiftUI (iOS 17+) 架构以及 CoreBluetooth 底层通信的资深 iOS 首席工程师。
请先加载并严格遵守已安装的 `swiftui-design` 和 `swiftui-expert-skill` 两个技能的规范，遵循现代 SwiftUI 最佳实践（`@Observable` 宏、`@MainActor` 线程安全、物理弹簧动画、语义化材质层级）以及苹果流体交互设计原则（瞬时按压响应、可中断物理弹簧、多模态触觉与视觉对齐），为我们的双模安全即时通讯品牌 **popopx** 构建一套完整的原生 iOS 视觉架构与全量可编译代码。

---

## 🛠️ Qoder CLI (`qoderclicn`) 本地工程执行约定

1. **目录与工程扫描（前置动作）：**
   - 在创建任何文件前，请先使用文件检索工具扫描 `apps/ios/` 的现有目录结构、`.xcodeproj` / `Package.swift` 配置以及现有 Asset 资产目录，确认源码存放的基准路径（下文简称为 `<iOS_Source_Root>`）。
   - 所有新建的 Swift 文件必须创建在 `<iOS_Source_Root>` 下的对应子目录中（如 `Theme/`、`Components/`、`Navigation/`、`Core/`、`Features/`），文档输出至 `Docs/`，确保与现有 Xcode 工程结构无缝兼容。
2. **资产保护红线：**
   - 严禁修改、覆盖或删除 `apps/ios/` 目录下已经修改好的新版 **popopx 紫色 Logo** 图片资产。请先检索 Asset 目录确认其准确名称（如 `popopx_logo` 或类似命名），在代码中直接引用该现有资产。
3. **增量替换与零旧版残留：**
   - 严禁沿用或混合 POPOPX Chat 原版粗线条黑紫极客 UI。包括主界面、新建群聊、聊天详情、所有全局及底层参数设置页，必须 100% 使用我们新建的 `PopopxControls` 原子控件库重写。
   - 在【第五阶段】重构二级页面时，请主动搜索并定位 `apps/ios/` 下现有的 `CreateGroup`、`ChatInfo`、`Settings` 等旧视图文件，直接将其重构覆盖为新架构实现，严禁保留废弃的旧版 UI 视图文件。
4. **分阶段门禁与编译验证（Execution Gate）：**
   - 由于工程量庞大，**严禁在单次回复中压缩或省略代码**。请严格按照以下 5 个阶段依次推进，**每次仅执行并写入当前阶段的完整文件**。
   - 每完成一个阶段的文件写入后，如果当前终端环境支持 `xcodebuild` 或 `swift build`，请尝试运行编译校验检查语法与引用；随后列出本阶段已创建/修改的文件清单，并**暂停等待我回复确认后，再进入下一阶段**。

---

## 🛡️ 核心代码规范铁律（Global Constraints）

1. **双模架构深度融合：**
   - **在线加密模（POPOPX Chat）：** 无用户 ID、多匿名身份切换、端到端加密队列（SMP/XFTP）。
   - **离线蓝牙 Mesh 模（BitChat / 厢语）：** 无网 BLE 蓝牙 Mesh 1–7 跳中继、`#厢语` 本地广播频道、基于 RSSI 的面对面秒连、紧急自毁（Panic Wipe）。
2. **现代 SwiftUI API 与性能红线：**
   - **状态管理：** 统一使用 iOS 17+ `@Observable` 和 `@Bindable`（禁止使用旧版 `ObservableObject` / `@Published`）。
   - **现代修饰符：** 强制使用 `.foregroundStyle(...)` 替代 `.foregroundColor(...)`；强制使用 `.clipShape(.rect(cornerRadius: ...))` 替代 `.cornerRadius(...)`；使用 `NavigationStack` 替代 `NavigationView`。
   - **无障碍与动态字体：** 所有间距与组件自适应 Dynamic Type，并响应 `@Environment(\.accessibilityReduceMotion)`（减弱动态效果时将弹簧位移降级为平滑淡入淡出）。
   - **零占位符原则：** 严禁输出 `// TODO`、`// 省略其余代码` 等偷懒注释，所有文件必须逻辑完整、可直接编译运行。

---

## ⚙️ 五阶段开发蓝图

### 第一阶段：双模视觉规范与全局主题系统
**目标文件：** `Docs/popopx-brand-spec.md`、`<iOS_Source_Root>/Theme/PopopxTheme.swift`
1. **自适应双模色板（严格满足 WCAG 2.1 AA 对比度 >= 4.5:1）：**
   - **主品牌色（在线加密态）：** 现代深靛紫（Light `#5856D6` / Dark `#7D7AFF`），用于主按钮、Tab 选中态、发送方在线气泡（配纯白文字 `#FFFFFF`）。
   - **离线蓝牙 Mesh 态（厢语专属色）：** 雷达青绿（Light `#00A896` / Dark `#00D2B8`），专用于 BLE Mesh 节点、多跳信号指示器与“厢语”频道。
   - **警戒危险色：** 原生系统红（Light `#FF3B30` / Dark `#FF453A`），用于清除记录与 Panic Wipe 紧急自毁。
   - **表面与材质层级：**
     - Light Mode：系统浅灰底色 `#F2F2F7` + 纯白卡片 `#FFFFFF`。
     - Dark Mode：OLED 纯黑底色 `#000000` + 二级深灰卡片 `#1C1C1E` + `0.5pt` 极细高光内描边（`Color.white.opacity(0.12)`）。
2. **排版与物理动画常量：**
   - 定义标准字体阶梯（支持动态字体缩放，大标题收紧字距 `-0.02em`）。
   - 定义 Apple 级物理弹簧参数：`PopopxTheme.Motion.snappy`（`response: 0.3, dampingFraction: 0.85`）、`PopopxTheme.Motion.fluid`（`response: 0.4, dampingFraction: 1.0` 无过冲阻尼）。

### 第二阶段：原子级基础 UI 控件库与多模态交互反馈
**目标文件：** `<iOS_Source_Root>/Components/PopopxHaptics.swift`、`<iOS_Source_Root>/Components/PopopxToast.swift`、`<iOS_Source_Root>/Components/PopopxControls.swift`
1. **三重同步交互反馈引擎（Visual + Haptic + Status）：**
   - **瞬时按压缩放：** 自定义 `PopopxPressButtonStyle`，在 `isPressed`（pointer-down 瞬间）触发 `scaleEffect(0.97)` 弹簧微缩，而非等到松手才响应。
   - **原生触觉引擎（`PopopxHaptics`）：** 封装 `UIImpactFeedbackGenerator`（light/medium/heavy）与 `UINotificationFeedbackGenerator`（success/warning/error），确保触觉与视觉变换在同一帧触发。
   - **全局顶部毛玻璃回执（`PopopxToast`）：** 封装支持排队与手势上滑打断的 `.ultraThinMaterial` 顶部悬浮状态胶囊，支持成功（绿勾）、离线发现（青绿雷达）、警告（橙/红感叹号）状态。
2. **全量标准化原子控件：**
   - `PopopxButton`、`PopopxTextField` / `PopopxTextArea`、`PopopxToggle` / `PopopxToggleRow` 以及各类单选、多选、分段与弹窗容器组件。

### 第三阶段：顶部三段式导航、微信式 `+` 号菜单与类微信“添加朋友”页
**目标文件：** `<iOS_Source_Root>/Navigation/PopopxTelemetryHeader.swift`、`<iOS_Source_Root>/Features/AddFriend/PopopxAddFriendView.swift`、`<iOS_Source_Root>/Features/AddFriend/PopopxFaceToFaceAddView.swift`、`<iOS_Source_Root>/Features/AddFriend/PopopxQRCardSheet.swift`
1. **顶部三段式遥测导航栏（`PopopxTelemetryHeader`）：**
   - 包含多匿名身份切换胶囊、紫色 Logo（连续点击3次触发 Panic Wipe 紧急自毁弹窗）、双模通信状态动态胶囊以及微信式 `+` 号聚合菜单。
2. **类微信“添加朋友”专属页面（`PopopxAddFriendView`）：**
   - 支持粘贴邀请链接校验、面对面蓝牙近场雷达与 4 位加密口令配对、加密名片微标条及下方功能卡片列表。

### 第四阶段：底层蓝牙 Mesh 引擎与底部四栏经典导航
**目标文件：** `<iOS_Source_Root>/Core/Bluetooth/PopopxBleMeshManager.swift`、`<iOS_Source_Root>/Navigation/MainTabView.swift`、`<iOS_Source_Root>/Features/Chats/ChatsListView.swift`、`<iOS_Source_Root>/Features/Contacts/PopopxContactsView.swift`、`<iOS_Source_Root>/Features/Cabin/PopopxCabinView.swift`、`<iOS_Source_Root>/Features/Me/PopopxMeView.swift`
1. **iOS 原生蓝牙 Mesh 引擎（`PopopxBleMeshManager`）：**
   - 基于 `CoreBluetooth` 构建 `@Observable` 状态机，支持周边节点扫描、RSSI 距离估算、1–7 跳路由跳数追踪、`#厢语` 频道广播及紧急自毁 `panicWipe()` 方法。
2. **底部四栏经典导航（`MainTabView`）：**
   - 涵盖 消息（`ChatsListView`）、通讯录（`PopopxContactsView`）、厢语（`PopopxCabinView`）与我（`PopopxMeView`）。

### 第五阶段：对话流气泡、毛玻璃输入栏与全量二级设置页彻底重写
**目标文件：** `<iOS_Source_Root>/Features/ChatRoom/ChatView.swift`、`<iOS_Source_Root>/Features/ChatRoom/PopopxMessageBubble.swift`、`<iOS_Source_Root>/Features/ChatRoom/PopopxInputBar.swift`、`<iOS_Source_Root>/Features/Group/CreateGroupView.swift`、`<iOS_Source_Root>/Features/ChatRoom/ChatInfoView.swift`、`<iOS_Source_Root>/Features/Settings/PopopxSettingsViews.swift`
1. **现代对话流与输入栏：**
   - 动态圆角合并气泡 (`PopopxMessageBubble`)、通道状态微标、阅后即焚倒计时以及 `.ultraThinMaterial` 毛玻璃输入栏 (`PopopxInputBar`)。
2. **全量重写所有二级页面与底层参数设置：**
   - 100% 原子化重构群组创建、聊天详情、隐私安全、生物识别锁、SMP/XFTP 测速、蓝牙 Mesh 功耗配置及本地数据库自毁等页面。

---

**现在，请先加载技能并扫描 `apps/ios/` 现有工程结构与紫色 Logo 资产路径,确认后立即开始执行【第一阶段】。**

