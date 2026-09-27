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
}
