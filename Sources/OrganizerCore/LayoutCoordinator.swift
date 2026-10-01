import Foundation

/// Discovery returns the observed left-to-right order. Each move must revalidate
/// native coordinates immediately before issuing the gesture.
public enum VisibilityRequestIntent: Sendable {
    case automatic, userToggle, userSettings, termination

    public var permitsRelease: Bool { self != .automatic }
}

public protocol LayoutBackend: Sendable {
    func discover() async throws -> [DiscoveredItem]
    func hasActiveVisibilityRestriction() async -> Bool
    func visibilityWarnings() async -> [VisibilityWarning]
    func setHiddenApplications(_ bundleIDs: Set<String>, intent: VisibilityRequestIntent) async throws
    func moveItem(id: String, before targetID: String) async throws
    func moveItem(id: String, relativeTo targetID: String, placement: ItemMovePlacement) async throws
}

public enum LayoutBackendMoveError: Error { case unsupportedPlacement }

public extension LayoutBackend {
    func hasActiveVisibilityRestriction() async -> Bool { false }
    func visibilityWarnings() async -> [VisibilityWarning] { [] }
    func moveItem(id: String, relativeTo targetID: String, placement: ItemMovePlacement) async throws {
        guard placement == .before else { throw LayoutBackendMoveError.unsupportedPlacement }
        try await moveItem(id: id, before: targetID)
    }
}

/// A target-local failure that leaves unrelated visibility restrictions usable.
public struct VisibilityWarning: Equatable, Sendable {
    public var target: String
    public var reason: String
    public init(target: String, reason: String) { self.target = target; self.reason = reason }
}

public enum LayoutApplyStatus: Equatable, Sendable {
    case applied, partial, superseded, failed
}

public struct LayoutApplyReport: Sendable {
    public var status: LayoutApplyStatus
    /// Visibility was accepted, even if later discovery or ordering failed.
    public var visibilityApplied: Bool
    /// Latest observed inventory, not proof of visibility from the backend.
    public var snapshot: RegistrySnapshot?
    /// Actual discovery order; duplicate identities remain duplicated. Unknown owners are omitted.
    public var observedOrder: [String]
    public var movedCount: Int
    public var deferredIDs: [String]
    public var error: String?
    public var fallbackError: String?
    /// AX can retain a system row after its icon has disappeared. Diagnostic only.
    public var unverifiedSystemTargets: [String]
    public var visibilityWarnings: [VisibilityWarning] = []
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

    public func apply(_ document: LayoutDocument, revealed: Bool = false, allowReordering: Bool = true,
                      currentVisibilityLayout: LayoutDocument? = nil,
                      intent: VisibilityRequestIntent = .automatic) async -> LayoutApplyReport {
        generation &+= 1
        let token = generation
        let previous = tail
        let task = Task {
            if let previous { _ = await previous.value }
            return await self.perform(document, revealed: revealed, allowReordering: allowReordering,
                                      currentVisibilityLayout: currentVisibilityLayout, intent: intent, token: token)
        }
        tail = task
        let result = await task.value
        if generation == token { tail = nil }
        return result
    }

    /// Restore saved order while every item is visible, then apply saved hiding.
    /// Hiding first would remove its targets from discovery and prevent moves.
    public func restoreSavedLayout(_ document: LayoutDocument, intent: VisibilityRequestIntent = .automatic) async -> LayoutApplyReport {
        let orderingGeneration = generation &+ 1
        let ordering = await apply(document, revealed: true, allowReordering: true, intent: intent)
        guard generation == orderingGeneration, ordering.status != .superseded else { return ordering }
        var visibility = await apply(document, allowReordering: false, intent: intent)
        if visibility.status == .applied, ordering.status != .applied {
            visibility.status = .partial
            visibility.error = ordering.error ?? "nonintrusiveReorderingUnavailable"
            visibility.movedCount = ordering.movedCount
            visibility.deferredIDs = ordering.deferredIDs
        }
        return visibility
    }

    private struct VerificationFailure: Error { }

    private func observedIDs(_ observations: [DiscoveredItem]) -> [String] {
        observations.compactMap { item in
            guard item.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            return ItemRegistry.observationID(item)
        }
    }

    private struct VisibilityDiagnostic {
        var observations: [DiscoveredItem]
        var snapshot: RegistrySnapshot
        var hidden: Set<String>
        var hasUnverifiedTargets: Bool
    }

    /// Post-activation inventory is diagnostic. A changed/ambiguous row must
    /// never revoke an accepted filter, even during an explicit settings apply.
    private func diagnoseVisibilityEligibility(_ observations: [DiscoveredItem], document: LayoutDocument,
                                       hidden: Set<String>, token: UInt64) throws -> VisibilityDiagnostic? {
        guard token == generation else { return nil }
        let snapshot = try ItemRegistry.reconcile(observations, with: document)
        let unverified = snapshot.items.contains { item in
            let target = item.entry.bundleID.hasPrefix("com.apple.")
                ? ItemRegistry.systemVisibilityTarget(for: item.entry) : item.entry.bundleID
            return item.availability != .absent && !item.canSetVisibility && target.map(hidden.contains) == true
        }
        return VisibilityDiagnostic(observations: observations, snapshot: snapshot,
                            hidden: hidden, hasUnverifiedTargets: unverified)
    }

