/// Supplies stable rows for known read-only system modules even before macOS
/// exposes their menu bar items.
public struct UnsupportedModulePresence: Sendable {
    public static let keys = ["module:AudioVideoModule", "module:AirDrop", "module:UserSwitcher"]

    public init() {}

    public func missingKeys(observed: [DiscoveredItem]) -> [String] {
        let seen = Set(observed.compactMap(\.positionTableKey)).intersection(Self.keys)
        return Self.keys.filter { !seen.contains($0) }
    }
}
