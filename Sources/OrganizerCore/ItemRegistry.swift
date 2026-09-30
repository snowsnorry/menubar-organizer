import Foundation

public struct DiscoveredItem: Equatable, Sendable {
    public var bundleID: String?
    public var identifier: String?
    public var name: String
    public var isDirectlyAccessible: Bool
    public var isSupported: Bool
    /// Transient UI identity, used only for separate system-owned menu items.
    public var presentationID: String?
    /// Exact key in the macOS menu-bar position table, only for a verified
    /// one-to-one system status item. Never inferred from its display name.
    public var positionTableKey: String?
    /// Stable presentation identity for a recognized read-only system service.
    /// This is not a position-table key and never authorizes layout changes.
    public var systemServiceID: String?
    public var isPinnedSystemItem: Bool
    public var isOmittedFromSettings: Bool

    public init(bundleID: String?, identifier: String?, name: String,
                isDirectlyAccessible: Bool = true, isSupported: Bool = true, presentationID: String? = nil,
                positionTableKey: String? = nil, systemServiceID: String? = nil,
                isPinnedSystemItem: Bool = false,
                isOmittedFromSettings: Bool = false) {
        self.bundleID = bundleID; self.identifier = identifier; self.name = name
        self.isDirectlyAccessible = isDirectlyAccessible; self.isSupported = isSupported
        self.presentationID = presentationID
        self.positionTableKey = positionTableKey
        self.systemServiceID = systemServiceID
        self.isPinnedSystemItem = isPinnedSystemItem
        self.isOmittedFromSettings = isOmittedFromSettings
    }
}

public enum ItemAvailability: String, Equatable, Sendable {
    case available, absent, overflow, ambiguous, unsupported
}

public struct RegistryItem: Identifiable, Equatable, Sendable {
    public var entry: LayoutEntry
    public var availability: ItemAvailability
    public var linkedIconCount: Int
    public var isPinnedByDiscovery: Bool = false
    public var isOmittedFromSettings: Bool = false
    /// Number of observed visible layout rows preceding this read-only row.
    public var presentationSlot: Int? = nil
    public var id: String { entry.id }
    public var displayName: String { entry.bundleID == ItemRegistry.organizerBundleID ? "Menubar Organizer" : entry.name }
    public var isPinnedSystemItem: Bool {
        ItemRegistry.isPinnedSystemPosition(entry) || isPinnedByDiscovery
    }
    /// A saved system position can outlive the menu bar item after macOS turns
    /// that item off. Keep the layout entry, but omit its unavailable visible row.
    public var isUnavailableVisibleSystemItem: Bool {
        entry.group == .visible && availability == .absent &&
            entry.bundleID.hasPrefix("com.apple.") && entry.id.hasPrefix("system-position:")
    }
    /// Unsupported is a display section, never a persisted visibility group.
    public var isUnsupportedInSettings: Bool {
        return availability == .unsupported || availability == .ambiguous ||
            (entry.bundleID.hasPrefix("com.apple.") && ItemRegistry.unsupportedSystemPositionIDs.contains(entry.id))
    }
    public var canReorder: Bool {
        !isUnsupportedInSettings && !isPinnedSystemItem && availability == .available && linkedIconCount == 1
    }
    public var canSetVisibility: Bool {
        if isUnsupportedInSettings { return false }
        if isPinnedSystemItem { return false }
        if entry.bundleID == ItemRegistry.organizerBundleID { return false }
        if entry.bundleID.hasPrefix("com.apple.") {
            return ItemRegistry.systemVisibilityTarget(for: entry) != nil &&
                (availability == .available || availability == .overflow ||
                 (availability == .absent && entry.group == .hidden))
        }
        return availability == .available || availability == .overflow
    }
}

public struct RegistrySnapshot: Equatable, Sendable {
    public var layout: LayoutDocument
    public var items: [RegistryItem]
    public var unknownOwnerCount: Int
}

public enum ItemRegistry {
    public static let organizerBundleID = "local.menubarorganizer.app"
    public static let timeMachinePositionID = "system-position:status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine"
    public static let vpnPositionID = "system-position:status:com.apple.systemuiserver::com.apple.menuextra.vpn"
    public static let legacyExtraTargetPrefix = "legacy-extra:"
    public static let legacyExtraBundleIDs: Set<String> = ["com.apple.menuextra.vpn", "com.apple.menuextra.TimeMachine"]
    public static let unsupportedSystemPositionIDs: Set<String> = [
        "system-position:module:FocusModes",
        "system-position:module:AudioVideoModule",
        "system-position:module:AirDrop",
        "system-position:module:UserSwitcher"
    ]

