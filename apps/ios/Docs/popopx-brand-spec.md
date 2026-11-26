# popopx 品牌视觉规范 · Brand Spec v1

适用范围：`apps/ios/` 主工程（POPOPX (iOS) target）与 `PopopxMeshKit` 的 UI 层。
Token 实现：`apps/ios/Shared/Theme/PopopxTheme.swift`。
对比度数据来源：`apps/ios/Docs/contrast_check.py`（本文所有比例均由该脚本实测，非估算）。

状态：**第一、二阶段已落地**（规范 + 全局主题 `PopopxTheme.swift` + 原子控件库 `Shared/Components/`）。第三～五阶段按 `ui-prompt.md` 的门禁推进。

---

## 0. 前置扫描对齐清单（实测）

### 0.1 PopopxMeshKit 包

| 事实 | 实测位置 |
|---|---|
| 本地 SPM，两个 product：`PopopxMeshKit` / `PopopxMeshUI` | `PopopxMeshKit/Package.swift:16-18` |
| 平台声明 `.iOS(.v15), .macOS(.v14)` | `PopopxMeshKit/Package.swift:12-14` |
| tools-version 6.0（包内 target 走 Swift 6 严格并发） | `PopopxMeshKit/Package.swift:1` |
| 源码 31 个 .swift / 13,632 行（Kit 23 文件 9,074 行 + UI 8 文件 4,558 行） | `Sources/PopopxMeshKit/*`、`Sources/PopopxMeshUI/*` |
| 包内测试：16 个文件，`@Test` 标注 289 处（Swift Testing，非 XCTest） | `PopopxMeshKit/Tests/*` |
| 已在工程中挂载（`XCLocalSwiftPackageReference "PopopxMeshKit"`） | `POPOPX.xcodeproj/project.pbxproj`（2026-11-18 重测）：`PopopxMeshUI in Frameworks` build file `:21`、`PopopxMeshKit in Frameworks` `:267`，两条同挂于 Frameworks 阶段 `:757-758`；target 的 `packageProductDependencies` `:1375-1376`；包引用定义 `:2718`（`relativePath = PopopxMeshKit` `:2720`）；`XCSwiftPackageProductDependency` 区段自 `:2783`。**这些行号每次 Xcode 重存工程都会位移**（第二阶段挂载后已从 286/756/2714/2778 全部变过），引用前先 `grep -n "PopopxMesh" POPOPX.xcodeproj/project.pbxproj` 重测 |

**桥接与身份（Phase 3 直接调用）**

| 能力 | 签名与位置 |
|---|---|
| 生成离线邀请链接 | `PopopxOfflineBridge.generateOfflineInviteLink(meshPublicKeyHex:incognito:)` — `Bridge/PopopxOfflineBridge.swift:141`（actor，`init(core:store:)` `:109`） |
| 接受邀请链接 | `acceptOfflineInviteLink(_:meshPublicKeyHex:incognito:)` — 同文件 `:180` |
| 写入 Mesh 身份绑定 | `IdentityMappingStore.bind(tempConnId:meshPublicKeyHex:nickname:)` — `Identity/IdentityMappingStore.swift:228`；升级 `:261`、解绑 `:287/:296`、全清 `emergencyWipeAllMappings()` `:316`；均为 `public actor`，`.shared` 可用 |
| 配对策略 / Mesh 总开关真值 | `pairingPolicy` `:140`、`meshEnabled` `:152`、`updatePairingPolicy` `:162`、`updateMeshEnabled` `:166` |

**蓝牙挂起 / 恢复（Phase 3 的射频互斥红线）**

| 层级 | 实测 |
|---|---|
| 传输层 | `PopopxBLETransport.stop()` — `BLE/PopopxBLETransport.swift:134` → `shutDown()` `:256`，其中 **真实调用** `centralManager?.stopScan()` `:262`、`cancelPeripheralConnection(_:)` `:263`、`peripheralManager?.stopAdvertising()` `:266`，随后 `dropAllLinks` 与两个 delegate 摘除 `:275-276` |
| 恢复 | `start()` `:130` → `begin()` → `bringRadioUp()` `:238`（scan 周期 + 广播 + maintenance 全部幂等重挂）；任一 manager 先回 `.poweredOn` 时由 `resumeRadioIfReady()` `:251` 补齐另一半 |
| 引擎层 | `PopopxMeshEngine.start(nickname:)` `Engine/PopopxMeshEngine.swift:144`、`stop()` `:164`、`isRunning` `:185`、`bluetoothState` `:188` |
| App 侧句柄 | `PopopxMeshEngineBackend.meshSwitchDidTurnOff()` / `meshSwitchDidTurnOn(nickname:)` — `Shared/Model/POPOPXAPI.swift:3614` 与 `:3607`（协议 `PopopxMeshSwitchable` 定义在 `Sources/PopopxMeshUI/PopopxMeshKillSwitch.swift:43`）；实例挂在 `PopopxMeshRuntime.shared.engineBackend` |

> 结论：Phase 3 的"挂起/恢复"必须走 `engineBackend`（或包内 `PopopxMeshEngine`）的 **stop/start**，不得只翻布尔位；上表已证明 stop 路径真的落到 CoreBluetooth。

**节点状态与健康（Phase 3 顶栏 / Phase 4 厢语页绑定）**

