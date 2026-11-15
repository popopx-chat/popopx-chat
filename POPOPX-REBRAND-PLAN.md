# POPOPX 品牌替换方案 v2（仅方案，未执行）

- 生成日期：2026-11-12
- 基线：`master` @ `d71a11741`，工作区干净（仅 2 个未跟踪文件：`.install-libs.tmp.sh`、本文档）
- 状态：**方案待选，本轮全程只读，未改动任何文件**
- **v1 已作废**：v1（2026-11-11）之后落了 9 个 commit，其中"iOS 工程身份 / Haskell 命名空间 / 链接 scheme / TLD / mq 依赖标识 / Android+desktop+商店身份 / libpopopx"**已经完成**。本文件按当前树重测。

> 本文所有数字单位为 **处（occurrences）**，不是行数。测量工具：`git grep -o -I`（仅受跟踪文本文件）。

---

## 〇、扫描范围（已锁定，逐项交代）

| 范围 | 结果 |
|---|---|
| 受版本控制文件 | **5,164**（全部纳入检查） |
| 含 `simplex`（任意大小写）内容的文本文件 | **1,929**（37%） |
| 路径名含 `simplex` 的受控文件 | **1,415**（文本 1,199 / **二进制 216**，二进制只能改名不能改内容） |
| 自身路径段含 `simplex` 的目录 | **303** |
| 未纳入内容扫描（按规则排除） | 二进制文件（`-I`）、`apps/ios/Libraries/**`（418MB/slice 真实 Haskell 归档，gitignored）、`dist-newstyle/**`（gitignored，由 `cabal.project` pin 的上游仓决定） |
| 磁盘上多出的非受控残留 | `apps/ios/SimpleX.xcodeproj/`（**0 个受控文件**，只剩 `project.xcworkspace`/`xcshareddata`/`xcuserdata` 空壳）→ 见 **A7** |

---

## 一、规模盘点（2026-11-12 实测）

### 1.1 按大小写

| 形式 | 处 | 文件 |
|---|---|---|
| `SimpleX` | 19,658 | 1,211 |
| `simplex` | 19,652 | 1,361 |
| `Simplex` | 2,095 | 321 |
| `SIMPLEX` | 385 | 124 |
| **合计（case-insensitive）** | **41,792** | **1,929** |

### 1.2 按区域（处 / 文件）

| 区域 | 处 | 主要内容 |
|---|---|---|
| `apps` | 23,190 | iOS 死本地化包 6,310、KMP common 8,964、iOS `*.lproj` 3,450、iOS spec/product 812 |
| `website` | 6,196 | `langs/*.json`、`src/_includes/**`、`channel-preview.jsc` 267 |
| `docs` | 3,496 | `docs/LINKS.md` **886**（本仓最大单文件） |
| `plans` | 2,573 | 历史设计文档 |
| `blog` | 1,593 | 历史文章 |
| `packages` | 1,585 | nodejs 107 路径、mcp 46、python 32、webrtc 30、client 30 |
| `tests` | 927 | `tests/Bots/DirectoryTests.hs` **475**、`MarkdownTests.hs` 226（夹具+域名断言） |
| 根目录散落 | 642 | `README.md` 324、`PRIVACY.md`、`CHANGELOG.md` |
| `scripts` | 808 | `scripts/flatpak/*.metainfo.xml` 49 处 `simplex.chat`、CI 脚本 |
| `src`（Haskell） | 418 | **客户端自有标识符 + 刻意保留的协议串**（见 B2/C2） |
| `.github` | 158 | `workflows/build.yml` **94** |
| `bots` | 165 | |
| `fastlane` | 28 | 商店文案 |
| `media-logos` / `assets` / `eth` | 2 / 5 / 6 | |
| `images` | 0 | 只有路径名含 simplex（3 个 svg） |

### 1.3 禁令落点（必须先扣除的"不可动"基数）

| 项 | 处 | 依据 |
|---|---|---|
| URL 串内含 `simplex`（任意 host） | **2,611** | 禁令 5 |
| └ 其中 host 为 github / raw.githubusercontent / gist / objects | **1,001** | 禁令 5 硬保护 |
| `simplex.chat` 主机名（含 URL 内外） | 1,513 | 待裁定 **B1** |
| `simplex.im` | 520 | 待裁定 **B1** |
| `smp://` / `xftp://` | 110 / 50 | **C3** 运营商基础设施 |
| `chat.simplex.app` | 28 | 上轮刻意保留：blog 7 / badge-service 示例 17 / moko 注释 4 |
| `simplex:` 残留 | 95 | 上轮已把协议与注册 scheme 改成 `popopx:`（213 处），这 95 处多为 DB 值/注释/历史 |
| `libsimplex` | 120 | **C5**：`1bb572be6` 刻意保留的 SDK 双查找 |
| `simplexmq` | 442 | 依赖标识已改（`popopxmq` 176 处），余量为 docs 198 / plans 71 / website 67 / apps 50 / blog 37 / packages 9 / 根 md 11 / scripts 2 / `src` 1 |
| `SimpleX Chat Ltd` 版权署名 | 82 / 28 文件 | **C4** AGPL §7 |

