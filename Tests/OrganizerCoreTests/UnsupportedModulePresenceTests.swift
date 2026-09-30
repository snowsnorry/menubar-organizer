import XCTest
@testable import OrganizerCore

final class UnsupportedModulePresenceTests: XCTestCase {
    func testKnownModulesAreListedBeforeDiscoveryAndAfterCollapse() {
        let presence = UnsupportedModulePresence()
        XCTAssertEqual(presence.missingKeys(observed: []),
                       ["module:AudioVideoModule", "module:AirDrop", "module:UserSwitcher"])
        let expanded = [
            DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: "Audio and Video Controls", isSupported: false,
                positionTableKey: "module:AudioVideoModule"),
            DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: "AirDrop", isSupported: false, positionTableKey: "module:AirDrop"),
            DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: "User", isSupported: false, positionTableKey: "module:UserSwitcher")
        ]
        XCTAssertTrue(presence.missingKeys(observed: expanded).isEmpty)
        XCTAssertEqual(presence.missingKeys(observed: []),
                       ["module:AudioVideoModule", "module:AirDrop", "module:UserSwitcher"])
    }

    func testObservedModuleDoesNotProduceDuplicateRow() {
        let observed = DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
            name: "AirDrop", positionTableKey: "module:AirDrop")
        XCTAssertEqual(UnsupportedModulePresence().missingKeys(observed: [observed]),
                       ["module:AudioVideoModule", "module:UserSwitcher"])
    }
}
