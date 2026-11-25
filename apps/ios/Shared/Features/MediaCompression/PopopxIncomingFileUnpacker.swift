//
//  Copyright © 2026 POPOPX Chat. All rights reserved.
//  SPDX-License-Identifier: AGPL-3.0-only
//
// POPOPX incoming file unpacker.
//
// The receiving half of the document container. It runs after the core has
// already downloaded and decrypted the file into the sandbox, so nothing here
// knows or cares about the transport: it recognises the `.ppxlz` container,
// restores the original file name, unpacks into a protected cache directory, and
// deletes that cache the moment the app leaves the foreground or the emergency
// wipe starts.
//
// Where this deviates from the brief, and why: the plaintext cache is rebuilt on
// demand rather than kept warm. iOS purges `tmp/` under pressure without
// telling anyone, so a cached path can vanish between two taps. Every call
// therefore re-verifies the cache and unpacks again from the encrypted source,
// which is the durable copy.

import Foundation
import PopopxMeshUI
import SwiftUI
import UIKit

// MARK: - Unpacker

enum PopopxIncomingFileUnpacker {
    static func isContainer(_ url: URL) -> Bool {
        PopopxDocumentContainer.isContainer(url)
    }

    static func isContainer(named fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".\(PopopxDocumentContainer.pathExtension)")
    }

    /// The name shown in the bubble: `notes.md.ppxlz` becomes `notes.md`.
    static func displayName(for fileName: String) -> String {
        guard isContainer(named: fileName) else { return fileName }
        let stem = String(fileName.dropLast(PopopxDocumentContainer.pathExtension.count + 1))
        return stem.isEmpty ? fileName : stem
    }

    /// Icon for the restored file type, chosen from the name the user sees.
    static func systemImage(for fileName: String) -> String {
        let ext = (displayName(for: fileName) as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "doc.plaintext"
        case "txt", "text", "log", "conf", "ini": return "doc.text"
        case "csv", "tsv": return "tablecells"
        case "json", "jsonl": return "curlybraces"
        case "xml", "html": return "doc.text.magnifyingglass"
        case "yaml", "yml": return "doc.append"
        case "ics": return "calendar"
        case "vcf": return "person.crop.card"
        case "sql": return "table.filled"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    /// The cache path for a container, only when a usable unpacked copy exists.
    static func cachedURL(for container: URL) -> URL? {
        guard let directory = try? PopopxMediaEngineCore.unpackedDirectory() else { return nil }
        let candidate = directory.appendingPathComponent(PopopxDocumentContainer.displayName(for: container))
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        let values = try? candidate.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize ?? 0) > 0 ? candidate : nil
    }

    static func unpack(_ container: URL) async -> PopopxUnpackResult {
        if let cached = cachedURL(for: container) { return .success(cached) }
        return await PopopxMediaEngine.shared.unpack(url: container)
    }

    /// Used by the open path: a container becomes its unpacked file, anything
    /// else is returned untouched so the existing presenter keeps working.
    static func prepareForOpening(_ url: URL) async -> PopopxOpenableFile {
        guard isContainer(url) else { return PopopxOpenableFile(url: url, unpacked: false, message: nil) }
        let result = await unpack(url)
        switch result {
        case let .success(unpacked):
            return PopopxOpenableFile(url: unpacked, unpacked: true, message: nil)
        case let .failure(message):
            return PopopxOpenableFile(url: url, unpacked: false, message: message)
        }
    }

    /// Physically clears both plaintext caches: the documents unpacked on the
    /// receiving side and the recompressed copies the sending side leaves behind.
    /// Synchronous and non-isolated by necessity: it runs from a background
    /// notification and from the emergency wipe immediately before the process is
    /// terminated. Only the contents are removed; the engine recreates both
    /// directories on demand.
    static func purgeTemporaryDirectories() {
        for directory in cacheDirectories() {
            clear(directory)
        }
    }

    static func cacheDirectories() -> [URL] {
        var directories: [URL] = []
        if let working = try? PopopxMediaEngineCore.workingDirectory() { directories.append(working) }
        if let unpacked = try? PopopxMediaEngineCore.unpackedDirectory() { directories.append(unpacked) }
        return directories
    }

    private static func clear(_ directory: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            try? manager.removeItem(at: entry)
        }
    }
}

// MARK: - Openable file

struct PopopxOpenableFile: Sendable, Equatable {
    let url: URL
    let unpacked: Bool
    let message: String?

    var displayName: String { PopopxIncomingFileUnpacker.displayName(for: url.lastPathComponent) }
}

// MARK: - Bubble affordances

/// The teal micro-label under a file name once its container has been unpacked
/// locally.
struct PopopxUnpackedMicroBadge: View {
    var body: some View {
        HStack(spacing: PopopxMetrics.space2XS) {
            Image(systemName: "shippingbox")
                .font(.system(size: 8, weight: .semibold))
            Text(PopopxMediaEngineCopy.unpackedBadge())
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(PopopxPalette.meshInk)
        .padding(.horizontal, PopopxMetrics.spaceXS)
        .padding(.vertical, 2)
        .background(PopopxPalette.mesh.opacity(0.12), in: Capsule())
        .accessibilityIdentifier("popopx.media.unpackedBadge")
    }
}

// MARK: - Lifecycle

/// Keeps the plaintext cache alive only for the length of a foreground session.
@MainActor
@Observable
final class PopopxUnpackLifecycleGuard {
    static let shared = PopopxUnpackLifecycleGuard()

    private(set) var isInstalled = false
    private var observer: NSObjectProtocol?

    private init() {}

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            PopopxIncomingFileUnpacker.purgeTemporaryDirectories()
        }
    }

    func uninstall() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        isInstalled = false
    }
}

// MARK: - Emergency wipe hook

/// Purges the unpacked cache as part of the panic wipe. The wipe's own steps run
/// immediately before the process is terminated, so this hook cannot rely on an
/// actor hop or an async task: it deletes synchronously on the calling thread.
struct PopopxMediaWipeRecorder: PopopxPanicWipeRecording {
    init() {}

    func panicWipeDidStart(step: PopopxPanicWipeStep) {
        PopopxIncomingFileUnpacker.purgeTemporaryDirectories()
    }

    func panicWipeDidFinish(step: PopopxPanicWipeStep, erasedFileCount: Int) {
        PopopxIncomingFileUnpacker.purgeTemporaryDirectories()
    }

    func panicWipeDidFail(_ failure: PopopxPanicWipeFailure, at step: PopopxPanicWipeStep) {
        PopopxIncomingFileUnpacker.purgeTemporaryDirectories()
    }
}