> **可直接动的量级**：41,792 处里，约 **2,611 处**在 URL 内、**约 2,033 处**是 `simplex.chat`/`simplex.im` 主机名（与 URL 有重叠）、**约 500 处**属协议/署名/双查找硬保留。真正的品牌工作量集中在**本地化文本、文档正文、目录名**三块。

---

## 二、上一轮已完成 —— 本轮**不要重复**

| 已完成 | commit | 现状（实测） |
|---|---|---|
| `src/Simplex` → `src/Popopx`，319 行 cabal 模块表 | `05dd5a73c` | `src/` 下只剩 `Popopx` |
| `simplex:` → `popopx:`（212 处）+ 各端注册 scheme | `05dd5a73c` | `popopx:` 213 处 |
| 已验证 TLD `.simplex` → `.popopx`（145 处） | `05dd5a73c` | — |
| fork 导出符号闭环改名（13 名 / 196 点）：`SSPopopx`、`SLSPopopx`、`PopopxNameInfo`、`resolvePopopxName`… | `05dd5a73c` | — |
| iOS 工程身份：`POPOPX.xcodeproj`、`POPOPX (iOS).entitlements`、`POPOPX--iOS--Info.plist`、`POPOPXChat/`、`POPOPX NSE/`、`POPOPX SE/`、`POPOPX Snapshots/`、3 个 `.xcscheme`、Swift module | `19eafa24e` | `Tests iOS` 区 0 处 simplex |
| `libsimplex` → `libpopopx`（保留 SDK 双查找） | `1bb572be6` | `libpopopx.dll.def` 已存在 |
| mq 依赖标识 `simplexmq` → `popopxmq`（含 JSON 键 `popopxmqVersion`/`popopxmqCommit`、UI 键 `core_popopxmq_version` 34） | `1d56a0fb8`、`26cf4c408` | KMP `SimpleXAPI.kt:7900-7901` 已是 `popopxmq*` |
| Android / desktop / 商店身份 → `com.popopxchat.popopx` | `2aac0f8b0`、Round 4 | `chat.simplex.app` 仅剩 28 处刻意保留 |

**已确立的两条惯例**（来自 `47e2c68e5` 的 revert 说明，本仓已写入历史，本轮视为约束）：
1. **指向上游事物的标识符保留原名**：`operatorSimpleXChat`（预设指向上游 simplex.chat 服务器）、`InvestInSimpleXChatView`（上游众筹）、终端欢迎语与 website footer 的上游社交账号。
2. Haskell 侧只改**代码位**，注释与字符串字面量**逐字节保留**，故 `server_operator_tag = 'simplex'`、`OTSimplex` 的 `"simplex"`、设置项 tag `"SIMPLEX"`、`simplex_domain_v1`、预设主机 `*.simplex.im`、`$HOME/.simplex` 数据目录、`hs_init.c` 的 RTS 程序名、打包名 **全部存活**。改动这些等于改 2 的约定，须单独立项。

---

## 三、A —— 必改（已成对失配或纯显示，零功能风险）

