import Foundation

public enum ItemGroup: String, Codable, Sendable, CaseIterable {
    case visible, hidden
}

/// Persistent identity never contains a PID, display, rectangle or icon pixels.
public struct LayoutEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var bundleID: String
    public var name: String
    public var group: ItemGroup

    public init(id: String, bundleID: String, name: String, group: ItemGroup = .visible) {
        self.id = id; self.bundleID = bundleID; self.name = name; self.group = group
    }
}

public enum LayoutValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidIdentity
    case duplicateIdentity
    case inconsistentApplicationVisibility
    case invalidDelay
}

/// Array order is the requested left-to-right order within each group.
/// Third-party visibility belongs to the whole application. System position
/// identities can have independent visibility choices.
public struct LayoutDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var entries: [LayoutEntry]
    public var hideDelay: Double
    public var launchAtLogin: Bool

    public init(version: Int = currentVersion, entries: [LayoutEntry] = [],
                hideDelay: Double = 5, launchAtLogin: Bool = false) {
        self.version = version; self.entries = entries
        self.hideDelay = hideDelay; self.launchAtLogin = launchAtLogin
    }

    public func validated() throws -> LayoutDocument {
        guard version == Self.currentVersion else { throw LayoutValidationError.unsupportedVersion(version) }
        guard hideDelay.isFinite, (1...60).contains(hideDelay) else { throw LayoutValidationError.invalidDelay }
        var identities = Set<String>()
        var visibility: [String: ItemGroup] = [:]
        for entry in entries {
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LayoutValidationError.invalidIdentity
            }
            guard identities.insert(entry.id).inserted else { throw LayoutValidationError.duplicateIdentity }
            if !(entry.bundleID.hasPrefix("com.apple.") && entry.id.hasPrefix("system-position:")) {
                if let group = visibility[entry.bundleID], group != entry.group {
                    throw LayoutValidationError.inconsistentApplicationVisibility
                }
                visibility[entry.bundleID] = entry.group
            }
        }
        return self
    }

    public func entries(in group: ItemGroup) -> [LayoutEntry] { entries.filter { $0.group == group } }
}