| 能力 | 实测位置 |
|---|---|
| 跳数 | `PopopxPeerReachability.hopCount` — `Health/BluetoothHealthMonitor.swift:54`；`reachability(ofMeshPublicKeyHex:)` `:209`；`isRadioUsable` `:205`、`currentRadioState` `:207`；actor `.shared`，`start()` `:101` / `stop()` `:122` |
| 蓝牙状态枚举 | `PopopxBluetoothState`（`unknown/resetting/unsupported/unauthorized/poweredOff/poweredOn`）— `Events/PopopxMeshEvents.swift:17-25` |
| 网络路径 | `NetworkStateMonitor.shared`（`start()` `:325`、`stop()` `:336`、`startIfNeeded()` `:347`、`isStarted` `:352`）、`PopopxNetworkPath.displayText` `:175`、`PopopxPathBlockage` `:78` — `Router/NetworkStateMonitor.swift` |
| 统一流状态 | `PopopxMeshStateSource.shared.observeState() -> AsyncStream<PopopxMeshStreamState>` — `Sources/PopopxMeshUI/PopopxMeshStateSource.swift:222`；`PopopxMeshStreamState` 含 `radioState/peers/privateMessages/broadcasts/awaitingRelayMessageIDs` `:24-40` |
| 路由发送 | `PopopxMessageRouter.send(_:)` `:630`、`sendText(_:toContactId:)` `:685` — `Router/PopopxMessageRouter.swift` |
| 手动建联横幅 | `PopopxMeshBannerModel`（`start()` `:164`、`approve()` `:204`、`decline()` `:216`）与 `ManualPairingBannerView(model:)` `:371` — `Sources/PopopxMeshUI/ManualPairingBannerView.swift` |
| 紧急自毁 | `PopopxPanicWipeManager.execute(includeApplicationDatabase:)` `:549`；三击手势组件 `PopopxPanicWipeGate(_:)` `:722`；确认弹窗第二句（数据边界）取 `PopopxPanicWipeManager.confirmationBoundary` `:454` — `Sources/PopopxMeshUI/PanicWipeManager.swift` |
| 频道角标语义（现状） | `PopopxMeshBadgeDescriptor.Tone = .blue/.orange/.grey`，图标 `shield.lefthalf.filled` / `antenna.radiowaves.left.and.right` / `clock` — `Sources/PopopxMeshUI/MergedTimelineModifier.swift:345-410` |

**App 侧集成层（同模块，internal，UI 可直接用）**

- `PopopxMeshRuntime.shared`（`@MainActor ObservableObject`）持有全部句柄：`core / eventFeed / engineBackend / mappingStore / bridge / pairing / router / eventObserver / stateSource / healthMonitor / killSwitch / bannerModel / timelineModel / panicWipe`（字段声明 `:3750-3763`）— `Shared/Model/POPOPXAPI.swift:3735`；观察项 `isFuseOn` `:3744`、`pairingPolicy` `:3748`。
- 已挂载点：`Shared/POPOPXApp.swift:156`（`.modifier(PopopxMeshPanicWipeMount())`，struct 本体在 `POPOPXAPI.swift:4071`）与 `:157`（`.task { await PopopxMeshRuntime.shared.bootstrap() }`，`bootstrap()` 在 `:158`）；`Shared/Views/Chat/ChatView.swift:161-177`（`.popopxMergedTimeline` / `.popopxMeshBanner`，两条分支各一次）；包内 `MeshPlazaView(` 现有三处宿主，SettingsView 那处已迁走：`Shared/Features/Cabin/PopopxCabinView.swift:404`（Cabin tab 根，自建 `NavigationStack` `:403`，走 `model:` 注入）与 `:826`（`.plaza` 目的地）、`Shared/Features/AddFriend/PopopxAddFriendView.swift:121`（`PopopxAddFriendRoute.meshPlaza` 目的地）。
- 包内 UI 目前用 `.foregroundColor` + `.blue/.orange/.gray`（系统色），且 `PopopxMeshChannelBadge.color(of:)` 是 internal static，主工程无法覆写 → **Phase 5 的频道配色改法**：在主工程侧用 public 的 `PopopxMeshBadgeDescriptor` 自建 `PopopxChannelBadge`（紫锁 / 青绿波纹+跳数 / 灰时钟），不改包内路由与 BLE 代码。

### 0.2 apps/ios 工程与视图路径

| 事实 | 实测 |
|---|---|
| 工程 / 无 workspace | `POPOPX.xcodeproj`（`POPOPX.xcodeproj/project.xcworkspace` 只是自包含容器） |
| Targets | `POPOPX (iOS)`、`POPOPXChat`（静态库 + FFI）、`POPOPX NSE`、`POPOPX SE`、`POPOPX Snapshots`、`Tests iOS` |
| Schemes | `POPOPX (iOS)`（主）、`POPOPXChat`、`PopopxMeshKit`、`PopopxMeshUI`、`POPOPX NSE`、`POPOPX SE` |
| 编译期设置 | `IPHONEOS_DEPLOYMENT_TARGET = 17.0`、`SWIFT_VERSION = 5.0`、`PRODUCT_BUNDLE_IDENTIFIER = com.popopxchat.popopx`（`xcodebuild -showBuildSettings` 实测） |
| 主源码目录 | `Shared/`（210 个 .swift，含新增的 `Theme/PopopxTheme.swift` 与 `Components/` 三个控件文件）：`Shared/Model/`、`Shared/Views/{Chat,ChatList,Contacts,NewChat,UserSettings,…}`、`Shared/Theme/`、`Shared/Components/`；库层 `POPOPXChat/`；扩展 `POPOPX NSE/`、`POPOPX SE/` |
| 根视图链 | `Shared/POPOPXApp.swift:42` → `ContentView`（`Shared/ContentView.swift:26`）→ `mainView()` `:257` → `ChatListView`（`Shared/Views/ChatList/ChatListView.swift:164`）。**当前没有 app 级 TabView**（Phase 4 需新建） |
| 关键待重写视图 | `Shared/Views/Chat/ChatView.swift:47`、`ChatItemView.swift:43`、`Chat/ComposeMessage/ComposeView.swift:378`、`NewChat/NewChatView.swift:79`、`NewChat/AddGroupView.swift:13`、`UserSettings/`（19 个文件） |
| 现存可复用件 | `Shared/Views/Helpers/PressedButtonStyle.swift:9`（仅换背景，无缩放）、`Helpers/AppSheet.swift`、`SheetRepresentable.swift`、`StickyScrollView.swift`、`ChatItemClipShape.swift`；**无触觉/Toast 抽象**，散落 `UIImpactFeedbackGenerator`（`ChatView.swift:2315`、`ChatInfoView.swift:1478`、`Call/SoundPlayer.swift:104`） |
| 旧视觉（本次摈弃对象） | `POPOPXChat/Theme/ThemeTypes.swift:684` `PopopxColorPalette.primary = 0xFF70F0F9`（青）、`background = 0xFF111528`（深蓝紫底）、`ThemeTypes.swift:705` `BlackColorPalette.primary = 0xff0077e0`；全局入口 `AppTheme.shared.colors` / `theme.colors.primary`（`Shared/Theme/Theme.swift:24`、`Shared/Theme/ThemeManager.swift:65`） |
| 颜色工具 | `POPOPXChat/Theme/Color.swift:87` `Color(_ argb: Int64)`、`:95` `Color(_:_:_:a:)`、`:156` `String.colorFromReadableHex()`；**全仓库没有 `Color(hex:)`** |

