//
//  PopopxLocation.swift
//  POPOPX (iOS)
//
//  「发送位置」的载荷层：一条位置消息在网络上就是下面 `wireString` 那一行文本。
//
//  这一层刻意不碰 MapKit，也不碰 CoreLocation：
//
//  1. 它要在发送（ComposeView）和渲染（PopopxMessageBubble）两端讲同一套字节，而这两端
//     谁都不需要地图能力，只需要两个 Double 和它们对外的文本形式。
//  2. `Map` / `CLLocationManager` 只会出现在 PopopxLocationPickerSheet.swift 一个文件里，
//     少一个 import 就少一处能被误用的入口。
//  3. 编解码是纯字符串算术，能脱离 UI 和系统框架单独验（macOS 上编译本文件跑的 31 项
//     往返/拒绝试验：中文、`&`、`#`、`=`、引号、空格、emoji、换行、长得像载荷的地名都
//     原样回来；邀请链接、越界/`nan`/`inf` 坐标、缺坐标、非法 UTF-8 转义、野 host 全部判死）。
//  4. 本文件在 `Shared/Features/ChatInfo/`，已人工拖入 `POPOPX (iOS)` target（`.pbxproj`
//     零脚本改动）。少拖一个，报错的是全工程，不会只报"少个文件"。
//  5. 命名空间：`popopx:/` 和 `popopx://` 是邀请链接的前缀（PopopxOfflineBridge.swift:91、
//     ChatUtils.swift:106、APITypes.swift:195），`popopx://loc?...` 因此**必须永远和邀请
//     链接互斥**——host 只认 `loc`，坐标必须有限且在量程内，任一条不满足就整串判死。
//     这是硬约束，不是风格问题：一个 `loc` 串被 `hasPopopxLink` 判成邀请链接，就会走建联，
//     把一条位置消息变成一次加好友。
//  6. 载荷是接收方会主动解析的输入，所以只走 `URLComponents`，不手工切字符串。
//  7. 显示文案和地图渲染在 PopopxMessageBubble.swift 的 `PopopxLocationCardBubble`，
//     选择器在 PopopxLocationPickerSheet.swift。
//

import Foundation

/// 一条位置消息的载荷。
///
/// 线上形态是两行文本，`messageContent` 发后者：
///
/// ```text
/// 📍 [位置] 深圳北站 (22.543096, 114.057865)
/// popopx://loc?lat=22.543096&lon=114.057865&name=%E6%B7%B1%E5%9C%B3%E5%8C%97%E7%AB%99
/// ```
///
/// 第一行给人看：接收方若不是 POPOPX（或这张卡还没渲染出来），看到的是一行读得懂的中文
/// 加一串坐标，而不是裸 scheme。
struct PopopxLocationPayload: Hashable, Sendable {
    /// 纬度，-90...90。
    var latitude: Double
    /// 经度，-180...180。
    var longitude: Double
    /// 地点名；缺省时界面用坐标本身当名字（`displayName`）。
    var name: String?
    /// 详细地址，只做展示，不参与任何决策。
    var address: String?

    init(
        latitude: Double,
        longitude: Double,
        name: String? = nil,
        address: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name?.popopxTrimmedOrNil
        self.address = address?.popopxTrimmedOrNil
    }

    /// 十进制度，6 位小数——约 0.11 m，比消费级 GPS 的精度还细，多写只是浪费字节。
    /// 纬度在前、经度在后，和 Apple 地图、CoreLocation 的顺序一致。
    var coordinateString: String {
        "(\(Self.degree(latitude)), \(Self.degree(longitude)))"
    }

    /// 没有地名时用坐标顶上，卡片永远有第一行可显示。
    var displayName: String {
        name ?? coordinateString
    }

    /// 缓存键用的稳定坐标形式（`PopopxLocationCardBubble` 的快照按它去重）。
    var coordinateKey: String {
        "\(Self.degree(latitude)),\(Self.degree(longitude))"
    }

    /// 机器读的那一行：`popopx://loc?lat=…&lon=…&name=…&addr=…`。
    ///
    /// 查询串手工拼而不是 `URLComponents.queryItems`：后者编码时把空格写成 `+` 还是 `%20`
    /// 取决于构造路径，这种差异会进到线上字节；这里的每一个值都必须显式走 `.alphanumerics`
    /// 白名单（它把空格、`&`、`#`、换行全部转义掉——实测输出见会话记录），解析端才能安全地
    /// 按空白切 token、按 `&` 切字段、按第一个 `=` 分键值。
    var wireString: String {
        var query = "lat=\(Self.degree(latitude))&lon=\(Self.degree(longitude))"
        if let name {
            query += "&name=\(name.popopxLocationEncoded)"
        }
        if let address {
            query += "&addr=\(address.popopxLocationEncoded)"
        }
        return "popopx://loc?\(query)"
    }

    /// 实际发出去的那条文本：可读的降级行 + 换行 + 机器行。
    ///
    /// 它是纯文本，所以天然满足 `PopopxComposerRouting` 的 mesh 前提（`hasAttachments
    /// == false`、无 `quotedItem`、TTL off、1:1 直聊）——位置消息在双模路由面前和一条普通
    /// 文本消息**完全同构**，不需要任何特判。
    var messageContent: String {
        degradeLine + "\n" + wireString
    }

