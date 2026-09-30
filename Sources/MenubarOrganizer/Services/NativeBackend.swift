import AppKit
import ApplicationServices
import OrganizerCore

@MainActor
final class NativeBackend: LayoutBackend {
    let visibility = VisibilityDriver()
    private let positionStore = MenuBarPositionStore()
    private var tail: Task<Void, Error>?
    private var stopped = false
    private var gestureGeneration: UInt64 = 0
    private var explicitReorderingGeneration: UInt64?
    private var cachedInventory: [NativeItem]?
    private var cacheTime: ContinuousClock.Instant?
    private var cacheFingerprint: [String] = []
    private var cacheForeground: pid_t?
    private var hiddenApplications: Set<String> = []
    private var hiddenFingerprint: [String] = []
    private var recentlyRevealedApplications: Set<String>?
    private var recentlyRevealedFingerprint: [String] = []
    private let unsupportedModules = UnsupportedModulePresence()

    private var fingerprint: [String] {
        NSWorkspace.shared.runningApplications
            .map { "\($0.processIdentifier):\($0.launchDate?.timeIntervalSince1970 ?? 0)" }.sorted()
    }

    private func remember(_ inventory: [NativeItem]) {
        cachedInventory = inventory
        cacheTime = .now
        cacheFingerprint = fingerprint
        cacheForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func invalidateInventory() { cachedInventory = nil; cacheTime = nil }

    private func inventory(refresh: Bool) async throws -> [NativeItem] {
        let currentFingerprint = fingerprint
        let currentForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let cachedInventory, let cacheTime, explicitReorderingGeneration != nil,
           cacheFingerprint == currentFingerprint, cacheForeground == currentForeground,
           cacheTime.duration(to: .now) <= .seconds(60) {
            // Up to 60s reuses only the owner/metadata seed. Geometry older than
            // 2s is refreshed, and every gesture requests refresh regardless of age.
            if !refresh, cacheTime.duration(to: .now) <= .seconds(2) { return cachedInventory }
            let updated: [NativeItem]
            do {
                updated = try await NativeDiscovery.refresh(items: cachedInventory, validateMembership: true)
            } catch NativeDiscoveryError.staleGeometry {
                invalidateInventory()
                updated = try await NativeDiscovery.scan()
            }
            guard currentFingerprint == fingerprint else { invalidateInventory(); throw MoveError.expired }
            remember(updated)
            return updated
        }
        let updated = try await NativeDiscovery.scan()
        guard currentFingerprint == fingerprint else { invalidateInventory(); throw MoveError.expired }
        remember(updated)
        return updated
    }

    /// Only explicit OK or restoring the saved order at launch may open this session.
    func beginExplicitReordering() throws {
        guard !stopped, explicitReorderingGeneration == nil else { throw MoveError.unavailable }
        gestureGeneration &+= 1
        explicitReorderingGeneration = gestureGeneration
    }

    func endExplicitReordering() {
        explicitReorderingGeneration = nil
        gestureGeneration &+= 1
    }

    func preparePositionTableAccess(promptIfNeeded: Bool = true) throws {
        try positionStore.ensureAccess(promptIfNeeded: promptIfNeeded)
    }

    func cancelGestures() { endExplicitReordering() }

    func shutdown() async {
        stopped = true
        cancelGestures()
        if let tail { _ = try? await tail.value }
        positionStore.closeAccess()
        visibility.invalidateForTermination()
    }

    func discover() async throws -> [DiscoveredItem] {
        if let tail { _ = try? await tail.value }
        var observed = try await inventory(refresh: false).map(\.item)
        let missing = unsupportedModules.missingKeys(observed: observed)
        for key in missing {
            let name = switch key {
            case "module:AudioVideoModule": "system.audioVideoControls"
            case "module:AirDrop": "system.airDrop"
            default: "system.user"
            }
            observed.append(DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: L10n.text(name), isDirectlyAccessible: false,
                isSupported: false, positionTableKey: key))
        }
        for (key, bundle, name) in [
            ("module:FocusModes", "com.apple.MenuBarAgent", "system.focus"),
            ("status:com.apple.systemuiserver::com.apple.menuextra.vpn", "com.apple.systemuiserver", "system.vpn")
        ] where !observed.contains(where: { $0.positionTableKey == key }) {
            observed.append(DiscoveredItem(bundleID: bundle, identifier: nil,
                name: L10n.text(name), isDirectlyAccessible: false,
                isSupported: false, positionTableKey: key))
        }
        for (service, name) in [
            ("nowPlaying", "system.nowPlaying"),
            ("timer", "system.timer"),
            ("accessibility", "system.accessibility")
        ] where !observed.contains(where: { $0.systemServiceID == service }) {
            observed.append(DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: L10n.text(name), isDirectlyAccessible: false,
                isSupported: false, systemServiceID: service))
        }
        return observed
    }

    func hasActiveVisibilityRestriction() async -> Bool { visibility.isActive }

    /// The current assertion still covers the same running processes.
    func hasCurrentHiddenAssertion() -> Bool {
        visibility.isActive && !hiddenApplications.isEmpty && hiddenFingerprint == fingerprint
    }

    /// The exact targets of the assertion we just released are safe to reuse
    /// for a manual collapse while the running-process inventory is unchanged.
    func recentlyRevealedTargets() -> Set<String>? {
        guard let recentlyRevealedApplications,
              recentlyRevealedFingerprint == fingerprint else { return nil }
        return recentlyRevealedApplications
    }

    func setHiddenApplications(_ bundleIDs: Set<String>) async throws {
        try await serialize {
            guard !self.stopped || bundleIDs.isEmpty else { throw CancellationError() }
            try Task.checkCancellation()
            let fingerprint = self.fingerprint
            if !bundleIDs.isEmpty, self.hiddenApplications == bundleIDs,
               self.visibility.isActive, self.hiddenFingerprint == fingerprint { return }
            let wasActive = self.visibility.isActive
            let previousHidden = self.hiddenApplications
            let previousFingerprint = self.hiddenFingerprint
            do {
                try await self.visibility.setHiddenApplications(bundleIDs)
                // Reapplying even the same nonempty set replaces an assertion.
                if !bundleIDs.isEmpty || wasActive || self.hiddenApplications != bundleIDs {
                    self.invalidateInventory()
                }
                self.hiddenApplications = bundleIDs
                self.hiddenFingerprint = self.fingerprint
                if bundleIDs.isEmpty, wasActive, !previousHidden.isEmpty,
                   previousFingerprint == fingerprint, self.hiddenFingerprint == fingerprint {
                    self.recentlyRevealedApplications = previousHidden
                    self.recentlyRevealedFingerprint = self.hiddenFingerprint
                } else {
                    self.recentlyRevealedApplications = nil
                    self.recentlyRevealedFingerprint = []
                }
            } catch {
                if !self.visibility.isActive {
                    self.invalidateInventory(); self.hiddenApplications = []; self.hiddenFingerprint = []
                    self.recentlyRevealedApplications = nil; self.recentlyRevealedFingerprint = []
                }
                throw error
            }
        }
    }

    func moveItem(id: String, before targetID: String) async throws {
        try await moveItem(id: id, relativeTo: targetID, placement: .before)
    }

    func moveItem(id: String, relativeTo targetID: String, placement: ItemMovePlacement) async throws {
        guard let token = explicitReorderingGeneration, !stopped else {
            throw MoveError.explicitConfirmationRequired
        }
        try await serialize {
            try self.checkSession(token)
            do {
                let inventory = try await self.inventory(refresh: id.hasPrefix("system-position:") ||
                    targetID.hasPrefix("system-position:"))
                func key(_ value: NativeItem) -> String? {
                    ItemRegistry.observationID(value.item)
                }
                let sources = inventory.filter { key($0) == id }
                let targets = inventory.filter { key($0) == targetID }
                guard sources.count == 1, targets.count == 1,
                      let source = sources.first, let target = targets.first else {
                    throw MoveError.unavailable
                }
                let updated = try await self.positionStore.move(source: source, target: target,
                                                               inventory: inventory, placement: placement) {
                    try self.checkSession(token)
                }
                self.remember(updated)
            } catch {
                self.invalidateInventory()
                throw error
            }
        }
    }

    private func checkSession(_ token: UInt64) throws {
        guard !stopped, token == gestureGeneration, explicitReorderingGeneration == token else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func serialize(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            try await operation()
        }
        tail = task
        try await task.value
    }

    enum MoveError: Error, Equatable {
        case explicitConfirmationRequired, unavailable, expired
    }

}