| # | 内容 | 规模 / 证据 | 理由 |
|---|---|---|---|
| **A1** | `apps/ios/SimpleX Localizations/` 整个目录 | **232 个受控文件 / 6,310 处 / 28 个 `.xcloc`**；实测 `POPOPX.xcodeproj/project.pbxproj` 里 `xcloc` 与 `Localizations` 引用数 = **0** | 工程根本不加载它，纯死数据带着 SimpleX 名。改名（→ `POPOPX Localizations/`）零引用需回写，是本轮**风险最低**的改名 |
| **A2** | iOS 16 个 `<lang>.lproj/Localizable.strings` | **220 个受控 lproj 文件 / 3,450 处**；`en.lproj` 已是 0 命中，只有译文残留 | 用户可见文案；且 `47e2c68e5` 已说明"catalogue key 与 trans-unit id 承载 Swift 源文本，须随源码一起动" —— 现在源码侧是 POPOPX，**key 已不匹配** |
| **A3** | iOS `POPOPXChat/`、`POPOPX NSE/`、`POPOPX SE/`、`Shared/` 内剩余品牌串 | 169 / 48 / 98 / **975** 处（Shared 内 `SimpleX` 468 处） | 目录名已改完，**内容未改**：App 内显示文案与 Swift 标识符 |
| **A4** | KMP 44 个 `strings.xml` 及资源 | `apps/multiplatform/**/*.xml` **5,413 处** | 用户可见文案，同 A2 |
| **A5** | KMP `chat.simplex.common` 里的 `SimpleX` 标识符与显示串 | `.kt` 内 `SimpleX` **248 处**；`SimpleXAPI.kt` 等 | 品牌文案层，`common` 区共 8,964 处 |
| **A6** | 终端 UI / CLI 文案 | `Help.hs`（9 处 `SimpleX`）、`View.hs`（5）、`Terminal.hs`、`Presets.hs`（5，注意与 A 惯例①的 `operatorSimpleXChat` 区分：只改**显示名**，不改标识符与预设主机） | 用户每屏都能看到 |
| **A7** | 磁盘残留空壳 `apps/ios/SimpleX.xcodeproj/` | 0 受控文件，被 ignore | 与 `POPOPX.xcodeproj` 并存时，Xcode/脚本按 glob 或"最近打开"可能选中**错误的空工程**。直接删 |
| **A8** | **AGPL §5c 修改告知缺失** | `FORK.md` / `NOTICE` **不存在**，`README.md` 无 fork 声明 | 这是**合规硬缺口**，不是品牌偏好，见第五节 |
| **A9** | `README.md` 顶部 `Invest in SimpleX Chat … wefunder.com/simplex.chat` 与上游 badges | `README.md` 324 处之一部分 | badges 是 GitHub URL（**禁令 5，不动**）；**散文与 Wefunder 文案**是"把 POPOPX 用户导向上游募资"，须改写为 POPOPX 表述（URL 段保留） |

---

## 四、B —— 需裁定（改了会动功能 / 数据 / 发布）

### B1 域名与服务器（**建议：本轮不动**）
`simplex.chat` 1,513、`simplex.im` 520、`smp://` 110、`xftp://` 50。

实测前置条件**全部未就绪**：
- `popopx.chat` 在整仓出现 **0 次**（没有任何自有域名被写进来过）；
- `apps/ios/POPOPX (iOS).entitlements:9-15` 的 `applinks:` 仍全是 `simplex.chat` / `*.simplex.im` / `*.simplexonflux.com`；
- `website/src/.well-known/{apple-app-site-association/index.json,assetlinks.json}` 要靠**域名托管**才生效（上轮已记为待办）；
- `appLinkScheme` 上轮刻意留 `"simplexchat"`，理由就是"关联域仍是 simplex.chat"。**2026-11-15 已裁定并执行**：注册端本来就允许多个 scheme（iOS 同 plist 已注册 `popopx` + `simplexchat`），故新增 `popopxchat` 为主名、`simplexchat` 保留登记与识别；scheme 与关联域无关，此前把两者绑在一起的理由不成立。

**结论**：没有自有域名 + SMP/XFTP/RTC/relay/names 服务器之前，改这些串 = 客户端连不上 + Universal/App Links 全断。需要你先回答：**域名与服务器是否已有？** 有则这是一批独立工程（DNS、证书、`.well-known` 上线、entitlements、AASA、assetlinks 指纹），必须与 B1 同批。

**2026-11-15 回答（裁定 先使用上游的 smp 服务器）**：自有 SMP 服务器尚未搭建，预设中继在此轮之前继续指向上游 `*.simplex.im`（host 与 key 成对，不可半改）；服务器建成后按 CHANGELOG "Preset relays stay upstream's by decision" 一节列出的成组移动清单执行。

### B2 Haskell 客户端自有标识符（`src` 约 300 处）
`SimplexLinksGroupPreference` 13、`simplexLinks` 11、`SimplexDomainClaim` 8+7+6、`SGFSimplexLinks`/`GFSimplexLinks` 9+9、`simplexChatContact` 9、`simplexDomainLine` 8、`planSimplexName` 7、`CESimplexDomainNotReady` 7、`ftIsSimplexLink` 5、`simplexChatCLI` 5…

**风险点（上一轮就是为此才停手）**：这些不全是"重命名即等价"。
- `Chat/Types.hs` 里的**记录字段名即 JSON key**（`popopxmqVersion` 那批就是这么改的，但它是 fork 两侧同改）。单独改本仓字段名 → iOS `Shared/Model/SimpleXAPI.swift` 与 KMP `SimpleXAPI.kt` 解码失配。
- 类型名/构造器若出现在 `SerialName` 或 `ToJSON` 默认派生里 = 线格式。
- `View.hs` 的 `simplex*` 多数是**纯显示函数**，改了无契约影响。

