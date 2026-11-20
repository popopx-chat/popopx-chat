//
//  PopopxLocationPickerSheet.swift
//  POPOPX (iOS)
//
//  The "send location" picker: a pin fixed in the centre of the view, a draggable map, and a list of searched places.
//
//  This file does three things:
//
//  1. `PopopxLocationPickerModel` — permissions, positioning, reverse geocoding, search. The view only reads it.
//     `CLLocationManager` appears only in this file, so "ask for When In Use only, never Always"
//     (`location-prompt.md:35`) is therefore a rule you can grep for, not a verbal promise.
//  2. `PopopxLocationPickerSheet` — the layout. The map stage has a fixed height, search and the list take the remaining space,
//     and the send bar at the bottom does not participate in compression.
//  3. `PopopxLocationLookup` — brings the completion style of `CLGeocoder` / `MKLocalSearch` inside,
//     so the outside only sees async.
//
//  Four things that must be made clear up front:
//
//  1. **`PopopxSheetContainer` is not used**. It stuffs the whole content into a `ScrollView`
//     (`PopopxControls.swift:758-763`), and putting a draggable map into a vertical scroll container means two gestures fighting over
//     the same axis. This replicates its grabber, title bar, base colour and corner radius, replacing the middle with one non-scrolling gesture area.
//  2. **The pin is an overlay, not an annotation**. `camera`'s `region` is requested around `center`, so
//     "dead centre of the view = the selected coordinate" needs no `MKAnnotation` and no `MapProxy.convert`,
//     nor does picking a point have to bring in UIKit.
//  3. **Whether the camera was written by us or dragged by the user must be distinguishable** (`programmaticCenter` + 1e-6 degrees ≈ 0.1 m
//     tolerance). Without that distinction, the reverse geocode that fires after a POI is chosen and the map settles would wipe out the name just chosen.
//  4. **Location callbacks keep coming.** The first one decides the view; afterwards only the "current exact location" row updates — the camera being
//     snatched back while the user is dragging the map is the most common and most annoying failure of this kind of picker.
//

import CoreLocation
import MapKit
import SwiftUI

// MARK: - The selected place

/// The point the user selected on the page. Two things more than `PopopxLocationPayload`, meaningful only on this page:
/// The point the user selected on the page. One thing more than `PopopxLocationPayload`, meaningful only on this page:
/// accuracy — and it holds only while the pin still sits on the GPS point, which is the only time the model fills in `accuracyMeters`.
struct PopopxPickedLocation: Equatable {
    var latitude: Double
    var longitude: Double
    var name: String?
    var address: String?
    var accuracyMeters: Int?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The two lines of text handed to the send chain. When the place name is missing, `PopopxLocationPayload` falls back to the coordinate string itself,
    /// and nothing here invents an "unknown location" on its behalf.
    var payload: PopopxLocationPayload {
        PopopxLocationPayload(latitude: latitude, longitude: longitude, name: name, address: address)
    }
}

/// One row in the list: the current point from reverse geocoding, or a candidate point from a search.
struct PopopxNearbyPlace: Identifiable, Equatable {
    var title: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double

    var id: String { "\(latitude),\(longitude)|\(title)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The point the system tells us after the pin stops. The coordinate is brought in by the caller: `CLPlacemark` has no
    /// `coordinate` of its own (it sits on `CLLocation`, and the `location` returned by reverse geocoding is optional),
    /// and we were asking about one definite point anyway.
    ///
    /// When both `name` and `thoroughfare` are empty the row means nothing; returning nil keeps the UI showing coordinates instead of a blank row.
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

    /// One entry among the search results. An `MKMapItem` with neither a name nor a coordinate is dropped outright — a row in the list reading
    /// "(0.000000, 0.000000)" is worse than no results at all.
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
    /// Assembles a subtitle line from the administrative fields, dropping the part that repeats the place name.
    ///
    /// `CLPlacemark` has no ready-made full address line (`title` is on `MKAnnotation`, which it does not conform to),
    /// so it has to be assembled by hand: large to small, matching the reading order of Chinese addresses; postcode, province and country stay out of this line,
    /// because arranging to meet someone does not need them.
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

// MARK: - System queries

/// `CLGeocoder` / `MKLocalSearch` only come in completion form; wrapping a layer of async is the only way the outside can stay clean.
///
/// Neither throws an error at the interface: when nothing can be had, carry on with what the interface already shows (coordinates, empty results), because with location
/// it is mostly "the network is slow", not "the user did something wrong".
enum PopopxLocationLookup {
    static func place(at coordinate: CLLocationCoordinate2D) async -> PopopxNearbyPlace? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location) else { return nil }
        for placemark in placemarks {
            if let place = PopopxNearbyPlace(placemark: placemark, coordinate: coordinate) { return place }
        }
        return nil
    }