### 0.3 Info.plist（`POPOPX--iOS--Info.plist`，实测）

- 已有（按 plist 原文行号，第三阶段合并后重新实测）：`BGTaskSchedulerPermittedIdentifiers` `:5`、`CFBundleURLTypes` `:33`（scheme `popopx`，另有 `popopxchat`、`simplexchat`）、`NSBluetoothAlwaysUsageDescription` `:61`、`UIBackgroundModes` `:69`（含 `bluetooth-central` `:75`、`bluetooth-peripheral` `:76`、`audio`、`fetch`、`remote-notification`、`voip`）、`UIDesignRequiresCompatibility = true` `:78`。
- 第三阶段已**合并追加**（只插入、未覆盖，`plutil -lint` OK）：`NSNearbyInteractionUsageDescription` `:63`、`NSBonjourServices` `:65`（`_popopx-uwb._tcp`）。
- 仍不在此 plist 中的一项：`NSLocalNetworkUsageDescription`。它由 `project.pbxproj` 的 `INFOPLIST_KEY_NSLocalNetworkUsageDescription` 构建设定注入最终 Info.plist；改 pbxproj 是红线，因此不在文档 plist 里重复声明。`grep -c multicast POPOPX--iOS--Info.plist` = 0（`com.apple.developer.networking.multicast` 严禁添加）。
- `UIDesignRequiresCompatibility = true` 意味着当前工程显式退出 Liquid Glass；本规范按 iOS 17 视觉书写，**不引入 glass 专有 API**。
- `UIDesignRequiresCompatibility = true` 意味着当前工程显式退出 Liquid Glass；本规范按 iOS 17 视觉书写，**不引入 glass 专有 API**。

### 0.4 品牌资产（禁止改名/覆盖/删除）

| 引用名 | 用途 | 现有调用点 |
|---|---|---|
| `popopx_app_icon` | 方形品牌标（通知图标、身份胶囊） | `Shared/Model/AppAPITypes.swift:1793`（`operatorsInfo`）与 `:1893`（`dummyOperatorInfo`）、`Views/Call/CallController.swift:32` |
| `logo` | 横版字标（浅色面） | `AppAPITypes.swift:1794`、`Views/Onboarding/POPOPXInfo.swift:92` |
| `logo-light` | 横版字标（深色面） | `AppAPITypes.swift:1796` |
| `vertical_logo` | 竖版组合标（空态/引导） | `Views/Chat/ChatItem/MsgContentView.swift:353` |
| `icon-light` / `icon-dark` | 头像占位与 AppIcon 切换 | `Views/NewChat/QRCode.swift:82`、`UserSettings/AppearanceSettings.swift:205/221` |

均位于 `Shared/Assets.xcassets/`（`popopx_app_icon`/`logo`/`logo-light`/`vertical_logo` 为 @1x/@2x/@3x PNG 三件套）。代码只按上表名字引用，不重导、不改名、不删除。

---

## 1. 双模色板

### 1.1 语义分工（唯一硬规则）

- **靛紫 = 在线加密态（SMP）**：主按钮、Tab 选中、发方气泡、链接、`SMP 在线加密` 状态胶囊。
- **青绿 = 离线 Mesh 态（厢语专属）**：Mesh 节点、1–7 跳徽章、雷达动效、`#厢语` 频道、`厢语无网组网中` 胶囊。跳数上限 7 来自 `PopopxMeshConfig.fragmentRelayTtlCap = 7`（`Core/PopopxMeshConfig.swift:24`），密集网络下 TTL 收紧为 5（`:28`）。
- **系统红 = 危险**：清除记录、`PanicWipeManager` 紧急自毁。
- 同一条消息行、同一个气泡、同一个控件内**不得混用紫与青**；需要同时展示两种通道时，用两个独立徽章（见 §2.2）。

### 1.2 Token（Light / Dark）