**建议拆两档**：
- **B2a（安全）**：只改**不进 JSON、不进 DB** 的类型名/函数名 + 显示串。
- **B2b（须同步）**：进 JSON 的字段名 → 与 `popopxmq` fork 同批改，或加显式 `@options/SerialName` 冻结 key 再改名。

  **2026-11-15 已裁定并执行（档 A），实际比 B2a 更窄**：只改**代码位**的 7 个标识符（`simplexChatCore`、`runSimplexChat`、`simplexChatTerminal`、`simplexChatCLI`、`simplexChatContact`、`simplexChatInvitation`、`simplexChatServer`），16 文件 / 59 处；**显示串一个字都没动**，所以 `server_operator_tag = 'simplex'`、`Operators.hs:94/98` 的 `"simplex" -> OTSimplex` 全部存活——Haskell 侧沿用它自己的旧裁定，字面量要改须另开一项。B2b 没被触发：改名的 7 个都不进 JSON、不进 DB，进 DB 的那批（`customData` 的 `simplexMcp`/`simplexMcpFiles`）因此保留。命名上游事物的标识符也没动（`operatorSimpleXChat` 9、`simplexChatRelays` 9、`simplexChatSMPServers` 7、`OTSimplex` 4、`ConnectSimplex` 3，改后复测同数）。门闸是 `cabal build all`（library + 8 个 executable）与 `cabal build popopx-chat:test:popopx-chat-test`，都绿；第一次红是因为 **`apps/**/*.hs` 里还有 23 处读取者**，`src`/`tests` 盘点看不见它们。

  同一轮里 `flake.nix` 的 **`lib:simplex-chat` 没有改**，所以 `scripts/ci/**` 引它的行仍然正确：那是 **Nix attribute 路径**，`build-core.sh:14` 与 `scripts/android/build-android.sh:108` 当命令行参数用它，改文档=改假，改 attribute=另一项。

### B3 KMP 源码树 `chat/simplex/**`（改名 = 414 路径）
`apps/multiplatform` 下 **414 个受控路径**；`package chat.simplex` **346**、`import chat.simplex` **1,983**、FQN 合计 **2,364**。

必须同批（缺一不可编译）：
| 站点 | 位置 |
|---|---|
| Gradle `namespace` | `common/build.gradle.kts:158 = "chat.simplex.common"` |
| moko `resourcesPackage` | `common/build.gradle.kts:169 = "chat.simplex.res"` → 改名后须**重跑 `generateResourceAccessors`** |
| Maven `group` | `apps/multiplatform/build.gradle.kts:67`、`common:11`、`desktop:12` = `"chat.simplex"` |
| desktop 入口 | `desktop/build.gradle.kts` 的 `mainClass` |
| Manifest | `common/src/androidMain/AndroidManifest.xml` 的 `package` |
| **JNI 符号** | `cpp/android/simplex-api.c` 的 `Java_chat_simplex_common_platform_CoreKt_*`（27 处）+ `cpp/{android,desktop}/CMakeLists.txt` |

⚠️ **验证级别**：本机**无 Android SDK、无 gradle** → 这一项**只能静态核验，不能编译验证**。上轮 Round 4 就是这个限制，本轮不变。
另注意：现存 43 个文件已声明 `com.popopxchat.popopx` 却仍住在 `chat/simplex/` 目录（package 与目录错配是**上游惯例允许、IDE 会告警**的状态）。

### B4 包名 / 产物名 / 顶层目录名
| 对象 | 现值 | 证据 |
|---|---|---|
| cabal 包名 | `simplex-chat` | `simplex-chat.cabal:6`（文件名同名） |
| npm | `simplex-chat`、`@simplex-chat/mcp`、`@simplex-chat/webrtc` | `packages/*/package.json` |
| PyPI | `simplex-chat` + `src/simplex_chat` | `packages/simplex-chat-python/pyproject.toml` |
| 目录 | `apps/simplex-*` ×9、`packages/simplex-chat-*` ×5 | 414+ 路径 |