    /// Keyword search. `near` only narrows the results to the vicinity of the current view; it is not a hard filter — the system decides.
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

// MARK: - Location

/// A thin shell over `CLLocationManager`: the delegate callbacks moved onto three closures on the main actor.
///
/// A separate class, because `CLLocationManagerDelegate` methods cannot grow directly on an `@Observable` +
/// `@MainActor` model; this shell also closes "ask for When In Use only" into a single entry point.
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
        // Sending a location in chat wants "which intersection", not survey-grade accuracy: a hundred-metre band already places the pin correctly, and finer only burns battery.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// The only place in the whole project that requests location permission, and it always asks for When In Use only.
    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }

    func startUpdating() { manager.startUpdatingLocation() }

    func stopUpdating() { manager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let accuracy = location.horizontalAccuracy
        // A negative number = this fix failed (indoors, cold start); using it to display "accuracy ±-1m" is just looking for a bug.
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

// MARK: - State

@MainActor
@Observable
final class PopopxLocationPickerModel {
    enum Stage: Equatable {
        case idle
        case locating
        case ready
        /// Permission denied or restricted: the map area is replaced by a guidance card.
        case denied
        /// The system location service is off entirely, so there is not even a dialog to show.
        case unavailable
    }

    private(set) var stage: Stage = .idle
    /// No `private(set)`: `Map(position:)` wants a writable binding. The real source of the centre point is
    /// `onMapCameraChange` (`cameraChanged`); this is merely borrowed by it to serve as the binding.
    var camera: MapCameraPosition = .automatic
    private(set) var center: CLLocationCoordinate2D?
    private(set) var accuracyMeters: Int?
    private(set) var isPanning = false
    private(set) var failure: PopopxLocationError?
    private(set) var results: [PopopxNearbyPlace] = []
    private(set) var isSearching = false

    /// The search field. The view binds it directly with `$model.query` — everything else is `private(set)`.
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

    /// The point the pin currently points at. Coordinate, place name and accuracy have to be stated together; passing them apart to someone else will sooner or later mismatch —
    /// especially "accuracy": it holds only while the pin still sits on the GPS point.
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

    /// The point used by the "send my exact current location" row: the map does not move, the newest GPS point in hand is handed straight over.
    ///
    /// Once the pin has been dragged away this row carries no place name — that is another place's name, and sticking it onto a GPS point would lie.
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

    /// The payload handed to the send chain; while nothing is fixed yet there is nothing to send, so the send button is greyed out.
    var payload: PopopxLocationPayload? { selection?.payload }

    private var onCurrentFix: Bool {
        guard let center, let fix = currentFix else { return false }
        return Self.nearlyEqual(center, fix)
    }

    // MARK: Lifecycle

    func start() {
        guard stage == .idle else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            stage = .unavailable
            failure = .locationUnavailable
            return
        }
        apply(status: tracker.authorizationStatus)
    }

    /// Closing the page must reach here: if location never stops, the battery cost keeps being charged to this session.
    func stop() {
        settleTask?.cancel()
        labelTask?.cancel()
        tracker.stopUpdating()
    }

    private func apply(status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // `.authorizedAlways` was granted by the user elsewhere; this page never asks for it, so using it as granted is enough.
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
        // Later fixes only move the "current exact location" row; they do not snatch away the view the user is looking at.
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

    // MARK: Camera

    /// Every frame of `onMapCameraChange(frequency: .continuous)` comes in here.
    func cameraChanged(to center: CLLocationCoordinate2D) {
        if let target = programmaticCenter {
            programmaticCenter = nil
            // It is the camera we wrote ourselves and the map is settling back to the origin: do not wipe out the place name just chosen.
            if Self.nearlyEqual(center, target) { return }
        }
        isPanning = true
        setCenter(center, name: nil, address: nil, span: nil)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // Ask for the address only after it settles: hitting `CLGeocoder` on every frame of a continuous drag has no benefit beyond
            // setting off the system's rate limit.
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

    /// Search is called in after the view's `.task(id: model.query)` debounce.
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

    /// The first fix gives a region just large enough for the accuracy circle, and later fixes do not change it — every time the view rescales itself,
    /// the map looks as though it were breathing.
    private static func span(forAccuracy meters: Int?) -> MKCoordinateSpan {
        let width = Double(meters ?? 30) * 3.0 / 111_320.0
        let delta = min(max(width, 0.002), 0.02)
        return MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
    }

    /// 1e-6 degrees ≈ 0.1 m. This tolerance is what separates a programmatically written camera from the user's drag.
    static func nearlyEqual(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000001 && abs(lhs.longitude - rhs.longitude) < 0.000001
    }
}

// MARK: - Copy

enum PopopxLocationPickerCopy {
    static let title = NSLocalizedString("Location", comment: "")
    static let subtitle = NSLocalizedString("Drag the map to fine-tune, or search a place directly", comment: "")
    static let recenter = NSLocalizedString("Recenter on current location", comment: "")
    static let search = NSLocalizedString("Search places", comment: "")
    static let searchPrompt = NSLocalizedString("Street, landmark, or shop", comment: "")
    static let exact = NSLocalizedString("Send current precise location", comment: "")
    static let searching = NSLocalizedString("Searching…", comment: "")
    static let empty = NSLocalizedString("No matching places.", comment: "")
    static let send = NSLocalizedString("Send location", comment: "")
    static let pin = NSLocalizedString("Selected location", comment: "")
    static let deniedTitle = NSLocalizedString("No location permission", comment: "")
    static let openSettings = NSLocalizedString("Open System Settings", comment: "")

    static func accuracy(_ meters: Int) -> String { String(format: NSLocalizedString("Accuracy ±%lld m", comment: ""), meters) }

    static func hint(_ stage: PopopxLocationPickerModel.Stage) -> String? {
        switch stage {
        case .locating: NSLocalizedString("Getting your current location…", comment: "")
        case .denied: NSLocalizedString("Location access is denied. You can turn it on in System Settings.", comment: "")
        case .unavailable: NSLocalizedString("Location services are off on this device. Turn them on to send a location.", comment: "")
        case .idle, .ready: nil
        }
    }
}

// MARK: - Picker

struct PopopxLocationPickerSheet: View {
    /// Handing the payload to the host: who sends it and over which channel is ComposeView's business, and nothing here knows it.
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

    // MARK: Map stage

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
                // Before the first fix the map is a plain default region, so "still looking" has to be said clearly, otherwise the user thinks it is already fixed.
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

    /// The centre pin: the pin tip sits in the exact centre of the view, which is to say on `model.center`.
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

    // MARK: Search and list

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

    // MARK: Send bar

    private var footer: some View {
        VStack(spacing: PopopxMetrics.spaceXS) {
            if let payload = model.payload {
                // Before sending, read back what will actually go out: the place name may not have resolved, in which case the coordinates must be visible.
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

// MARK: - Search debounce

private extension View {
    /// Query only 280 ms after typing stops: `MKLocalSearch` firing a request per keystroke means an earlier result overwrites
    /// a later one, and the user sees in the list what they typed three letters ago.
    func searchableText(_ text: Binding<String>, search: @escaping () async -> Void) -> some View {
        task(id: text.wrappedValue) {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await search()
        }
    }
}

// MARK: - Previews

#if DEBUG
struct PopopxLocationPickerSheet_Previews: PreviewProvider {
    static var previews: some View {
        PopopxLocationPickerSheet { _ in }
            .padding(.horizontal, PopopxMetrics.space2XS)
    }
}
#endif
