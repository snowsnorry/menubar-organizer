import Foundation

public enum LayoutLoadStatus: Equatable, Sendable {
    case missing
    case loaded
    case recoveredCorruption(backupURL: URL)
}

public struct LayoutLoadResult: Equatable, Sendable {
    public let document: LayoutDocument
    public let status: LayoutLoadStatus
}

public enum LayoutStoreError: Error {
    case nonFileURL
    case symbolicLink
    case cannotCreateFile
}

/// Serializes stores in this process. The application must be the sole writer of its layout file.
public struct LayoutStore: Sendable {
    public let url: URL
    private static let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() throws -> LayoutLoadResult {
        try Self.lock.withLock {
            guard let data = try existingData() else {
                return LayoutLoadResult(document: LayoutDocument(), status: .missing)
            }
            if let document = try decodeCurrent(data) {
                try secureDirectory()
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return LayoutLoadResult(document: document, status: .loaded)
            }
            let backup = try preserve(data)
            let document = LayoutDocument()
            try write(document)
            return LayoutLoadResult(document: document, status: .recoveredCorruption(backupURL: backup))
        }
    }

    public func save(_ document: LayoutDocument) throws {
        try Self.lock.withLock {
            _ = try document.validated()
            if let original = try existingData(), try decodeCurrent(original) == nil {
                _ = try preserve(original)
            }
            try write(document)
        }
    }

    private func existingData() throws -> Data? {
        guard url.isFileURL else { throw LayoutStoreError.nonFileURL }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw LayoutStoreError.symbolicLink
            }
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Inspect the version independently, so a future document with different fields is never
    /// mistaken for corrupt current data and replaced. There is no historical product schema.
    private func decodeCurrent(_ data: Data) throws -> LayoutDocument? {
        struct Version: Decodable { let version: Int }
        if let version = try? JSONDecoder().decode(Version.self, from: data),
           version.version != LayoutDocument.currentVersion {
            throw LayoutValidationError.unsupportedVersion(version.version)
        }
        guard let document = try? JSONDecoder().decode(LayoutDocument.self, from: data) else { return nil }
        return try? document.validated()
    }

    private func secureDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw LayoutStoreError.symbolicLink
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func preserve(_ data: Data) throws -> URL {
        try secureDirectory()
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(UUID().uuidString).backup")
        try privateFile(data, at: backup)
        return backup
    }

    private func write(_ document: LayoutDocument) throws {
        try secureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".layout-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try privateFile(data, at: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary,
                                                      options: [.usingNewMetadataOnly])
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Create with private permissions before writing any bytes; flush before publishing.
    private func privateFile(_ data: Data, at destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw LayoutStoreError.cannotCreateFile
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
