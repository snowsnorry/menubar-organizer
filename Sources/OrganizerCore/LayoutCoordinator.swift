import Foundation

/// Discovery returns the observed left-to-right order. Each move must revalidate
/// native coordinates immediately before issuing the gesture.
public protocol LayoutBackend: Sendable {
    func discover() async throws -> [DiscoveredItem]
    func hasActiveVisibilityRestriction() async -> Bool
    func setHiddenApplications(_ bundleIDs: Set<String>) async throws
    func moveItem(id: String, before targetID: String) async throws
    func moveItem(id: String, relativeTo targetID: String, placement: ItemMovePlacement) async throws
}

public enum LayoutBackendMoveError: Error { case unsupportedPlacement }

public extension LayoutBackend {
    func hasActiveVisibilityRestriction() async -> Bool { false }
    func moveItem(id: String, relativeTo targetID: String, placement: ItemMovePlacement) async throws {
        guard placement == .before else { throw LayoutBackendMoveError.unsupportedPlacement }
        try await moveItem(id: id, before: targetID)
    }
}

public enum LayoutApplyStatus: Equatable, Sendable {
    case applied, partial, superseded, failed
}

public struct LayoutApplyReport: Sendable {
    public var status: LayoutApplyStatus
    /// Visibility was accepted and passed the safety checks, even if ordering failed.
    public var visibilityApplied: Bool
    /// Latest observed inventory, not proof of visibility from the backend.
    public var snapshot: RegistrySnapshot?
    /// Actual discovery order; duplicate identities remain duplicated. Unknown owners are omitted.
    public var observedOrder: [String]
    public var movedCount: Int
    public var deferredIDs: [String]
    public var error: String?
    public var fallbackError: String?
}