连锁面（实测）：`.github/workflows/build.yml` **94 处** + `desktop-linux.yml` 15 + `android-emu.yml` 10 + `reproduce-schedule.yml` 9 + `ios-sim.yml` 6 + `packages.yml` 5（含 `hashFiles` 缓存键）、`flake.nix`、`scripts/ci/scope-tests.sh`、`scripts/ci/README.md`、`scripts/badge-service/Dockerfile`、`scripts/calculator-bot/{Dockerfile,compose.yml}`、`scripts/desktop/build-lib-*.sh`、`packages/simplex-chat-nodejs/src/libs.ts`、`packages/simplex-chat-python/src/simplex_chat/_native.py`、`scripts/flatpak/chat.simplex.{simplex.desktop,simplex.metainfo.xml}`、`scripts/simplex-chat-reproduce-builds{,-android}.sh`。

**外部依赖**：npm/PyPI 换命名空间 = 必须自建发布源；`simplex-chat-nodejs` 的预编译产物从 `simplex-chat/simplex-chat-libs` 拉（GitHub URL，禁令 5 保护），改包名不会自动改上游资产路径。
**建议**：目录名（`apps/simplex-*` → `apps/poopsx-*`）可以动，**包名/发布名保留**。

### B5 `SIMPLEX` 大写形式（385 处，**不可盲改**）
| 子桶 | 代表 | 判定 |
|---|---|---|
| **持久化的用户设置值** | `ChatWallpaperTypes.swift:SIMPLEX` 13、`ChatWallpaper.kt:SIMPLEX` 13、`Theme.kt:9`、`ThemeManager.swift:8`、`ThemeManager.kt:7` | 上轮明确保留的"设置项 tag `SIMPLEX`"。改 = **用户主题/壁纸设置回落到默认**，且需写迁移。**建议不动** |
| **SDK 查找契约** | `packages/simplex-chat-nodejs/{src/libs.ts,tests/libs.test.ts}:SIMPLEX_LIBS_DIR/SIMPLEX_ADDON_PATH`（19+13+13） | `1bb572be6` 的"双查找"就是为兼容；改新名必须**保留旧 env 双读** |
| **CI secrets 名** | `APPLE_SIMPLEX_{SIGNING_KEYCHAIN,NOTARIZATION_*}`、`STATUS_SIMPLEX_WEBHOOK_*` | 须先在仓库 Settings 里建同名新 secret，**否则 CI 直接红** |
| **编译开关** | `SIMPLEX_ASSETS`（Swift/KMP 两侧） | 实测 `Debug.xcconfig`/`Release.xcconfig` **未定义** ⇒ 该分支当前不生效，改它零收益、纯增 diff |
| 文档/夹具大写 | `PRIVACY.md:13`、`README.md:5`、`docs/lang/*/README.md:5` | 可改（属 A4/文档层） |

### B6 iOS 快照基线（**法律而非技术问题**）
`apps/ios/POPOPX Snapshots/References/` = **377 个条目**。A2/A3 一改品牌文案，这些基线全部失效；而 `assets/ASSETS_LICENSE.md` 声明图形素材（含快照截图）**不随 AGPL 授权**，仅允许"未修改的应用分发"。
**三个选项**：① 改文案后用 `recordMode` 重录基线（需 Xcode 可用，见第七节）；② 暂时跳过这些文案；③ 整体移除快照测试。**不能**只改名继续使用。

---

## 五、C —— 不能改（改了必坏，或与禁令/法律冲突）

