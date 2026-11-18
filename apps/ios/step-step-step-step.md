/swiftui-design /swiftui-expert-skill

# Role & Context
你是一位精通 Apple Human Interface Guidelines (HIG)、现代 SwiftUI (iOS 17+) 架构、大规模多语言本地化工程规范（String Catalogs `.xcstrings` / `.lproj`）以及 `xcodebuild` 命令行自动化构建的资深 iOS 首席工程师。
目前项目（iOS App 新名称：**POPOPX**，Fork 自 SimpleX Chat iOS）已完成以下三大核心系统集成：
1. **双模通信与物理近场引擎（`PopopxMeshKit/` 本地 Swift Package）：** 包含无网 BLE 蓝牙 Mesh（`#厢语` 1–7 跳中继）、`PopopxMessageRouter` 智能路由、`IdentityMappingStore`、`PopopxOfflineBridge`、`ManualPairingManager`、`PopopxProximityEngine`（UWB 灵犀近场 15cm 感应 + TapDrop 顶部轻触密传）及 `PanicWipeManager` 紧急自毁。
2. **金融/军工级全链路防窥防录屏系统（`POPOPXSecurity/`）：** 包含 `POPOPXSecureWindowManager` 独立防截屏弹窗、`POPOPXCameraGuardEngine` 双引擎防偷窥检测、Face ID 启动锁与物理内存/数据库销毁。
3. **现代双模原子视觉架构：** 已在主工程建立 `Theme/PopopxTheme.swift`、`Components/PopopxControls.swift`、`Components/PopopxToast.swift`、`Components/PopopxHaptics.swift` 以及 `Navigation/`、`Features/` 下的完整现代界面体系，并保留了 `apps/ios/` 中现有的 **POPOPX 紫色 Logo** 图片资产。

现在，我们需要定位并彻底重构 **原版首次启动的 4 个引导页（Onboarding）UI 样式与交互结构**，将新品牌名称 **POPOPX** 融入视觉与文案，深度融合上述三大系统的核心能力，并**自动检测仓库已生成的全部语种实现 100% 全语种本地化同步补全，最后自动运行 `xcodebuild` 完成编译闭环验证**。

---

## 🛠️ Qoder CLI (`qodercli`) 本地工程执行约定（必须 100% 遵守）

### 1. 前置扫描与精确对齐（零凭空捏造符号）
- **引导页与状态机扫描：** 在编写任何代码前，先扫描 `apps/ios/` 目录下原版首次启动引导流程（Onboarding）的全部 SwiftUI 视图文件（通常位于 `Views/Onboarding/` 或相关启动状态机文件中，包含：**欢迎页、创建本地用户资料/匿名身份、推送通知与网络配置、Network commitments 网络承诺确认** 4 个核心步骤），同时定位 `.xcodeproj` / `.xcworkspace` 路径与主 Scheme 名称。
- **设计系统与引擎接口扫描：** 扫描 `Theme/PopopxTheme.swift`、`Components/PopopxControls.swift`、`Components/PopopxHaptics.swift`、`Components/PopopxToast.swift` 的**真实公开初始化参数与枚举定义**，以及 `PopopxMeshKit/`、`POPOPXSecurity/` 暴露的真实 `public` 接口，确保 100% 编译对齐。

### 2. 全量已生成语种检索与 100% 同步本地化铁律（关键红线）
- **盘点系统已生成的所有语种：**
  - 在第一阶段必须全面扫描 `apps/ios/` 下的本地化资源文件（包括 `.xcstrings` String Catalog 内已注册的所有 `localizations` 语言代码，以及所有 `*.lproj/Localizable.strings` 目录，如 `en`、`zh-Hans`、`zh-Hant`、`ja`、`ko`、`es`、`fr`、`de`、`ru` 等仓库现存全部语种）。
  - 向我明确列出扫描到的**全部语种清单**、**文件结构**及**现有 Key 命名规范**（如点分式、下划线式或集中式字符串封装）。