| Token | Light | Dark | 用途 |
|---|---|---|---|
| `brand` | `#5856D6` | `#7D7AFF` | 主按钮、Tab 选中、在线气泡、链接 |
| `onBrand` | `#FFFFFF` | `#0A0A1F` | 落在 `brand` 上的文字/图标 |
| `mesh` | `#00A896` | `#00D2B8` | Mesh 填充、雷达、跳数徽章底 |
| `meshInk` | `#00705F` | `#00D2B8` | 卡片上的青色**文字**与描边 |
| `onMesh` | `#00251F` | `#00211C` | 落在 `mesh` 上的文字 |
| `danger` | `#FF3B30` | `#FF453A` | 图标、描边、滑动删除底 |
| `dangerInk` | `#D70015` | `#FF453A` | 危险**文字** |
| `dangerFill` / `onDanger` | `#D70015` / 白 | `#FF453A` / `#0A0A1F` | 危险实底按钮 |
| `success` / `onSuccess` | `#34C759` / `#07240F` | `#30D158` / `#071A0C` | **仅**瞬时确认（成功闪勾）的实底与其上的墨 |
| `successInk` | `#1E7A34` | `#30D158` | 卡面上的绿色勾、图标、描边 |
| `base` | `#F2F2F7` | `#000000` | 页面底（Dark 为 OLED 纯黑） |
| `card` | `#FFFFFF` | `#1C1C1E` | 分组卡、收方气泡、列表行 |
| `cardHigh` | `#FFFFFF` | `#2C2C2E` | 弹层、输入栏、Toast |
| `separator` | `#E3E4EA` | `#38383B` | 1pt 分割线 |
| `label` | `#111114` | `#F4F4F6` | 正文 |
| `labelSecondary` | `#5A5A66` | `#A6A6B0` | 次要信息 |
| `labelHint` | `#8A8A94` | `#7C7C88` | 仅占位/禁用 |
| `hairlineInner` | `#111114 @ 5.5%` | `#FFFFFF @ 12%` | 0.5pt 内描边（Dark 专属高光） |

### 1.3 实测对比度（`python3 Docs/contrast_check.py` 输出，逐字照录）

```
TEXT (AA target 4.5:1)   [L = light mode, D = dark mode]
  L onBrand on brand (primary CTA)           #FFFFFF on #5856D6   5.65  AA
  L onDanger on dangerFill (destructive CTA) #FFFFFF on #D70015   5.38  AA
  L onMesh on mesh (mesh CTA / hop chip)     #00251F on #00A896   5.48  AA
  L label on card                            #111114 on #FFFFFF  18.85  AAA
  L label on base                            #111114 on #F2F2F7  16.89  AAA
  L labelSecondary on card                   #5A5A66 on #FFFFFF   6.80  AA
  L labelSecondary on base                   #5A5A66 on #F2F2F7   6.09  AA
  L labelHint on card (disabled/placeholder) #8A8A94 on #FFFFFF   3.42  AA-large only
  L dangerInk on card                        #D70015 on #FFFFFF   5.38  AA
  L brand as text on card                    #5856D6 on #FFFFFF   5.65  AA
  D onBrand on brand (primary CTA)           #0A0A1F on #7D7AFF   5.67  AA
  D onDanger on dangerFill (destructive CTA) #0A0A1F on #FF453A   5.73  AA
  D onMesh on mesh (mesh CTA / hop chip)     #00211C on #00D2B8   8.84  AAA
  D label on card                            #F4F4F6 on #1C1C1E  15.49  AAA
  D label on base                            #F4F4F6 on #000000  19.12  AAA
  D label on cardHigh (sheet/toast)          #F4F4F6 on #2C2C2E  12.69  AAA
  D labelSecondary on card                   #A6A6B0 on #1C1C1E   7.05  AAA
  D labelSecondary on cardHigh               #A6A6B0 on #2C2C2E   5.78  AA
  D labelHint on card (disabled/placeholder) #7C7C88 on #1C1C1E   4.13  AA-large only
  D dangerInk on card                        #FF453A on #1C1C1E   4.99  AA
  D meshInk on card                          #00D2B8 on #1C1C1E   8.84  AAA
  D brand as text on card                    #7D7AFF on #1C1C1E   4.94  AA
  L onSuccess on success (success flash CTA) #07240F on #34C759   7.46  AAA
  D onSuccess on success (success flash CTA) #071A0C on #30D158   8.94  AAA
  L successInk on card (tick / icon)         #1E7A34 on #FFFFFF   5.40  AA
  L successInk on base                       #1E7A34 on #F2F2F7   4.84  AA
  D successInk on card (tick / icon)         #30D158 on #1C1C1E   8.42  AAA
  D successInk on cardHigh (toast)           #30D158 on #2C2C2E   6.89  AA
  L neutral icon badge ink on its fill       #111114 on #E3E4EA  14.86  AAA
  D neutral icon badge ink on its fill       #F4F4F6 on #38383B  10.64  AAA

NON-TEXT UI components (target 3.0:1)
  L brand fill / stroke on card              #5856D6 on #FFFFFF   5.65  AA
  L brand as UI on base                      #5856D6 on #F2F2F7   5.06  AA
  D brand fill on base                       #7D7AFF on #000000   6.10  AA
  L mesh fill alone on card (see rule: needs ink) #00A896 on #FFFFFF   2.98  FAIL
  L meshInk stroke on card                   #00705F on #FFFFFF   6.03  AA
  D mesh as UI on card                       #00D2B8 on #1C1C1E   8.84  AAA
  D mesh as UI on base                       #00D2B8 on #000000  10.91  AAA
  L danger icon on card                      #FF3B30 on #FFFFFF   3.55  AA
  D danger icon on card                      #FF453A on #1C1C1E   4.99  AA
  L success fill alone on card (see rule: needs ink) #34C759 on #FFFFFF   2.22  FAIL
  L successInk stroke on card                #1E7A34 on #FFFFFF   5.40  AA
  D success as UI on base                    #30D158 on #000000  10.39  AAA
```

### 1.4 四条由实测得出的强制规则

