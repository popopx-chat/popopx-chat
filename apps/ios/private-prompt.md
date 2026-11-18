# Role & Context
你现在是一名资深的 iOS 安全架构师、逆向防御专家、计算机视觉工程师与 Swift / SwiftUI 专家。
当前 **popopx**（Fork 自 SimpleX Chat iOS）已完成第一阶段至第五阶段的现代 iOS 视觉重构与底层蓝牙组网融合，工程中已存在：
- 本地 Swift Package：`PopopxMeshKit/`（含 `PopopxMessageRouter` 双模智能路由、`BluetoothHealthMonitor`、`PanicWipeManager`）
- 现代设计系统与原子控件：`Theme/PopopxTheme.swift`、`Components/PopopxControls.swift`、`Components/PopopxHaptics.swift`、`Components/PopopxToast.swift`
- 重构后的现代聊天室：`Features/ChatRoom/ChatView.swift`、`Features/ChatRoom/PopopxMessageBubble.swift`、`Features/ChatRoom/PopopxInputBar.swift`

# Core Objective
请在现有 **popopx** 新版 UI 架构之上，无缝集成一套开箱即用、无需手动训练模型的**“绝密阅后即焚安全弹窗与金融级全链路防窥防录屏系统（POPOPX Secure Ephemeral Defense System）”**。

该系统必须严格复用现有的 `PopopxTheme` 与 `PopopxControls` 视觉规范，并遵循**“按需激活、用完即毁、零后台残留”**的生命周期边界，实现以下 **6 大核心安全防线**：
1. **独立安全弹窗、Release 级全局反调试（`PT_DENY_ATTACH`）与物理级内存/数据库销毁**
2. **金融/军工级防系统截图、屏幕录制与投屏（底层容器劫持 + 60Hz `CADisplayLink` 毫秒级轮询熔断）**
3. **防第二人旁观偷窥（前置摄像头双人脸检测 + 手势聚光灯模式）**
4. **【主引擎】零训练开源 YOLO 权重自动导出与多类别过滤（检测手机、相机、光学设备）**
5. **【兜底引擎】纯图像算法高光反射热点检测（无需深度学习模型，识别暗光/远距离镜头反光点）**
6. **光学与溯源防御（CADisplayLink 高频抗快门渲染 + 逐行滑动阅读 + 全屏隐形盲水印）**

---

## 🛠️ Qoder CLI (`qoderclicn`) 工程协同与编译约定
1. **复用现有新 UI 组件与双模路由：**
   - 严禁创建与 `PopopxControls` 冲突的自定义按钮或提示框。弹窗内的按钮、分段选择器（聚光灯模式 / 逐行模式切换）、触觉震动与警告提示，必须直接调用现有的 `PopopxTheme`、`PopopxControls`、`PopopxHaptics` 和 `PopopxToast`。
   - 绝密消息发送及“对方尝试截屏/录屏”的系统安全告警回执，统一通过 `PopopxMessageRouter` 发送，确保在在线（SMP）与离线（蓝牙 Mesh 厢语）双模式下均可送达。
2. **禁止修改 `.pbxproj` 与保护资产：** 严禁使用脚本直接修改 `.pbxproj` 工程文件；严禁修改现有的紫色 Logo 资产。
3. **现代 SwiftUI API 规范：** 统一使用 iOS 17+ `@Observable`、`@Bindable`、`.foregroundStyle(...)`、`.clipShape(.rect(cornerRadius: ...))`，严禁使用 `// TODO` 占位符。
4. **终端自动化编译门禁（`xcodebuild` Gate）：** 生成完毕后，自动执行 `xcodebuild` 编译校验并自愈修复所有代码报错（若仅因新建文件尚未手动拖入 `.pbxproj` Target 导致报错，请列出新增文件清单并暂停等待我拖入确认）。

---

## ⚙️ Detailed Engineering Specifications

### 模块一：零训练开源权重自动导出与多类别过滤 (`Scripts/setup_pretrained_coreml.py`)
1. **全自动开源权重拉取与转换**：
   - 在工程根目录生成 `Scripts/setup_pretrained_coreml.py` 与 `Scripts/requirements.txt`。
   - 脚本自动调用 `ultralytics` 下载轻量级开源预训练模型 `yolo11n.pt`（或自动回退至 `yolov8n.pt`），支持通过 `--custom-weights` 传入第三方开源手机检测权重（`.pt`）。
   - 自动导出为启用 **FP16 量化** 且 **内置 NMS（`nms=True`）** 的 iOS CoreML 模型包：`POPOPXAntiSpyDetector.mlpackage`（输入尺寸 `320x320`，确保 iPhone 端推理延迟 `< 12ms`）。
