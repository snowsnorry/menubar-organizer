import XCTest
@testable import OrganizerCore

private actor IntegrationBackend: LayoutBackend {
    var items: [DiscoveredItem]
    var hidden = Set<String>()
    init(_ items: [DiscoveredItem]) { self.items = items }
    func discover() -> [DiscoveredItem] { items }
    func setHiddenApplications(_ bundleIDs: Set<String>, intent: VisibilityRequestIntent) { hidden = bundleIDs }
    func moveItem(id: String, before targetID: String) {
        guard let index = items.firstIndex(where: { ItemRegistry.key(bundleID: $0.bundleID!, identifier: $0.identifier) == id }) else { return }
        let item = items.remove(at: index)
        guard let target = items.firstIndex(where: { ItemRegistry.key(bundleID: $0.bundleID!, identifier: $0.identifier) == targetID }) else { return }
        items.insert(item, at: target)
    }
}

@MainActor
final class CoreIntegrationTests: XCTestCase {
    private func item(_ bundle: String) -> DiscoveredItem {
        DiscoveredItem(bundleID: bundle, identifier: "status", name: bundle)
    }

    func testSavedHiddenGroupSurvivesRestartAndNewApplicationStaysVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(url: directory.appendingPathComponent("layout.json"))
        let first = try ItemRegistry.reconcile([item("org.saved")], with: store.load().document)
        let desired = try LayoutEditor.move(first.items[0].id, to: .hidden, at: 0, in: first.layout)
        try store.save(desired)

        let relaunched = try LayoutStore(url: store.url).load().document
        let backend = IntegrationBackend([item("org.new"), item("org.saved")])
        let coordinator = LayoutCoordinator(backend: backend)
        let report = await coordinator.apply(relaunched, intent: .userSettings)
        XCTAssertEqual(report.snapshot?.layout.entries.first(where: { $0.bundleID == "org.saved" })?.group, .hidden)
        XCTAssertEqual(report.snapshot?.layout.entries.first(where: { $0.bundleID == "org.new" })?.group, .visible)
        let hidden = await backend.hidden
        XCTAssertEqual(hidden, ["org.saved"])

        var reveal = RevealController(delay: relaunched.hideDelay)
        XCTAssertTrue(reveal.toggle(now: 10).contains(.showHidden))
        _ = await coordinator.apply(relaunched, revealed: true, intent: .userSettings)
        let revealed = await backend.hidden
        XCTAssertTrue(revealed.isEmpty)
        let timer = try XCTUnwrap(reveal.timerToken)
        _ = reveal.setMenuOpen(true, now: 12)
        XCTAssertTrue(reveal.timerFired(token: timer, now: 20).isEmpty)
        _ = reveal.setMenuOpen(false, now: 21)
        XCTAssertEqual(reveal.deadline, 26)
        XCTAssertTrue(reveal.timerFired(token: try XCTUnwrap(reveal.timerToken), now: 26).contains(.hideHidden))
        _ = await coordinator.apply(relaunched, intent: .userSettings)
        let collapsed = await backend.hidden
        XCTAssertEqual(collapsed, ["org.saved"])
    }

    func testRecoveredConfigurationNeverReappliesLostHiddenPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("layout.json")
        let broken = Data("{\"entries\": [unfinished".utf8)
        try broken.write(to: url)
        let recovered = try LayoutStore(url: url).load()
        guard case .recoveredCorruption(let backup) = recovered.status else { return XCTFail("Expected recovery") }
        XCTAssertEqual(try Data(contentsOf: backup), broken)
        let backend = IntegrationBackend([item("org.app")])
        let report = await LayoutCoordinator(backend: backend).apply(recovered.document, intent: .userSettings)
        XCTAssertEqual(report.snapshot?.layout.entries.first?.group, .visible)
        let hidden = await backend.hidden
        XCTAssertTrue(hidden.isEmpty)
    }
}