1. **Dark 模式的实底按钮不用白字。** `#FFFFFF` on `#7D7AFF` = 3.44（不足 4.5），故 Dark 下 `brand`/`dangerFill` 上的文字改用 `#0A0A1F`（5.67 / 5.73）。这是 `onBrand`、`onDanger` 双模取值不同的唯一原因。
2. **青绿实底永远配深色墨。** 白字压 `mesh` 只有 2.98（Light）/1.92（Dark），一律使用 `onMesh`。
3. **`mesh` 单色填充在浅色卡上 2.98，不足非文本 3.0。** 因此跳数徽章**永远显示数字**（`PopopxType.metric`），颜色只作装饰；需要边界时用 `meshInk` 描边（6.03），不靠底色区分。
4. **绿色不承载任何常驻状态。** 它只出现在瞬时确认里（`PopopxButton` 成功闪勾、`PopopxToast` 的 success 回执），因为一旦常驻就会与青绿的 Mesh 语义争色。且 `success` 亮绿在白卡上只有 2.22（不足非文本 3.0），所以它只作**实底**并承载 `onSuccess` 深墨（7.46 / 8.94）；画在卡面上的勾与描边一律用 `successInk`（5.40 / 8.42）。选中态（勾选框、单选、分段滑块）用 `brand` + `onBrand`，不用绿色。

---

## 2. 组件级视觉规则

### 2.1 气泡

- 发方（在线 SMP）：`brand` 底 + `onBrand` 文字；外侧圆角 16，连续消息内侧收紧为 4。
- 收方：`card` 底 + `label` 文字，Dark 下加 0.5pt `hairlineInner` 内描边（纯黑底上的 `#1C1C1E` 需要边缘信息）。
- 离线 Mesh 气泡：仍用 `card`，通道信息由左上角徽章承担，不给整条气泡上青色。

### 2.2 通道徽章（Phase 5 重写目标，语义映射现状）

| 通道 | 现状（包内） | 规范（主工程侧新徽章） |
|---|---|---|
| SMP 公网 | `.blue` + `shield.lefthalf.filled` | `brand` + `lock.shield.fill` |
| 离线 Mesh | `.orange` + `antenna.radiowaves.left.and.right` + `· N` | `meshInk` + `antenna.radiowaves.left.and.right` + `· N`（N 为 1–7） |
| 待中继 | `.grey` + `clock` | `labelSecondary` + `clock` |

`PopopxMeshBadgeDescriptor` 是 public 且与 SwiftUI 解耦（`MergedTimelineModifier.swift:344-410`：struct `:344`、Tone `:345-349`、`init(channel:)` `:357`、`color(of:)` `:404-410`），主工程可直接复用其分类结果，无需触碰包内逻辑。

### 2.3 卡片与分组

`PopopxSectionCard`：`card` 底、16pt 圆角、内边距 `spaceM(16)`、段间距 `spaceL(24)`、左右 `gutter(16)`；Light 用阴影（`popopxCardElevation`），Dark 用 0.5pt `hairlineInner`。禁止"圆角卡 + 左侧色条"这种 AI 味版式。

### 2.4 禁用清单

- 紫→蓝渐变整屏背景；渐变只允许出现在二维码卡片这类"实体物件"上。
- Emoji 当功能图标；一律 SF Symbols 或 §0.4 的资产。
- Inter / Roboto 作标题字；平台原生 SF Pro。
- 深蓝紫"极客底"（`#111528`、`#121C37`、`#172941`）——即当前 `PopopxColorPalette` 的底色家族，重构后不得再出现在新视图。
- 对称三栏营销网格、居中大字 hero 页；聊天工具首屏直接给内容。
- 每屏保留**一个** 120% 打磨的签名细节（厢语页是雷达，聊天室是气泡内联徽章，加友页是 UWB 近场动效），其余保持克制。

### 2.5 原子控件库（第二阶段已落地）

实现：`Shared/Components/PopopxControls.swift`、`PopopxHaptics.swift`、`PopopxToast.swift`。三重同步反馈 = 按压缩放（`PopopxPressButtonStyle`，pointer-down 同帧 `scaleEffect(0.97)` + 触觉）+ 顶部回执胶囊（`PopopxToastModel`，队列 + 上滑打断）。

| 控件 | 关键约定 |
|---|---|
| `PopopxButton` | 四态 `primary`/`secondary`/`ghost`/`destructive`；`isLoading` 或 async 动作结束后闪 700ms `success` 实底 + `onSuccess` 勾，随即回原色 |
| `PopopxTextField` / `PopopxTextArea` | 卡面底 + 静止 `labelHint` 1pt 边、聚焦 `brand` 1.5pt 边；文本区 `axis: .vertical` 3–8 行 |
| `PopopxToggle` / `PopopxToggleRow` | 行即 `Toggle` 的 label，44pt 命中区与 VoiceOver 状态由系统给，不自握手势 |
| `PopopxCheckbox` / `PopopxRadioRow` | 选中态用 `brand` + `onBrand`（5.65），**不用绿色**（§1.4 第 4 条） |
| `PopopxPickerRow` | 纯 disclosure：标题 + 当前值 + `chevron.right`，导航由调用方拥有 |
| `PopopxSegmentedControl` | `matchedGeometryEffect` 滑块，`brand` 药丸 + `onBrand` 字，切换 `PopopxHaptics.selection()` |
| `PopopxSliderRow` | 数值读数用 `PopopxType.metric`（等宽数字，刷新不抖） |
| `PopopxSectionCard` | §2.3；段间距由外层容器给 `spaceL`，卡片自身只带左右 `gutter`，因此可嵌套 |
| `PopopxSheetContainer` | 拖拽指示条 + 标题块 + 滚动内容 + 可选 `footer` 实底按钮；不含关闭按钮（`presentationDragIndicator` 与 toolbar 归调用方） |

三条额外规则：

1. **控件自己的边界用 `labelHint`，不用 `separator`。** `separator`（`#E3E4EA` on `#FFFFFF`）只有 1.19，作为输入框、次级按钮或未勾选框的边框等于没有；`labelHint` 是 3.42（Light）/ 4.13（Dark），刚跨过非文本 3.0。`separator` 仍只用于行间 1pt 分割与装饰底。
2. **`PopopxIconTint` 把"实底 + 能压在它上面的墨"绑成一对**：`brand`+`onBrand` / `mesh`+`onMesh` / `danger`+`onDanger` / `success`+`onSuccess` / `neutral`=`separator`+`label`（实测 14.86 与 10.64），调用方配不出欠对比的徽章。
3. **库内零硬编码文案**：所有用户可见文字由调用方注入（含 `PopopxToastMessage.text`），不绕过仓库现有 l10n。