2. **多类别智能过滤规则（在 `POPOPXCameraGuardEngine.swift` 中实现）**：
   - 动态加载 `POPOPXAntiSpyDetector.mlmodelc`（支持模型未导入时的平滑降级，自动切换至模块二的纯算法兜底引擎）。
   - 过滤高危拍摄设备白名单：
     - **高危拍摄类**（置信度 `>= 0.40` 立即熔断）：`"cell phone"`, `"camera"`, `"mobile phone"`, `"lens"`。
     - **潜在近距离录屏类**（置信度 `>= 0.55` 熔断）：`"laptop"`, `"tv"`, `"remote"`。

### 模块二：纯图像算法高光反射热点兜底引擎 (`POPOPXSecurity/POPOPXGlareDetector.swift`)
使用 Apple 原生高性能图像处理框架 **`CoreImage` + `Accelerate (vImage)`** 实现纯数学镜头反光检测（零包体积增加）：
1. **高光饱和度热点提取**：读取前置摄像头 `CVPixelBuffer` 的亮度通道（Y-Plane / Luma），利用 `vImage` 阈值二值化提取亮度极高（`Luma > 245`）的过曝像素区域。
2. **连通域圆形度与亮度突变过滤**：仅保留占画面 `0.05% ~ 3.5%` 的微型反光点，计算圆形度 $C = \frac{4\pi \times \text{Area}}{\text{Perimeter}^2}$（阈值 $C \ge 0.72$）。若连续 2 帧检测到高圆形度微型光斑，或整体画面均值突然跃升（闪光灯/激光对焦），毫秒级触发 `SecurityAlert.lensGlareDetected`。

### 模块三：防第二人旁观偷窥与算力互斥调度 (`POPOPXSecurity/POPOPXCameraGuardEngine.swift`)
- **前置摄像头静默调度**：仅在安全弹窗打开期间，以低功耗模式（`.vga640x480`, `10 FPS`）启动前置摄像头，并在弹窗开启时通知底层临时降低非必要蓝牙后台扫描频率以保障 NPU 算力；弹窗关闭后立即恢复。
- **双引擎并行推理**：在独立串行队列 `com.popopx.vision.guard` 中同步执行 `VNDetectFaceRectanglesRequest`（检测到 **>= 2 张人脸** 或主用户离开视角超过 `0.5s` 立即锁定遮罩）、CoreML 目标检测与 `POPOPXGlareDetector` 高光热点检测。

### 模块四：金融/军工级防截图、防录屏与反调试 (`POPOPXSecurity/POPOPXScreenCaptureShieldView.swift` & `POPOPXAntiDebug.swift`)
1. **底层渲染层 DRM 级黑屏屏蔽**：构建 `UIViewRepresentable` 安全容器 `POPOPXScreenCaptureShieldView`，封装隐藏的 `UITextField`（`isSecureTextEntry = true`）并提取 `_UITextLayoutCanvasView`，确保系统录屏、截图、AirPlay 无线投屏及有线采集卡捕获到的画面全部变成**纯黑**。
2. **60Hz `CADisplayLink` 每帧轮询 `isCaptured` 毫秒级熔断**：除监听系统截屏/录屏/后台切换通知外，弹窗激活期间挂载 **60Hz `CADisplayLink` 实时监控器**，每 `16.6ms` 轮询所有 `UIScreen.screens` 的 `isCaptured` 属性。一旦检测到 `isCaptured == true` 或截屏，16ms 内强制替换为全屏纯黑遮罩、销毁消息、清零内存，并通过 `PopopxMessageRouter` 发送安全告警回执。
3. **Release 生产包全局反调试（`POPOPXAntiDebug.swift`）**：使用 `#if !DEBUG` 隔离，在 App 启动入口通过 `dlsym` 动态调用 `ptrace(PT_DENY_ATTACH, 0, 0, 0)` 及 `sysctl` 检测 `P_TRACED`，防止攻击者在普通界面提前挂载 LLDB/Frida 调试器。

### 模块五：独立安全弹窗、协议兼容与内存物理销毁 (`POPOPXSecurity/POPOPXProtocolParser.swift` & `POPOPXSecureWindowManager.swift`)
- **协议无侵入兼容**：识别消息前缀 `::popopx_sec::{ttl_seconds}::{payload}`。在现代气泡组件 `Features/ChatRoom/PopopxMessageBubble.swift` 中拦截此类消息，渲染为符合 `PopopxTheme` 视觉规范（现代深靛紫加密锁盾卡片 + 倒计时角标）的不可预览安全卡片。
- **独立安全窗口与生物识别**：打开前预检 `UIScreen.main.isCaptured`；通过后触发 `LAContext`（FaceID / TouchID）认证，随后在独立 `UIWindow` 层级（`windowLevel = .alert + 1`）弹出 `POPOPXSecureSheetView`。
- **物理销毁与内存擦除**：倒计时归零、关闭弹窗或触发安全告警时，调用 SimpleX 底层接口物理删除本地数据库记录，并对存储明文的 `Data` 缓冲区调用 C 标准库 `memset_s` 执行强制内存覆写清零。