    public static func isPinnedSystemPosition(_ entry: LayoutEntry) -> Bool {
        guard entry.bundleID == "com.apple.controlcenter" || entry.bundleID == "com.apple.MenuBarAgent" else { return false }
        return entry.id == "system-position:module:Clock" || entry.id == "system-position:module:BentoBox-0"
    }

    private static let moduleVisibilityTargets: [String: String] = [
        "module:Battery": "system-item:0", "module:Bluetooth": "system-item:1",
        "module:Displays": "system-item:3",
        "module:KeyboardBrightness": "system-item:4", "module:Sound": "system-item:5",
        "module:WiFi": "system-item:6", "module:ScreenMirroring": "system-item:7"
    ]

    /// Return only targets whose discovery identity uniquely names a supported
    /// system icon. The owner bundle is checked as well as the position key.
    public static func systemVisibilityTarget(for entry: LayoutEntry) -> String? {
        if isPinnedSystemPosition(entry) { return nil }
        if entry.bundleID == "com.apple.systemuiserver" {
            return legacyExtraBundleIDs.first {
                entry.id == "system-position:status:com.apple.systemuiserver::\($0)"
            }.map { legacyExtraTargetPrefix + $0 }
        }
        if entry.bundleID == "com.apple.controlcenter" || entry.bundleID == "com.apple.MenuBarAgent" {
            guard entry.id.hasPrefix("system-position:") else { return nil }
            return moduleVisibilityTargets[String(entry.id.dropFirst("system-position:".count))]
        }
        let singleIconOwners: [String: String] = [
            "com.apple.TextInputMenuAgent": "system-position:status:com.apple.TextInputMenuAgent::Item-0",
            "com.apple.weather.menu": "system-position:status:com.apple.weather.menu::Item-0",
            "com.apple.campo": "system-position:status:com.apple.campo::Item-0"
        ]
        return singleIconOwners[entry.bundleID] == entry.id ? entry.bundleID : nil
    }

    /// Keep protected rows visible when loading layouts from older versions.
    /// Legacy or unknown SystemUIServer rows cannot safely select the process-wide filter.
    public static func recoveringUnsupportedVisibility(in saved: LayoutDocument) throws -> LayoutDocument {
        var result = try saved.validated()
        // Earlier builds offered a speculative Siri identity. It was not
        // confirmed on this system, so discard those saved editable rows.
        result.entries.removeAll {
            $0.bundleID == "com.apple.Siri" || $0.bundleID == "com.apple.Siri.MenuExtra"
        }
        func mustRemainVisible(_ entry: LayoutEntry) -> Bool {
            entry.bundleID == organizerBundleID || isPinnedSystemPosition(entry) ||
                (entry.bundleID == "com.apple.systemuiserver" && systemVisibilityTarget(for: entry) == nil) ||
                unsupportedSystemPositionIDs.contains(entry.id)
        }
        guard result.entries.contains(where: {
            $0.group == .hidden && mustRemainVisible($0)
        }) else {
            return result
        }
        for index in result.entries.indices where mustRemainVisible(result.entries[index]) {
            result.entries[index].group = .visible
        }
        result.entries = result.entries(in: .visible) + result.entries(in: .hidden)
        return try result.validated()
    }

    public static func observationID(_ observation: DiscoveredItem) -> String? {
        guard let bundle = observation.bundleID, !bundle.isEmpty else { return nil }
        if bundle.hasPrefix("com.apple.") {
            if let key = observation.positionTableKey, !key.isEmpty { return "system-position:\(key)" }
            if let service = observation.systemServiceID, !service.isEmpty { return "system-service:\(service)" }
            if let presentation = observation.presentationID, !presentation.isEmpty {
                return "system-presentation:\(bundle.utf8.count):\(bundle)\(presentation)"
            }
        }
        return self.key(bundleID: bundle, identifier: observation.identifier)
    }