- **全语种零遗漏翻译补全：**
  - 严格对齐项目现有 Key 命名风格与调用方式，禁止发明冲突规范。
  - **必须为仓库中已生成的每一个语种（100% 全覆盖，绝不只写中英三语）同步写入这 4 个引导页的全部新增词条**，确保任何语言环境下均无 Key 原始字符串外露（Raw Key Leak）。
  - **品牌名称统一：** 所有语种文案中涉及 App 名称的地方统一使用 **POPOPX**（严禁残留 `SimpleX` 或 `SimpleX Chat` 字样）。
  - **零硬编码 UI 字符串：** 4 个引导页中的所有标题、副标题、胶囊标签、卖点描述、输入框占位符、开关说明、承诺条款、按钮文案及 `PopopxToast` 提示，**严禁出现任何硬编码字符串**。

### 3. 免改 `.pbxproj` 零工程破坏策略 & 资产保护
- **严禁使用脚本直接修改 `.pbxproj` 工程文件**（极易导致工程损坏）。
- **免手动拖入 Xcode 技巧：** 所有重构代码（包括公共引导页顶部进度条组件 `PopopxOnboardingHeader`）**优先直接原地写入已存在于 Xcode Compile Sources 中的原版引导页 `.swift` 文件内**，避免新增未注册的孤立文件，确保无需手动打开 Xcode 拖入即可直接参与编译。
- **严禁覆盖、修改或删除 `apps/ios/` 中现有的 POPOPX 紫色 Logo 图片资产**。
- 完整保留原版数据库初始化、Profile 创建、APNs 推送模式配置、备份恢复跳转及网络承诺状态保存的底层状态机逻辑绑定。

### 4. 现代 SwiftUI API 与视觉统一红线
- **100% 原子化重构：** 4 个引导页中严禁残留任何原版细线边框、黑紫极客风或系统默认蓝色按钮/输入框，全部使用 `PopopxControls`（`PopopxButton`、`PopopxTextField`、`PopopxToggleRow`、`PopopxRadioRow`、`PopopxCheckbox`、`PopopxSectionCard`）。
- **双模色板严格对齐：**
  - 在线 SMP 加密主品牌色：现代深靛紫（Light `#5856D6` / Dark `#7D7AFF`）配纯白文字 `#FFFFFF`（WCAG 2.1 AA >= 4.5:1）。
  - 离线蓝牙 Mesh 专属色（`#厢语`）：雷达青绿（Light `#00A896` / Dark `#00D2B8`）。
  - 表面材质：Light `#F2F2F7` 底色配纯白圆角卡片；Dark `#000000` OLED 纯黑底色配 `#1C1C1E` 二级深灰圆角卡片（`16pt` 圆角）与 `0.5pt` 极细内描边，兼容现代 iOS 毛玻璃（Liquid Glass）视觉层次。
- **三重交互反馈：** 所有可交互控件强制具备 ① `scaleEffect(0.97)` 弹簧微缩 + ② `PopopxHaptics` 触觉震动 + ③ 即时状态回执（绿勾动画 / 顶部毛玻璃 `PopopxToast`）。
- **现代 API：** 严禁使用 `.foregroundColor`、`.cornerRadius`、旧版 `NavigationView`，统一使用 `.foregroundStyle`、`NavigationStack`、`.clipShape(.rect(cornerRadius: ...))` 及 iOS 17+ `@Observable` / `@Bindable`，并完整适配 Dynamic Type 动态字体与 `accessibilityReduceMotion`。

