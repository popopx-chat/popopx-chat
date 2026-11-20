//
//  PopopxAntiPhotoRenderView.swift
//  POPOPX (iOS)
//
//  【绝密阅后即焚 · 模块四·快门侧】对着屏幕拍照的那一路，这里给三件东西：
//  1. `PopopxAntiPhotoRenderView`：分时复用点阵覆盖层，打的是相机快门的积分时间/滚动快门；
//  2. `PopopxSpotlightTextView` / `PopopxTeleprompterTextView`：两种"要按住才读得清"的阅读模式，
//     打的是"举着手机另一台机器还能顺手拍完一整页"这个动作；
//  3. `PopopxBlindWatermarkOverlay`：肉眼看不见的盲水印，不防任何人，只负责事后能查出是谁漏的。
//
//  ### 点阵覆盖层的物理主张（写到能被反驳的程度，不写"绝对拍不清"）
//  做的事：每帧在两副**逐像素互补**的二值灰度点阵之间切换（`PopopxShutterPattern`），由
//  `PopopxFrameTicker` 驱动在 60Hz 上交替；同一块 tile 只生成一次并缓存，每帧换的只是一个引用。
//  为什么肉眼还读得清、照片会坏：
//  - 肉眼：单帧空间频率在 1 像素级（超出正常阅读距离下的分辨力），时间上 60Hz 交替被视觉暂留
//    平均成一层约 5% 的灰雾；平均亮度不随相位变，所以看不到"闪"，只看到"糊了一层"。
//  - 相机：CMOS 是**滚动快门**——每一行像素的曝光时刻不同，一帧里靠上的行采到相位 A、靠下的行
//    采到相位 B、跨边界的行把 A+B 积分到一起。三种行各自拿到不同的点阵，输出就是横向带状 + 低频
//    摩尔纹拍在文字上；再叠上镜头 MTFO 低通、Bayer 去马赛克与 JPEG 4:2:0 —— 因为点阵是**纯亮度**
//    信号（灰度，无彩色），色度下采样没法把它和图像自身的亮度分开，也就没法靠去噪把它当噪声扔掉。
//  不成立的条件（这几条是真的能被绕过，不许在界面文案里说满）：
//  - 全局快门 / 机器视觉相机把整帧曝光压进一个显示帧内 → 只采到一副相位，交替这一条腿直接失效
//    （这时还剩空间混叠那条腿，但幅度小得多）；
//  - 慢速快门（≥2 个显示周期）把两相位完整积分 → 点阵自己抵消掉，只剩一层均匀的雾；
//  - 纯黑或纯白表面上单边被削顶：0 值像素在纯黑背景上没作用，255 值像素在纯白背景上没作用，
//    互补性只剩一半 —— 所以这层的最佳工作区间是**中间调**表面；
//  - 长距离变焦 + 低分辨率，或干脆把照片送进多帧平均/深度学习复原 → 都能显著缓解。
//  所以这一层的定位是"让随手拍的照片里那几行小字变得不可读/不可信"，不是"拍不下来"。
//
//  ### 光敏与可读性（这条不是可选的道德声明，是设计参数）
//  全屏 60Hz 交替是**闪烁**。这里的缓解是四件：不透明度只有 0.05；两副点阵各自的亮/暗格数由构造
//  保证严格 32/32（`PopopxShutterPattern.baseBit` 的中心对称配对），所以交替**不改变平均亮度**，
//  屏上不存在 30Hz 的低频亮度分量，闪烁只落在空间-时间通道里；单帧亮暗跳变在 1 像素尺度上只占
//  一半面积；`accessibilityReduceMotion` 为真时**停掉交替**，退化成一副静止点阵（保住空间混叠那条腿，
//  放弃时间那条腿）。另外这一屏最长只存在 `ttlSeconds` 秒。即便如此，"上机后按 WCAG 2.3.1 复核过"
//  仍然必须是发布前的人工步骤——本文件给不出这个证明。
//
//  ### 两种阅读模式打的是动作，不是像素
//  聚光灯：默认整屏糊，只有按住的那块圆里清晰；逐行：一次一个逻辑行，必须按住并纵向拖动才走。
//  共同点是"手不能离开屏幕、而且每次只看一小块"——用另一台设备顺手拍完整页这个动作因此做不到
//  （拍得到的只是一小块清晰区域，其余是糊的/别的行）。这两种模式**不防**把手机递出去给别人看，
//  也不防长按不动把清晰窗口停在某一行再拍——那是物理防窥屏/摄像头检测那两路的活。
//
//  ### 盲水印防什么，一目了然
//  什么都不防。它是**取证**：设备 `identifierForVendor` + 会话 id（超过 64 整字 / 128 UTF-8 字节
//  会被截断，这是写明有损的一处）+ 毫秒时间戳编成点阵，两种颜色的对比是 1/255，肉眼看不见，只在一帧
//  被拍下来或被系统截屏之后、丢进编辑器里拉亮度/对比度时才浮出来。它只在一件已经发生的事（图漏出去
//  了）之后提供归因，因此：不要把"带水印"写进任何"防拍照"的文案里。
//
//  ### 线程与所有权契约
//  - 三个视图都只读调用方传进来的值，不订阅任何东西，不持有对方对象；
//  - 点阵驱动 `PopopxRollingShutterDriver` 只在 `isEnabled` 为真、且这层进了视图树之后才存在，
//    `onDisappear` 里必停（`PopopxAntiPhotoRenderView` 关掉时是**真零开销**：不建 ticker、不进绘制）；
//  - 两个缓存（tile / 水印矩阵）是进程级可变字典，只在主线程访问（视图 body 求值即主线程）。
//    键是 `sessionIdentifier` / 缩放档位，容量都有上限，不因为缓存而延长任何一份明文的寿命。
//
//  ### 可验证的纯逻辑区
//  下面 `POPUPX_PURE_CORE_BEGIN`/`END` 之间那一段**不引用任何 UIKit/SwiftUI 符号**，为的是能被整段
//  切出去用 host 编译器跑往返试验（位编码 ↔ 解码、两相位逐像素互补且各 32/32、屏幕视觉行列 ↔ 比特
//  下标互逆、切分不越预算也不丢字）。改这一段之后必须重跑那套断言；也正因为它只能被这样验，
//  把它保持在一个连续区间里是硬性要求，不是排版偏好。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import SwiftUI
import UIKit

