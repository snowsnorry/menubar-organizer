/// Keeps read-only system modules listed while macOS omits their AX items from
/// the collapsed menu bar. A successful position-table read replaces stale
/// memory; a failed read retains modules observed earlier in this session.
public struct UnsupportedModulePresence: Sendable {
    public static let keys = ["module:AudioVideoModule", "module:AirDrop", "module:UserSwitcher"]
    private var remembered: Set<String> = []

    public init() {}

    public mutating func missingKeys(observed: [DiscoveredItem], configured: Set<String>?) -> [String] {
        let seen = Set(observed.compactMap(\.positionTableKey)).intersection(Self.keys)
        if let configured {
            remembered = configured.intersection(Self.keys).union(seen)
        } else {
            remembered.formUnion(seen)
        }
        return Self.keys.filter { remembered.contains($0) && !seen.contains($0) }
    }
}