/// Explicit apply requests only. Passive discovery must not invoke this actor.
/// A newer request supersedes queued work, but waits for an in-flight backend
/// operation to finish before starting its own operations.
public actor LayoutCoordinator {
    private let backend: any LayoutBackend
    private var generation: UInt64 = 0
    var requestGeneration: UInt64 { generation }
    private var tail: Task<LayoutApplyReport, Never>?

    public init(backend: any LayoutBackend) { self.backend = backend }

    /// Supersede queued work and drain the current bounded backend operation.
    /// This performs no new discovery, visibility request, or reorder.
    public func cancelPending() async {
        generation &+= 1
        let token = generation
        let previous = tail
        if let previous { _ = await previous.value }
        if generation == token { tail = nil }
    }

    public func apply(_ document: LayoutDocument, revealed: Bool = false, allowReordering: Bool = true) async -> LayoutApplyReport {
        generation &+= 1
        let token = generation
        let previous = tail
        let task = Task {
            if let previous { _ = await previous.value }
            return await self.perform(document, revealed: revealed, allowReordering: allowReordering, token: token)
        }
        tail = task
        let result = await task.value
        if generation == token { tail = nil }
        return result
    }

    private struct VerificationFailure: Error { }

    private func observedIDs(_ observations: [DiscoveredItem]) -> [String] {
        observations.compactMap { item in
            guard item.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            return ItemRegistry.observationID(item)
        }
    }

    private struct SafetyResult {
        var observations: [DiscoveredItem]
        var snapshot: RegistrySnapshot
        var hidden: Set<String>
        var adjusted: Bool
    }

    /// Only removes applications from the hidden set. Each iteration therefore
    /// strictly decreases a finite set; newly appearing items never cause hiding.
    private func enforceSafeVisibility(_ observations: [DiscoveredItem], document: LayoutDocument,
                                       hidden: Set<String>, token: UInt64) async throws -> SafetyResult? {
        var result = SafetyResult(observations: observations,
                                  snapshot: try ItemRegistry.reconcile(observations, with: document),
                                  hidden: hidden, adjusted: false)
        while true {
            guard token == generation else { return nil }
            let unsafe = Set(result.snapshot.items.filter {
                $0.availability != .absent && !$0.canSetVisibility
            }.map { item in ItemRegistry.systemVisibilityTarget(for: item.entry) ?? item.entry.bundleID })
            // Absence after hiding is expected and does not prove ineligibility.
            let safe: Set<String> = result.snapshot.unknownOwnerCount > 0 ? [] : result.hidden.subtracting(unsafe)
            guard safe != result.hidden else { return result }
            try await backend.setHiddenApplications(safe)
            guard token == generation else { return nil }
            result.hidden = safe
            result.adjusted = true
            result.observations = try await backend.discover()
            guard token == generation else { return nil }
            result.snapshot = try ItemRegistry.reconcile(result.observations, with: document)
        }
    }

    private func perform(_ document: LayoutDocument, revealed: Bool, allowReordering: Bool, token: UInt64) async -> LayoutApplyReport {
        var report = LayoutApplyReport(status: .superseded, visibilityApplied: false, snapshot: nil,
                                       observedOrder: [], movedCount: 0, deferredIDs: [], error: nil, fallbackError: nil)
        guard token == generation else { return report }
        do {
            let document = try document.validated()
            var hidden: Set<String> = []
            // Eligibility needs a pre-change inventory only when this request
            // could hide an application. Revealing everything can be followed
            // by a single discovery of the resulting state.
            if !revealed && document.entries.contains(where: { $0.group == .hidden }) {
                // A prior assertion can remove its own targets from discovery.
                // Reveal first, then derive the next allow-list from a full
                // inventory instead of mistaking absent hidden icons for gone.
                if await backend.hasActiveVisibilityRestriction() {
                    try await backend.setHiddenApplications([])
                    guard token == generation else { return report }
                }
                let before = try await backend.discover()
                guard token == generation else { return report }
                let beforeSnapshot = try ItemRegistry.reconcile(before, with: document)
                report.snapshot = beforeSnapshot
                report.observedOrder = observedIDs(before)
                if beforeSnapshot.unknownOwnerCount > 0 {
                    report.status = .partial
                    report.error = "unidentifiedMenuBarOwners"
                    return report
                }
                hidden = ItemRegistry.eligibleHiddenApplications(in: beforeSnapshot)
            }
            try await backend.setHiddenApplications(hidden)
            guard token == generation else { return report }
            var observations = try await backend.discover()
            guard token == generation else { return report }
            var snapshot = try ItemRegistry.reconcile(observations, with: document)
            report.snapshot = snapshot
            report.observedOrder = observedIDs(observations)
            func visibleHiddenSystemTargets(in snapshot: RegistrySnapshot) -> Set<String> {
                Set(snapshot.items.compactMap { item -> String? in
                    guard item.availability == .available,
                          let target = ItemRegistry.systemVisibilityTarget(for: item.entry),
                          // The process-wide Time Machine filter can leave an
                          // AX row visible after the icon disappears. Treating
                          // that row as proof of failure releases every hidden
                          // application, including unrelated ones.
                          target != "com.apple.systemuiserver",
                          hidden.contains(target) else { return nil }
                    return target
                })
            }
            var stillVisibleSystemTargets = visibleHiddenSystemTargets(in: snapshot)
            if !stillVisibleSystemTargets.isEmpty {
                // Assessment activation can precede the menu bar's redraw.
                // Verify once more before releasing every hidden target.
                try await Task.sleep(for: .milliseconds(300))
                guard token == generation else { return report }
                observations = try await backend.discover()
                guard token == generation else { return report }
                snapshot = try ItemRegistry.reconcile(observations, with: document)
                report.snapshot = snapshot
                report.observedOrder = observedIDs(observations)
                stillVisibleSystemTargets = visibleHiddenSystemTargets(in: snapshot)
            }
            if !stillVisibleSystemTargets.isEmpty {
                try await backend.setHiddenApplications([])
                report.status = .partial
                report.error = "systemVisibilityNotVerified"
                return report
            }
            guard let checked = try await enforceSafeVisibility(observations, document: document, hidden: hidden, token: token) else { return report }
            if checked.adjusted {
                report.snapshot = checked.snapshot
                report.observedOrder = observedIDs(checked.observations)
                report.status = .partial
                report.error = "Visibility eligibility changed; unsafe applications were revealed."
                return report
            }
            hidden = checked.hidden
            report.visibilityApplied = true

            // A bundle fallback can address exactly one directly accessible icon.
            // Linked fallback groups remain indivisible and cannot be reordered.
            func movable(_ snapshot: RegistrySnapshot) -> Set<String> {
                Set(snapshot.items.filter { $0.canReorder &&
                    (!$0.entry.bundleID.hasPrefix("com.apple.") || $0.id.hasPrefix("system-position:")) }
                    .map(\.id))
            }
            func order(_ observations: [DiscoveredItem], among ids: Set<String>) -> [String] {
                observations.compactMap { item in
                    guard let id = ItemRegistry.observationID(item) else { return nil }
                    return ids.contains(id) ? id : nil
                }
            }
            let initiallyMovable = movable(snapshot)
            report.deferredIDs = document.entries.filter { $0.group == .visible }
                .map(\.id).filter { !initiallyMovable.contains($0) }
            if !allowReordering {
                // This request is visibility-only. A previously saved order
                // can differ from reality; report the visibility result and
                // let the caller adopt the observed order without moving icons.
                report.status = .applied
                return report
            }
            // Plan once per group with minimum insertions; each is verified, never retried.
            for group in ItemGroup.allCases {
                let desired = document.entries(in: group).map(\.id).filter { initiallyMovable.contains($0) }
                let ids = Set(desired)
                var expected = order(observations, among: ids)
                let plan = try ReorderPlanner.plan(from: expected, to: desired)
                for move in plan {
                    guard token == generation else { return report }
                    guard ids.isSubset(of: movable(snapshot)) else {
                        let unavailable = desired.filter { !movable(snapshot).contains($0) }
                        report.deferredIDs.append(contentsOf: unavailable.filter { !report.deferredIDs.contains($0) })
                        report.status = .partial
                        return report
                    }
                    guard order(observations, among: ids) == expected,
                          let sourceIndex = expected.firstIndex(of: move.id) else { throw VerificationFailure() }
                    expected.remove(at: sourceIndex)
                    guard let targetIndex = expected.firstIndex(of: move.targetID) else { throw VerificationFailure() }
                    expected.insert(move.id, at: targetIndex + (move.placement == .after ? 1 : 0))
                    try await backend.moveItem(id: move.id, relativeTo: move.targetID, placement: move.placement)
                    report.movedCount += 1
                    guard token == generation else { return report }
                    observations = try await backend.discover()
                    guard token == generation else { return report }
                    snapshot = try ItemRegistry.reconcile(observations, with: document)
                    report.snapshot = snapshot
                    report.observedOrder = observedIDs(observations)
                    guard let checked = try await enforceSafeVisibility(observations, document: document, hidden: hidden, token: token) else { return report }
                    if checked.adjusted {
                        report.snapshot = checked.snapshot
                        report.observedOrder = observedIDs(checked.observations)
                        report.status = .partial
                        report.error = "Visibility eligibility changed; unsafe applications were revealed."
                        return report
                    }
                    hidden = checked.hidden
                    guard ids.isSubset(of: movable(snapshot)), order(observations, among: ids) == expected else {
                        throw VerificationFailure()
                    }
                }
            }
            report.status = report.deferredIDs.isEmpty ? .applied : .partial
            return report
        } catch {
            guard token == generation else { return report }
            report.status = report.movedCount > 0 ? .partial : .failed
            report.error = error is VerificationFailure
                ? "reorderVerificationFailed" : String(describing: error)
            if !report.visibilityApplied {
                do {
                    try await backend.setHiddenApplications([])
                } catch {
                    report.fallbackError = String(describing: error)
                }
            }
            guard token == generation else { report.status = .superseded; return report }
            // Capture actual state without issuing any more moves.
            do {
                let observations = try await backend.discover()
                guard token == generation else { report.status = .superseded; return report }
                report.snapshot = try ItemRegistry.reconcile(observations, with: document)
                report.observedOrder = observedIDs(observations)
            } catch {
                if report.fallbackError == nil { report.fallbackError = "Post-recovery discovery: \(error)" }
            }
            if token != generation { report.status = .superseded }
            return report
        }
    }
}