| # | 内容 | 处 | 后果 |
|---|---|---|---|
| **C1** | GitHub URL 全串（`github.com` / `raw.` / `gist.` / `objects.`） | **1,001** | 违反禁令 5；`cabal.project` tag pin 与 `sha256map.nix` 失配 → 依赖解析失败；`Package.resolved` 的 WebRTC 拉取失败 |
| **C2** | `/version` 的编译期解析锚点 | `Controller.hs:130` 逐字节匹配 `"location: https://github.com/popopx-chat/popopxmq.git"` 读 `./cabal.project` | 改任一侧 → mq commit 静默显示空串 |
| **C3** | 协议 / 加密 / 已落库的 DB 名 | `simplex_domain_v1`（`Library/Commands.hs`）、`SerialName("SIMPLEX")`、`server_operator_tag = 'simplex'`、`OTSimplex` 存储值 `"simplex"`、迁移里的 `_simplex_name` 列（`M20260603_popopx_name.hs` ×2 store，8 处）、`foreign export ccall "simplex_*"`（`M20251117_member_relations_vector.hs`） | 对端/老数据校验失败，**不可逆** |
| **C4** | 运营商地址 | `Operators/Presets.hs`（18 处 `*.simplex.im` + 12 处 `*.simplexonflux.com`）、`presetDomains`、`stun/turn.simplex.im`、`simplexchat/smp-server` 镜像名 | 客户端全部连不上（属 B1，但即便 B1 选"改"，这一批也必须等有服务器） |
| **C5** | `libsimplex` 120 处 | `1bb572be6` 刻意保留的 SDK 双查找、`libHSsimplex-chat-*.a` 文件名由 cabal 包名派生 | 断链，iOS 直接编不过 |
| **C6** | `simplexmq` 442 处 | docs 198 / plans 71 / website 67 / apps 50 / blog 37 / packages 9 / 根 md 11 / scripts 2 / **`src/Popopx/Chat/Remote/Protocol.hs:253`（1，注释里的上游 rfcs 链接）** | 绝大多数在 URL 或历史文档内；依赖标识本身已改完（`popopxmq` 176） |
| **C7** | **法律署名**（AGPL §7 不得移除） | `SimpleX Chat Ltd` **82 处 / 28 文件**；`simplex-chat.cabal:10-14`（`homepage`/`author: simplex.chat`/`maintainer: chat@simplex.chat`/`copyright: 2020-22 simplex.chat`）；`LICENSE`；`packages/*/LICENSE` ×4；`docs/dependencies/licences/**` | 移除或改写 = 违反 AGPL 且削弱我方合规立场 |
| **C8** | 运行时数据目录 | `$HOME/.simplex`（上轮明确保留）、`simplex_v1_*` DB/asset 前缀、`~/.cache/simplex-chat`、`%AppData%\SimpleX` | 用户视角 = **数据丢失**；要改必须配迁移 |
| **C9** | 上游账号 / 指向上游的标识符 | `reddit.com/r/SimpleXChat`、`twitter.com/SimpleXChat`、`mastodon.social/@simplex`、`operatorSimpleXChat`、`InvestInSimpleXChatView` | `47e2c68e5` 已确立：那是上游拥有、当前仍正确的指向 |

---

## 六、D —— 需要**关联同步替换**的地方（你特别要求列出）

判据：改动落在"一处定义、别处按字面消费"的边界上，或落在跨进程/跨端/跨仓线格式上。

| # | 主改动 | 必须同批的镜像 | 现状 |
|---|---|---|---|
| **D1** | B2b：Haskell JSON 字段名 | iOS `apps/ios/Shared/Model/SimpleXAPI.swift`（`Shared` 区 975 处）、KMP `model/SimpleXAPI.kt`、`packages/simplex-chat-client`（30 路径）、`packages/simplex-chat-python`、`packages/simplex-chat-mcp` | **跨仓**：与 `popopxmq` fork 同命名空间，需两边同 commit |
| **D2** | B3：KMP 包目录 | Gradle `namespace`/`resourcesPackage`/`group`、`AndroidManifest.xml`、**JNI `Java_chat_simplex_common_platform_CoreKt_*`**（`cpp/android/simplex-api.c` 27）、`cpp/{android,desktop}/CMakeLists.txt`、moko 生成物重跑 | 未同步 = 能改源码树但 `ld` 找不到 JNI 符号 |
| **D3** | A1/A2/A3：iOS 文案与 catalogue | `project.pbxproj`（当前仍 94 处 simplex）、`.xcscheme` 的 `BuildableName`/`BlueprintName`、`PRODUCT_NAME`、`Info.plist` 的 `CFBundleName`/`CFBundleURLSchemes`、16 个 `<lang>/POPOPX--iOS--InfoPlist.strings`、`@testable import` | pbxproj 改错 = **Xcode 打不开工程** |
| **D4** | B4：目录改名 | `.github/workflows/*` **158 处**（`build.yml` 94；`hashFiles(...)` 缓存键须同步，否则缓存永远 miss）、`scripts/ci/scope-tests.sh:9`、`scripts/ci/README.md`、`scripts/badge-service/Dockerfile` + `.dockerignore`、`scripts/calculator-bot/{Dockerfile,compose.yml}`、`Dockerfile`、`Dockerfile.build`、`flake.nix`、`cabal.project` 的 `packages:` 段 | CI 与本地构建同时断 |
| **D5** | B4：npm/PyPI 名 | `packages/*/package-lock.json`、`package.json` 的 `bin`、`src/libs.ts`、`tests/*.ts`、`pyproject.toml` 的 `packages`、`_native.py`、`website/test/simplex-lib.test.js` | 与外部发布源耦合 |
| **D6** | B1：域名 | `POPOPX (iOS).entitlements:9-15`、`website/src/.well-known/**`（AASA + assetlinks）、`docs/LINKS.md` **886**、`tests/MarkdownTests.hs` **117**、`scripts/flatpak/chat.simplex.simplex.metainfo.xml` **49**、`appLinkScheme="simplexchat"` | **外部前置**：DNS + 证书 + `.well-known` 上线 + **assetlinks 的 3 条 `sha256_cert_fingerprints` 仍是 SimpleX 的**（上轮待办 #1） |
| **D7** | B1：Team ID | `PDBA6XRBQT`（本仓 WIP，已写进 `ACCESS_GROUP`，`KeyChain.swift:13` **运行时已生效**）vs `PQ7U3P36H8`（`popopxmq` 仓同名文件） | **两个只有一个是对的**；选错 → 设备端 keychain 与 Universal Links 同时失败。上轮待办 #3，仍未裁定 |
| **D8** | B5：secrets 名 | GitHub 仓库 Settings → Secrets（`APPLE_SIMPLEX_*`、`STATUS_SIMPLEX_WEBHOOK_*`） | 先建后改，否则 CI 立刻红 |
| **D9** | 已发出的邀请链接 | `simplex:` → `popopx:` **上轮 `05dd5a73c` 已改** | 需确认：历史 `simplex:/` 链接是否仍被解析（双解析）？若不解析，老用户互发的链接在我方客户端已失效 —— 这是**上轮遗留、本轮建议先验证**的项 |
| **D10** | 本地化 key | `.strings`/`.xliff` 把 `popopx:/…` 与品牌串当 **key + trans-unit id** | 改 value 不改 key → 运行时查不到；必须 key 与引用它的 Swift/Kotlin 源文本同批 |
| **D11** | 快照基线 | B6：`POPOPX Snapshots/References/*` | 文案一改即全红，需 `recordMode` 重录 |
| **D12** | AGPL 告知 | `FORK.md`/`NOTICE`（新建）、`README.md` 顶部、`docs/TRADEMARK.md`、`assets/ASSETS_LICENSE.md`、`media-logos/README.md`、`docs/DIRECTORY.md` | 见第七节 |

