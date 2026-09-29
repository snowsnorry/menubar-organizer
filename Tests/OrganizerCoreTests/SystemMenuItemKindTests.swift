import XCTest
@testable import OrganizerCore

final class SystemMenuItemKindTests: XCTestCase {
    func testChildMetadataTakesPriorityOverHost() {
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.controlcenter", metadata: ["com.apple.menuextra.battery"]), .battery)
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.MenuBarAgent", metadata: ["com.apple.menuextra.clock"]), .clock)
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.systemuiserver", metadata: ["TimeMachineMenuExtra.TMMenuExtraHost"]), .timeMachine)
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.controlcenter", metadata: ["com.apple.controlcenter", "com.apple.controlcenter.WiFi"]), .wifi)
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.MenuBarAgent", metadata: ["com.apple.controlcenter", "com.apple.menuextra.battery"]), .battery)
    }
    func testLocalizedNamesAndDedicatedAgents() {
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.MenuBarAgent", metadata: ["Пункт управления"]), .controlCenter)
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.TextInputMenuAgent", metadata: []), .inputSource)
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.WeatherMenu", metadata: []), .weather)
    }
    func testUnknownHostDoesNotInventAnIconName() {
        XCTAssertNil(SystemMenuItemKind.identify(bundleID: "com.apple.systemuiserver", metadata: []))
        XCTAssertNil(SystemMenuItemKind.identify(bundleID: "third.party", metadata: ["Time Machine"]))
    }

    func testWiFiPositionKeyRequiresExactIdentifier() {
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata: ["com.apple.controlcenter", "com.apple.controlcenter.WiFi"]), ["module:WiFi"])
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata: ["com.apple.menuextra.wifi", "Wi‑Fi, connected, 3 bars"]), ["module:WiFi"])
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata: ["WiFi", "com.apple.controlcenter.WiFi"]), ["module:WiFi"])
        XCTAssertTrue(SystemMenuItemKind.modulePositionKeys(metadata: ["com.apple.controlcenter.WiFi.Other"]).isEmpty)
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata: ["com.apple.controlcenter.WiFi", "Battery"]), ["module:WiFi", "module:Battery"])
    }

    func testFocusStatusItemUsesItsSavedModuleIdentity() {
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata:
            ["com.apple.menuextra.focusmode", "Focus"]), ["module:FocusModes"])
        XCTAssertTrue(SystemMenuItemKind.modulePositionKeys(metadata:
            ["com.apple.menuextra.focusmode.settings"]).isEmpty)
    }

    func testReadOnlyModulesUseStablePositionKeys() {
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata:
            ["com.apple.menuextra.audiovideo", "Audio and Video Controls"]),
            ["module:AudioVideoModule"])
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata:
            ["com.apple.menuextra.airdrop", "AirDrop"]), ["module:AirDrop"])
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata:
            ["com.apple.menuextra.user", "User"]), ["module:UserSwitcher"])
        XCTAssertTrue(SystemMenuItemKind.modulePositionKeys(metadata:
            ["com.apple.menuextra.user.settings"]).isEmpty)
    }

    func testReadOnlyModulesHaveDistinctSymbolsIndependentOfDisplayName() {
        XCTAssertEqual(SystemMenuItemKind.symbol(forPositionID:
            "system-position:module:AudioVideoModule"), "video.badge.waveform")
        XCTAssertEqual(SystemMenuItemKind.symbol(forPositionID:
            "system-position:module:AirDrop"), "dot.radiowaves.left.and.right")
        XCTAssertEqual(SystemMenuItemKind.symbol(forPositionID:
            "system-position:module:UserSwitcher"), "person.crop.circle")
        XCTAssertNil(SystemMenuItemKind.symbol(forPositionID:
            "system-position:module:FocusModes"))
    }

    func testPinnedControlCenterRequiresChildEvidence() {
        XCTAssertTrue(SystemMenuItemKind.isControlCenterStatusItem(metadata: ["com.apple.controlcenter", "Пункт управления"]))
        XCTAssertTrue(SystemMenuItemKind.isControlCenterStatusItem(metadata: ["com.apple.controlcenter.BentoBox"]))
        XCTAssertFalse(SystemMenuItemKind.isControlCenterStatusItem(metadata: ["com.apple.controlcenter", "Wi-Fi"]))
    }

    func testVPNAndKeyboardBrightnessIdentifiers() {
        XCTAssertEqual(SystemMenuItemKind.identify(bundleID: "com.apple.systemuiserver",
            metadata: ["com.apple.menuextra.vpn"]), .vpn)
        XCTAssertEqual(SystemMenuItemKind.modulePositionKeys(metadata:
            ["com.apple.controlcenter.KeyboardBrightness"]), ["module:KeyboardBrightness"])
    }

    func testLegacyExtrasAreMatchedIndividually() {
        let extras = ["/System/Library/CoreServices/Menu Extras/TimeMachine.menu",
                      "/System/Library/CoreServices/Menu Extras/VPN.menu"]
        XCTAssertEqual(SystemMenuItemKind.legacyPositionKey(metadata: ["VPN"], configuredExtras: extras),
                       "status:com.apple.systemuiserver::com.apple.menuextra.vpn")
        XCTAssertEqual(SystemMenuItemKind.legacyPositionKey(
            metadata: ["TimeMachineMenuExtra.TMMenuExtraHost"], configuredExtras: extras),
                       "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        XCTAssertEqual(SystemMenuItemKind.legacyPositionKey(
            metadata: ["TimeMachineMenuExtra, Backup Status"], configuredExtras: extras),
                       "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        XCTAssertNil(SystemMenuItemKind.legacyPositionKey(metadata: ["System Menu"], configuredExtras: extras))
        XCTAssertNil(SystemMenuItemKind.legacyPositionKey(metadata: ["VPN"], configuredExtras: []))
        XCTAssertNil(SystemMenuItemKind.legacyPositionKey(metadata: ["VPN", "Time Machine"], configuredExtras: extras))
    }

    func testUnlabelledTimeMachineIsResolvedFromCompleteOwnerInventory() {
        let extras = ["/System/Library/CoreServices/Menu Extras/TimeMachine.menu",
                      "/System/Library/CoreServices/Menu Extras/VPN.menu"]
        let rows = [[], ["Siri", "Siri"], ["VPN"]]
        XCTAssertEqual(SystemMenuItemKind.legacyPositionKeys(metadataByChild: rows,
            configuredExtras: extras), [
                "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine",
                nil,
                "status:com.apple.systemuiserver::com.apple.menuextra.vpn"
            ])
        XCTAssertEqual(SystemMenuItemKind.legacyPositionKeys(metadataByChild: [[], [], ["VPN"]],
            configuredExtras: extras), [nil, nil,
                "status:com.apple.systemuiserver::com.apple.menuextra.vpn"])
        XCTAssertEqual(SystemMenuItemKind.legacyPositionKeys(metadataByChild: rows,
            configuredExtras: extras + ["/tmp/Unknown.menu"]), [nil, nil,
                "status:com.apple.systemuiserver::com.apple.menuextra.vpn"])
    }
}