### 2.6 顶栏三段式与近场加友（第三阶段已落地）

| 文件 | 行数 | 内容 / 关键约定 |
|---|---|---|
| `PopopxMeshKit/Sources/PopopxMeshKit/Proximity/PopopxProximityEngine.swift` | 904 | 引擎 A：`MCNearbyServiceAdvertiser` + `MCNearbyServiceBrowser`（服务类型 `popopx-uwb`）+ `MCSession(encryptionPreference: .required)` + `NearbyInteraction` 测距。整类 `@available(iOS 17.0, *) @MainActor`（§8.2）。线上帧前缀 `POPOPX_PROXIMITY:`、上限 8192B；`PopopxProximityPhase` 8 态、`PopopxProximityFailure` 12 案例，视图侧 `failureWords(_:)` 穷尽。 |
| `Shared/Navigation/PopopxTelemetryHeader.swift` | 548 | 左（身份切换胶囊 + Logo，连点 3 次触发 panic wipe）、中（`PopopxDualStatusCapsule`：公网 + 射频双模）、右（`PopopxPlusMenu`：添加朋友 / 发起群聊 / 扫一扫 / 生成一次性连接链接）。信号唯一来源 `PopopxHeaderSignal.resolve(proximityActive:directPeerCount:path:)`，`PopopxTelemetryModel` 消费 `NetworkStateMonitor.shared.pathChanges()`（`Router/NetworkStateMonitor.swift:372`）。三段必须**可压缩**：中间胶囊自己排 `ViewThatFits` 三档（双胶囊全文字 → 射频退回圆点 → 两端都退回圆点），宿主**不得**再对它 `.fixedSize()`（那会把 proposal 变成 nil，三档永远停在最宽一档，375pt 屏上把「+」整颗推出右边界）；左侧身份胶囊上限 `PopopxMetrics.headerIdentityMaxWidth`。实测判据见 `spec/client/testing.md` §6 的 `assertHeaderFits`。 |
| `Shared/Features/AddFriend/PopopxAddFriendView.swift` | 743 | 搜索框解析 `popopx:` / `simplex:` / `https://simplex.chat`（`PopopxAddFriendLink.classify`）：离线走 `PopopxOfflineBridge`，在线走 `planAndConnect`；剪贴板有效链接 → `PopopxBreathingDot`（青绿呼吸，Reduce Motion 静态）；面对面入口、加密名片微标条、功能卡片列表。 |
| `Shared/Features/AddFriend/PopopxProximityAddContactView.swift` | 561 | 引擎 A 的弹层。`onAppear` 真挂起 Mesh 射频、`onDisappear` 释放后恢复（前提：总开关原本开着）；精确测距分层（`supportsPreciseDistanceMeasurement` → 雷达环，否则 `symbolEffect(.variableColor.iterative)` + 诚实降级文案）；`didCrossPreciseThreshold` → `PopopxHaptics.impact(.heavy)`；`.paired` → 成功触觉 + Toast + 延时自动关闭。引擎 B（TapDrop）先 `stopProximityLinkEngine()` 再 `UIActivityViewController`，关闭时 `defer` 恢复近场链路。 |
| `Shared/Features/AddFriend/PopopxQRCardSheet.swift` | 244 | 加密名片卡（§2.4 唯一允许的渐变：只用 `PopopxPalette.brand` 与其变暗止点，底衬 `label`）。QR 复用 `POPOPXLinkQRCode`（`Shared/Views/NewChat/QRCode.swift:37`），本文件不写 CIFilter；弹层不带自己的导航容器，`presentationDetents` 归宿主。 |

四条硬约定：

1. **射频互斥不是"调用了 stopScan"，而是可复核的静默快照。** 链路：`PopopxMeshRuntime.shared.killSwitch.setEnabled(false)` → `PopopxMeshEngine.stop()`（`Engine/PopopxMeshEngine.swift:164`）→ `PopopxBLETransport.shutDown()` → `centralManager?.stopScan()`（`BLE/PopopxBLETransport.swift:262`）与 `peripheralManager?.stopAdvertising()`（`:266`）。弹层用 `verifiedActivitySnapshot().isRadioQuiet` 把结果写回 UI（`radioYielded`），挂起失败就显示失败，不假装已让路。恢复只按进入页面时记录的 `fuse.isEnabled` 原样回滚。
2. **单向发包仲裁**：字典序小的一方发送邀请帧、大的一方静默接收并写入 `IdentityMappingStore` 完成加友 + 绑定。两处对 `ui-prompt.md` 字面要求的偏差（已在文件头注释里记录）：显示名相同时（双方默认都是 `mesh user`）回退到 mesh 公钥的字典序；`.handshake` 帧由双方各发一次，因为发起方需要对方的 mesh 公钥才能绑定。
3. **panic wipe 只有一个状态机**：顶栏 Logo 连点只是第二个入口，复用 `PopopxPanicWipeArming`（`PopopxMeshUI/PanicWipeManager.swift:360`）与已挂载的 `PopopxMeshPanicWipeMount`（`Shared/Model/POPOPXAPI.swift:4071`），不新建第二套 arming/弹窗，避免两个弹窗抢同一次触发。
4. **跨模块符号一律 `public`**：App 侧只能看到包导出的类型；`PopopxProximityEngine` 的 `@Published` 状态全部经引擎暴露，视图不复制状态（`@StateObject` 持 sheet model、`@ObservedObject` 持引擎，因为只有引擎发布变化）。