---

## 七、AGPL-3.0 合规做法（"同时替换要遵循 AGPL 3.0"）

1. **AGPL 文本零改动**：`LICENSE`、`packages/*/LICENSE` ×4、`docs/dependencies/licences/**`（含 4 份文件名带 SimpleX 版权的第三方许可）。AGPL 前言明写"允许逐字复制该文档，但**不允许修改**"。
2. **§7 保留法律署名**：28 个文件 / 82 处 `Copyright (c) … SimpleX Chat Ltd`、`simplex-chat.cabal:11-14` 的 author/maintainer/copyright → **原文保留**，只在其下方**追加** fork 声明；仅新建文件用 POPOPX 署名。
3. **§5c 修改告知（当前缺失 = A8）**：新建 `FORK.md`/`NOTICE`，写明派生自上游 `db0768c21`、上游仓库 URL、修改日期与范围（标识符 + 品牌清单）；`README.md` 顶部显著标注"本仓库为 simplex-chat 的非官方 fork，已修改"。
4. **§13 网络服务条款**：`apps/simplex-support-bot-light`、`apps/simplex-directory-service`、`apps/simplex-badge-service` 属服务端。若以 SaaS/relay/bot 对外提供，界面必须提供对应完整源码获取入口。
5. ⚠️ **商标与图形素材不在 AGPL 授权内**（两条硬约束，**不能靠文本替换解决**）：
   - `docs/TRADEMARK.md`：SimpleX 名称与 logo 是 SimpleX Chat Ltd 商标，禁止用途明写"as part of any software's name, branding, or logo, **including forks**"。这既是**必须完成品牌清扫的法理依据**，也意味着该文件不能留成"看起来是我们的政策" → 移入 `docs/upstream/` 并注明"上游政策原文"，另写 POPOPX 自己的声明。
   - `assets/ASSETS_LICENSE.md`：logo、图标、插画、应用截图、**测试快照图**为专有，仅允许"未修改的应用分发"。→ **216 个含 simplex 的二进制路径** + **B6 的 377 个快照基线**，改名后仍是 SimpleX 的美术。必须三选一：**换自制素材 / 移除 / 取得书面授权**。
   - `docs/SIMPLEX.md` 与 `docs/lang/{cs,fr,pl}/SIMPLEX.md` 是品牌说明文档，需整体改写或下架。

---

## 八、执行方式（获批后才做）

