//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
// POPOPX Local Media & File Compression Engine
//
// Fully local, zero-server compression for outgoing attachments and silent
// unpacking of the document container on the receiving side. Every entry point
// takes a file URL that already lives in the app sandbox and returns a new file
// URL, so the caller decides when the result is handed to the core for
// encryption. No transport code is touched.
//
// Where this deviates from the brief, and why:
//
// 1. Container algorithm: the brief asked for `COMPRESSION_ZSTD`, but Apple's
//    `Compression` framework exposes only LZFSE, zlib, LZ4, LZMA, LZBITMAP and
//    Brotli (verified against the iPhoneOS 27.2 SDK `compression.h`, which
//    contains no zstd symbol). The user ruled LZFSE, so the document container
//    suffix is `.ppxlz` rather than `.ppxz`.
// 2. Image resize: `UIGraphicsImageRenderer` needs the *full* decoded bitmap in
//    memory before it can scale, which is the OOM path the brief forbids (a
//    12 MP HEIC decodes to roughly 48 MB). ImageIO's thumbnail API decodes
//    straight to the target size and emits no metadata dictionary, so EXIF,
//    GPS and the camera model are absent as a property of the encode rather
//    than deleted after the fact.
// 3. Video bitrate: `AVAssetExportSession` cannot express a target bitrate, so
//    "low bitrate" is implemented with `AVAssetWriter` on the hardware encoder.
//    `metadata = []` is kept as the brief requires.
// 4. Animated images pass through untouched. Re-encoding a multi-frame GIF into
//    a single-frame JPEG destination silently destroys the animation, and no
//    native API compresses GIF in place.
// 5. PDF: page-by-page re-draw into a new document drops the Info dictionary
//    and re-samples the page while keeping text selectable. It is not
//    guaranteed to shrink every file, so the same fuse used for documents
//    guards it too.
// 6. Classification reads the file itself (ImageIO's type identifier,
//    AVFoundation's track list, PDFKit, then a control-byte probe) instead of
//    `UTType` content initialisation, because the SDK in use exposes no
//    content-sniffing `UTType` initialiser. The consequence is the same: a JPEG
//    renamed `.dat` by the document picker is still caught as an image.

import AVFoundation
import Compression
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Copy

/// The English sentence is the catalog key, matching the rest of the app.
enum PopopxMediaEngineCopy {
    static func key(_ value: String) -> String {
        NSLocalizedString(value, comment: "POPOPX local compression")
    }

    static func processingStatus() -> String { key("Compressing & stripping metadata locally...") }
    static func unpackedBadge() -> String { key("Unpacked locally") }
    static func oversizedBlocked() -> String {
        key("This file is still too large after compression. Use an encrypted link instead.")
    }
    static func unpackFailed() -> String { key("The attachment could not be unpacked on this device.") }
    static func settingsTitle() -> String { key("Local media compression") }
    static func settingsFootnote() -> String {
        key("Attachments are shrunk and stripped of camera and location metadata on this device before they are encrypted. Nothing is uploaded for processing.")
    }
    static func strictGroupToggle() -> String { key("Large-group data saver") }
    static func strictGroupNote() -> String {
        key("Force-compress attachments in large groups and block anything still over 5 MB after compression.")
    }
    static func qualityRow() -> String { key("Image quality") }
    static func savedTotal(_ bytes: Int64) -> String {
        String(format: key("Saved %@ on this device"), PopopxMediaByteFormat.string(bytes))
    }
}

// MARK: - Byte formatting

enum PopopxMediaByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

// MARK: - Presets

enum PopopxImageQualityPreset: String, CaseIterable, Identifiable, Sendable {
    case dataSaver
    case standardHD

    var id: String { rawValue }

    var maxDimensionInPixels: Int {
        switch self {
        case .dataSaver: return 1080
        case .standardHD: return 1600
        }
    }

    var jpegQuality: Double {
        switch self {
        case .dataSaver: return 0.6
        case .standardHD: return 0.75
        }
    }