    public static func key(bundleID: String, identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "app:\(bundleID)" }
        return "\(bundleID.utf8.count):\(bundleID)\(identifier)"
    }

    /// Missing records remain in the requested layout. A snapshot never issues
    /// backend operations and never equates an absent icon with an empty bar.
    public static func reconcile(_ observations: [DiscoveredItem], with saved: LayoutDocument) throws -> RegistrySnapshot {
        var layout = try recoveringUnsupportedVisibility(in: saved)
        var buckets: [String: [DiscoveredItem]] = [:]
        var observedOrder: [String] = []
        var unknownOwners = 0
        for observation in observations {
            guard let bundle = observation.bundleID, !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                unknownOwners += 1; continue
            }
            guard let id = observationID(observation) else { continue }
            if buckets[id] == nil { observedOrder.append(id) }
            buckets[id, default: []].append(observation)
        }
        var persistedIDs = Set(layout.entries.map(\.id))
        var groups = Dictionary(layout.entries.filter { !($0.bundleID.hasPrefix("com.apple.") && $0.id.hasPrefix("system-position:")) }
            .map { ($0.bundleID, $0.group) }, uniquingKeysWith: { first, _ in first })
        for id in observedOrder {
            guard !persistedIDs.contains(id), let observation = buckets[id]?.first, let bundle = observation.bundleID,
                  (!bundle.hasPrefix("com.apple.") || id.hasPrefix("system-position:")),
                  (!id.hasPrefix("system-position:") || buckets[id]?.count == 1),
                  buckets[id]?.allSatisfy(\.isSupported) == true else { continue }
            let group = (bundle.hasPrefix("com.apple.") && id.hasPrefix("system-position:")) || bundle == organizerBundleID
                ? ItemGroup.visible : groups[bundle] ?? .visible
            let entry = LayoutEntry(id: id, bundleID: bundle, name: observation.name, group: group)
            if id.hasPrefix("system-position:") || bundle == organizerBundleID {
                // New system items and the Organizer join at their observed position, including
                // between two already-saved third-party entries.
                let preceding = observedOrder.prefix { $0 != id }.reversed()
                    .compactMap { observedID in layout.entries.firstIndex(where: { $0.id == observedID && $0.group == .visible }) }.first
                let following = observedOrder.drop { $0 != id }.dropFirst()
                    .compactMap { observedID in layout.entries.firstIndex(where: { $0.id == observedID && $0.group == .visible }) }.first
                let insertion = preceding.map { $0 + 1 } ?? following ?? layout.entries.firstIndex(where: { $0.group == .hidden }) ?? layout.entries.count
                layout.entries.insert(entry, at: insertion)
            } else {
                layout.entries.append(entry)
            }
            if !(bundle.hasPrefix("com.apple.") && id.hasPrefix("system-position:")) { groups[bundle] = group }
            persistedIDs.insert(id)
        }
        for index in layout.entries.indices {
            if let current = buckets[layout.entries[index].id]?.first,
               current.bundleID == layout.entries[index].bundleID, !current.name.isEmpty {
                layout.entries[index].name = current.name
            }
        }
        var records = layout.entries
        // System/unsupported items can be described in the UI but never saved
        // as editable layout entries merely because they were discovered.
        for id in observedOrder where !persistedIDs.contains(id) {
            guard let current = buckets[id]?.first, let bundle = current.bundleID else { continue }
            records.append(LayoutEntry(id: id, bundleID: bundle, name: current.name))
        }
        var slots: [String: Int] = [:]
        let visibleIDs = Set(layout.entries.filter { $0.group == .visible }.map(\.id))
        var visibleCount = 0
        for id in observedOrder {
            if !persistedIDs.contains(id) { slots[id] = visibleCount }
            else if visibleIDs.contains(id) { visibleCount += 1 }
        }
        let items = records.map { entry -> RegistryItem in
            guard let members = buckets[entry.id], let first = members.first else {
                return RegistryItem(entry: entry, availability: .absent, linkedIconCount: 0,
                    isOmittedFromSettings: entry.bundleID == "com.apple.Siri" ||
                        entry.bundleID == "com.apple.Siri.MenuExtra")
            }
            let hasExplicitID = first.identifier?.isEmpty == false
            let availability: ItemAvailability
            if (entry.bundleID.hasPrefix("com.apple.") && !entry.id.hasPrefix("system-position:")) ||
                members.contains(where: { !$0.isSupported || $0.bundleID != entry.bundleID }) {
                availability = .unsupported
            } else if (hasExplicitID || entry.id.hasPrefix("system-position:")) && members.count > 1 {
                availability = .ambiguous
            } else if members.contains(where: { !$0.isDirectlyAccessible }) {
                availability = .overflow
            } else {
                availability = .available
            }
            return RegistryItem(entry: entry, availability: availability, linkedIconCount: members.count,
                                isPinnedByDiscovery: first.isPinnedSystemItem,
                                isOmittedFromSettings: first.isOmittedFromSettings,
                                presentationSlot: slots[entry.id])
        }
        return RegistrySnapshot(layout: try layout.validated(), items: mergingDraft(items, with: layout), unknownOwnerCount: unknownOwners)
    }

    /// The Organizer's NSStatusItem restores its own autosaved position at launch.
    /// Accept that position before replaying the saved order of other icons.
    public static func adoptingObservedOrganizerPosition(_ observations: [DiscoveredItem],
                                                         in saved: LayoutDocument) throws -> LayoutDocument {
        let saved = try saved.validated()
        guard let own = saved.entries.first(where: { $0.bundleID == organizerBundleID && $0.group == .visible }),
              let ownID = observations.compactMap(observationID).first(where: { $0 == own.id }) else { return saved }
        let visibleIDs = Set(saved.entries(in: .visible).map(\.id))
        let observed = observations.compactMap(observationID).filter { visibleIDs.contains($0) }
        guard observed.filter({ $0 == ownID }).count == 1,
              let observedIndex = observed.firstIndex(of: ownID) else { return saved }
        let withoutOwn = saved.entries(in: .visible).filter { $0.id != ownID }
        let before = observed.dropFirst(observedIndex + 1).first { $0 != ownID }
        let after = observed.prefix(observedIndex).last { $0 != ownID }
        let insertion = before.flatMap { neighbor in withoutOwn.firstIndex(where: { $0.id == neighbor }) }
            ?? after.flatMap { neighbor in withoutOwn.firstIndex(where: { $0.id == neighbor }).map { $0 + 1 } }
        guard let insertion else { return saved }
        return try LayoutEditor.move(ownID, to: .visible, at: insertion, in: saved)
    }

    /// Draft edits retain their requested order. Read-only rows keep ordinal
    /// positions from the latest discovery, rather than becoming editable anchors.
    /// Hidden/absent rows consume no visible slot; extra slots clamp to the end.
    /// Presentation identities and slots never enter the returned layout document.
    public static func mergingDraft(_ items: [RegistryItem], with document: LayoutDocument) -> [RegistryItem] {
        let existing = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let savedIDs = Set(document.entries.map(\.id))
        var result = document.entries.compactMap { entry -> RegistryItem? in
            guard var item = existing[entry.id] else { return nil }
            item.entry = entry
            return item
        }
        let readOnly = items.filter { !savedIDs.contains($0.id) }
        let visibleIndices = result.indices.filter {
            result[$0].entry.group == .visible && result[$0].availability != .absent
        }
        // Compute against the unchanged editable rows so several system items
        // sharing a slot retain their observed left-to-right order.
        var placements: [(index: Int, ordinal: Int, item: RegistryItem)] = []
        for (ordinal, item) in readOnly.enumerated() {
            let slot = max(0, item.presentationSlot ?? visibleIndices.count)
            let insertion: Int
            if slot < visibleIndices.count {
                insertion = visibleIndices[slot]
            } else if let last = visibleIndices.last {
                insertion = last + 1
            } else {
                insertion = 0
            }
            placements.append((index: insertion, ordinal: ordinal, item: item))
        }
        placements.sort { lhs, rhs in
            if lhs.index == rhs.index { return lhs.ordinal < rhs.ordinal }
            return lhs.index < rhs.index
        }
        for placement in placements.reversed() {
            result.insert(placement.item, at: placement.index)
        }
        return result
    }

    /// Third-party hiding is application-wide. Supported system items contribute
    /// individual targets; ambiguous or unsupported observations never hide.
    public static func eligibleHiddenApplications(in snapshot: RegistrySnapshot) -> Set<String> {
        let systemTargets = snapshot.items.compactMap { item -> String? in
            guard item.entry.group == .hidden, item.canSetVisibility,
                  let target = systemVisibilityTarget(for: item.entry) else { return nil }
            // A system module hidden by the old assertion may still be absent
            // from AX immediately after that assertion is released. Its exact
            // numeric system-item target remains safe to carry into the new
            // assertion. Process-wide system owners still require observation.
            guard item.availability == .available || item.availability == .overflow ||
                  (item.availability == .absent && target.hasPrefix("system-item:")) else { return nil }
            return target
        }
        let groups = Dictionary(grouping: snapshot.items.filter { !$0.entry.bundleID.hasPrefix("com.apple.") }, by: { $0.entry.bundleID })
        let applications: [String] = groups.compactMap { bundle, items -> String? in
            guard bundle != organizerBundleID else { return nil }
            let present = items.filter { $0.availability != .absent }
            guard !present.isEmpty, present.allSatisfy({ $0.canSetVisibility && $0.entry.group == .hidden }) else { return nil }
            return bundle
        }
        return Set(systemTargets + applications)
    }
}