---

## 3. 排版阶梯

全部基于 Dynamic Type text style（`PopopxType`），不接受固定 pt 作为正文。

| Token | 基于 text style | 默认字号 | 用途 |
|---|---|---|---|
| `display` | `.largeTitle` + bold | 34 | 页面大标题（仅"我"页与引导页） |
| `title` | `.title2` + semibold | 22 | 弹层标题 |
| `sectionHeader` | `.headline` | 17 semibold | 分组标题、行内主标题 |
| `body` | `.body` | 17 | 正文、消息文本 |
| `emphasis` | `.body` + semibold | 17 semibold | 按钮标签、关键值 |
| `secondary` | `.callout` | 16 | 次级正文 |
| `meta` | `.subheadline` | 15 | 行副标题 |
| `caption` | `.footnote` | 13 | 时间戳、说明 |
| `microTag` | `.caption` | 12 | 徽章文字 |
| `metric` | `.footnote` + `monospacedDigit` | 13 | 跳数、延迟、链接码 |
| `metricSmall` | `.caption2` + `monospacedDigit` | 11 | 顶栏节点状态数字 |

数字一律 `monospacedDigit()`，避免 Mesh 状态刷新时布局抖动。

---

## 4. 度量

- 栅格：4pt 基准，8pt 为默认步进（`space2XS 4 / spaceXS 8 / spaceS 12 / spaceM 16 / spaceL 24 / spaceXL 32 / space2XL 48`）。
- 圆角：`chip 8`、`avatar 8`、`control 12`、`card 16`、`bubbleOuter 16` / `bubbleTucked 4`、`sheet 20`。
- 线宽：`hairline 0.5`（Dark 内高光）、`divider 1`、`stroke 1.5`（图标环、雷达环）。
- 触控：最小 44×44pt（`minHitTarget`），全宽度点击区不得只在图标上。

---

## 5. 动效与触觉常量

- `snappy`：`Animation.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0)` — 控件响应手指。
- `fluid`：`Animation.spring(response: 0.4, dampingFraction: 1.0, blendDuration: 0)` — 非用户直接触发的状态迁移。
- 按压缩放：`PopopxSpring.pressScale = 0.97`（pointer-down 瞬间）。
- Reduce Motion：`@Environment(\.accessibilityReduceMotion)` → `PopopxMotion.animation(_:reduceMotion:)` / `.popopxAnimation(_:value:reduceMotion:)`；关闭动效时是"无动画"，不是"更短的弹簧"。
- 雷达/脉冲类循环动画在 Reduce Motion 下退化为静态环 + 数字跳数。

> SDK 现实（Xcode 27 / iOS 27 SDK，deployment 17.0 实测）：`Spring(response:dampingFraction:)` 与 `Animation.spring(_:duration:)` 已不可用（编译报错 `expected 'response:dampingRatio:'` / `expected 'duration:bounce:blendDuration:'`）；本规范固定使用 `Animation.spring(response:dampingFraction:blendDuration:)`。

---

## 6. 图标词汇表

已在代码中出现的（继续用，不新造同义词）：
`shield.lefthalf.filled`、`antenna.radiowaves.left.and.right`、`clock`（`MergedTimelineModifier.swift:360`、`:365`、`:372`）。

本规范新增并固定下来的：
`lock.shield.fill`（SMP 在线）、`lock`/`lock.open`（身份切换）、`plus`（聚合菜单）、`qrcode`、`doc.on.doc`（粘贴链接）、`person.2.badge.plus`（面对面加友）、`dot.radiowaves.left.and.right`（近场感应）、`exclamationmark.triangle.fill`（危险）、`wifi.slash`（无网）、`checkmark`（成功闪勾与勾选框）、`chevron.right`（disclosure 行）。

约束：同一语义只用一个符号；徽章符号一律 `.medium` 重量以上，禁用 emoji。

---

## 7. 与旧主题系统的关系（已裁定：B）

现状：全仓 UI 通过 `AppTheme.shared.colors` / `theme.colors.primary` 取色（`Shared/Theme/Theme.swift:23`、`ThemeManager.swift:65`），`PopopxColorPalette` 的青/深蓝底仍在一处生效（`POPOPXChat/Theme/ThemeTypes.swift:684-705`）。

两条候选路线：

- **A. 桥接翻转**：把 `PopopxColorPalette` 的字段改为指向 `PopopxPalette` token，一次让所有旧页面获得新配色；风险是旧页面里以 `isLight`/`primary` 反推文字色的分支会连锁变色，需要逐页目视验证。
- **B. 双轨渐进**：新视图只用 `PopopxPalette`，旧视图保持原样，随第四、五阶段的重写逐个下线；风险是过渡期两套视觉并存。

2026-11-18 裁定：**B**（用户裁定，与 `ui-prompt.md` 第五阶段"100% 重写后旧残留为 0"的验收一致）。因此过渡期两套视觉并存是**预期状态**，不是缺陷；第二～五阶段新建的每个视图只允许出现 `PopopxPalette` / `PopopxType` / `PopopxMetrics`，不得读取 `AppTheme.shared.colors` 或 `theme.colors.primary`。

---

## 8. 工程约束（影响后续阶段的编译门禁）