// ================ POPUPX_PURE_CORE_BEGIN（这一段不许出现 UIKit/SwiftUI 符号） ================

// MARK: - 阅读模式

/// 绝密弹窗的两种"要按住才读得清"的读法。
enum PopopxSecureReadMode: String, CaseIterable, Identifiable, Sendable {
    /// 聚光灯：整屏重度模糊，只有按住的那块圆清晰。
    case spotlight
    /// 逐行：单行窗口，按住拖动才走。
    case teleprompter

    /// `Identifiable` 要显式给：`CaseIterable` 只保证 `allCases`，不保证 id。
    var id: String { rawValue }

    /// 给 `PopopxSegmentedControl` 的短标签。
    var title: String {
        switch self {
        case .spotlight: return NSLocalizedString("Spotlight", comment: "secure read mode")
        case .teleprompter: return NSLocalizedString("Line by line", comment: "secure read mode")
        }
    }

    /// 给 `PopopxSectionCard(footnote:)` 的一行说明：讲清楚"要按住"这个动作，不讲保证。
    var note: String {
        switch self {
        case .spotlight:
            return NSLocalizedString("The whole screen is heavily blurred; only the circle under your finger stays sharp. Let go and it all blurs back.", comment: "secure read mode")
        case .teleprompter:
            return NSLocalizedString("One logical line at a time: hold and drag up to move down, release to stop where you are.", comment: "secure read mode")
        }
    }
}

// MARK: - 分时复用点阵（纯逻辑）

/// 两副逐像素互补的二值点阵。tile 与 tile 之间在**每一个像素上**都相反，这是"积分互相抵消"这条
/// 判据的来源；单块 tile 只有 64 字节，所以两副都只生成一次。
/// 两副各自的亮格数由构造保证相等（见 `baseBit`），因此叠加层的平均亮度与相位无关 —— 不引入闪烁。
enum PopopxShutterPattern {
    /// tile 边长（设备像素）。8 是刻意选的小于常见屏幕宽度的 2 的幂：平铺时不产生可见的大周期，
    /// 摩尔纹因此是宽频的而不是几条固定带（固定带会被相机降噪当成规则噪声处理掉）。
    static let tilePixels = 8

    /// 点阵只用这两个电平：只有两个取值，才能宣称"最高空间频率 + 最大幅度"。
    static let darkValue: UInt8 = 0
    static let lightValue: UInt8 = 255

    /// (x, y) 在某一相位下是亮格还是暗格。相位只做一次取反，别的什么都不做。
    static func bit(x: Int, y: Int, phase: Int) -> Bool {
        let raw = baseBit(x: x, y: y)
        return phase & 1 == 0 ? raw : !raw
    }

    /// 一副相位灰度平面（行优先，`tilePixels * tilePixels` 字节，每字节只可能是 dark/light）。
    static func grayPlane(phase: Int) -> [UInt8] {
        var plane = [UInt8](repeating: darkValue, count: tilePixels * tilePixels)
        for y in 0 ..< tilePixels {
            for x in 0 ..< tilePixels {
                plane[y * tilePixels + x] = bit(x: x, y: y, phase: phase) ? lightValue : darkValue
            }
        }
        return plane
    }

    /// 基准位：只由 (x, y) 决定，不含 phase —— 相位只做取反，所以互补性是结构性保证，不是巧合。
    ///
    /// **平衡是构造出来的**：每个像素与它的中心对称像素配成一对，一对里必出一亮一暗
    /// （`tilePixels` 是偶数，所以不存在自配对的像素）。于是两相位在 tile 内都恰好 32 亮 32 暗，
    /// 叠加层的平均亮度与相位无关 —— 屏幕上不会有任何低频闪烁，闪烁只存在于空间-时间通道里。
    /// 若只靠哈希不保证计数平衡，实测会出 26/38 这种偏离，那 = 两相位之间多出一个约 18.8% ×
    /// 不透明度的 30Hz 亮度分量；它对"相机积分抵消"没帮忙也没添乱，但没有任何理由留着它。
    private static func baseBit(x: Int, y: Int) -> Bool {
        let mirrorX = tilePixels - 1 - x
        let mirrorY = tilePixels - 1 - y
        let here = y * tilePixels + x
        let there = mirrorY * tilePixels + mirrorX
        if here <= there {
            return rawBit(x: x, y: y)
        }
        return rawBit(x: mirrorX, y: mirrorY) == false
    }

    /// 取 bit 13：低位被 `x &* 31 &+ y` 那一步的算术结构污染，实测同一行内会出现连续同值；
    /// 换到中位之后相邻像素翻转率接近 50%、2×2 全同窗口数量跌到个位（`/tmp` 自测台有实测数字）。
    private static func rawBit(x: Int, y: Int) -> Bool {
        (mix(x: x, y: y) >> 13) & 1 == 1
    }