public enum LayoutEditError: Error, Equatable {
    case itemNotFound, invalidInsertionIndex, protectedApplication
}

public enum LayoutEditor {
    /// Translate an insertion in the settings list to the saved group's index.
    /// The list may omit read-only system rows that still occupy saved slots.
    public static func insertionIndex(in destination: [LayoutEntry], displayedIDs: [String],
                                      precedingIDs: Set<String>) -> Int {
        let displayedIndex = displayedIDs.filter { precedingIDs.contains($0) }.count
        if displayedIDs.indices.contains(displayedIndex),
           let next = destination.firstIndex(where: { $0.id == displayedIDs[displayedIndex] }) {
            return next
        }
        if displayedIndex > 0,
           let previous = destination.firstIndex(where: { $0.id == displayedIDs[displayedIndex - 1] }) {
            return previous + 1
        }
        return destination.count
    }

    /// Insertion index refers to the destination group after moved records have
    /// been removed. A cross-group move carries all third-party application icons.
    public static func move(_ id: String, to group: ItemGroup, at index: Int, in document: LayoutDocument) throws -> LayoutDocument {
        var document = try document.validated()
        guard let selected = document.entries.first(where: { $0.id == id }) else { throw LayoutEditError.itemNotFound }
        if ItemRegistry.isPinnedSystemPosition(selected) { throw LayoutEditError.protectedApplication }
        if selected.bundleID == ItemRegistry.organizerBundleID && group == .hidden {
            throw LayoutEditError.protectedApplication
        }
        if selected.bundleID.hasPrefix("com.apple.") &&
            (!selected.id.hasPrefix("system-position:") ||
             (selected.group != group && ItemRegistry.systemVisibilityTarget(for: selected) == nil)) {
            throw LayoutEditError.protectedApplication
        }
        let moved = document.entries.filter { selected.group != group && !selected.id.hasPrefix("system-position:") ? $0.bundleID == selected.bundleID : $0.id == id }
            .map { entry -> LayoutEntry in var entry = entry; entry.group = group; return entry }
        let movedIDs = Set(moved.map(\.id))
        let remaining = document.entries.filter { !movedIDs.contains($0.id) }
        var destination = remaining.filter { $0.group == group }
        guard (0...destination.count).contains(index) else { throw LayoutEditError.invalidInsertionIndex }
        destination.insert(contentsOf: moved, at: index)
        let other = remaining.filter { $0.group != group }
        document.entries = group == .visible ? destination + other : other + destination
        return try document.validated()
    }

    /// Adopt a direct user reorder only when the caller is idle and its observed
    /// order is verified. Missing slots and entries in the other group stay put.
    public static func adoptObservedOrder(_ ids: [String], group: ItemGroup, in document: LayoutDocument) throws -> LayoutDocument {
        var document = try document.validated()
        guard Set(ids).count == ids.count else { throw LayoutValidationError.duplicateIdentity }
        let byID = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.id, $0) })
        guard ids.allSatisfy({ byID[$0]?.group == group }) else { throw LayoutEditError.itemNotFound }
        let observed = Set(ids)
        var next = 0
        document.entries = document.entries.map { entry in
            guard entry.group == group, observed.contains(entry.id) else { return entry }
            defer { next += 1 }
            return byID[ids[next]]!
        }
        return document
    }
}
