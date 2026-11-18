//
//  PopopxLocationPickerSheet.swift
//  POPOPX (iOS)
//
//  「发送位置」的选择器：一枚定在画面中央的针、一片可以拖的地图、一串搜出来的地点。
//
//  这个文件干三件事：
//
//  1. `PopopxLocationPickerModel` —— 权限、定位、反向地理编码、搜索。视图只读它。
//     `CLLocationManager` 只出现在这个文件里，"只申请 When In Use、永不申请 Always"
//     （`location-prompt.md:35`）因此是一条 grep 得着的规则，而不是一句口头承诺。
//  2. `PopopxLocationPickerSheet` —— 版式。地图舞台高度固定，搜索与列表吃掉剩下的空间，
//     底部发送栏不参与压缩。
//  3. `PopopxLocationLookup` —— 把 `CLGeocoder` / `MKLocalSearch` 的 completion 形态收进来，
//     外面只看见 async。
//
//  四件必须先说清的事：
//
//  1. **没有用 `PopopxSheetContainer`**。它把 content 整个塞进 `ScrollView`
//     （`PopopxControls.swift:758-763`），而一张可拖的地图放进竖向滚动容器里，两个手势会抢
//     同一根轴。这里复刻了它的把手、标题栏、底色和圆角，中间换成一整块不滚动的手势区。
//  2. **图针是浮层，不是 annotation**。`camera` 的 `region` 是绕着 `center` 要的，所以
//     "画面正中央 = 已选坐标"这一步不需要 `MKAnnotation`、不需要 `MapProxy.convert`，
//     也不需要为选点引入 UIKit。
//  3. **相机是自己写的还是用户拖的，必须分得清**（`programmaticCenter` + 1e-6 度 ≈ 0.1 m
//     的容差）。分不清，选中一个 POI、地图停稳之后那一次反向地理编码会把刚选好的地名冲掉。
//  4. **定位回调会一直来**。第一次决定画面，之后只更新"当前精确位置"那一行——用户正在拖
//     地图时镜头被抢回去，是这类选择器最常见也最讨厌的失败。
//

import CoreLocation
import MapKit
import SwiftUI

// MARK: - 选中的地点

/// 用户在页面上选定了一个点。比 `PopopxLocationPayload` 多两样只在这一页有意义的东西：
/// 用户在页面上选定了一个点。比 `PopopxLocationPayload` 多一样只在这一页有意义的东西：
/// 精度——而且只有针还停在 GPS 点上时它才成立，那时模型才会把 `accuracyMeters` 填进来。
struct PopopxPickedLocation: Equatable {
    var latitude: Double
    var longitude: Double
    var name: String?
    var address: String?
    var accuracyMeters: Int?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 交给发送链路的那两行文本。地名缺失时 `PopopxLocationPayload` 自己退回坐标串，
    /// 这里不替它编一个"未知位置"。
    var payload: PopopxLocationPayload {
        PopopxLocationPayload(latitude: latitude, longitude: longitude, name: name, address: address)
    }
}

/// 列表里的一行：反向地理编码得到的当前点，或一次搜索得到的候选点。
struct PopopxNearbyPlace: Identifiable, Equatable {
    var title: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double