    /// 单独那一行降级文本。
    ///
    /// 它必须正好是一行——`name` / `address` 在 `init` 里已经把空白收敛成单个空格，所以
    /// 来自 `CLPlacemark` 的换行（邮政地址里很常见）不会把这条消息撑成三行，接收方的
    /// 纯文本降级视图和 `PopopxLocationCardBubble` 的标题行拿到的永远是同一句完整的话。
    var degradeLine: String {
        "📍 [位置] \(displayName) \(coordinateString)"
    }

    /// 从任意文本里把一条 `popopx://loc` 载荷读出来；读不到就返回 nil，调用方
    /// （`PopopxBubbleMount`）把 nil 当"这不是位置消息"，交回原来的纯文本渲染。
    ///
    /// 输入是接收方主动送进解析器的东西，所以每一步都当它在试探边界：先按空白切出候选
    /// token（载荷里永远不会有空白），再逐段判 scheme / host / 键名 / 数值 / 量程。
    ///
    /// 非锚定的整串匹配是有意的：真机上一旦给载荷前后加了标点，位置卡片就会无声地退化成
    /// 一行纯文本，比抛错难查得多。宁可多认，也不放过。
    ///
    /// 命中多个候选时取**最后一个**，因为生产端把机器行拼在可读行之后——人读的那行里若
    /// 夹着一个长得像载荷的串（地名就叫 `popopx://loc?lat=0&lon=0`，或转发来的文本），
    /// 取第一个会让卡片的动作坐标和它自己印出来的坐标各行其是。实测过这条：取首个时
    /// `messageContent` 甚至回不到自己。
    static func parse(from text: String) -> PopopxLocationPayload? {
        for token in text.split(whereSeparator: \.isWhitespace).reversed() {
            if let payload = parseToken(String(token)) {
                return payload
            }
        }
        return nil
    }

    private static func parseToken(_ token: String) -> PopopxLocationPayload? {
        guard let components = URLComponents(string: token),
              components.scheme == "popopx",
              components.host == "loc"
        else { return nil }

        var fields: [String: String] = [:]
        // 必须是 `percentEncodedQuery`，不能用 `query`：后者返回的是**已解码**的查询串，
        // `name=a%26b` 到它手里先变成 `name=a&b`，再按 `&` 切就把地名截断成了 `a`（实测）。
        // 在编码形式上切分、再逐个值解码，`&` / `#` / `=` / 换行才回得来。
        for pair in components.percentEncodedQuery?.split(separator: "&") ?? [] {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            // 只认这四个键，其余（包括来历不明的野键）一律丢掉，不让一条字符串借着
            // 我们的 scheme 拿到界面。键名在这里按**编码原字节**比较，所以写成 `na%6De`
            // 这种绕过形式的键也一并落不进白名单。
            guard fieldNames.contains(key) else { continue }
            let rawValue = String(pair[pair.index(after: separator)...])
            // `URLComponents` 会把非法转义先修好（`name=%zz` 交出来的是 `%25zz`，读回字面量
            // `%zz`），所以这道 guard 挡的不是残缺的 `%`，而是**语法合法、字节不是 UTF-8**
            // 的序列（`%C0%80`、`%FF` 实测返回 nil）：那种 token 整串判死，不 fallback 到
            // 原串，也不让半个字段进来。
            guard let value = rawValue.removingPercentEncoding else { return nil }
            fields[key] = value
        }

        guard let rawLatitude = fields["lat"],
              let rawLongitude = fields["lon"],
              let latitude = Double(rawLatitude),
              let longitude = Double(rawLongitude),
              // `Double("inf")`、`Double("nan")`、`Double("1e9")` 都解析得成功，所以"能变成
              // 数"离"能当坐标"还差两步：先判有限，再判量程。
              latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude)
        else { return nil }

        return PopopxLocationPayload(
            latitude: latitude,
            longitude: longitude,
            name: fields["name"],
            address: fields["addr"]
        )
    }

    private static let fieldNames: Set<String> = ["lat", "lon", "name", "addr"]

    /// 定长坐标分量，`wireString`、`coordinateString`、`coordinateKey` 共用一处写法，
    /// 保证三者永远一致（`%.6f` 会把 89.9999999 进位成 `90.000000`，那是可接受的：
    /// 载荷的语义精度就是 6 位）。
    private static func degree(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

/// 定位那条链路上唯一会说清楚的失败原因：拿不到位置。渲染失败的提示文案由选择器
/// （`PopopxLocationPickerSheet.swift`）自己拼，这里不藏句子；界面上也从不显示枚举本身，
/// 所以成员只有语义、没有 `LocalizedError`。
enum PopopxLocationError: Error {
    /// 定位服务没开（`CLLocationManager.locationServicesEnabled()`）。
    case locationUnavailable
    /// 用户拒绝或尚未决定：只申请 When In Use，不追问 Always（`location-prompt.md:35`）。
    case permissionDenied
    /// 请求被取消，或 `CLLocationManager` 自己结束了更新。
    case cancelled
    /// 系统返回 `kCLErrorDenied`（地理围栏权限被拒）。
    case regionDenied
}

extension String {
    /// 载荷字段用的编码：只留字母数字，其余全转义。空格、`&`、`#`、换行因此不可能出现在
    /// 字段值里，`parse` 的"按空白切 token、按 `&` 切字段"才是安全的。
    fileprivate var popopxLocationEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }

    /// 空白串当 nil：一个只有空格的地名不如没有，界面上会显示成一行空白。
    ///
    /// 顺手把内部的空白串收敛成一个空格，于是 `name` / `address` 里不可能留换行，
    /// `degradeLine` 恒为一行（见上面那段）。
    fileprivate var popopxTrimmedOrNil: String? {
        let collapsed = self
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
