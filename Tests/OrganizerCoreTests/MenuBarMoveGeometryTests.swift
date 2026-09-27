import Foundation
import CoreGraphics
import XCTest
@testable import OrganizerCore

final class MenuBarMoveGeometryTests: XCTestCase {
    func testSystemCrossingIsDistinctFromEditableEndpoints() throws {
        let geometry = try XCTUnwrap(MenuBarMoveGeometry(
            sourceFrame: CGRect(x: 1762, y: 3.5, width: 36, height: 24),
            targetFrame: CGRect(x: 1679, y: 3.5, width: 36, height: 24)))
        let language = CGRect(x: 1718, y: 3.5, width: 36, height: 24)
        XCTAssertTrue(geometry.canCrossSystemItem(frame: language, bundleID: "com.apple.TextInputMenuAgent"))
        XCTAssertFalse(geometry.canCrossSystemItem(frame: language, bundleID: nil))
        XCTAssertFalse(geometry.canCrossSystemItem(frame: language, bundleID: "third.party"))
        XCTAssertFalse(geometry.canCrossSystemItem(frame: language.offsetBy(dx: 0, dy: 30), bundleID: "com.apple.test"))
        XCTAssertFalse(geometry.canCrossSystemItem(frame: CGRect(x: 1600, y: 3.5, width: 200, height: 24), bundleID: "com.apple.test"))
        XCTAssertFalse(geometry.canCrossSystemItem(frame: .null, bundleID: "com.apple.test"))
    }
    func testProvenInsertionEndpointAndCompleteCorridor() throws {
        let geometry = try XCTUnwrap(MenuBarMoveGeometry(
            sourceFrame: CGRect(x: 1575, y: 3.5, width: 36, height: 24),
            targetFrame: CGRect(x: 1539, y: 3.5, width: 38, height: 24)))
        XCTAssertEqual(geometry.source, CGPoint(x: 1593, y: 15.5))
        XCTAssertEqual(geometry.destination, CGPoint(x: 1548.5, y: 15.5))
        XCTAssertEqual(geometry.corridor, CGRect(x: 1547.5, y: 3.5, width: 46.5, height: 24))
        XCTAssertTrue(geometry.corridor.contains(CGPoint(x: 1550, y: 15.5)))
    }

    func testCorridorIncludesBothRowsWhenEndpointsDifferSlightly() throws {
        let geometry = try XCTUnwrap(MenuBarMoveGeometry(
            sourceFrame: CGRect(x: 124, y: 1, width: 24, height: 24),
            targetFrame: CGRect(x: 100, y: 0, width: 24, height: 24)))
        XCTAssertEqual(geometry.destination.y, 12)
        XCTAssertEqual(geometry.source.y, 13)
        XCTAssertEqual(geometry.corridor.minY, 0)
        XCTAssertEqual(geometry.corridor.maxY, 25)
    }

    func testInvalidGeometryAndSameCenterAreRejected() {
        let target = CGRect(x: 100, y: 0, width: 24, height: 24)
        for source in [CGRect(x: 100, y: 0, width: 24, height: 24),
                       CGRect(x: 124, y: 3, width: 24, height: 24),
                       CGRect(x: 124, y: 0, width: -24, height: 24),
                       CGRect(x: 124, y: 0, width: 0, height: 24),
                       CGRect(x: CGFloat.infinity, y: 0, width: 24, height: 24)] {
            XCTAssertNil(MenuBarMoveGeometry(sourceFrame: source, targetFrame: target))
        }
        XCTAssertNil(MenuBarMoveGeometry(sourceFrame: target, targetFrame: .null))
    }
    func testRightwardAfterInsertionUsesRightQuarterAndCrossesSystemItems() throws {
        let geometry = try XCTUnwrap(MenuBarMoveGeometry(
            sourceFrame: CGRect(x: 100, y: 0, width: 24, height: 24),
            targetFrame: CGRect(x: 200, y: 0, width: 40, height: 24), placement: .after))
        XCTAssertEqual(geometry.source.x, 112)
        XCTAssertEqual(geometry.destination.x, 230)
        XCTAssertEqual(geometry.corridor, CGRect(x: 111, y: 0, width: 120, height: 24))
        XCTAssertTrue(geometry.canCrossSystemItem(frame: CGRect(x: 150, y: 0, width: 24, height: 24), bundleID: "com.apple.test"))
        XCTAssertFalse(geometry.canCrossSystemItem(frame: CGRect(x: 220, y: 0, width: 24, height: 24), bundleID: "com.apple.test"))
    }

    func testBothPlacementsAllowEitherDirection() throws {
        let left = CGRect(x: 100, y: 0, width: 24, height: 24)
        let right = CGRect(x: 200, y: 0, width: 40, height: 24)
        XCTAssertEqual(MenuBarMoveGeometry(sourceFrame: left, targetFrame: right)?.destination.x, 210)
        XCTAssertEqual(MenuBarMoveGeometry(sourceFrame: right, targetFrame: left, placement: .after)?.destination.x, 118)
    }

}