    var id: String { "\(latitude),\(longitude)|\(title)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 针停下后系统告诉我们的那个点。坐标由调用方带进来：`CLPlacemark` 自己没有
    /// `coordinate`（它在 `CLLocation` 上，而反向地理编码回来的 `location` 可空），
    /// 而我们本来就在问一个确定的点。
    ///
    /// `name` 和 `thoroughfare` 都空时这一行没有意义，判 nil 让界面继续显示坐标，不显示空白行。
    init?(placemark: CLPlacemark, coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let title = [placemark.name, placemark.thoroughfare, placemark.locality]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let title else { return nil }
        self.title = title
        subtitle = placemark.popopxAddress(excluding: title)
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    /// 搜索结果里的一条。没有名字也没有坐标的 `MKMapItem` 直接丢掉——列表里出现一行
    /// "(0.000000, 0.000000)" 比搜不到更糟。
    init?(mapItem: MKMapItem) {
        let coordinate = mapItem.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let title = [mapItem.name, mapItem.placemark.name, mapItem.placemark.thoroughfare]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let title else { return nil }
        self.title = title
        subtitle = mapItem.placemark.popopxAddress(excluding: title)
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

private extension CLPlacemark {
    /// 由行政区字段拼一行副标题，去掉和地名重复的那一段。
    ///
    /// `CLPlacemark` 没有现成的整行地址（`title` 在 `MKAnnotation` 上，而它不遵守那个协议），
    /// 所以只能自己拼：从大到小，和中国地址的阅读顺序一致；邮编、省、国家不进这一行，
    /// 约个人用不上。
    func popopxAddress(excluding name: String?) -> String? {
        let candidates = [subAdministrativeArea, locality, subLocality, thoroughfare]
        var parts: [String] = []
        for case let piece0? in candidates {
            let piece = piece0.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty, piece != name, !parts.contains(piece) else { continue }
            parts.append(piece)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - 系统查询

/// `CLGeocoder` / `MKLocalSearch` 只有 completion 形态；包一层 async 是外面能干净的唯一办法。
///
/// 两者都不抛错给界面：拿不到就用界面上已有的东西（坐标、空白结果）继续走，位置这件事
/// 大部分时候是"网络慢"，不是"用户做错了什么"。
enum PopopxLocationLookup {
    static func place(at coordinate: CLLocationCoordinate2D) async -> PopopxNearbyPlace? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location) else { return nil }
        for placemark in placemarks {
            if let place = PopopxNearbyPlace(placemark: placemark, coordinate: coordinate) { return place }
        }
        return nil
    }

    /// 关键词搜索。`near` 只是把结果收窄到当前视野附近，不是硬过滤——系统说了算。
    static func search(_ query: String, near coordinate: CLLocationCoordinate2D?) async -> [PopopxNearbyPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            )
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.compactMap(PopopxNearbyPlace.init(mapItem:))
    }
}

// MARK: - 定位

/// `CLLocationManager` 的薄壳：delegate 回调搬到主 actor 上的三个闭包。
///
/// 单独一个类，是因为 `CLLocationManagerDelegate` 的方法不能直接长在 `@Observable` +
/// `@MainActor` 的模型上；这层壳同时把"只问 When In Use"收在一个入口。
final class PopopxLocationTracker: NSObject, CLLocationManagerDelegate {
    struct Update {
        var coordinate: CLLocationCoordinate2D
        var accuracyMeters: Int
    }

    var onUpdate: ((Update) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onFailure: ((PopopxLocationError) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // 聊天里发位置要的是"哪个路口"，不是测绘级精度：百米档已经够把针放对，再细只是耗电。
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// 全工程唯一一次申请位置权限的地方，且永远只问 When In Use。
    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }

    func startUpdating() { manager.startUpdatingLocation() }

    func stopUpdating() { manager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let accuracy = location.horizontalAccuracy
        // 负数 = 这次定不上（室内、冷启动），拿它去显示"精度 ±-1m"是给自己找 bug。
        guard accuracy.isFinite, accuracy >= 0 else { return }
        onUpdate?(Update(coordinate: location.coordinate, accuracyMeters: Int(accuracy.rounded())))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code == .denied else { return }
        onFailure?(.regionDenied)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}

// MARK: - 状态

@MainActor
@Observable
final class PopopxLocationPickerModel {
    enum Stage: Equatable {
        case idle
        case locating
        case ready
        /// 权限被拒或被限制：地图区换成一张引导卡片。
        case denied
        /// 系统定位服务整体关着，弹窗都没得弹。
        case unavailable
    }

    private(set) var stage: Stage = .idle
    /// 不做 `private(set)`：`Map(position:)` 要的是一个可写绑定。中心点的真正来源是
    /// `onMapCameraChange`（`cameraChanged`），这里只是被它借去当绑定用。
    var camera: MapCameraPosition = .automatic
    private(set) var center: CLLocationCoordinate2D?
    private(set) var accuracyMeters: Int?
    private(set) var isPanning = false
    private(set) var failure: PopopxLocationError?
    private(set) var results: [PopopxNearbyPlace] = []
    private(set) var isSearching = false

    /// 搜索框。视图直接用 `$model.query` 绑它——其余全是 `private(set)`。
    var query = ""

    private let tracker = PopopxLocationTracker()
    private var placeName: String?
    private var placeAddress: String?
    private var currentFix: CLLocationCoordinate2D?
    private var programmaticCenter: CLLocationCoordinate2D?
    private var settleTask: Task<Void, Never>?
    private var labelTask: Task<Void, Never>?

    init() {
        tracker.onUpdate = { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        tracker.onAuthorizationChange = { [weak self] status in
            Task { @MainActor in self?.apply(status: status) }
        }
        tracker.onFailure = { [weak self] error in
            Task { @MainActor in self?.apply(error: error) }
        }
    }

    /// 针当前指向的点。坐标、地名、精度三样必须一起说，拆开传给别人早晚对不上——
    /// 尤其是"精度"：只有针还停在 GPS 点上时它才成立。
    var selection: PopopxPickedLocation? {
        guard let center else { return nil }
        let onFix = onCurrentFix
        return PopopxPickedLocation(
            latitude: center.latitude,
            longitude: center.longitude,
            name: placeName,
            address: placeAddress,
            accuracyMeters: onFix ? accuracyMeters : nil
        )
    }

    /// 「发送当前精确位置」那一行用的点：地图不动，直接把手里最新的 GPS 点交出去。
    ///
    /// 针被拖走之后这一行不带地名——那是别的地点的名字，贴在一个 GPS 点上会撒谎。
    var exactLocation: PopopxPickedLocation? {
        guard let fix = currentFix else { return nil }
        return PopopxPickedLocation(
            latitude: fix.latitude,
            longitude: fix.longitude,
            name: onCurrentFix ? placeName : nil,
            address: onCurrentFix ? placeAddress : nil,
            accuracyMeters: accuracyMeters
        )
    }

    /// 交给发送链路的载荷；还没定上位就没有可发的东西，发送按钮因此是灰的。
    var payload: PopopxLocationPayload? { selection?.payload }

    private var onCurrentFix: Bool {
        guard let center, let fix = currentFix else { return false }
        return Self.nearlyEqual(center, fix)
    }

    // MARK: 生命周期

    func start() {
        guard stage == .idle else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            stage = .unavailable
            failure = .locationUnavailable
            return
        }
        apply(status: tracker.authorizationStatus)
    }

    /// 页面关掉时必须走到这里：定位不停，耗电就一直算在这条会话上。
    func stop() {
        settleTask?.cancel()
        labelTask?.cancel()
        tracker.stopUpdating()
    }

    private func apply(status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // `.authorizedAlways` 是用户在别处给过的，本页面从不主动追问，照单用即可。
            if stage != .ready { stage = .locating }
            failure = nil
            tracker.startUpdating()
        case .notDetermined:
            stage = .locating
            tracker.requestWhenInUse()
        case .denied, .restricted:
            tracker.stopUpdating()
            stage = .denied
            failure = .permissionDenied
        @unknown default:
            tracker.stopUpdating()
            stage = .denied
            failure = .permissionDenied
        }
    }

    private func apply(_ update: PopopxLocationTracker.Update) {
        stage = .ready
        failure = nil
        accuracyMeters = update.accuracyMeters
        let fix = update.coordinate
        let isFirstFix = currentFix == nil
        currentFix = fix
        // 之后的定位只挪"当前精确位置"那一行，不去抢用户正在看的画面。
        guard isFirstFix || center == nil else { return }
        setCenter(fix, name: nil, address: nil, span: Self.span(forAccuracy: update.accuracyMeters))
        refreshLabel()
    }

    private func apply(error: PopopxLocationError) {
        guard error == .regionDenied else { return }
        tracker.stopUpdating()
        stage = .denied
        failure = .permissionDenied
    }

    // MARK: 画面

    /// `onMapCameraChange(frequency: .continuous)` 的每一帧都会进来。
    func cameraChanged(to center: CLLocationCoordinate2D) {
        if let target = programmaticCenter {
            programmaticCenter = nil
            // 是我们自己写的相机，地图停回原点：不要把刚选好的地名冲掉。
            if Self.nearlyEqual(center, target) { return }
        }
        isPanning = true
        setCenter(center, name: nil, address: nil, span: nil)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // 停稳之后再问地址：连续拖动的每一帧都打一次 `CLGeocoder`，除了把系统限流撞响
            // 之外没有别的好处。
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, !Task.isCancelled else { return }
            self.isPanning = false
            self.refreshLabel()
        }
    }

    func select(_ place: PopopxNearbyPlace) {
        PopopxHaptics.selection()
        setCenter(
            place.coordinate,
            name: place.title,
            address: place.subtitle,
            span: Self.focusSpan
        )
        settleTask?.cancel()
        isPanning = false
    }

    func recenter() {
        guard let fix = currentFix else {
            PopopxHaptics.notice(.warning)
            return
        }
        PopopxHaptics.impact(.light)
        setCenter(fix, name: nil, address: nil, span: Self.span(forAccuracy: accuracyMeters))
        refreshLabel()
    }

    func isSelected(_ place: PopopxNearbyPlace) -> Bool {
        guard let center else { return false }
        return Self.nearlyEqual(center, place.coordinate)
    }

    /// 搜索由视图的 `.task(id: model.query)` 防抖后调进来。
    func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        defer { isSearching = false }
        let found = await PopopxLocationLookup.search(text, near: center)
        guard !Task.isCancelled else { return }
        results = found
    }

    private func setCenter(
        _ center: CLLocationCoordinate2D,
        name: String?,
        address: String?,
        span: MKCoordinateSpan?
    ) {
        self.center = center
        placeName = name
        placeAddress = address
        guard let span else { return }
        programmaticCenter = center
        camera = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func refreshLabel() {
        guard let center else { return }
        labelTask?.cancel()
        labelTask = Task { [weak self] in
            guard let found = await PopopxLocationLookup.place(at: center) else { return }
            guard let self, !Task.isCancelled, let current = self.center,
                  Self.nearlyEqual(current, center) else { return }
            self.placeName = found.title
            self.placeAddress = found.subtitle
        }
    }

    private static let focusSpan = MKCoordinateSpan(latitudeDelta: 0.0025, longitudeDelta: 0.0025)

    /// 首次定位给一个刚好装下精度圈的视野，之后不随定位变化——画面每次自己改比例，
    /// 看起来就像地图在呼吸。
    private static func span(forAccuracy meters: Int?) -> MKCoordinateSpan {
        let width = Double(meters ?? 30) * 3.0 / 111_320.0
        let delta = min(max(width, 0.002), 0.02)
        return MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
    }

    /// 1e-6 度 ≈ 0.1 m。程序写的相机和用户手里的拖动，就靠这个容差分开。
    static func nearlyEqual(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000001 && abs(lhs.longitude - rhs.longitude) < 0.000001
    }
}

// MARK: - 文案

enum PopopxLocationPickerCopy {
    static let title = "位置"
    static let subtitle = "拖动画布微调，或直接搜索一个地点"
    static let recenter = "回到当前位置"
    static let search = "搜索地点"
    static let searchPrompt = "街道、地标或商铺"
    static let exact = "发送当前精确位置"
    static let searching = "搜索中…"
    static let empty = "没有匹配的地点。"
    static let send = "发送位置"
    static let pin = "已选位置"
    static let deniedTitle = "没有位置权限"
    static let openSettings = "打开系统设置"

    static func accuracy(_ meters: Int) -> String { "精度 ±\(meters)m" }

    static func hint(_ stage: PopopxLocationPickerModel.Stage) -> String? {
        switch stage {
        case .locating: "正在获取当前位置…"
        case .denied: "位置权限被拒绝，可在系统设置里打开。"
        case .unavailable: "系统定位服务已关闭，打开后才能发送位置。"
        case .idle, .ready: nil
        }
    }
}

// MARK: - 选择器

struct PopopxLocationPickerSheet: View {
    /// 把载荷交给宿主：谁来发、走哪条通道，是 ComposeView 的事，这里一概不知。
    var onSend: (PopopxLocationPayload) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = PopopxLocationPickerModel()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            handle
            titleBar
            mapStage
                .frame(height: 232)
                .padding(.horizontal, PopopxMetrics.gutter)
            places
            footer
        }
        .background(PopopxPalette.cardHigh)
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusSheet, style: .continuous))
        .task { model.start() }
        .onDisappear { model.stop() }
        .searchableText($model.query) { await model.runSearch() }
    }