    var labelKey: String {
        switch self {
        case .dataSaver: return "Data saver"
        case .standardHD: return "Standard HD"
        }
    }

    var localizedLabel: String { PopopxMediaEngineCopy.key(labelKey) }
}

/// Classification of an attachment, decided from the file contents rather than
/// its extension, so a renamed photo cannot bypass the engine.
enum PopopxAttachmentKind: String, CaseIterable, Sendable {
    case image
    case animatedImage
    case video
    case pdf
    case document
    case passthrough

    var shouldCompress: Bool { self != .passthrough && self != .animatedImage }
}

// MARK: - Result

struct PopopxCompressedAttachment: Sendable, Equatable {
    let url: URL
    let kind: PopopxAttachmentKind
    let originalBytes: Int64
    let finalBytes: Int64
    let compressed: Bool

    var savedBytes: Int64 { compressed ? max(0, originalBytes - finalBytes) : 0 }

    /// A file the fuse rejected, or one that is not compressible, keeps its
    /// original URL so the caller hands it over untouched.
    static func unchanged(_ url: URL, kind: PopopxAttachmentKind, bytes: Int64) -> PopopxCompressedAttachment {
        PopopxCompressedAttachment(url: url, kind: kind, originalBytes: bytes, finalBytes: bytes, compressed: false)
    }
}

// MARK: - Unpack result

enum PopopxUnpackResult: Sendable, Equatable {
    case success(URL)
    case failure(String)

    var unpackedURL: URL? {
        if case let .success(url) = self { return url }
        return nil
    }
}

// MARK: - Engine

/// MainActor-facing façade. It owns nothing but progress state and moves every
/// byte of work into `PopopxMediaEngineCore`, which runs off the main thread.
@MainActor
@Observable
final class PopopxMediaEngine {
    static let shared = PopopxMediaEngine()

    private(set) var handledAttachmentCount = 0
    private(set) var unpackedFileCount = 0
    private(set) var savedBytesTotal: Int64 = 0
    private(set) var isProcessing = false

    private init() {}

    /// Single entry point for the outgoing pipeline. Never throws: an engine
    /// failure degrades to the original attachment rather than blocking a send.
    func process(url: URL, preset: PopopxImageQualityPreset? = nil) async -> PopopxCompressedAttachment {
        let chosen = preset ?? PopopxMediaCompressionSettings.shared.imageQualityPreset
        let bytes = PopopxMediaEngineCore.fileSize(of: url)
        isProcessing = true
        let output = await Task.detached(priority: .userInitiated) {
            await PopopxMediaEngineCore.perform(source: url, bytes: bytes, preset: chosen)
        }.value
        isProcessing = false
        handledAttachmentCount += 1
        savedBytesTotal += output.savedBytes
        return output
    }

    /// Receiving side: unpacks a `.ppxlz` container into the protected cache.
    func unpack(url: URL) async -> PopopxUnpackResult {
        let result = await Task.detached(priority: .userInitiated) {
            PopopxMediaEngineCore.unpack(container: url)
        }.value
        if result.unpackedURL != nil { unpackedFileCount += 1 }
        return result
    }

    func reset() {
        handledAttachmentCount = 0
        savedBytesTotal = 0
        unpackedFileCount = 0
        isProcessing = false
    }
}

// MARK: - Core

/// Stateless worker. Nothing here touches observable state, so it is safe to run
/// inside a detached task.
enum PopopxMediaEngineCore {
    // MARK: Sizing

    static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    // MARK: Classification

    static func identify(_ url: URL) async -> PopopxAttachmentKind {
        if PopopxDocumentContainer.isContainer(url) { return .passthrough }
        if let imageKind = imageKind(of: url) { return imageKind }
        if await hasVideoTrack(url) { return .video }
        if PDFDocument(url: url) != nil { return .pdf }
        if PopopxDocumentContainer.eligibleExtensions.contains(url.pathExtension.lowercased()), looksLikeText(url) {
            return .document
        }
        return .passthrough
    }