### 5. 终端自动化 `xcodebuild` 编译与异常处理闭环
- 在第二阶段写入代码后，直接调用终端工具执行主工程编译校验（等效于 Xcode `Cmd + B`）：
  `xcodebuild build -project <定位到的工程路径> -scheme <主Scheme名> -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
- **自愈修复：** 若编译器输出任何 `error:`（如类型不匹配、参数签名不一致等），请**自动分析错误堆栈并立即修改代码重新编译**，直到输出 `** BUILD SUCCEEDED **`。
- **例外处理：** 如果终端报错显示因 `.pbxproj` 未索引到新建文件而编译失败，请立即停止反复重试，清晰列出需要手动拖入 Xcode Target 的文件并暂停等待确认。

---

## ⚙️ 4 个引导页 UI 样式与功能融合详细规范

### 第 1 页：双模安全与军工隐私宣言页（Welcome & Dual-Mode Hero）
- **顶部视觉焦点：** 居中展示现有的 **POPOPX 紫色 Logo**（叠加柔和现代深靛紫环境光晕，响应 `accessibilityReduceMotion`），Logo 下方展示品牌名 **POPOPX** 与两枚并排悬浮的双模动态状态胶囊：
  - 左侧胶囊（深靛紫徽章 + `lock.shield.fill`）：`SMP 端到端加密`（多语言 Key）
  - 右侧胶囊（雷达青绿徽章 + `dot.radiowaves.left.and.right`）：`厢语蓝牙 Mesh 无网中继`（多语言 Key）
- **核心卖点卡片（替代原版枯燥轮播文字）：** 使用 `PopopxSectionCard`（`16pt` 圆角）整合 3 条核心卖点，每条配备圆角彩色 SF Symbol 徽章、清晰主标题与一行副标题：
  1. **零用户 ID（No User IDs）：** 无手机号、无邮箱、无全局公钥，彻底杜绝社交图谱追踪。
  2. **多匿名身份与双模近场通信：** 支持多身份隔离，有网走加密队列，断网自动切换 `#厢语` 1–7 跳蓝牙 Mesh 中继，支持 UWB 灵犀近场与轻触密传面对面秒连。
  3. **军工级防窥阅后即焚：** 硬件级防截屏录屏、前置防旁观偷窥与三击 Logo 紧急物理自毁保护。
- **底部操作区：**
  - 通栏 `PopopxButton(.primary)`（深靛紫实心主按钮，文案对应“开始构建加密身份”）。
  - 下方配 `PopopxButton(.ghost)`（文案对应“从加密备份恢复”，直接打通原版导入备份入口，解决必须先建空库才能导入备份的痛点）。

### 第 2 页：创建本地匿名身份（Create Local Identity）
- **顶部统一进度胶囊：** 显示 `1 / 3` 步骤进度与标签“身份隔离”，主标题“创建你的首个匿名身份”，副标题强调“身份与密钥仅加密存储于本机，服务器完全不可见”。
- **头像与身份卡片（`PopopxSectionCard`）：**
  - 顶部放置可点击生成的几何抽象头像（带相机相册选取 / 随机色盘刷新微标）。
  - 下方使用 `PopopxTextField`（`12pt` 圆角容器，聚焦态 `FocusState` 触发深靛紫高亮描边）重构原版表单：
    - **主输入框：** 匿名代号（必填，左侧 `person.crop.circle.badge.checkmark` 图标 + 一键清空按钮）。
    - **次输入框：** 备注全名（选填，说明仅展示给指定信任好友）。
- **隐私增强快捷开关：** 独立 `PopopxSectionCard` 内置 `PopopxToggleRow`，默认开启“默认启用隐身模式（Incognito）”，说明每次建立新连接自动随机化独立临时昵称。
- **底部操作区：** `PopopxButton(.primary)`（“下一步”，输入为空时自动禁用并给予温柔校验提示）。

### 第 3 页：双模通信与通知策略（Dual-Mode & Notifications）
- **顶部统一进度胶囊：** 显示 `2 / 3` 步骤进度与标签“双模路由与通知”，主标题“选择连接与唤醒方式”。
- **卡片 A · 在线 SMP 加密通道（iOS 推送模式）：** 使用 `PopopxSectionCard` + `PopopxRadioRow` 重构原版推送选择，将大段说明文字精简为直观的选项与隐私等级标签：
  1. **即时推送（Instant）：** 依托 Apple APNs 毫秒级触达（副标题标注“低延迟 · 轻微元数据暴露”）。
  2. **定时静默拉取（Periodic）：** 后台定时检查加密队列（副标题标注“高隐私 · 均衡续航”）。
  3. **零推送服务器（No Push）：** 仅打开 App 时拉取消息（副标题标注“极致隐身 · 零服务器推送”）。
- **卡片 B · 离线蓝牙 Mesh 与近场引擎（#厢语模式）：** 新增 `PopopxSectionCard` + `PopopxToggleRow`（雷达青绿 `#00A896` 图标徽章），直接绑定 `IdentityMappingStore` 的蓝牙 Mesh 总开关状态，引导用户一键预开启 **CoreBluetooth 蓝牙 Mesh 中继**，说明断网时自动加入附近 1–7 跳设备网络并支持 UWB / 轻触密传面对面秒连。
- **底部操作区：** 支持返回上一步 + `PopopxButton(.primary)`（“继续”）。

