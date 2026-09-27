import XCTest
@testable import OrganizerCore

final class PositionTableKeyResolverTests: XCTestCase {
    private func item(_ bundle: String, name: String, identifier: String? = nil) -> DiscoveredItem {
        DiscoveredItem(bundleID: bundle, identifier: identifier, name: name)
    }

    func testRazerOwnerNameMatchesWhenTableUsesNameInsteadOfBundleID() throws {
        let razer = item("com.razer.appengine.app", name: "Razer")
        let keys: Set<String> = ["status:Razer::Item-0", "status:com.pilotmoon.popclip::Item-0"]
        XCTAssertEqual(try PositionTableKeyResolver.resolve(item: razer, inventory: [razer], tableKeys: keys),
                       "status:Razer::Item-0")
    }

    func testBundleIDTakesPriorityOverName() throws {
        let app = item("com.example.app", name: "Example", identifier: "main")
        let keys: Set<String> = ["status:com.example.app::main", "status:Example::old"]
        XCTAssertEqual(try PositionTableKeyResolver.resolve(item: app, inventory: [app], tableKeys: keys),
                       "status:com.example.app::main")
    }

    func testNameFallbackRejectsAmbiguousOwnerAndMultipleIcons() {
        let a = item("com.example.one", name: "Shared")
        let b = item("com.example.two", name: "Shared")
        let keys: Set<String> = ["status:Shared::Item-0"]
        XCTAssertThrowsError(try PositionTableKeyResolver.resolve(item: a, inventory: [a, b], tableKeys: keys))
        XCTAssertThrowsError(try PositionTableKeyResolver.resolve(item: a, inventory: [a, a], tableKeys: keys))
    }

    func testNameFallbackRejectsSeveralTableEntries() {
        let app = item("com.example.app", name: "Example")
        let keys: Set<String> = ["status:Example::first", "status:Example::second"]
        XCTAssertThrowsError(try PositionTableKeyResolver.resolve(item: app, inventory: [app], tableKeys: keys))
    }

    func testNameFallbackRejectsDifferentExplicitIdentifier() {
        let app = item("com.example.app", name: "Example", identifier: "current")
        let keys: Set<String> = ["status:Example::old"]
        XCTAssertThrowsError(try PositionTableKeyResolver.resolve(item: app, inventory: [app], tableKeys: keys))
    }
}