1. **还原点**：当前工作区干净 → 直接开 `rebrand/popopx-text` 分支，**每组一个 commit**，任一组可独立 revert。
2. **占位符保护法**（满足禁令 4/5，上两轮已验证）：
   - ① 哨兵保护 `simplexmq|simplexMQ|SimpleXMQ|Simplexmq|core_simplexmq` → `␕MQ␕`；
   - ② 哨兵保护 host ∈ {`github.com`,`raw.`,`gist.`,`objects.`} 的**整条 URL** → `␕GH␕n`；
   - ③ 按 **`SimpleX`→`POPOPX`、`Simplex`→`Popopx`、`simplex`→`popopx`** 顺序替换（大小写敏感、互不重叠）；`SIMPLEX` 依 B5 单独处理；
   - ④ 还原哨兵；
   - ⑤ 负向校验：`POPOPXMQ|popopxmq(?!Version|Commit)` 为 0；**GitHub URL 行数前后必须一致**（本轮基线 1,001 处）。
3. **额外保护**（本轮新增，上轮踩过的）：替换前先冻结 C3/C5/C8/C9 的字面量清单（`simplex_domain_v1`、`SerialName("SIMPLEX")`、`_simplex_name`、`libsimplex`、`$HOME/.simplex`、`operatorSimpleXChat`、上游社交 handle），逐条做"禁改串"，而不是靠事后 grep 找回。
4. **改名机制**：按路径深度**从最深往上** `git mv`，每段只替换品牌名，全部改完再统一回写引用文本（D3/D4）。
5. **验证级别（如实区分，不合并汇报）**：
   - 可实跑：`cabal build`（**`cabal.project.local` 是 load-bearing**：keg-only OpenSSL + `flags: +openssl`，丢了会编出**不加密**的 sqlcipher；`~/.ghcup/bin` 不在 PATH）、`xcodebuild` 设备 + 模拟器（模拟器**必须** `ARCHS=arm64`）、`npm test` / `pytest`、Markdown/链接检查。
   - **只能静态核验**：Android / KMP（本机无 Android SDK 与 gradle）。
   - 任何 `cabal` 红跑之后**必须复查** `src/Popopx/Chat/Store/SQLite/chat_schema.sql`：本机系统 sqlite **3.54** 会因纯格式差异误判并把该文件改写成非法 SQL → PATH 须前置自建的 `~/.local/share/sqlite-3.39.2/bin`。
6. 逐条留痕：`(file, line, before, after, expected-count)` JSONL 到 `~/popopx-chat/rebrand-log-popopx-chat/`，每条替换带 **expected-count 断言**（上轮该断言拦下过我写错的期望值）。

---

## 九、可选档位

| 档 | 内容 | 处（约） | 风险 | 可验证性 |
|---|---|---|---|---|
| **甲**（文案+合规） | **A1…A9 全部**：死本地化包、`.strings`、`.xliff`、`strings.xml`、Swift/Kotlin 显示串、终端文案、空壳工程目录、`FORK.md` | ≈15,000 | **零功能风险**（A1/A7 连引用都没有） | cabal + xcodebuild 可实跑；KMP 静态 |
| **乙**（甲 + 全部目录名） | + B4 的目录改名（`apps/simplex-*`、`packages/simplex-chat-*`、`scripts/flatpak`、R5 类）与 D4 CI 同步；+ A1 之外的 R1 静态资源改名（`docs/links/images` 153、`blog` 47、`media-logos` 8…） | +≈1,400 路径 | **中**：CI/nix/Docker 必须同批改对，改错 = 构建断 | CI 只能静态核验（本机无 Actions） |
| **丙**（乙 + KMP 源码树） | + B3（414 路径 / 2,364 处 / D2 的 JNI+CMake+gradle） | +≈3,000 | **高**：**本机无法编译验证 Android** | 静态 |
| **丁**（丙 + 线格式与标识符） | + B2b（JSON 字段）+ B5（大写全量）+ C8（数据目录，含迁移） | +≈700 | **最高**：跨 `popopxmq` 仓、涉及用户数据迁移 | 需 mq 同批 + 迁移脚本 |
| **（独立）戊** | B1 域名 + D6/D7 | ≈2,033 | 属**基础设施工程**不是文本替换，**必须等域名与服务器就绪** | 需线上验证 |

**建议顺序**：**甲 → （验证 cabal/xcodebuild）→ 乙 → 观察 → 丙**；丁、戊各自单独立项。

---

## 附：请回复的格式

```
执行 <甲|乙|丙|丁>            （可多选，如：甲 + 乙）
B1 域名      = 不动 | 已有自有域名：<填域名与服务器地址>
B2 Haskell   = a 只改非线格式 | b 全改（需 popopxmq 同批）
B4 包名      = 只改目录名 | 连 cabal/npm/PyPI 包名一起改
B5 SIMPLEX   = 不动 | 只改文档与显示项 | 全量
B6 快照素材  = 重录基线 | 移除快照测试 | 保留待授权
D7 Team ID   = PDBA6XRBQT | PQ7U3P36H8
```