### 第 4 页：安全承诺与本地库加固（Security Commitments & Vault）
- **顶部统一进度胶囊：** 显示 `3 / 3` 步骤进度与标签“安全承诺与启动”，主标题“安全承诺与本地防护”。
- **网络与安全承诺可视化卡片（替代原版 `Network commitments` 纯文本条款）：** 使用 `PopopxSectionCard` + `PopopxCheckbox`（勾选触发 `0.97` 弹性微缩 + `PopopxHaptics` 轻震 + 绿勾动画回执），精简为 3 项清晰确认项：
  1. 已知悉消息经由去中心化中继节点异步转发，本地删除即不可逆。
  2. 已知悉多跳隐私路由（Private Routing）默认开启以隐藏真实 IP 地址。
  3. 已知悉连续点击顶部 Logo 3 次可触发 **Panic Wipe 紧急物理擦除**，绝密消息受硬件级防截屏与防偷窥保护。
- **本地防窥快速配置：** 独立 `PopopxSectionCard` 内置 `PopopxToggleRow`“启用 Face ID / Touch ID 启动锁”（联动项目现有的生物识别锁配置状态）。
- **完成操作：** 全部必选项勾选后高亮激活底部 `PopopxButton(.primary)`（“同意并进入 POPOPX”）；点击后触发成功强震动反馈与顶部毛玻璃 `PopopxToast`（“加密队列、蓝牙 Mesh 与防窥盾已就绪”），完成初始化并平滑过渡进入主界面四栏 Tab。

---

## 📋 分阶段执行与验收输出要求（防截断）

**请严格按以下两阶段执行，严禁使用 `// TODO` 或省略号占位符：**

### 【第一阶段】：工程扫描、全语种盘点与多语言词条写入（执行后暂停汇报）
1. **全面扫描汇报：**
   - 扫描并列出 `apps/ios/` 下原版 4 个引导页视图文件路径，以及 `.xcodeproj` / `.xcworkspace` 路径与主 Scheme 名称；
   - 扫描并列出项目**已生成的全部语种清单**、**多语言文件位置（`.xcstrings` 或 `*.lproj/*.strings`）、Key 命名格式及调用方式**；
   - 扫描 `Theme/PopopxTheme.swift`、`Components/PopopxControls.swift`、`Components/PopopxToast.swift`、`Components/PopopxHaptics.swift` 的精确初始化签名，以及引导页开关需绑定的 `PopopxMeshKit` 与生物识别锁状态接口。
2. **全语种词条预录入：** 按照扫描到的项目真实多语言命名规范，为**仓库已生成的每一个语种**完整写入本批引导页所需的全套本地化词条（确保品牌名统一为 `POPOPX`）。
3. 汇报扫描映射表、覆盖语种列表与新增本地化 Key 列表后**立即暂停**，等待我确认“继续第二阶段”。

### 【第二阶段】：POPOPX 4 引导页全量 UI 重构与 `xcodebuild` 自动编译验证
1. 直接在已纳入编译目标的原版引导页文件中完成重构（公共顶栏进度组件 `PopopxOnboardingHeader` 内聚在现有引导页文件内，确保零未注册孤立文件），确保：
   - 100% 使用 `PopopxControls` 原子控件与 `PopopxTheme` 双模色板；
   - 所有 UI 文本全部引用第一阶段录入的本地化 Key，零硬编码字符串、零 `SimpleX` 旧品牌名残留；
   - 保留原版状态机跳转、创建 Profile、推送模式设置、备份导入及蓝牙 Mesh/生物识别开关状态持久化。
2. **全自动命令行编译闭环：**
   - 严格按照第 5 条运行 `xcodebuild` 编译校验，自动分析并修复任何编译错误直至输出 `** BUILD SUCCEEDED **`。
3. 最终向我输出：
   - 修改文件清单与覆盖语种总结；
   - `xcodebuild` 编译通过日志摘要；
   - 全语种切换与暗黑/浅色模式双模视觉自检结论。