    private func perform(_ document: LayoutDocument, revealed: Bool, allowReordering: Bool,
                         currentVisibilityLayout: LayoutDocument?, intent: VisibilityRequestIntent, token: UInt64) async -> LayoutApplyReport {
        var report = LayoutApplyReport(status: .superseded, visibilityApplied: false, snapshot: nil,
                                       observedOrder: [], movedCount: 0, deferredIDs: [], error: nil,
                                       fallbackError: nil, unverifiedSystemTargets: [])
        guard token == generation else { return report }
        do {
            let document = try document.validated()
            var hidden: Set<String> = []
            // Automatic callers cannot release or rebuild any active restriction,
            // regardless of stale/missing layout metadata or failed diagnostics.
            if !intent.permitsRelease, await backend.hasActiveVisibilityRestriction() {
                report.visibilityApplied = true
                let observations = try await backend.discover()
                guard token == generation else { return report }
                report.snapshot = try ItemRegistry.reconcile(observations, with: document)
                report.observedOrder = observedIDs(observations)
                report.visibilityWarnings = await backend.visibilityWarnings()
                report.status = .applied
                return report
            }
            if !revealed, !allowReordering, let currentVisibilityLayout,
               await backend.hasActiveVisibilityRestriction() {
                do {
                    let observations = try await backend.discover()
                    guard token == generation else { return report }
                    let snapshot = try ItemRegistry.reconcile(observations, with: document)
                    let warnings = await backend.visibilityWarnings()
                    if VisibilityRefreshPolicy.canKeepCurrentAssertion(applied: currentVisibilityLayout,
                                                                       current: document, snapshot: snapshot,
                                                                       failedSystemTargets: Set(warnings.map(\.target))) {
                        report.visibilityWarnings = warnings
                        report.snapshot = snapshot
                        report.observedOrder = observedIDs(observations)
                        report.visibilityApplied = true
                        report.status = .applied
                        return report
                    }
                } catch {
                    // A read-only check cannot invalidate the existing filter.
                    report.visibilityApplied = true
                    throw error
                }
            }
            // Eligibility needs a pre-change inventory only when this request
            // could hide an application. Revealing everything can be followed
            // by a single discovery of the resulting state.
            if !revealed && document.entries.contains(where: { $0.group == .hidden }) {
                // A prior assertion can remove its own targets from discovery.
                // Reveal first, then derive the next allow-list from a full
                // inventory instead of mistaking absent hidden icons for gone.
                if await backend.hasActiveVisibilityRestriction() {
                    try await backend.setHiddenApplications([], intent: intent)
                    guard token == generation else { return report }
                }
                let before = try await backend.discover()
                guard token == generation else { return report }
                let beforeSnapshot = try ItemRegistry.reconcile(before, with: document)
                report.snapshot = beforeSnapshot
                report.observedOrder = observedIDs(before)
                hidden = ItemRegistry.eligibleHiddenApplications(in: beforeSnapshot)
            }
            try await backend.setHiddenApplications(hidden, intent: intent)
            // A later inventory read cannot undo an acknowledged visibility
            // request. Record it before any diagnostic work can throw.
            report.visibilityApplied = true
            report.visibilityWarnings = await backend.visibilityWarnings()
            guard token == generation else { return report }
            var observations = try await backend.discover()
            guard token == generation else { return report }
            var snapshot = try ItemRegistry.reconcile(observations, with: document)
            report.snapshot = snapshot
            report.observedOrder = observedIDs(observations)
            func observedHiddenSystemTargets(in snapshot: RegistrySnapshot) -> Set<String> {
                Set(snapshot.items.compactMap { item -> String? in
                    guard item.availability == .available,
                          let target = ItemRegistry.systemVisibilityTarget(for: item.entry),
                          hidden.contains(target),
                          !report.visibilityWarnings.contains(where: { $0.target == target }) else { return nil }
                    return target
                })
            }
            var remainingSystemRows = observedHiddenSystemTargets(in: snapshot)
            if !remainingSystemRows.isEmpty {
                // Assessment activation can precede the menu bar's redraw.
                // Check once more for diagnostics, without replacing the filter.
                try await Task.sleep(for: .milliseconds(300))
                guard token == generation else { return report }
                observations = try await backend.discover()
                guard token == generation else { return report }
                snapshot = try ItemRegistry.reconcile(observations, with: document)
                report.snapshot = snapshot
                report.observedOrder = observedIDs(observations)
                remainingSystemRows = observedHiddenSystemTargets(in: snapshot)
            }
            if !remainingSystemRows.isEmpty {
                // AX presence alone is not evidence that the icon is visible.
                // Replacing the assertion here exposes every hidden icon briefly.
                report.unverifiedSystemTargets = remainingSystemRows.sorted()
            }
            guard let checked = try diagnoseVisibilityEligibility(observations, document: document, hidden: hidden, token: token) else { return report }
            if checked.hasUnverifiedTargets {
                report.snapshot = checked.snapshot
                report.observedOrder = observedIDs(checked.observations)
                report.visibilityApplied = !checked.hidden.isEmpty
                report.status = .partial
                report.error = "Visibility eligibility could not be verified; accepted filter preserved."
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
                    guard let checked = try diagnoseVisibilityEligibility(observations, document: document, hidden: hidden, token: token) else { return report }
                    if checked.hasUnverifiedTargets {
                        report.snapshot = checked.snapshot
                        report.observedOrder = observedIDs(checked.observations)
                        report.status = .partial
                        report.error = "Visibility eligibility could not be verified; accepted filter preserved."
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
            // Errors report the failed operation; they do not request a reveal.
            // The driver keeps any previous assertion when preflight fails.
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
