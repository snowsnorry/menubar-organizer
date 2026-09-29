import XCTest
@testable import OrganizerCore

final class UnsupportedModulePresenceTests: XCTestCase {
    func testObservedModulesRemainListedAfterCollapseWithoutPositionAccess() {
        var presence = UnsupportedModulePresence()
        let expanded = [
            DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: "Audio and Video Controls", isSupported: false,
                positionTableKey: "module:AudioVideoModule"),
            DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: "AirDrop", isSupported: false, positionTableKey: "module:AirDrop"),
            DiscoveredItem(bundleID: "com.apple.MenuBarAgent", identifier: nil,
                name: "User", isSupported: false, positionTableKey: "module:UserSwitcher")
        ]
        XCTAssertTrue(presence.missingKeys(observed: expanded, configured: nil).isEmpty)
        XCTAssertEqual(presence.missingKeys(observed: [], configured: nil),
                       ["module:AudioVideoModule", "module:AirDrop", "module:UserSwitcher"])
    }

    func testConfiguredModulesAppearBeforeAXDiscoveryAndCanDisappearWhenDisabled() {
        var presence = UnsupportedModulePresence()
        XCTAssertEqual(presence.missingKeys(observed: [], configured: ["module:AudioVideoModule"]),
                       ["module:AudioVideoModule"])
        XCTAssertTrue(presence.missingKeys(observed: [], configured: []).isEmpty)
    }
}