    /// 过程稳定的确定性哈希（FNV-1a 变体），不用 `Int.hashValue`：后者的种子每次进程启动都不同，
    /// 那样"两副 tile 互补"仍然成立、但同一台设备两次生成的图案不一样，取证与上机复现都没法比对。
    private static func mix(x: Int, y: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in [UInt64(x & 0xFF), UInt64(y & 0xFF), UInt64((x &* 31 &+ y) & 0xFF)] {
            hash = (hash ^ value) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - 逐行阅读的切分（纯逻辑）

/// 把一段正文切成"逐行模式"的逻辑行。
///
/// 为什么不能交给 SwiftUI 自己排版：这一档要的是**一次只出现一行**，而排版结果取决于宽度、
/// 字体档位与文案，同一句话在 SE 档是一行、在 AX 档是三行。拿排版结果当"行"，用户拖一下
/// 跳的就是两三行，且不同设备上跳的量不一样 —— 这个交互必须是可预期的，所以行由我们切。
enum PopopxReadingLines {
    /// 一个逻辑行的字符预算（整字计数，CJK 与拉丁都按"一个字/一个字母"算）。
    /// 24 是按"375pt 窄屏 + body 字号 + 不缩放"一行放得下的保守估计；宁可多切几行，
    /// 也不能在窄屏上让一行绕成两行——那样窗口里会同时露出两行。
    static let charactersPerLine = 24

    /// 段落优先（换行的判定用 `Character.isNewline`，见下），段落内按字符预算贪心切：
    /// 窗口后半段里能找到空格就在空格处下刀（英文词不被腰斩），找不到就硬切（CJK 无空格的正解）。
    /// 全空白的段落被丢弃：一次按压换来一个空行，等于告诉用户"这个手势没用"。
    ///
    /// 任何输入都必须返回**终止的、有界的**结果：`limit < 1` 不递归、4000 字符无空格的单"词"
    /// 也只是多切几块，绝不可能变成一次 O(n²) 的扫描或死循环。
    static func lines(from text: String, maxCharactersPerLine limit: Int = charactersPerLine) -> [String] {
        guard limit > 0 else { return text.isEmpty ? [] : [text] }
        let characters = Array(text)
        var result: [String] = []
        var start = 0
        var index = 0
        while index <= characters.count {
            // 这里**不能**写成 `characters[index] == "\n"`：Swift 的 `Character` 是字素簇，
            // 跨平台传来的 "第一段\r\n第二段" 里那个 CRLF 是**一个**整字 "\r\n"，它不等于 "\n"，
            // 于是整篇消息会被当成一个段落硬切，切出来的"行"里还带着 CR/CRLF 这种不可见整字 ——
            // 交给 Text 排版时就是一行里突然折行，"一次只显示一行"当场失效。
            // `isNewline` 认 \n、\r、\r\n 以及 U+000B/U+000C/U+0085/U+2028/U+2029，一次覆盖全部写法。
            if index == characters.count || characters[index].isNewline {
                appendWrapped(characters: characters, start: start, end: index, limit: limit, into: &result)
                start = index + 1
            }
            index += 1
        }
        return result
    }

    /// 恒等式（被断言覆盖的那条）：把结果去掉空白拼回来，等于原文去掉全部空白。
    /// 也就是说切分只**加**换行、只**删**空白，永远不丢字符、不改字符。
    static func isLossless(original: String, lines: [String]) -> Bool {
        withoutWhitespace(original) == withoutWhitespace(lines.joined())
    }

    static func withoutWhitespace(_ value: String) -> String {
        value.filter { $0.isWhitespace == false }
    }

    private static func appendWrapped(
        characters: [Character],
        start: Int,
        end: Int,
        limit: Int,
        into result: inout [String]
    ) {
        // 段落两端先各去掉空白：开头那圈空白让切出来的第一行以空格起头（缩进错觉），
        // 结尾那圈让最后一行带着看不见的尾巴占掉字符预算。中间的空白原样保留。
        var cursor = start
        while cursor < end, characters[cursor].isWhitespace { cursor += 1 }
        var paragraphEnd = end
        while paragraphEnd > cursor, characters[paragraphEnd - 1].isWhitespace { paragraphEnd -= 1 }
        while cursor < paragraphEnd {
            let windowEnd = min(cursor + limit, paragraphEnd)
            var cut = windowEnd
            // 只有"窗口装不下"时才需要下刀；装得下的段落绝不因为里面有个空格就被拆成两行
            // （那样一句短话会变成三次按压，而这一档的全部意义就是"一次只看一行"）。
            if windowEnd < paragraphEnd {
                var probe = windowEnd - 1
                // 从窗口尾往回找第一个空格，且只认落在窗口**后半段**的空格：
                // 在前一半下刀会让行宽突然掉到预算的一半，比腰斩一个长词更难看。
                // 不许落在 cursor 上，否则这一轮不前进。
                let floor = cursor + (windowEnd - cursor) / 2
                while probe > cursor {
                    if characters[probe].isWhitespace, probe >= floor {
                        cut = probe
                        break
                    }
                    probe -= 1
                }
            }
            let piece = String(characters[cursor ..< cut])
            if piece.isEmpty == false {
                result.append(piece)
            }
            cursor = cut
            while cursor < paragraphEnd, characters[cursor].isWhitespace { cursor += 1 }
        }
    }
}

// MARK: - 盲水印编码（纯逻辑）

/// 一条盲水印的可解码内容。
struct PopopxWatermarkBits: Equatable, Sendable {
    let deviceIdentifier: String
    let sessionIdentifier: String
    let epochMillis: Int64
}

/// 点阵的格数、散布步长、两种颜色与编解码。全部是整数算术 —— 屏幕上那块 Canvas 只负责按这里
/// 给出的 `onCells` 画格子，几何与编码的任何一处改动都会让已发出的图对不上号。
enum PopopxBlindWatermarkCodec {
    /// 固定的 40×40 格。**不是**按屏幕尺寸算列数：取证时分析者必须能从图里数出格数才知道怎么读，
    /// 而几何相关的布局在不同尺寸下解出的是不同的比特顺序，那等于把水印写成"只有同一台设备能解"。
    static let gridColumns = 40
    static let gridRows = 40
    static let cellCount = gridColumns * gridRows

    /// 比特 i 放到格子 `(i * stride) % cellCount`。步长与格数必须互质，否则散布会提前循环、
    /// 后半段比特全被覆盖掉（40×40 = 1600 = 2^5 × 5^2，31 与之互质 ✓）。
    /// 散布的意义：载荷只有千把比特，若按格顺序铺就会在屏幕一角留一条高密度带子，
    /// 既容易被当"纹理"注意到，也容易在被裁掉的图里整段丢失。
    static let scatterStride = 31

    /// 载荷字节上限 = 格数 / 8。超出就是编码端的错，`encode` 直接返回 nil 而不是悄悄截断。
    static let maximumPayloadBytes = cellCount / 8

    /// 会话 id 的**字符**上限。超过就截断 —— 这是**已知的信息损失**，写在这里而不是藏在代码里：
    /// 载荷里另外还留着完整时间戳与设备号，截断只影响"这次查看"和会话表的对齐精度。
    static let maximumSessionCharacters = 64

    /// 会话 id 的 **UTF-8 字节**上限，与上面那条**同时**生效，且对中文 id 才是实际起作用的那条：
    /// 一个 CJK 整字占 3 字节，只按字符截会得到 64 字 = 192 字节，整帧载荷 247 > 200，
    /// `encode` 返回 nil —— 结果是**水印整个不出现**，而这正是最难发现的一种失效。
    /// 128 的取法：4(magic) + 1 + 36(设备 UUID) + 1 + 128 + 13 = 183 ≤ 200，留出设备号最长的现实情形。
    static let maximumSessionBytes = 128

    /// 规范要求的两种近黑色。整幅点阵除了这两个值不出现第三个值（`rgb(isOn:)` 是唯一出口）。
    static let offColorRGB: UInt32 = 0x0000_00
    static let onColorRGB: UInt32 = 0x0101_01

    /// magic(4) | deviceLen(1) | device | sessionLen(1) | session | millis(13 个 ASCII 数字)
    static let magicBytes: [UInt8] = [0x50, 0x58, 0x53, 0x31] // "PXS1"
    static let millisDigits = 13

    /// 编成一帧载荷。`deviceIdentifier` 由调用方给（拿不到时传 ""，见视图侧的 nil 处理）。
    static func encode(_ record: PopopxWatermarkBits) -> [UInt8]? {
        let device = Array(record.deviceIdentifier.utf8)
        let session = Array(clamp(record.sessionIdentifier).utf8)
        let millis = millisecondDigits(record.epochMillis)
        var bytes: [UInt8] = magicBytes
        bytes.append(UInt8(min(device.count, 255)))
        bytes.append(contentsOf: device.prefix(255))
        bytes.append(UInt8(min(session.count, 255)))
        bytes.append(contentsOf: session.prefix(255))
        bytes.append(contentsOf: millis)
        guard bytes.count <= maximumPayloadBytes else { return nil }
        return bytes
    }

    static func decode(_ bytes: [UInt8]) -> PopopxWatermarkBits? {
        let header = magicBytes.count
        guard bytes.count >= header + 2 else { return nil }
        guard Array(bytes[0 ..< header]) == magicBytes else { return nil }
        let deviceLength = Int(bytes[header])
        let deviceStart = header + 1
        guard bytes.count >= deviceStart + deviceLength + 1 else { return nil }
        let sessionLength = Int(bytes[deviceStart + deviceLength])
        let sessionStart = deviceStart + deviceLength + 1
        guard bytes.count >= sessionStart + sessionLength + millisDigits else { return nil }
        let device = String(decoding: bytes[deviceStart ..< deviceStart + deviceLength], as: UTF8.self)
        let session = String(decoding: bytes[sessionStart ..< sessionStart + sessionLength], as: UTF8.self)
        let millisRange = sessionStart + sessionLength ..< sessionStart + sessionLength + millisDigits
        let millisText = String(decoding: bytes[millisRange], as: UTF8.self)
        // 时间戳那一格只认数字：整串里出现任何一个非数字就说明这张图不是我们画的点阵。
        guard millisText.allSatisfy(\.isNumber), let millis = Int64(millisText) else { return nil }
        return PopopxWatermarkBits(deviceIdentifier: device, sessionIdentifier: session, epochMillis: millis)
    }

    /// 载荷 → 格子。返回长度恒为 `cellCount`，载荷之外的格子是 false。
    static func cells(from bytes: [UInt8]) -> [Bool] {
        var cells = [Bool](repeating: false, count: cellCount)
        guard bytes.count <= maximumPayloadBytes else { return cells }
        var bitIndex = 0
        for byte in bytes {
            var mask: UInt8 = 0x80
            while mask != 0 {
                if byte & mask != 0 {
                    cells[bitIndex] = true
                }
                mask >>= 1
                bitIndex += 1
            }
        }
        return cells
    }

    /// 散布：第 i 比特落到格子 `(i * stride) % cellCount`。
    ///
    /// 只搬运为 1 的比特就够了：目标是全 false 的新数组，而 `(i * stride) % cellCount` 在互质
    /// 前提下是一个置换（不会有两个比特抢同一个格子），所以"只写 1"和"整段赋值"结果相同，
    /// 前者少一半写入。
    static func scatter(_ cells: [Bool]) -> [Bool] {
        precondition(cells.count == cellCount, "scatter input must be \(cellCount) cells, got \(cells.count)")
        var scattered = [Bool](repeating: false, count: cellCount)
        for (bitIndex, isOn) in cells.enumerated() where isOn {
            scattered[(bitIndex * scatterStride) % cellCount] = true
        }
        return scattered
    }

    /// 反散布：`gather` 的第 i 比特就是 `scatter` 放在格子 `(i * stride) % cellCount` 上的那一比特。
    /// 也就是沿同一条公式正向走一遍 —— 反函数靠的是互质，不靠查表，因此取证端不需要任何附加数据。
    static func gather(_ scattered: [Bool]) -> [Bool] {
        precondition(scattered.count == cellCount, "gather input must be \(cellCount) cells, got \(scattered.count)")
        var cells = [Bool](repeating: false, count: cellCount)
        for bitIndex in 0 ..< cellCount {
            cells[bitIndex] = scattered[(bitIndex * scatterStride) % cellCount]
        }
        return cells
    }

    /// 唯一的颜色出口：任何格子都只可能是两种近黑色之一。
    static func rgb(isOn: Bool) -> UInt32 {
        isOn ? onColorRGB : offColorRGB
    }

    /// 整条链：载荷 → 未散布格子 → 散布后的点阵。
    static func matrix(for record: PopopxWatermarkBits) -> PopopxWatermarkMatrix? {
        guard let bytes = encode(record) else { return nil }
        let scattered = scatter(cells(from: bytes))
        let onCells = scattered.enumerated().compactMap { $0.element ? $0.offset : nil }
        return PopopxWatermarkMatrix(record: record, cells: scattered, onCells: onCells)
    }

    /// 从点阵读回来（取证/自测用；参数是**散布后**的格子）。
    static func record(from cells: [Bool]) -> PopopxWatermarkBits? {
        let gathered = gather(cells)
        var bytes: [UInt8] = []
        var bitIndex = 0
        while bitIndex + 8 <= gathered.count {
            var byte: UInt8 = 0
            for bit in 0 ..< 8 {
                if gathered[bitIndex + bit] {
                    byte |= UInt8(0x80 >> bit)
                }
            }
            bytes.append(byte)
            bitIndex += 8
        }
        return decode(bytes)
    }

    /// 两个口径都无条件收窄（字符数 → `maximumSessionCharacters`，UTF-8 字节数 → `maximumSessionBytes`）。
    /// 不写"长度不够就直接返回原串"的捷径：那条捷径正是让 64 个汉字（192 字节）漏过字节上限的原因。
    /// 逐字 `removeLast` 退的是**整字**，因此结果永远是合法 UTF-8，`decode` 侧不会读到坏序列。
    static func clamp(_ session: String) -> String {
        var candidate = session
        if candidate.count > maximumSessionCharacters {
            candidate = String(candidate.prefix(maximumSessionCharacters))
        }
        while candidate.utf8.count > maximumSessionBytes, candidate.isEmpty == false {
            candidate.removeLast()
        }
        return candidate
    }

    private static func millisecondDigits(_ millis: Int64) -> [UInt8] {
        // 上限 13 位（≈ 公元 2286 年）：超出就钉死在最大值而不是截断前 13 位 ——
        // 截断会让 `decode` 读回一个和写进去完全不同的时刻，而往返可逆是这一层唯一的正确性判据。
        let clamped = min(max(0, millis), 9_999_999_999_999)
        let text = String(clamped)
        let padded = String(repeating: "0", count: millisDigits - text.count) + text
        return Array(padded.utf8)
    }
}

/// 一帧画完的水印点阵。不可变 —— 时间戳必须在一次查看会话里只取一次，否则每次重绘都会换一套
/// 比特，屏幕上的格子就会蠕动（肉眼可见），而取证读到的时间戳也不再代表"这次查看"。
///
/// 格子下标 → 屏幕位置用一个**逐行错开**的映射（不是行优先直铺）。原因在自测里量到了：
/// 载荷以 ASCII/UUID 为主，比特下标 mod 8 的分布极不均匀，而 1600 = 40 × 40、40 = 8 × 5，
/// 于是纯行优先的 `column = i % 40` 会把"同一个 mod-8 剩余类"的亮格全挤进固定的 5 列 ——
/// 实测某典型载荷 244 个亮格只覆盖 34/40 列。列被整块裁掉时亮格会成片消失，
/// 错开之后同样的载荷覆盖全部 40 列（见 /tmp 自测报告的数字）。
struct PopopxWatermarkMatrix: Equatable, Sendable {
    let record: PopopxWatermarkBits
    /// 散布后的格子，长度恒为 `PopopxBlindWatermarkCodec.cellCount`。
    let cells: [Bool]
    /// 需要着色的格子下标（比遍历 1600 格再判断便宜，也是 Canvas 那一侧唯一的绘制清单）。
    let onCells: [Int]

    /// 每往下一行，整行往右挪这么多格。与 `gridColumns` 无公因子即可（这里 7 与 40 互质）。
    static let rowStagger = 7

    func column(of index: Int) -> Int {
        let columns = PopopxBlindWatermarkCodec.gridColumns
        let shifted = index % columns + Self.rowStagger * row(of: index)
        return ((shifted % columns) + columns) % columns
    }

    func row(of index: Int) -> Int {
        index / PopopxBlindWatermarkCodec.gridColumns
    }

    /// 屏幕位置 → 格子下标：`column(of:)` 的逆，取证端从照片上数出行列之后调它拿回比特位置。
    /// 这一对函数是水印唯一的几何契约，改动任意一条都必须同时改另一条。
    static func cellIndex(row: Int, column: Int) -> Int {
        let columns = PopopxBlindWatermarkCodec.gridColumns
        let unshifted = ((column - rowStagger * row) % columns + columns) % columns
        return row * columns + unshifted
    }

    /// 从照片上读回来的 1600 格（按**视觉**行列排布，行优先）→ 载荷。
    /// 与 `PopopxBlindWatermarkCodec.record(from:)` 的差别只是这里入参是屏幕上数到的格子，
    /// 而那里的入参是散布域的数组。
    static func record(visualCells: [Bool]) -> PopopxWatermarkBits? {
        let columns = PopopxBlindWatermarkCodec.gridColumns
        guard visualCells.count == columns * PopopxBlindWatermarkCodec.gridRows else { return nil }
        var scattered = [Bool](repeating: false, count: visualCells.count)
        // 入参下标 = 屏幕上数到的 (行, 列)；`cellIndex` 把它送回散布域的下标。
        // 方向不能反：`column(of:)` 是"下标→屏幕"，这里要的是"屏幕→下标"。
        for visualIndex in visualCells.indices {
            scattered[cellIndex(row: visualIndex / columns, column: visualIndex % columns)] = visualCells[visualIndex]
        }
        return PopopxBlindWatermarkCodec.record(from: scattered)
    }
}

// ================ POPUPX_PURE_CORE_END ================

// MARK: - 分时复用点阵覆盖层

/// 抗快门时分复用点阵覆盖层。`isEnabled` 为假时必须是真正的零开销（不建 ticker、不进绘制）。
struct PopopxAntiPhotoRenderView: View {
    private let isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    var body: some View {
        // `if` 而不是 `.opacity(0)`：关掉时这一支根本不存在 —— 不建驱动、不建 ticker、
        // 不进 tile 缓存、不参与一次绘制。用透明度或 `hidden()` 都还在布局与合成里付钱。
        Group {
            if isEnabled {
                PopopxRollingShutterLayer()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 真干活那一层。相位由驱动回调写进 `@State`，body 因此每帧重算一次 —— 重算的内容只是
/// 在两块已经缓存好的 `UIImage` 之间挑一个引用，没有分配、没有栅格化。
private struct PopopxRollingShutterLayer: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var driver: PopopxRollingShutterDriver?
    @State private var phase = 0

    var body: some View {
        Image(uiImage: PopopxShutterPatternAtlas.tile(forPhase: phase, displayScale: displayScale))
            .resizable(resizingMode: .tile)
            .opacity(PopopxShutterPatternAtlas.overlayOpacity)
            // 不加 `.drawingGroup()`：这一层本来就是一次 pattern 填充，套上它等于把整棵子树
            // 每帧光栅化到一张离屏 MTLTexture —— 我们要省的正是这个。要合并多层时再加，而这里没有。
            .onAppear { installDriver() }
            .onDisappear { removeDriver() }
            .onChange(of: reduceMotion) { _, _ in installDriver() }
            .onChange(of: displayScale) { _, _ in installDriver() }
    }

    private func installDriver() {
        if driver == nil {
            driver = PopopxRollingShutterDriver()
        }
        // `@State` 的 setter 是 nonmutating，所以这里从逃逸闭包里写 `phase` 不需要可变 self。
        driver?.onPhaseChange = { nextPhase in phase = nextPhase }
        driver?.start(alternating: reduceMotion == false)
    }

    private func removeDriver() {
        driver?.stop()
        driver = nil
        phase = 0
    }
}

/// 60Hz 相位驱动。`PopopxFrameTicker` 的唯一使用者，也是这层唯一会挂 CADisplayLink 的对象。
///
/// 主线程约定来自 `PopopxFrameTicker` 本身（它挂在主 runloop 上），所以这个类不加 `@MainActor`：
/// 加了只会让视图里那三个生命周期回调各自多一次跨 actor 跳转，而跳转的目的地还是同一条主线程。
private final class PopopxRollingShutterDriver {
    var onPhaseChange: ((Int) -> Void)?

    private let ticker = PopopxFrameTicker(framesPerSecond: 60)
    private var frameIndex = 0

    /// 幂等。`alternating == false`（Reduce Motion）时不启动 link，相位就停在 0：
    /// 空间混叠那条腿留着，时间那条腿放弃 —— 这条取舍是本文件里少数"安全性让位于无障碍"的地方。
    func start(alternating: Bool) {
        guard alternating else {
            stop()
            return
        }
        if ticker.isRunning == false {
            ticker.onFrame = { [weak self] _ in
                self?.advance()
            }
            ticker.start()
        }
    }

    func stop() {
        ticker.stop()
        onPhaseChange = nil
    }

    deinit {
        // 本类不是 actor 隔离的，所以 deinit 里可以直接收尾；`ticker.stop()` 会 invalidate link
        // 并断掉 onFrame，`link` 已经是 nil 时它是空操作，因此和 `stop()` 重复调用是安全的。
        ticker.stop()
    }

    private func advance() {
        // 只保留最低一位：两副 tile 就是两个相位，索引不需要（也不该）无限增长。
        frameIndex = (frameIndex + 1) & 1
        onPhaseChange?(frameIndex)
    }
}

/// 两副 tile 的缓存。生成一次，进程内复用。
enum PopopxShutterPatternAtlas {
    /// 覆盖层的不透明度。0.05 的取舍：再高就看得清是"雪花"、读长文累；再低就基本不影响照片。
    /// 这条曲线只能上机调，本文件给不出跨设备的安全值 —— 所以它是**参数**而不是常量。
    static let overlayOpacity: Double = 0.05

    /// key = 设备像素比（取整）；value = [相位 0, 相位 1]。两副一起生成，因此"只生成一次"
    /// 这件事由这个数组的形状保证，不依赖调用顺序。
    private static var cache: [Int: [UIImage]] = [:]

    static func tile(forPhase phase: Int, displayScale: CGFloat) -> UIImage {
        let steps = max(1, Int(displayScale.rounded()))
        if let built = cache[steps] {
            return built[phase & 1]
        }
        let built = (0 ... 1).map { rasterize(phase: $0, pixelRatio: steps) }
        // 上限：像素比只有 1/2/3 这几个现实取值，写死一条清理规则只是为了不让这个字典在
        // 一次极长的进程生命周期里跟着什么奇怪的东西增长。
        if cache.count > 4 {
            cache.removeAll()
        }
        cache[steps] = built
        return built[phase & 1]
    }

    private static func rasterize(phase: Int, pixelRatio: Int) -> UIImage {
        let edge = PopopxShutterPattern.tilePixels
        let plane = PopopxShutterPattern.grayPlane(phase: phase)
        guard let provider = CGDataProvider(data: Data(plane) as CFData),
              let image = CGImage(
                  width: edge,
                  height: edge,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: edge,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            // 造不出一块 8×8 灰度图 = CoreGraphics 这条路已经不通。返回空 image：覆盖层失效，
            // 正文一个字都不受影响。
            return UIImage()
        }
        // scale = 像素比 → tile 的 point 尺寸正好等于它的像素尺寸，平铺时 1 图像像素 = 1 设备像素。
        // 这一条不是审美问题：一旦不是 1:1，系统就会插值，而插值本身是一次低通 —— 我们要打的就是
        // 那个低通，先把自已的高频抹掉就等于自我缴械。
        return UIImage(cgImage: image, scale: CGFloat(pixelRatio), orientation: .up)
    }
}

// MARK: - 聚光灯阅读模式

/// 聚光灯阅读模式：默认全糊，手指按住处 `radius` 圆内清晰。
struct PopopxSpotlightTextView: View {
    private let text: String
    private let radius: CGFloat

    /// 模糊到这个半径，正文在 4pt 之外就一个字符都拼不出来了；再大对可读性没有额外好处，
    /// 只是多花 CoreImage 的模糊半径。
    private static let blurRadius: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spotlightCenter = CGPoint.zero
    @State private var isFingerDown = false

    init(text: String, radius: CGFloat = 45) {
        self.text = text
        self.radius = radius
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            textLayer
                .blur(radius: PopopxSpotlightTextView.blurRadius)
            textLayer
                .mask { spotlightWindow }
        }
        .contentShape(Rectangle())
        // `simultaneousGesture` 而不是 `gesture`：调用方很可能把这层放进 ScrollView（长正文），
        // 独占手势会把滚动吃掉；而聚光灯本来就不靠滑动前进，两者同时成立才对。
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    spotlightCenter = value.location
                    isFingerDown = true
                }
                .onEnded { _ in isFingerDown = false }
        )
        // 视觉上这块屏是一团糊，无障碍里它必须是整段正文：否则 VoiceOver 用户拿到的是一份
        // 被刻意毁掉的替代品。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// 清晰窗口。半径在抬手时回到 0 —— 半径为 0 的 mask 画不出任何东西，顶下的清晰副本因此
    /// 整块消失，屏幕上只剩糊的那一份（"restoring to full blur"就落在这里，不靠条件插入视图，
    /// 那样每次按压都会重建整棵文本子树）。
    ///
    /// 动画只挂在**半径**上、而且挂在 `.position` 之前：跟着手指走的位置必须是即时的，
    /// 给位置加弹簧就会出现"光圈比手指慢半拍"，那正是这个模式最刺眼的失败形状。
    /// Reduce Motion 把这一段动画整条拿掉（半径瞬开瞬合），点阵与模糊本身都不受影响。
    @ViewBuilder private var spotlightWindow: some View {
        let activeRadius = isFingerDown ? radius : 0
        Circle()
            .fill(
                RadialGradient(
                    colors: [.black, .black, .clear],
                    center: .center,
                    startRadius: activeRadius * 0.55,
                    endRadius: activeRadius
                )
            )
            .frame(width: activeRadius * 2, height: activeRadius * 2)
            .animation(PopopxMotion.animation(PopopxSpring.fluid, reduceMotion: reduceMotion), value: activeRadius)
            .position(spotlightCenter)
    }

    /// 两份**完全相同**的文本层。模糊底稿与清晰副本必须逐字重合，所以这个函数不许带任何
    /// 只在其中一路出现的修饰；两处调用的差别只由外层（`.blur` / `.mask`）决定。
    private var textLayer: some View {
        Text(text)
            .font(PopopxType.body)
            .foregroundStyle(PopopxPalette.label)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - 逐行阅读模式

/// 逐行防构图阅读模式：一次只显示一行，必须按住并纵向拖动才前进。
struct PopopxTeleprompterTextView: View {
    private let text: String
    private let lines: [String]

    /// 一格行进的拖动量。用 `minHitTarget` 这个 token 而不是拍一个数：44pt 是手指一次可靠做出的
    /// 最小位移，也是 HIG 里"一次意图明确的动作"的距离下限。
    private static let pointsPerLine: CGFloat = PopopxMetrics.minHitTarget

    @State private var committedLine = 0
    @GestureState private var dragTranslation: CGFloat = 0

    init(text: String) {
        self.text = text
        self.lines = PopopxReadingLines.lines(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            Text(currentLine)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                ProgressView(value: progressValue, total: 1)
                    .tint(PopopxPalette.brand)
                HStack {
                    Text(hintText)
                        .font(PopopxType.microTag)
                    Spacer(minLength: PopopxMetrics.spaceXS)
                    Text(positionText)
                        .font(PopopxType.metricSmall)
                }
                .foregroundStyle(PopopxPalette.labelHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { _ in
                    // 松手停在当前行：把手势期间算出来的位置固化下来，`@GestureState` 同时归零，
                    // 两者互相抵消 —— 所以既不回弹，也不额外跳一格。
                    committedLine = displayedIndex
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var currentLine: String {
        guard lines.isEmpty == false else { return text }
        return lines[displayedIndex]
    }

    /// 行号推进只由"按住 + 纵向拖动"决定，且对称：向上拖满一格进一步，向下拖满一格退一步，
    /// 半格都不算（`towardZero`），所以不存在"轻轻一碰就跳过一行"的误读。
    private var displayedIndex: Int {
        guard lines.isEmpty == false else { return 0 }
        let steps = Int((dragTranslation / Self.pointsPerLine).rounded(.towardZero))
        return min(max(committedLine - steps, 0), lines.count - 1)
    }

    private var progressValue: Double {
        guard lines.count > 1 else { return lines.isEmpty ? 0 : 1 }
        return Double(displayedIndex) / Double(lines.count - 1)
    }

    private var positionText: String {
        guard lines.isEmpty == false else { return "0 / 0" }
        return "\(displayedIndex + 1) / \(lines.count)"
    }

    /// 空正文时这句提示比"按住向上拖"更诚实：不是手势不管用，是这条消息本来就没有内容。
    private var hintText: String {
        lines.count > 1 ? NSLocalizedString("Hold and drag up · release stops at the current line", comment: "secure reading") : NSLocalizedString("This message has no more content", comment: "secure reading")
    }
}

// MARK: - 盲水印

/// 隐形盲水印：设备 UUID + 会话 id + 毫秒时间戳编成极低对比点阵铺满全屏。
///
/// 它是**表面**，不是叠加滤镜：每个格子都会被填上两种近黑色之一，所以它必须画在正文**底下**
/// （由窗口管理器/`PopopxSecureSheetView` 当作背景层用）。画在正文上面等于把整屏糊成近黑，
/// 这不是保守，这是把消息藏起来谁都看不见。
struct PopopxBlindWatermarkOverlay: View {
    private let matrix: PopopxWatermarkMatrix?

    init(sessionIdentifier: String) {
        self.matrix = PopopxBlindWatermarkCache.matrix(
            forSession: sessionIdentifier,
            deviceIdentifier: UIDevice.current.identifierForVendor?.uuidString
        )
    }

    var body: some View {
        Canvas { context, size in
            let columns = CGFloat(PopopxBlindWatermarkCodec.gridColumns)
            let rows = CGFloat(PopopxBlindWatermarkCodec.gridRows)
            let cellWidth = size.width / columns
            let cellHeight = size.height / rows
            // 整块底色 = 0 号颜色，一次填充；下面只补 1 号格子的位。
            // 底色**不依赖** matrix 是否存在：这一层的契约是"一块不透明的近黑表面"，
            // matrix 为 nil（载荷超容量，编码端的错）时应当退化成"没有水印的底色"，
            // 而不是退化成透明 —— 透明会让正文底下直接露出窗口背景，那是另一种更难发现的失效。
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(PopopxBlindWatermarkPalette.color(forRGB: PopopxBlindWatermarkCodec.rgb(isOn: false)))
            )
            guard let matrix else { return }
            for index in matrix.onCells {
                let rect = CGRect(
                    x: CGFloat(matrix.column(of: index)) * cellWidth,
                    y: CGFloat(matrix.row(of: index)) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                // 外扩半像素：Canvas 的填充是抗锯齿的，相邻格子之间会留下一条既不等于 0x010101
                // 也不等于 0x000000 的插值缝 —— 那会让"整幅点阵只用两种颜色"这条主张在像素层面
                // 不成立，也会给取证读数多一层噪声。同色重叠不改变颜色，只消掉这条缝。
                context.fill(
                    Path(rect.insetBy(dx: -0.5, dy: -0.5)),
                    with: .color(PopopxBlindWatermarkPalette.color(forRGB: PopopxBlindWatermarkCodec.rgb(isOn: true)))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 两种近黑色到 `Color` 的映射。集中一处，避免绘制端和文档里说的数字对不上。
enum PopopxBlindWatermarkPalette {
    static func color(forRGB rgb: UInt32) -> Color {
        Color.popopx(rgb)
    }
}

/// 会话 → 点阵的一次性缓存。存在的唯一理由是让时间戳**每个会话只取一次**：
/// 视图值会被父级反复重建（倒计时每秒一次），没有这层缓存就等于每秒换一套比特，
/// 屏幕上的格子会蠕动（肉眼可见，水印因此不再"隐形"），而解出来的时间戳也不再指向"这次查看"。
enum PopopxBlindWatermarkCache {
    private static var matrices: [String: PopopxWatermarkMatrix] = [:]

    static func matrix(forSession sessionIdentifier: String, deviceIdentifier: String?) -> PopopxWatermarkMatrix? {
        if let cached = matrices[sessionIdentifier] {
            return cached
        }
        let record = PopopxWatermarkBits(
            deviceIdentifier: deviceIdentifier ?? "",
            sessionIdentifier: sessionIdentifier,
            // 毫秒：这是水印里唯一"什么时候"的信息，也是事后归因时唯一能和服务器时间对表的量。
            epochMillis: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        guard let built = PopopxBlindWatermarkCodec.matrix(for: record) else { return nil }
        if matrices.count > 8 {
            matrices.removeAll()
        }
        matrices[sessionIdentifier] = built
        return built
    }
}

#if DEBUG
private struct PopopxAntiPhotoGallery: View {
    @State private var mode = PopopxSecureReadMode.spotlight
    @State private var overlayOn = true

    private let sample = """
    Shenzhen North Station · Platform 3 · the 18:42 service
    The contact is the one in the grey coat; he holds a sheet of paper and what you need is on it.
    Leave no copy of this text on any device, and do not forward it.
    """

    var body: some View {
        PopopxSheetContainer(NSLocalizedString("Anti-photo reading preview", comment: "secure reading preview"), subtitle: "PopopxAntiPhotoRenderView") {
            PopopxSectionCard(NSLocalizedString("Reading mode", comment: "secure reading preview"), footnote: mode.note) {
                PopopxSegmentedControl(
                    PopopxSecureReadMode.allCases.map { .init(selection: $0, title: $0.title) },
                    title: \.title,
                    selection: $mode
                )
                PopopxDividerRow()
                PopopxToggleRow(NSLocalizedString("Dot-matrix overlay", comment: "secure reading preview"), note: NSLocalizedString("When it is off, no ticker is created and nothing is drawn", comment: "secure reading preview"), isOn: $overlayOn)
            }
            PopopxSectionCard(NSLocalizedString("Message body", comment: "secure reading preview")) {
                ZStack {
                    PopopxBlindWatermarkOverlay(sessionIdentifier: "preview-session")
                    Group {
                        switch mode {
                        case .spotlight: PopopxSpotlightTextView(text: sample)
                        case .teleprompter: PopopxTeleprompterTextView(text: sample)
                        }
                    }
                    .frame(minHeight: 220, alignment: .topLeading)
                    PopopxAntiPhotoRenderView(isEnabled: overlayOn)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
            }
        }
        .background(PopopxPalette.base)
    }
}

private struct PopopxDividerRow: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

struct PopopxAntiPhotoGallery_Previews: PreviewProvider {
    static var previews: some View {
        PopopxAntiPhotoGallery()
    }
}
#endif
