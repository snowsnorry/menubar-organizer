import XCTest
@testable import OrganizerCore

private actor FakeLayoutBackend: LayoutBackend {
    enum Failure: Error { case unavailable }
    var items: [DiscoveredItem]
    var visibility: [Set<String>] = []
    var moves: [(String, String)] = []
    var ignoreMoves = false
    var failMoveAt: Int?
    var failVisibility = false
    var blockNextVisibility = false
    var blocked: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    var events: [String] = []
    var discoveryCount = 0
    var failingDiscoveries: Set<Int> = []
    var additions: [Int: [DiscoveredItem]] = [:]
    var omitHidden = false
    var omitHiddenAfterDiscovery: Int?
    var currentHidden: Set<String> = []
    var warnings: [VisibilityWarning] = []
    func configureWarnings(_ warnings: [VisibilityWarning]) { self.warnings = warnings }
    func visibilityWarnings() -> [VisibilityWarning] { warnings.filter { currentHidden.contains($0.target) } }

    init(_ items: [DiscoveredItem]) { self.items = items }
    func configure(ignoreMoves: Bool = false, failVisibility: Bool = false, block: Bool = false, failMoveAt: Int? = nil) {
        self.failMoveAt = failMoveAt
        self.ignoreMoves = ignoreMoves; self.failVisibility = failVisibility; blockNextVisibility = block
    }
    func omitHiddenFromDiscovery() { omitHidden = true }
    func omitHiddenStartingWithDiscovery(_ count: Int) { omitHiddenAfterDiscovery = count }
    func addOnDiscovery(_ number: Int, items: [DiscoveredItem]) { additions[number] = items }
    func failDiscoveries(_ numbers: Set<Int>) { failingDiscoveries = numbers }
    func discover() throws -> [DiscoveredItem] {
        events.append("discover")
        discoveryCount += 1
        if failingDiscoveries.contains(discoveryCount) { throw Failure.unavailable }
        items.append(contentsOf: additions[discoveryCount] ?? [])
        let shouldOmit = omitHidden || (omitHiddenAfterDiscovery.map { discoveryCount >= $0 } ?? false)
        return shouldOmit ? items.filter { !currentHidden.contains($0.bundleID ?? "") } : items
    }
    func hasActiveVisibilityRestriction() async -> Bool { !currentHidden.isEmpty }
    func setHiddenApplications(_ bundleIDs: Set<String>) async throws {
        visibility.append(bundleIDs); events.append("visibility")
        if blockNextVisibility {
            blockNextVisibility = false
            await withCheckedContinuation { continuation in
                blocked = continuation
                entered?.resume(); entered = nil
            }
        }
        if failVisibility { throw Failure.unavailable }
        currentHidden = bundleIDs
    }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func unblock() { blocked?.resume(); blocked = nil }
    func moveItem(id: String, before targetID: String) throws {
        try moveItem(id: id, relativeTo: targetID, placement: .before)
    }
    func moveItem(id: String, relativeTo targetID: String, placement: ItemMovePlacement) throws {
        moves.append((id, targetID)); events.append("move")
        if moves.count == failMoveAt { throw Failure.unavailable }
        guard !ignoreMoves else { return }
        let source = items.firstIndex { key($0) == id }!
        let item = items.remove(at: source)
        let target = items.firstIndex { key($0) == targetID }!
        items.insert(item, at: target + (placement == .after ? 1 : 0))
    }
    func observedIDs() -> [String] { items.map(key) }
    func moveCount() -> Int { moves.count }
    func visibilityRequests() -> [Set<String>] { visibility }
    func operationEvents() -> [String] { events }
    private func key(_ item: DiscoveredItem) -> String {
        ItemRegistry.observationID(item)!
    }
}

