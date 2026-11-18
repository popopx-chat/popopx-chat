//
//  PopopxMeshStorage.swift
//  PopopxMeshKit
//
//  Nothing in this package touches the SQLCipher database or libpopopx.a. Offline state lives in
//  its own sandbox directory and secret state in the Keychain, both named here and nowhere else.
//

import Foundation
import Security

public enum PopopxMeshStorageError: Error, Hashable, Sendable {
    case directoryUnusable(path: String, underlying: String)
    case writeFailed(path: String, underlying: String)
    case readFailed(path: String, underlying: String)
    case keychain(status: Int32, operation: String)
    case encodingFailed(String)
}

public enum PopopxMeshPaths {
    /// Rule 5 of the brief: the mesh's cache lives in `Documents/popopx_mesh/`, not in the chat database.
    public static let directoryName = "popopx_mesh"

    public static let unacknowledgedQueueName = "unacknowledged_mesh.json"
    public static let outboxName = "mesh_outbox.json"

    /// Documents of the app sandbox. A package cannot know the container, so the host injects it
    /// with `setDocumentsDirectory` at startup; the fallback keeps unit tests working.
    public static func meshDirectory(fallbackOn firstUse: Bool = true) -> URL {
        if let injected = injectedDocumentsDirectory {
            return injected.appendingPathComponent(directoryName, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent(directoryName, isDirectory: true)
    }

    private nonisolated(unsafe) static var injectedDocumentsDirectory: URL?

    /// Called once from the app (phase 2) with `URL.documentsDirectory` of its own sandbox.
    public static func setDocumentsDirectory(_ url: URL) {
        injectedDocumentsDirectory = url
    }

    @discardableResult
    public static func ensureMeshDirectory() throws -> URL {
        let url = meshDirectory()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var item = url
            try item.setResourceValues(values)
            return item
        } catch {
            throw PopopxMeshStorageError.directoryUnusable(path: url.path, underlying: error.localizedDescription)
        }
    }

    public static func unacknowledgedQueueURL() -> URL {
        meshDirectory().appendingPathComponent(unacknowledgedQueueName)
    }
}

/// Reads and writes a JSON payload in the mesh directory under complete file protection, so an
/// offline queue on disk is unreadable while the device is locked.
public enum PopopxMeshFileStore {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encode(value, with: encoder)
        try writeAtomic(data, to: url)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PopopxMeshStorageError.readFailed(path: url.path, underlying: "absent")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(type, from: data)
    }

    public static func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private static func encode<T: Encodable>(_ value: T, with encoder: JSONEncoder) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw PopopxMeshStorageError.encodingFailed(error.localizedDescription)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PopopxMeshStorageError.readFailed(path: "json", underlying: error.localizedDescription)
        }
    }

    private static func writeAtomic(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw PopopxMeshStorageError.writeFailed(path: url.path, underlying: error.localizedDescription)
        }
    }
}

/// The Keychain, behind a protocol so `IdentityMappingStore` can be tested without a keychain.
public protocol PopopxMeshSecretStoring: Sendable {
    func data(service: String, account: String) throws -> Data?
    func set(_ data: Data, service: String, account: String) throws
    func remove(service: String, account: String) throws
    /// Used by panic wipe: one call empties the whole service, not one account at a time.
    func removeAll(service: String) throws
}

/// Generic-password items, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never backed up,
/// never moved to another device, unreadable while locked.
public struct PopopxMeshKeychain: Sendable {
    public static let shared = PopopxMeshKeychain()

    public init() {}

    public func data(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            SecClass.genericPassword: true,
            SecAttr.service: service,
            SecAttr.account: account,
            SecAttr.returnData: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw PopopxMeshStorageError.keychain(status: status, operation: "copy")
        }
    }

    public func set(_ data: Data, service: String, account: String) throws {
        let attributes: [String: Any] = [
            SecClass.genericPassword: true,
            SecAttr.service: service,
            SecAttr.account: account,
            SecAttr.value: data,
            SecAttr.accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecDuplicateItem else {
            if status == errSecSuccess { return }
            throw PopopxMeshStorageError.keychain(status: status, operation: "add")
        }
        let query: [String: Any] = [
            SecClass.genericPassword: true,
            SecAttr.service: service,
            SecAttr.account: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [SecAttr.value: data] as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw PopopxMeshStorageError.keychain(status: updateStatus, operation: "update")
        }
    }

    public func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            SecClass.genericPassword: true,
            SecAttr.service: service,
            SecAttr.account: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PopopxMeshStorageError.keychain(status: status, operation: "delete")
        }
    }

    public func removeAll(service: String) throws {
        let query: [String: Any] = [
            SecClass.genericPassword: true,
            SecAttr.service: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PopopxMeshStorageError.keychain(status: status, operation: "deleteAll")
        }
    }
}

/// `Security`'s constants are `CFString`; these are the `String` keys a `[String: Any]` query
/// needs, kept in one place so no caller has to remember which spelling `SecItemAdd` wants.
enum SecClass {
    static let genericPassword = kSecClass as String
}

enum SecAttr {
    static let service = kSecAttrService as String
    static let account = kSecAttrAccount as String
    static let value = kSecValueData as String
    static let returnData = kSecReturnData as String
    static let accessible = kSecAttrAccessible as String
}