    private var handle: some View {
        Capsule()
            .fill(PopopxPalette.separator)
            .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.space2XS)
            .padding(.top, PopopxMetrics.spaceXS)
    }

    private var titleBar: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
            Text(PopopxLocationPickerCopy.title)
                .font(PopopxType.title)
                .foregroundStyle(PopopxPalette.label)
            Text(PopopxLocationPickerCopy.subtitle)
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.vertical, PopopxMetrics.spaceS)
    }

    // MARK: 地图舞台

    @ViewBuilder
    private var mapStage: some View {
        if model.stage == .denied || model.stage == .unavailable {
            PopopxSectionCard(PopopxLocationPickerCopy.deniedTitle) {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                    Text(PopopxLocationPickerCopy.hint(model.stage) ?? "")
                        .font(PopopxType.secondary)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PopopxButton(
                        PopopxLocationPickerCopy.openSettings,
                        systemImage: "gearshape",
                        role: .secondary,
                        fullWidth: false
                    ) {
                        PopopxLocationPickerSheet.openSettings()
                    }
                }
            }
        } else {
            stage
        }
    }

    private var stage: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $model.camera, interactionModes: .all) {
                UserAnnotation()
            }
            .mapControlVisibility(.hidden)
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .continuous) { (context: MapCameraUpdateContext) in
                model.cameraChanged(to: context.region.center)
            }

            pin
                .allowsHitTesting(false)

            recenter
        }
        .overlay {
            if model.stage == .locating {
                // 第一次定位之前地图是一片默认视野，得说清楚"还在找"，不然用户以为已经定上了。
                PopopxPalette.base
                    .opacity(0.55)
                    .overlay(alignment: .center) {
                        Label(PopopxLocationPickerCopy.hint(model.stage) ?? "", systemImage: "location.viewrange")
                            .font(PopopxType.meta)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .padding(PopopxMetrics.spaceXS)
                            .background(PopopxMaterial.chip, in: .rect(cornerRadius: PopopxMetrics.radiusChip))
                    }
                    .transition(.opacity)
            }
        }
        .clipShape(.rect(cornerRadius: PopopxMetrics.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopopxMetrics.radiusCard)
                .strokeBorder(PopopxPalette.hairlineInner, lineWidth: PopopxMetrics.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PopopxLocationPickerCopy.pin)
    }

    /// 中心针：针尖压在画面正中，也就是压在 `model.center` 上。
    private var pin: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 34))
            .foregroundStyle(PopopxPalette.brand)
            .background(
                Circle()
                    .fill(PopopxPalette.onBrand)
                    .frame(width: 18, height: 18)
                    .offset(y: 12)
            )
            .scaleEffect(model.isPanning ? 1.12 : 1, anchor: .bottom)
            .offset(y: -17)
            .popopxAnimation(PopopxSpring.snappy, value: model.isPanning, reduceMotion: reduceMotion)
            .accessibilityHidden(true)
    }

    private var recenter: some View {
        Button(action: { model.recenter() }) {
            Image(systemName: "location.fill")
                .font(PopopxType.meta)
                .foregroundStyle(PopopxPalette.onBrand)
                .frame(width: PopopxMetrics.minHitTarget, height: PopopxMetrics.minHitTarget)
                .background(PopopxPalette.brand, in: .circle)
        }
        .buttonStyle(.plain)
        .padding(PopopxMetrics.spaceXS)
        .accessibilityLabel(PopopxLocationPickerCopy.recenter)
    }

    // MARK: 搜索与列表

    private var places: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopopxTextField(
                PopopxLocationPickerCopy.search,
                prompt: PopopxLocationPickerCopy.searchPrompt,
                text: $model.query,
                systemImage: "magnifyingglass",
                keyboard: .webSearch
            )
            .padding(.horizontal, PopopxMetrics.gutter)
            .padding(.top, PopopxMetrics.spaceS)

            List {
                if let exact = model.exactLocation {
                    exactRow(exact)
                }
                if model.isSearching {
                    Text(PopopxLocationPickerCopy.searching)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .listRowSeparator(.hidden)
                } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty, model.results.isEmpty {
                    Text(PopopxLocationPickerCopy.empty)
                        .font(PopopxType.meta)
                        .foregroundStyle(PopopxPalette.labelSecondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(model.results) { place in
                        placeRow(place)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
    }

    private func exactRow(_ exact: PopopxPickedLocation) -> some View {
        Button(action: { send(exact.payload) }) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                Image(systemName: "location.circle.fill")
                    .font(PopopxType.title)
                    .foregroundStyle(PopopxPalette.brand)
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(PopopxLocationPickerCopy.exact)
                        .font(PopopxType.emphasis)
                        .foregroundStyle(PopopxPalette.label)
                    HStack(spacing: PopopxMetrics.space2XS) {
                        Text(exact.payload.coordinateString)
                        if let meters = exact.accuracyMeters {
                            Text("·")
                            Text(PopopxLocationPickerCopy.accuracy(meters))
                        }
                    }
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                Image(systemName: "paperplane.fill")
                    .font(PopopxType.meta)
                    .foregroundStyle(PopopxPalette.brand)
            }
            .contentShape(.rect)
            .frame(minHeight: PopopxMetrics.minHitTarget)
        }
        .buttonStyle(.plain)
        .listRowBackground(PopopxPalette.card)
        .listRowSeparatorTint(PopopxPalette.separator)
    }

    private func placeRow(_ place: PopopxNearbyPlace) -> some View {
        Button(action: { model.select(place) }) {
            HStack(alignment: .firstTextBaseline, spacing: PopopxMetrics.spaceXS) {
                VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                    Text(place.title)
                        .font(PopopxType.body)
                        .foregroundStyle(PopopxPalette.label)
                        .lineLimit(1)
                    if let subtitle = place.subtitle {
                        Text(subtitle)
                            .font(PopopxType.caption)
                            .foregroundStyle(PopopxPalette.labelSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: PopopxMetrics.spaceXS)
                Image(systemName: model.isSelected(place) ? "checkmark.circle.fill" : "circle")
                    .font(PopopxType.meta)
                    .foregroundStyle(model.isSelected(place) ? PopopxPalette.brand : PopopxPalette.separator)
                    .symbolVariant(.none)
                    .popopxAnimation(PopopxSpring.snappy, value: model.isSelected(place), reduceMotion: reduceMotion)
            }
            .contentShape(.rect)
            .frame(minHeight: PopopxMetrics.minHitTarget)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.isSelected(place) ? [.isButton, .isSelected] : .isButton)
        .listRowSeparatorTint(PopopxPalette.separator)
    }

    // MARK: 发送栏

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if let payload = model.payload {
                // 发送前把最终要发出去的东西念一遍：地名可能没解析出来，那就必须看得见坐标。
                Text(payload.displayName)
                    .font(PopopxType.microTag)
                    .foregroundStyle(PopopxPalette.labelHint)
                    .lineLimit(1)
            }
            PopopxButton(PopopxLocationPickerCopy.send, systemImage: "paperplane.fill") {
                if let payload = model.payload { send(payload) }
            }
            .environment(\.isEnabled, model.payload != nil)
        }
        .padding(.horizontal, PopopxMetrics.gutter)
        .padding(.top, PopopxMetrics.spaceS)
        .padding(.bottom, PopopxMetrics.spaceS)
        .background(PopopxMaterial.bar)
    }

    private func send(_ payload: PopopxLocationPayload) {
        model.stop()
        onSend(payload)
    }

    private static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 搜索防抖

private extension View {
    /// 输入停下 280 ms 再查：`MKLocalSearch` 每敲一个字发一次请求，前一次的结果会盖掉
    /// 后一次，用户在列表里看到的是自己三个字母之前的输入。
    func searchableText(_ text: Binding<String>, search: @escaping () async -> Void) -> some View {
        task(id: text.wrappedValue) {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await search()
        }
    }
}

// MARK: - 预览

#if DEBUG
#Preview("位置选择器") {
    PopopxLocationPickerSheet { _ in }
        .padding(.horizontal, PopopxMetrics.space2XS)
}
#endif