    private static func imageKind(of url: URL) -> PopopxAttachmentKind? {
        guard let source = openImageSource(url) else { return nil }
        guard let identifier = CGImageSourceGetType(source) as String? else { return nil }
        guard identifier.contains("image") || imageIdentifiers.contains(identifier) else { return nil }
        return CGImageSourceGetCount(source) > 1 ? .animatedImage : .image
    }

    private static let imageIdentifiers: Set<String> = [
        "public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff",
        "public.bmp", "public.gif", "public.raw-image", "public.svg-image",
        "com.apple.quicktime-movie", "org.webmproject.webp",
    ]

    private static func hasVideoTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    /// A document is text only when its first block carries no stray control
    /// bytes; this is what keeps a ZIP-based format out of the container.
    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2048)) ?? Data()
        guard !head.isEmpty else { return false }
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return true }
        for byte in head where byte < 0x09 || (byte > 0x0D && byte < 0x20 && byte != 0x1B) {
            return false
        }
        return true
    }

    // MARK: Dispatch

    static func perform(
        source: URL,
        bytes: Int64,
        preset: PopopxImageQualityPreset
    ) async -> PopopxCompressedAttachment {
        let kind = await identify(source)
        guard kind.shouldCompress else {
            return .unchanged(source, kind: kind, bytes: bytes)
        }
        let candidate: URL?
        switch kind {
        case .image:
            candidate = try? imageResult(source, preset)
        case .video:
            candidate = await videoOutputURL(source)
        case .pdf:
            candidate = try? pdfResult(source)
        case .document:
            candidate = try? documentResult(source)
        case .animatedImage, .passthrough:
            candidate = nil
        }
        guard let output = candidate, output != source else {
            return .unchanged(source, kind: kind, bytes: bytes)
        }
        let finalBytes = fileSize(of: output)
        guard finalBytes > 0, finalBytes < bytes else {
            try? FileManager.default.removeItem(at: output)
            return .unchanged(source, kind: kind, bytes: bytes)
        }
        return PopopxCompressedAttachment(
            url: output,
            kind: kind,
            originalBytes: bytes,
            finalBytes: finalBytes,
            compressed: true
        )
    }

    // MARK: Directories

    /// Scratch space for recompressed attachments. Cleared by the same hooks as
    /// the unpacked cache, so neither side leaves a plaintext copy behind.
    static let workingDirectoryName = "popopx_media"

    /// Plaintext cache for documents unpacked on the receiving side. Cleared on
    /// background and on the emergency wipe, see `PopopxIncomingFileUnpacker`.
    static let unpackedDirectoryName = "popopx_unpacked"

    static func workingDirectory() throws -> URL {
        try protectedDirectory(named: workingDirectoryName)
    }

    static func unpackedDirectory() throws -> URL {
        try protectedDirectory(named: unpackedDirectoryName)
    }

    private static func protectedDirectory(named name: String) throws -> URL {
        let manager = FileManager.default
        let target = manager.temporaryDirectory
            .appendingPathComponent("popopx", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if manager.fileExists(atPath: target.path) {
            try? manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
            return target
        }
        do {
            try manager.createDirectory(
                at: target,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            throw PopopxMediaEngineError.outputDirectoryUnavailable
        }
        return target
    }

    static func scratchURL(for source: URL, newExtension: String) throws -> URL {
        let name = "\(PopopxDocumentContainer.stem(of: source))-\(UUID().uuidString.prefix(8)).\(newExtension)"
        return try workingDirectory().appendingPathComponent(name)
    }

    // MARK: Images

    static func imageResult(_ source: URL, _ preset: PopopxImageQualityPreset) throws -> URL {
        guard let sourceImage = openImageSource(source) else {
            throw PopopxMediaEngineError.unreadable(source)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: preset.maxDimensionInPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(sourceImage, 0, options as CFDictionary) else {
            throw PopopxMediaEngineError.imageDecodeFailed
        }
        let output = try scratchURL(for: source, newExtension: "jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PopopxMediaEngineError.imageEncodeFailed
        }
        // No metadata dictionary is passed to the destination, so the JPEG
        // carries no EXIF, GPS, camera model or author entry.
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: preset.jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw PopopxMediaEngineError.imageEncodeFailed
        }
        return output
    }

    private static func openImageSource(_ url: URL) -> CGImageSource? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        return CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary)
    }

    // MARK: Video

    /// Long edge of a transcoded clip. 1280 px keeps a group clip readable while
    /// the bitrate ladder below does the traffic saving.
    static let videoMaxDimensionInPixels: Int = 1280

    private static func videoOutputURL(_ source: URL) async -> URL? {
        if case let .success(url) = await videoResult(source) { return url }
        return nil
    }

    static func videoResult(_ source: URL) async -> Result<URL, PopopxMediaEngineError> {
        let asset = AVURLAsset(url: source)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else { return .failure(.videoNoVideoTrack) }
            let (naturalSize, preferredTransform, nominalFrameRate) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate
            )
            guard naturalSize.width > 0, naturalSize.height > 0 else { return .failure(.videoExportFailed) }

            let displayed = displayedSize(of: naturalSize, transform: preferredTransform)
            let scale = min(1, Double(videoMaxDimensionInPixels) / Double(max(displayed.width, displayed.height)))
            let width = even(Int(naturalSize.width * scale))
            let height = even(Int(naturalSize.height * scale))
            guard width >= 16, height >= 16 else { return .failure(.videoExportFailed) }

            let output = try scratchURL(for: source, newExtension: "mp4")
            guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
                return .failure(.videoExportFailed)
            }
            writer.metadata = []
            writer.shouldOptimizeForNetworkUse = true

            let bitrate = videoBitrate(width: width, height: height, frameRate: nominalFrameRate)
            let compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: evenKeyframeInterval(nominalFrameRate),
            ]
            let hevcProbe: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProperties,
            ]
            let encoder = writer.canApply(outputSettings: hevcProbe, forMediaType: .video)
                ? AVVideoCodecType.hevc
                : AVVideoCodecType.h264
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: encoder,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProperties,
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = preferredTransform
            guard writer.canAdd(videoInput) else { return .failure(.videoExportFailed) }
            writer.add(videoInput)

            guard let reader = try? AVAssetReader(asset: asset) else { return .failure(.videoExportFailed) }
            let videoReaderOutput = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            guard reader.canAdd(videoReaderOutput) else { return .failure(.videoExportFailed) }
            reader.add(videoReaderOutput)

            let audio = try await audioLeg(of: asset, reader: reader, writer: writer)

            guard writer.startWriting() else { return .failure(.videoExportFailed) }
            guard reader.startReading() else {
                writer.cancelWriting()
                return .failure(.videoExportFailed)
            }
            writer.startSession(atSourceTime: .zero)

            let completed = await transcode(
                TranscodeContext(
                    reader: reader,
                    writer: writer,
                    videoInput: videoInput,
                    videoReaderOutput: videoReaderOutput,
                    audio: audio
                )
            )
            guard completed, fileSize(of: output) > 0 else {
                try? FileManager.default.removeItem(at: output)
                return .failure(.videoExportFailed)
            }
            return .success(output)
        } catch {
            return .failure(.videoExportFailed)
        }
    }

    private static func even(_ value: Int) -> Int {
        let clamped = max(16, value)
        return clamped - clamped % 2
    }

    private static func evenKeyframeInterval(_ frameRate: Float) -> Int {
        max(1, Int(round(min(max(frameRate, 1), 60) * 2)))
    }

    /// The transform is what turns a portrait recording into a landscape pixel
    /// grid, so the pixel budget has to be measured after applying it.
    private static func displayedSize(of size: CGSize, transform: CGAffineTransform) -> CGSize {
        let horizontal = CGPoint(x: size.width, y: 0).applying(transform)
        let vertical = CGPoint(x: 0, y: size.height).applying(transform)
        return CGSize(
            width: abs(horizontal.x) + abs(vertical.x),
            height: abs(horizontal.y) + abs(vertical.y)
        )
    }

    private struct AudioLeg {
        let input: AVAssetWriterInput
        let readerOutput: AVAssetReaderTrackOutput
    }

    private static func audioLeg(
        of asset: AVURLAsset,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> AudioLeg? {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return nil }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 64_000,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(readerOutput) else { return nil }
        writer.add(input)
        reader.add(readerOutput)
        return AudioLeg(input: input, readerOutput: readerOutput)
    }

    /// The objects that drive one transcode. AVFoundation gives these types no
    /// `Sendable` conformance, but pumping is confined to the single serial
    /// queue created below and every property is read inside the ready handler,
    /// so the capture is safe by construction rather than by suppression.
    private final class TranscodeContext: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let videoReaderOutput: AVAssetReaderTrackOutput
        let audioInput: AVAssetWriterInput?
        let audioReaderOutput: AVAssetReaderTrackOutput?

        init(
            reader: AVAssetReader,
            writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            videoReaderOutput: AVAssetReaderTrackOutput,
            audio: AudioLeg?
        ) {
            self.reader = reader
            self.writer = writer
            self.videoInput = videoInput
            self.videoReaderOutput = videoReaderOutput
            self.audioInput = audio?.input
            self.audioReaderOutput = audio?.readerOutput
        }

        func pump(isVideo: Bool, group: DispatchGroup, queue: DispatchQueue) {
            guard isVideo || audioInput != nil else { return }
            let target = isVideo ? videoInput : audioInput
            guard let target else { return }
            group.enter()
            target.requestMediaDataWhenReady(on: queue) { [self] in
                // Re-read the leg from self so the handler captures nothing
                // non-Sendable from the enclosing scope.
                let input = isVideo ? videoInput : audioInput!
                let output = isVideo ? videoReaderOutput : audioReaderOutput!
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let buffer = output.copyNextSampleBuffer() else { break }
                    if !input.append(buffer) { break }
                }
                input.markAsFinished()
                group.leave()
            }
        }
    }

    /// Pumping loop. `requestMediaDataWhenReady` returns control while the
    /// encoder drains, and the continuation resumes only after every input is
    /// marked finished and the session has been closed. Success is read from the
    /// reader and writer status, so no mutable state crosses queues.
    private static func transcode(_ context: TranscodeContext) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queue = DispatchQueue(label: "popopx.media.video.transcode", qos: .userInitiated)
            let group = DispatchGroup()
            context.pump(isVideo: true, group: group, queue: queue)
            context.pump(isVideo: false, group: group, queue: queue)
            group.notify(queue: queue) {
                guard context.reader.status == .completed, context.writer.status == .writing else {
                    if context.writer.status == .writing { context.writer.cancelWriting() }
                    continuation.resume(returning: false)
                    return
                }
                context.writer.finishWriting {
                    continuation.resume(returning: context.writer.status == .completed)
                }
            }
        }
    }

    private static func videoBitrate(width: Int, height: Int, frameRate: Float) -> Int {
        let pixels = Double(max(1, width * height))
        let fps = Double(min(max(frameRate, 1), 60))
        // About 0.06 bit per pixel per frame, clamped so a 720p clip lands near
        // 1.5 Mbps and a 1280 px clip near 3 Mbps.
        return Int(min(max(pixels * fps * 0.06, 400_000), 4_000_000))
    }

    // MARK: PDF

    /// Long edge of a re-rendered page, in points at 72 dpi.
    static let pdfMaxPageDimension: CGFloat = 1600

    static func pdfResult(_ source: URL) throws -> URL {
        guard let document = PDFDocument(url: source) else {
            throw PopopxMediaEngineError.pdfUnreadable
        }
        guard document.pageCount > 0 else { throw PopopxMediaEngineError.pdfUnreadable }
        let output = try scratchURL(for: source, newExtension: "pdf")
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pdfMaxPageDimension, height: pdfMaxPageDimension)
        )
        let maxPage = pdfMaxPageDimension
        do {
            try renderer.writePDF(to: output) { context in
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    let box = page.bounds(for: .mediaBox)
                    let longest = max(box.width, box.height)
                    let factor = longest > 0 ? min(1, maxPage / longest) : 1
                    context.beginPage(
                        withBounds: CGRect(
                            x: 0,
                            y: 0,
                            width: max(1, box.width * factor),
                            height: max(1, box.height * factor)
                        ),
                        pageInfo: [:]
                    )
                    let canvas = context.cgContext
                    canvas.saveGState()
                    canvas.scaleBy(x: factor, y: factor)
                    page.draw(with: .mediaBox, to: canvas)
                    canvas.restoreGState()
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw PopopxMediaEngineError.pdfExportFailed
        }
        return output
    }

    // MARK: Documents

    static func documentResult(_ source: URL) throws -> URL {
        guard PopopxDocumentContainer.isEligible(source) else {
            throw PopopxMediaEngineError.streamFailed
        }
        let originalBytes = fileSize(of: source)
        guard originalBytes > 0 else { throw PopopxMediaEngineError.unreadable(source) }
        let output = try scratchURL(for: source, newExtension: PopopxDocumentContainer.pathExtension)
        let packed: Int64
        do {
            packed = try PopopxDocumentContainer.pack(source: source, to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        // Negative-optimization fuse: a file that did not shrink by at least 15%
        // keeps its original URL instead of shipping a larger payload that the
        // recipient then has to unpack.
        guard Double(packed) < Double(originalBytes) * PopopxDocumentContainer.minimumReductionRatio else {
            try? FileManager.default.removeItem(at: output)
            return source
        }
        return output
    }

    static func unpack(container: URL) -> PopopxUnpackResult {
        let destination: URL
        do {
            let directory = try unpackedDirectory()
            destination = directory.appendingPathComponent(PopopxDocumentContainer.displayName(for: container))
        } catch {
            return .failure(PopopxMediaEngineCopy.unpackFailed())
        }
        do {
            _ = try PopopxDocumentContainer.unpack(container: container, to: destination)
            return .success(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failure(PopopxMediaEngineCopy.unpackFailed())
        }
    }
}

// MARK: - Errors

enum PopopxMediaEngineError: Error, Equatable, Sendable {
    case unreadable(URL)
    case imageDecodeFailed
    case imageEncodeFailed
    case videoExportFailed
    case videoNoVideoTrack
    case pdfUnreadable
    case pdfExportFailed
    case containerMagicMismatch
    case containerTruncated
    case streamFailed
    case outputDirectoryUnavailable
}

// MARK: - Container

/// The `.ppxlz` container: a fixed magic prefix followed by a raw LZFSE stream
/// produced and consumed in bounded chunks, so no document is ever fully
/// resident in memory.
enum PopopxDocumentContainer {
    static let pathExtension = "ppxlz"

    /// Extensions worth streaming through LZFSE. Office formats are deliberately
    /// absent: they are already ZIP containers, and the fuse rejects them.
    static let eligibleExtensions: Set<String> = [
        "md", "txt", "csv", "tsv", "json", "jsonl", "log", "text",
        "yaml", "yml", "xml", "ini", "conf", "srt", "ics", "vcf", "sql",
    ]

    /// Keep the packed file only when it is more than 15% smaller.
    static let minimumReductionRatio = 0.85

    static let magic: [UInt8] = Array("PPXLZ1".utf8)
    static let inputChunkByteCount = 1 << 20
    static let outputBufferByteCount = 4 << 20

    static func isContainer(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == pathExtension
    }

    static func isEligible(_ url: URL) -> Bool {
        guard !isContainer(url) else { return false }
        return eligibleExtensions.contains(url.pathExtension.lowercased())
    }

    /// `notes.md.ppxlz` -> `notes.md`, which is the name the bubble shows and the
    /// name the unpacker writes.
    static func stem(of url: URL) -> String {
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".\(pathExtension)") {
            name.removeLast(pathExtension.count + 1)
        }
        return sanitize(name)
    }

    static func displayName(for url: URL) -> String { stem(of: url) }

    static func sanitize(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { scalar in
            scalar != "/" && scalar.value != 0 && !CharacterSet.newlines.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    static func pack(source: URL, to destination: URL) throws -> Int64 {
        guard let input = FileHandle(forReadingAtPath: source.path) else {
            throw PopopxMediaEngineError.unreadable(source)
        }
        defer { try? input.close() }
        return try FileManager.default.withProtectedFile(at: destination) { output in
            try output.write(contentsOf: Data(magic))
            return try process(input: input, output: output, operation: .encode)
        }
    }

    static func unpack(container: URL, to destination: URL) throws -> Int64 {
        guard let input = FileHandle(forReadingAtPath: container.path) else {
            throw PopopxMediaEngineError.unreadable(container)
        }
        defer { try? input.close() }
        let header = try input.read(upToCount: magic.count) ?? Data()
        guard [UInt8](header) == magic else {
            throw PopopxMediaEngineError.containerMagicMismatch
        }
        return try FileManager.default.withProtectedFile(at: destination) { output in
            try process(input: input, output: output, operation: .decode)
        }
    }

    // MARK: Streaming loop

    private enum Operation {
        case encode
        case decode

        var streamOperation: compression_stream_operation {
            switch self {
            case .encode: return COMPRESSION_STREAM_ENCODE
            case .decode: return COMPRESSION_STREAM_DECODE
            }
        }

        var processFlags: Int32 {
            switch self {
            case .encode: return Int32(COMPRESSION_STREAM_ENCODE.rawValue)
            case .decode: return Int32(COMPRESSION_STREAM_DECODE.rawValue)
            }
        }
    }

    /// `compression_stream_init` zeroes every field except `state`, so the
    /// buffers are attached after it. A buffer is only refilled once the stream
    /// has consumed all of the previous one, which keeps the pointers live.
    private static func process(
        input: FileHandle,
        output: FileHandle,
        operation: Operation
    ) throws -> Int64 {
        let sourceCapacity = inputChunkByteCount
        let targetCapacity = outputBufferByteCount
        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: sourceCapacity)
        let targetBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: targetCapacity)
        defer {
            sourceBuffer.deallocate()
            targetBuffer.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: targetBuffer,
            dst_size: targetCapacity,
            src_ptr: UnsafePointer(sourceBuffer),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, operation.streamOperation, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw PopopxMediaEngineError.streamFailed
        }
        defer { compression_stream_destroy(&stream) }

        var totalWritten: Int64 = 0
        var finalize = Int32(0)
        stream.dst_ptr = targetBuffer
        stream.dst_size = targetCapacity

        while true {
            if stream.src_size == 0 {
                let chunk = try input.read(upToCount: sourceCapacity) ?? Data()
                if chunk.isEmpty {
                    finalize = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                } else {
                    chunk.withUnsafeBytes { raw in
                        let bytes = raw.bindMemory(to: UInt8.self)
                        sourceBuffer.update(from: bytes.baseAddress!, count: raw.count)
                    }
                    stream.src_ptr = UnsafePointer(sourceBuffer)
                    stream.src_size = chunk.count
                }
            }
            guard stream.src_size > 0 || finalize != 0 else { break }

            let status = compression_stream_process(&stream, operation.processFlags | finalize)
            let produced = targetCapacity - stream.dst_size
            if produced > 0 {
                try output.write(contentsOf: Data(bytes: targetBuffer, count: produced))
                totalWritten += Int64(produced)
                stream.dst_ptr = targetBuffer
                stream.dst_size = targetCapacity
            }
            switch status {
            case COMPRESSION_STATUS_END:
                return totalWritten
            case COMPRESSION_STATUS_OK:
                continue
            default:
                throw PopopxMediaEngineError.streamFailed
            }
        }
        return totalWritten
    }
}

// MARK: - Protected file helper

extension FileManager {
    /// Creates an empty file with complete protection and opens it for writing,
    /// so nothing produced by the engine is readable while the device is locked.
    func withProtectedFile(at url: URL, _ body: (FileHandle) throws -> Int64) throws -> Int64 {
        createFile(atPath: url.path, contents: nil)
        try setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw PopopxMediaEngineError.outputDirectoryUnavailable
        }
        defer { try? handle.close() }
        return try body(handle)
    }
}