1. `POPOPX.xcodeproj/project.pbxproj` 中 **没有** `PBXFileSystemSynchronizedRootGroup`（实测 0 处），文件逐条 `PBXFileReference`（实测 373 条，其中 236 条 `.swift`）。因此 **新建 .swift 不会被自动编译**，必须人工拖入 target；`ui-prompt.md` 又禁止脚本改 pbxproj → 每阶段交付时列出需拖入的文件清单。挂载现状（`grep -c "<文件名>.swift" project.pbxproj`，每文件命中 4 = build file / fileRef / group / Sources）：第一阶段 `Shared/Theme/PopopxTheme.swift` 与第二阶段的 `Shared/Components/PopopxControls.swift`、`PopopxToast.swift`、`PopopxHaptics.swift` 均已挂载（各 4 处）；**第三阶段的 4 个新文件也已挂载（实测各 4 处）**；每阶段交付时仍需列出待拖入清单（清单见 §9）。
2. `PopopxMeshKit/Package.swift` 声明 `.iOS(.v15)`（`:9`），而 `ui-prompt.md` 第三阶段要求 `.iOS(.v17)`（`@Observable`、`NearbyInteraction` 精确测距等）。2026-11-18 裁定：**保持 `.iOS(.v15)` 不变**（用户裁定），以免影响包内 289 个测试与 `.macOS(.v14)` 宿主。因此第三阶段新增的 `PopopxProximityEngine` 等使用 iOS 17 API 的类型必须**整体**标 `@available(iOS 17.0, *)`——含 `@Observable` 宏展开出的成员，不只是方法级——且宿主调用点须在 `if #available(iOS 17.0, *)` 内；包内既有类型一律不动。主工程 deployment target 是 `"$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)"`，不能假设 ≥17，所以 App 侧的 `PopopxProximityAddContactView` 同样整体 gate，`#Preview` 经由一个不 gate 的宿主包装。
3. 包内 target 为 Swift 6 语言模式（tools-version 6.0），主工程为 Swift 5 模式；新增进包的 `PopopxProximityEngine.swift` 必须严格并发可编译。
4. `UIDesignRequiresCompatibility = true`：不采用 Liquid Glass 专有 API。
5. Info.plist 的第三阶段两项已合并落地（`NSNearbyInteractionUsageDescription`、`NSBonjourServices`，见 §0.3）；`NSLocalNetworkUsageDescription` 由 pbxproj 的 `INFOPLIST_KEY_NSLocalNetworkUsageDescription` 注入（实测 2 个 configuration，`:2272`、`:2321`），不改 plist、不改 pbxproj。URL scheme `popopx` 已存在，Phase 3 的自定义 Scheme 唤醒无需新增。
6. **模拟器门禁只能编 arm64**：`Libraries/sim/*.a` 是 arm64-only 的 vendored 产物，`x86_64` 一律在链接期失败（与本轮改动无关）。可用的门禁命令必须带 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`：
   `xcodebuild build -project POPOPX.xcodeproj -scheme "POPOPX (iOS)" -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData`
   包侧同理换 `-scheme PopopxMeshKit`。判定以日志里的 `** BUILD SUCCEEDED **` + `error:` 计数为准，并且要用编译调用计数（`SwiftCompile`/`CompileC`）证明真的编了东西——0 次编译也会打印 BUILD SUCCEEDED。

---

## 9. 验收方式

- 视觉 token：在 Xcode 打开 `Shared/Theme/PopopxTheme.swift` 的 `#Preview("popopx theme")`，切换 Light/Dark 核对 §1.2。
- 对比度：`cd apps/ios && python3 Docs/contrast_check.py`，§1.3 的表必须逐字复现；改动任何 token 后重跑并同步本节。
- 原子控件：`Shared/Components/PopopxControls.swift` 的 `#Preview("popopx controls")`（一张 `PopopxSheetContainer` 里装了全部控件 + Toast），Light/Dark 各过一遍。
- 未挂进 target 时的编译证明（工程无 `PBXFileSystemSynchronizedRootGroup`，新文件不参与编译，见 §8.1）：
  `xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios17.0-simulator -swift-version 5 Shared/Theme/PopopxTheme.swift Shared/Components/*.swift`
  必须 0 error / 0 warning；拖入 target 之后再以 `xcodebuild` 门禁为准。
- **第三阶段新增文件（4 个）**：`Shared/Navigation/PopopxTelemetryHeader.swift`、`Shared/Features/AddFriend/PopopxAddFriendView.swift`、`Shared/Features/AddFriend/PopopxProximityAddContactView.swift`、`Shared/Features/AddFriend/PopopxQRCardSheet.swift` —— 2026-11-18 已由用户拖入 `POPOPX (iOS)` target（实测各 4 处），门禁 `** BUILD SUCCEEDED **` / 0 error / 0 warning。包侧的 `PopopxProximityEngine.swift` 由 SPM 自动 glob，无需挂载，且已过包门禁。
  这 4 个文件引用 App module 的符号（`ChatModel`、`AppTheme`、`apiAddContact`、`planAndConnect`、`PopopxOfflineBridge`、`CodeScannerView`、`.appSheet`），**单文件 `swiftc -typecheck` 看不见这些类型**，只能退化成 `swiftc -frontend -parse` 的语法判定：PARSE OK 的 4 个文件在挂载后门禁仍暴露 7 类真实问题 —— ①`PopopxPalette.bg`/`labelTertiary`/`warningInk` 三个 token 不存在；②`PopopxProximityCopy.linking` 是 `%@` 模板却被当函数调用；③让路闭包在 `self.engine` 初始化完成前捕获 `self`；④`BluetoothHealthMonitor` 是 actor，读数需 `await`（连带三个方法转 async）；⑤`= .shared` 默认参数命中 `@MainActor` 隔离；⑥typed-throw 上的多余下转；⑦非 async 闭包上的多余 `await`。**PARSE OK 从不等于类型证明，只有 `xcodebuild` 门禁算。**
- 双引擎近场的真机验证（不可在模拟器完成，`NearbyInteraction` 与 BLE 都需要实体 U1 芯片设备）：见 §2.6 第 1、2 条与 `ui-prompt.md` 第三阶段自检清单。
- 语义：任一列表行/气泡内出现紫与青同时着色，即为违规（§1.1）。
- 资产：`git diff` 中 `Shared/Assets.xcassets/**` 的 §0.4 资产不得出现删除或覆盖。