@MainActor
final class LayoutCoordinatorTests: XCTestCase {
    private func item(_ name: String, accessible: Bool = true) -> DiscoveredItem {
        DiscoveredItem(bundleID: "org.\(name)", identifier: name, name: name, isDirectlyAccessible: accessible)
    }
    private func document(_ items: [DiscoveredItem], hidden: Set<String> = []) -> LayoutDocument {
        LayoutDocument(entries: items.map {
            LayoutEntry(id: ItemRegistry.key(bundleID: $0.bundleID!, identifier: $0.identifier),
                        bundleID: $0.bundleID!, name: $0.name,
                        group: hidden.contains($0.name) ? .hidden : .visible)
        })
    }

    func testLegacyWarningDoesNotRevealOtherAppsOrRetryOnPassiveRefresh() async throws {
        let app = item("a")
        let vpn = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil, name: "VPN",
            positionTableKey: "status:com.apple.systemuiserver::com.apple.menuextra.vpn")
        let initial = try ItemRegistry.reconcile([app, vpn], with: LayoutDocument())
        let appHidden = try LayoutEditor.move(ItemRegistry.observationID(app)!, to: .hidden, at: 0, in: initial.layout)
        let saved = try LayoutEditor.move(ItemRegistry.vpnPositionID, to: .hidden, at: 1, in: appHidden)
        let backend = FakeLayoutBackend([app, vpn])
        await backend.omitHiddenFromDiscovery()
        let warning = VisibilityWarning(target: "legacy-extra:com.apple.menuextra.vpn", reason: "legacyExtraVerificationFailed")
        await backend.configureWarnings([warning])
        let coordinator = LayoutCoordinator(backend: backend)
        let first = await coordinator.apply(saved, allowReordering: false)
        XCTAssertEqual(first.status, .applied)
        XCTAssertTrue(first.visibilityApplied)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.visibilityWarnings, [warning])
        XCTAssertTrue(first.unverifiedSystemTargets.isEmpty)
        let refresh = await coordinator.apply(saved, allowReordering: false, currentVisibilityLayout: saved)
        XCTAssertEqual(refresh.visibilityWarnings, [warning])
        let beforeReveal = await backend.visibilityRequests()
        let targets: Set<String> = ["org.a", warning.target]
        XCTAssertEqual(beforeReveal, [targets])
        let reveal = await coordinator.apply(saved, revealed: true, allowReordering: false)
        XCTAssertTrue(reveal.visibilityWarnings.isEmpty)
        let collapse = await coordinator.apply(saved, allowReordering: false)
        XCTAssertEqual(collapse.status, .applied)
        XCTAssertEqual(collapse.visibilityWarnings, [warning])
        let afterCollapse = await backend.visibilityRequests()
        XCTAssertEqual(afterCollapse, [targets, [], targets])
    }

    func testReapplyRevealsBeforeDiscoveringHiddenIcon() async {
        let a = item("a")
        let backend = FakeLayoutBackend([a])
        await backend.omitHiddenFromDiscovery()
        let coordinator = LayoutCoordinator(backend: backend)
        let saved = document([a], hidden: ["a"])
        let first = await coordinator.apply(saved, allowReordering: false)
        let second = await coordinator.apply(saved, allowReordering: false)
        let visibility = await backend.visibilityRequests()
        XCTAssertEqual(first.status, .applied)
        XCTAssertEqual(second.status, .applied)
        XCTAssertEqual(visibility, [["org.a"], [], ["org.a"]])
    }

    func testReapplyKeepsVerifiedCurrentFilter() async {
        let a = item("a")
        let backend = FakeLayoutBackend([a])
        await backend.omitHiddenFromDiscovery()
        let coordinator = LayoutCoordinator(backend: backend)
        let saved = document([a], hidden: ["a"])
        _ = await coordinator.apply(saved, allowReordering: false)
        let second = await coordinator.apply(saved, allowReordering: false,
                                             currentVisibilityLayout: saved)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(second.status, .applied)
        XCTAssertTrue(second.visibilityApplied)
        XCTAssertEqual(requests, [["org.a"]])
    }

    func testChangedHiddenLayoutStillReplacesCurrentFilter() async {
        let a = item("a")
        let b = item("b")
        let backend = FakeLayoutBackend([a, b])
        await backend.omitHiddenFromDiscovery()
        let coordinator = LayoutCoordinator(backend: backend)
        let old = document([a, b], hidden: ["a"])
        let changed = document([a, b], hidden: ["a", "b"])
        _ = await coordinator.apply(old, allowReordering: false)
        let second = await coordinator.apply(changed, allowReordering: false,
                                             currentVisibilityLayout: old)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(second.status, .applied)
        XCTAssertEqual(requests, [["org.a"], [], ["org.a", "org.b"]])
    }

    func testReapplyKeepsFilterWhenSystemAXRowRemains() async throws {
        let bluetooth = DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil,
            name: "Bluetooth", positionTableKey: "module:Bluetooth")
        let backend = FakeLayoutBackend([bluetooth])
        let coordinator = LayoutCoordinator(backend: backend)
        let initial = try ItemRegistry.reconcile([bluetooth], with: LayoutDocument())
        let hidden = try LayoutEditor.move(initial.items[0].id, to: .hidden, at: 0, in: initial.layout)
        _ = await coordinator.apply(hidden, allowReordering: false)
        let second = await coordinator.apply(hidden, allowReordering: false,
                                             currentVisibilityLayout: hidden)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(second.status, .applied)
        XCTAssertEqual(requests, [["system-item:1"]])
    }

    func testSystemAXRowDoesNotReplaceAcceptedVisibilityFilter() async throws {
        let bluetooth = DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil,
            name: "Bluetooth", positionTableKey: "module:Bluetooth")
        let backend = FakeLayoutBackend([bluetooth])
        let initial = try ItemRegistry.reconcile([bluetooth], with: LayoutDocument())
        let hidden = try LayoutEditor.move(initial.items[0].id, to: .hidden, at: 0, in: initial.layout)
        let report = await LayoutCoordinator(backend: backend).apply(hidden, allowReordering: false)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(report.status, .applied)
        XCTAssertTrue(report.visibilityApplied)
        XCTAssertEqual(report.unverifiedSystemTargets, ["system-item:1"])
        XCTAssertEqual(requests, [["system-item:1"]])
    }

    func testSystemAXRowDoesNotRevealHiddenApplication() async throws {
        let bluetooth = DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil,
            name: "Bluetooth", positionTableKey: "module:Bluetooth")
        let app = item("hidden")
        let backend = FakeLayoutBackend([bluetooth, app])
        await backend.omitHiddenFromDiscovery()
        let initial = try ItemRegistry.reconcile([bluetooth, app], with: LayoutDocument())
        let withSystemHidden = try LayoutEditor.move(initial.items[0].id, to: .hidden, at: 0, in: initial.layout)
        let saved = try LayoutEditor.move(initial.items[1].id, to: .hidden, at: 1, in: withSystemHidden)

        let report = await LayoutCoordinator(backend: backend).apply(saved, allowReordering: false)

        XCTAssertEqual(report.status, .applied)
        XCTAssertTrue(report.visibilityApplied)
        XCTAssertEqual(report.unverifiedSystemTargets, ["system-item:1"])
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["system-item:1", "org.hidden"]])
    }

    func testReordersWithinEachGroupWithoutForcingGroupBoundary() async {
        let a = item("a"), b = item("b"), c = item("c"), d = item("d")
        let backend = FakeLayoutBackend([d, b, c, a])
        let coordinator = LayoutCoordinator(backend: backend)
        let requested = document([a, b, c, d], hidden: ["c", "d"])
        let report = await coordinator.apply(requested)
        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(report.movedCount, 2)
        let order = await backend.observedIDs()
        XCTAssertEqual(order, document([c, d, a, b]).entries.map(\.id))
        let events = await backend.operationEvents()
        XCTAssertEqual(events, ["discover", "visibility", "discover", "move", "discover", "move", "discover"])
    }

    func testStartupRestoreMovesSavedOrderBeforeHidingItems() async {
        let a = item("a"), b = item("b"), c = item("c")
        let backend = FakeLayoutBackend([c, b, a])
        await backend.omitHiddenFromDiscovery()
        let saved = document([a, b, c], hidden: ["b"])

        let report = await LayoutCoordinator(backend: backend).restoreSavedLayout(saved)
        let order = await backend.observedIDs()
        let visibility = await backend.visibilityRequests()

        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(order, document([a, c, b]).entries.map(\.id))
        XCTAssertEqual(visibility, [[], ["org.b"]])
    }

    func testStartupRestoreStillHidesItemsWhenReorderingFails() async {
        let a = item("a"), b = item("b"), c = item("c")
        let backend = FakeLayoutBackend([c, b, a])
        await backend.configure(failMoveAt: 1)
        let saved = document([a, b, c], hidden: ["b"])

        let report = await LayoutCoordinator(backend: backend).restoreSavedLayout(saved)
        let visibility = await backend.visibilityRequests()

        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.visibilityApplied)
        XCTAssertEqual(visibility.last, ["org.b"])
    }

    func testFirstToLastRotationUsesOneVerifiedMove() async {
        let a = item("a"), b = item("b"), c = item("c"), d = item("d")
        let backend = FakeLayoutBackend([a, b, c, d])
        let desired = document([b, c, d, a])
        let report = await LayoutCoordinator(backend: backend).apply(desired)
        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertEqual(report.observedOrder, desired.entries.map(\.id))
        let events = await backend.operationEvents()
        XCTAssertEqual(events, ["visibility", "discover", "move", "discover"])
    }

    func testUnrealizedAfterMoveStopsAndFailsOpenWithoutRetry() async {
        let a = item("a"), b = item("b"), c = item("c")
        let backend = FakeLayoutBackend([a, b, c])
        await backend.configure(ignoreMoves: true)
        let report = await LayoutCoordinator(backend: backend).apply(document([b, c, a]))
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertNotNil(report.error)
        let count = await backend.moveCount()
        XCTAssertEqual(count, 1)
        let visibility = await backend.visibilityRequests()
        XCTAssertEqual(visibility.last, [])
        XCTAssertEqual(report.observedOrder, document([a, b, c]).entries.map(\.id))
    }

    func testDisabledReorderingStillAppliesVisibilityWithoutSendingMoves() async {
        let a = item("a"), b = item("b"), c = item("c")
        let backend = FakeLayoutBackend([b, a, c])
        let desired = document([a, b, c], hidden: ["c"])
        let report = await LayoutCoordinator(backend: backend).apply(desired, allowReordering: false)
        XCTAssertEqual(report.status, .applied)
        XCTAssertNil(report.error)
        XCTAssertEqual(report.movedCount, 0)
        XCTAssertEqual(report.observedOrder, document([b, a, c]).entries.map(\.id))
        let events = await backend.operationEvents()
        XCTAssertFalse(events.contains("move"))
        let visibility = await backend.visibilityRequests()
        XCTAssertEqual(visibility, [Set(["org.c"])])
    }

    func testDisabledReorderingDoesNotClaimAnAlreadyMatchingOrderIsDeferred() async {
        let a = item("a"), b = item("b")
        let backend = FakeLayoutBackend([a, b])
        let report = await LayoutCoordinator(backend: backend).apply(document([a, b]), allowReordering: false)
        XCTAssertEqual(report.status, .applied)
        XCTAssertNil(report.error)
        XCTAssertTrue(report.deferredIDs.isEmpty)
        let count = await backend.moveCount()
        XCTAssertEqual(count, 0)
    }

    func testUnrealizedMoveStopsAndFailsOpenWithoutRetry() async {
        let a = item("a"), b = item("b")
        let backend = FakeLayoutBackend([b, a])
        await backend.configure(ignoreMoves: true)
        let report = await LayoutCoordinator(backend: backend).apply(document([a, b], hidden: ["a"]))
        // Different groups need no move; exercise same-group order explicitly.
        XCTAssertEqual(report.status, .applied)
        let failed = await LayoutCoordinator(backend: backend).apply(document([a, b]))
        XCTAssertEqual(failed.status, .partial)
        XCTAssertNotNil(failed.error)
        let moves = await backend.moveCount()
        XCTAssertEqual(moves, 1)
        let visibility = await backend.visibilityRequests()
        XCTAssertEqual(visibility.last, [])
    }

    func testFailureAfterOneMoveReportsPartialActualOrder() async {
        let a = item("a"), b = item("b"), c = item("c")
        let backend = FakeLayoutBackend([c, b, a])
        await backend.configure(failMoveAt: 2)
        let report = await LayoutCoordinator(backend: backend).apply(document([a, b, c]))
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertNotNil(report.error)
        XCTAssertEqual(report.observedOrder, document([a, c, b]).entries.map(\.id))
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests.last, [])
    }

    func testFailedReorderDoesNotUndoSuccessfulHiding() async {
        let a = item("a"), b = item("b"), c = item("c")
        let backend = FakeLayoutBackend([a, b, c])
        await backend.configure(ignoreMoves: true)
        await backend.omitHiddenFromDiscovery()
        let report = await LayoutCoordinator(backend: backend)
            .apply(document([b, a, c], hidden: ["c"]))
        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.visibilityApplied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [Set(["org.c"])])
    }

    func testSingleFallbackBundleIdentityCanReorder() async {
        let fallback = DiscoveredItem(bundleID: "org.fallback", identifier: nil, name: "fallback")
        let other = item("other")
        let backend = FakeLayoutBackend([other, fallback])
        let desired = document([fallback, other])
        let report = await LayoutCoordinator(backend: backend).apply(desired)
        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertTrue(report.deferredIDs.isEmpty)
        let order = await backend.observedIDs()
        XCTAssertEqual(order, desired.entries.map(\.id))
    }

    func testOverflowAbsentAmbiguousFallbackAndSystemAreDeferred() async {
        let overflow = item("overflow", accessible: false)
        let duplicate = item("duplicate")
        let fallback = DiscoveredItem(bundleID: "org.fallback", identifier: nil, name: "fallback")
        let system = DiscoveredItem(bundleID: "com.apple.system", identifier: "system", name: "system")
        let unsupported = DiscoveredItem(bundleID: "org.unsupported", identifier: "u", name: "u", isSupported: false)
        let desired = document([overflow, duplicate, fallback, system, unsupported, item("absent")])
        let backend = FakeLayoutBackend([system, duplicate, unsupported, fallback, fallback, duplicate, overflow])
        let report = await LayoutCoordinator(backend: backend).apply(desired)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(Set(report.deferredIDs), Set(desired.entries.map(\.id)))
        let count = await backend.moveCount()
        XCTAssertEqual(count, 0)
    }

    func testDeliberatelyHiddenAbsenceDoesNotOscillateVisibility() async {
        let a = item("a")
        let backend = FakeLayoutBackend([a])
        await backend.omitHiddenFromDiscovery()
        let report = await LayoutCoordinator(backend: backend).apply(document([a], hidden: ["a"]))
        XCTAssertEqual(report.status, .applied)
        XCTAssertTrue(report.deferredIDs.isEmpty)
        XCTAssertTrue(report.observedOrder.isEmpty)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a"]])
    }

    func testTimeMachineReorderIsAppliedAfterBecomingVisible() async throws {
        let timeMachine = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "Time Machine", positionTableKey: "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        let app = item("app")
        let backend = FakeLayoutBackend([timeMachine, app])
        let document = LayoutDocument(entries: [
            LayoutEntry(id: ItemRegistry.observationID(app)!, bundleID: "org.app", name: "app"),
            LayoutEntry(id: ItemRegistry.timeMachinePositionID, bundleID: "com.apple.systemuiserver", name: "Time Machine")
        ])
        let report = await LayoutCoordinator(backend: backend).apply(document)
        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(report.movedCount, 1)
        let observed = await backend.observedIDs()
        XCTAssertEqual(observed, document.entries.map(\.id))
    }

    func testTimeMachineHideUsesLegacyBackendOnlyForExactPositionID() async throws {
        let timeMachine = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "Time Machine", positionTableKey: "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        let backend = FakeLayoutBackend([timeMachine])
        await backend.omitHiddenFromDiscovery()
        let initial = try ItemRegistry.reconcile([timeMachine], with: LayoutDocument())
        let hidden = try LayoutEditor.move(ItemRegistry.timeMachinePositionID, to: .hidden, at: 0, in: initial.layout)
        let report = await LayoutCoordinator(backend: backend).apply(hidden, allowReordering: false)
        XCTAssertEqual(report.status, .applied)
        XCTAssertTrue(report.visibilityApplied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["legacy-extra:com.apple.menuextra.TimeMachine"]])
    }

    func testDelayedTimeMachineDisappearanceKeepsFilterActive() async throws {
        let timeMachine = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "Time Machine", positionTableKey: "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        let backend = FakeLayoutBackend([timeMachine])
        await backend.omitHiddenStartingWithDiscovery(3)
        let initial = try ItemRegistry.reconcile([timeMachine], with: LayoutDocument())
        let hidden = try LayoutEditor.move(ItemRegistry.timeMachinePositionID, to: .hidden, at: 0, in: initial.layout)
        let report = await LayoutCoordinator(backend: backend).apply(hidden, allowReordering: false)
        XCTAssertEqual(report.status, .applied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["legacy-extra:com.apple.menuextra.TimeMachine"]])
    }

    func testStaleTimeMachineAXRowDoesNotRevealOtherHiddenApplications() async throws {
        let timeMachine = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "Time Machine", positionTableKey: "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        let grammarly = item("grammarly")
        let backend = FakeLayoutBackend([timeMachine, grammarly])
        let initial = try ItemRegistry.reconcile([timeMachine, grammarly], with: LayoutDocument())
        let withTimeMachineHidden = try LayoutEditor.move(ItemRegistry.timeMachinePositionID,
            to: .hidden, at: 0, in: initial.layout)
        let hidden = try LayoutEditor.move(ItemRegistry.observationID(grammarly)!,
            to: .hidden, at: 1, in: withTimeMachineHidden)
        let report = await LayoutCoordinator(backend: backend).apply(hidden, allowReordering: false)
        XCTAssertEqual(report.status, .applied)
        XCTAssertTrue(report.visibilityApplied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["legacy-extra:com.apple.menuextra.TimeMachine", "org.grammarly"]])
    }

    func testReadOnlySystemUIServerSiblingsDoNotCancelTimeMachineFilter() async throws {
        let timeMachine = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "Time Machine", positionTableKey:
                "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        let vpn = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "VPN", isSupported: false, presentationID: "vpn")
        let siri = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "Siri", isSupported: false, presentationID: "siri",
            isOmittedFromSettings: true)
        let backend = FakeLayoutBackend([timeMachine, vpn, siri])
        let initial = try ItemRegistry.reconcile([timeMachine, vpn, siri], with: LayoutDocument())
        let hidden = try LayoutEditor.move(ItemRegistry.timeMachinePositionID,
            to: .hidden, at: 0, in: initial.layout)
        let report = await LayoutCoordinator(backend: backend).apply(hidden, allowReordering: false)
        XCTAssertEqual(report.status, .applied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["legacy-extra:com.apple.menuextra.TimeMachine"]])
    }

    func testUnknownOwnerAfterVisibilityKeepsRequestedItemsHidden() async {
        let a = item("a")
        let backend = FakeLayoutBackend([a])
        await backend.addOnDiscovery(2, items: [DiscoveredItem(bundleID: nil, identifier: nil, name: "unknown")])
        let report = await LayoutCoordinator(backend: backend).apply(document([a], hidden: ["a"]))
        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(report.snapshot?.unknownOwnerCount, 1)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a"]])
    }

    func testUnknownOwnerBeforeVisibilityAllowsHiding() async {
        let a = item("a")
        let unknown = DiscoveredItem(bundleID: nil, identifier: nil, name: "unknown")
        let backend = FakeLayoutBackend([a, unknown])
        let report = await LayoutCoordinator(backend: backend)
            .apply(document([a], hidden: ["a"]), allowReordering: false)
        XCTAssertEqual(report.status, .applied)
        XCTAssertTrue(report.visibilityApplied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a"]])
    }

    func testEligibilityChangeKeepsOtherHiddenApplicationActive() async {
        let a = item("a"), b = item("b")
        let backend = FakeLayoutBackend([a, b])
        await backend.addOnDiscovery(2, items: [a])

        let report = await LayoutCoordinator(backend: backend)
            .apply(document([a, b], hidden: ["a", "b"]), allowReordering: false)

        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.visibilityApplied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a", "org.b"], ["org.b"]])
    }

    func testAmbiguousSiblingAfterMoveImmediatelyRevealsAndStops() async {
        let a = item("a"), b = item("b")
        let backend = FakeLayoutBackend([b, a])
        await backend.addOnDiscovery(3, items: [a])
        let report = await LayoutCoordinator(backend: backend).apply(document([a, b], hidden: ["a", "b"]))
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.movedCount, 1)
        XCTAssertEqual(report.observedOrder, document([a, b, a]).entries.map(\.id))
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a", "org.b"], ["org.b"]])
    }

    func testVisibilityFailureIsReportedWithoutRequestingReveal() async {
        let backend = FakeLayoutBackend([item("a")])
        await backend.configure(failVisibility: true)
        let report = await LayoutCoordinator(backend: backend).apply(document([item("a")], hidden: ["a"]))
        XCTAssertEqual(report.status, .failed)
        XCTAssertNotNil(report.error)
        XCTAssertNil(report.fallbackError)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a"]])
    }

    func testPostHideDiscoveryFailurePreservesAcceptedRestriction() async {
        let a = item("a")
        let backend = FakeLayoutBackend([a])
        await backend.failDiscoveries([2, 3])

        let report = await LayoutCoordinator(backend: backend)
            .apply(document([a], hidden: ["a"]), allowReordering: false)

        XCTAssertEqual(report.status, .failed)
        XCTAssertNotNil(report.error)
        XCTAssertTrue(report.visibilityApplied)
        let active = await backend.hasActiveVisibilityRestriction()
        XCTAssertTrue(active)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a"]])
    }

    func testRejectedReplacementDoesNotClearPreviousRestriction() async {
        let a = item("a")
        let layout = document([a], hidden: ["a"])
        let backend = FakeLayoutBackend([a])
        await backend.omitHiddenFromDiscovery()
        let coordinator = LayoutCoordinator(backend: backend)
        _ = await coordinator.apply(layout, allowReordering: false)
        await backend.configure(failVisibility: true)

        let report = await coordinator.apply(document([a]), revealed: true, allowReordering: false)

        XCTAssertEqual(report.status, .failed)
        let active = await backend.hasActiveVisibilityRestriction()
        XCTAssertTrue(active)
        let requests = await backend.visibilityRequests()
        // The explicit reveal fails; the error handler must not repeat it.
        XCTAssertEqual(requests, [["org.a"], []])
    }

    func testDelayedSystemVerificationFailurePreservesAllHiddenTargets() async {
        let app = item("a")
        let bluetooth = DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil,
            name: "Bluetooth", positionTableKey: "module:Bluetooth")
        let layout = LayoutDocument(entries: [
            document([app], hidden: ["a"]).entries[0],
            LayoutEntry(id: "system-position:module:Bluetooth", bundleID: "com.apple.controlcenter",
                name: "Bluetooth", group: .hidden)
        ])
        let backend = FakeLayoutBackend([app, bluetooth])
        await backend.failDiscoveries([3])

        let report = await LayoutCoordinator(backend: backend).apply(layout, allowReordering: false)

        XCTAssertEqual(report.status, .failed)
        XCTAssertTrue(report.visibilityApplied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a", "system-item:1"]])
    }

    func testRefreshAfterPostHideDiscoveryFailureDoesNotReleaseRestriction() async {
        let a = item("a")
        let layout = document([a], hidden: ["a"])
        let backend = FakeLayoutBackend([a])
        await backend.omitHiddenFromDiscovery()
        await backend.failDiscoveries([2, 3, 4])
        let coordinator = LayoutCoordinator(backend: backend)

        let first = await coordinator.apply(layout, allowReordering: false)
        let refresh = await coordinator.apply(layout, allowReordering: false, currentVisibilityLayout: layout)
        let recovered = await coordinator.apply(layout, allowReordering: false, currentVisibilityLayout: layout)

        XCTAssertTrue(first.visibilityApplied)
        XCTAssertTrue(refresh.visibilityApplied)
        XCTAssertEqual(recovered.status, .applied)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a"]])
    }

    func testLatestRequestWaitsForBlockedOperationAndWins() async {
        let a = item("a"), b = item("b")
        let backend = FakeLayoutBackend([b, a])
        await backend.configure(block: true)
        let coordinator = LayoutCoordinator(backend: backend)
        let first = Task { await coordinator.apply(document([a, b], hidden: ["a", "b"])) }
        await backend.waitUntilBlocked()
        let latest = Task { await coordinator.apply(document([b, a]), revealed: true) }
        // Wait for the actor to enqueue the latest request before releasing the
        // first operation; no sleeps or wall-clock race assumptions.
        while await coordinator.requestGeneration < 2 { await Task.yield() }
        await backend.unblock()
        let firstReport = await first.value
        let finalReport = await latest.value
        XCTAssertEqual(firstReport.status, .superseded)
        XCTAssertEqual(finalReport.status, .applied)
        let count = await backend.moveCount()
        XCTAssertEqual(count, 0)
        let requests = await backend.visibilityRequests()
        XCTAssertEqual(requests, [["org.a", "org.b"], []])
    }

    func testCancelDrainsPendingOperationWithoutIssuingReorderOrNewVisibility() async {
        let a = item("a"), b = item("b")
        let backend = FakeLayoutBackend([b, a])
        await backend.configure(block: true)
        let coordinator = LayoutCoordinator(backend: backend)
        let applying = Task { await coordinator.apply(document([a, b])) }
        await backend.waitUntilBlocked()
        let cancelling = Task { await coordinator.cancelPending() }
        while await coordinator.requestGeneration < 2 { await Task.yield() }
        await backend.unblock()
        await cancelling.value
        let report = await applying.value
        let events = await backend.operationEvents()
        XCTAssertEqual(report.status, .superseded)
        XCTAssertEqual(events, ["visibility"])
    }

    func testRevealedLayoutDiscoversOnlyAfterApplyingVisibility() async {
        let a = item("a"), b = item("b")
        let backend = FakeLayoutBackend([a, b])
        let report = await LayoutCoordinator(backend: backend).apply(document([a, b], hidden: ["a"]), revealed: true)
        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(report.observedOrder, document([a, b]).entries.map(\.id))
        let events = await backend.operationEvents()
        XCTAssertEqual(events, ["visibility", "discover"])
    }
}