### 模块六：光学抗拍照、手势聚光灯与隐形盲水印 (`POPOPXSecurity/POPOPXAntiPhotoRenderView.swift`)
- **CADisplayLink 高频时分复用抗快门渲染**：利用 `CADisplayLink`（60Hz/120Hz）在每一帧交替绘制互补的高频像素点阵掩码覆盖在文字上（利用卷帘快门采样频率差使外部手机拍出摩尔纹与残缺乱码），提供一键开关。
- **防窥阅读交互模式（使用 `PopopxSegmentedControl` 切换）**：
  - **手势聚光灯模式（Spotlight）**：全文默认重度高斯模糊，仅手指按住坐标周围 `45pt` 圆形区域显示清晰明文，松手即恢复模糊。
  - **按住逐行防构图模式（Teleprompter）**：限制单行窗口，必须按住并拖动滑块逐字浏览，防止外部相机对焦拍下完整段落。
- **全屏隐形溯源盲水印（`POPOPXBlindWatermarkOverlay`）**：顶层叠加自定义 `CALayer`，将查看者设备 UUID、会话 ID 和毫秒时间戳编码为微弱低对比度点阵纹理（`#010101` 与 `#000000` 交替像素矩阵），后期色阶拉伸可还原追责。

---

## 🛡️ Lifecycle & Memory Leak Prevention Standards (Strict Enforcement)
除全局反调试外，**所有摄像头采集、Vision/CoreML 推理、`CADisplayLink` 定时器、截屏容器劫持与盲水印渲染，必须严格限定在 `POPOPXSecureSheetView` 弹窗显示期间运行**：
1. **打破 `CADisplayLink` 强引用循环**：必须实现通用的 `POPOPXWeakDisplayLinkProxy` 弱引用代理类，严禁直接强引用视图或控制器。
2. **摄像头与视频流确定性销毁**：设置原子状态锁 `private var isSessionActive = false`，`stopMonitoring()` 时先置为 `false` 丢弃残余帧、解除 `SampleBufferDelegate`、停止 `captureSession` 并置空，确保绿色摄像头指示灯在弹窗关闭瞬间熄灭。
3. **双保险清理与 `deinit` 自检**：在 `.onDisappear` 与 `dismissSecureWindow()` 中显式清理所有引擎，并为所有核心管理类编写 `#if DEBUG` 下的 `deinit` 回收断言日志。

---

## 📂 File Structure & Integration Points
请在 `apps/ios/` 对应的 Swift 源码目录下创建 `POPOPXSecurity/` 文件夹及脚本目录，生成以下 10 个完整文件（严禁省略核心代码）：
1. `Scripts/setup_pretrained_coreml.py`（及 `Scripts/requirements.txt`）
2. `POPOPXSecurity/POPOPXAntiDebug.swift`
3. `POPOPXSecurity/POPOPXWeakDisplayLinkProxy.swift`
4. `POPOPXSecurity/POPOPXProtocolParser.swift`
5. `POPOPXSecurity/POPOPXGlareDetector.swift`
6. `POPOPXSecurity/POPOPXCameraGuardEngine.swift`
7. `POPOPXSecurity/POPOPXScreenCaptureShieldView.swift`
8. `POPOPXSecurity/POPOPXAntiPhotoRenderView.swift`
9. `POPOPXSecurity/POPOPXSecureWindowManager.swift`
10. `POPOPXSecurity/POPOPXSecureSheetView.swift`

# Execution Instructions
1. 首先读取并对齐现有的 `Theme/PopopxTheme.swift`、`Components/PopopxControls.swift`、`Features/ChatRoom/PopopxInputBar.swift`、`Features/ChatRoom/PopopxMessageBubble.swift`、App 启动入口及 `Info.plist`。
2. 在 App 启动入口接入 `POPOPXAntiDebug.enableProtection()`（仅 `#if !DEBUG` 生效），并检查 `Info.plist` 确保包含 `NSCameraUsageDescription` 与 `NSFaceIDUsageDescription`。
3. 依次生成上述 10 个完整文件，并修改 `PopopxInputBar.swift`（在 `+` 号功能面板中添加“绝密阅后即焚”发送按钮与 TTL 时长选择器）及 `PopopxMessageBubble.swift`（拦截 `::popopx_sec::` 消息并渲染现代安全卡片点击入口）。
4. 执行终端 `xcodebuild` 自动编译门禁校验并汇报结果。
