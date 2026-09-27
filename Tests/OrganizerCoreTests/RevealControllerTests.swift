import XCTest
@testable import OrganizerCore

final class RevealControllerTests: XCTestCase {
    func testDesiredVisibilityDoesNotClaimBackendSuccess() {
        var controller = RevealController()
        XCTAssertNil(controller.observedVisibility)
        XCTAssertEqual(controller.toggle(now: 10), [.showHidden, .schedule(deadline: 15, token: 1)])
        XCTAssertEqual(controller.state, .revealed)
        XCTAssertNil(controller.observedVisibility)
        controller.confirmVisibility(.visible)
        XCTAssertEqual(controller.timerFired(token: 1, now: 15), [.cancelTimer, .hideHidden])
        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertEqual(controller.observedVisibility, .visible)
        controller.confirmVisibility(.hidden)
        XCTAssertEqual(controller.observedVisibility, .hidden)
    }

    func testRapidToggleRejectsEarlierRevealTimer() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        XCTAssertEqual(controller.toggle(now: 0.1), [.cancelTimer, .hideHidden])
        XCTAssertEqual(controller.toggle(now: 0.2), [.showHidden, .schedule(deadline: 5.2, token: 2)])
        XCTAssertEqual(controller.timerFired(token: 1, now: 5), [])
        XCTAssertEqual(controller.state, .revealed)
        XCTAssertEqual(controller.deadline, 5.2)
        XCTAssertEqual(controller.timerFired(token: 2, now: 5.2), [.cancelTimer, .hideHidden])
        XCTAssertEqual(controller.timerFired(token: 2, now: 6), [])
    }

    func testActivityRestartsFullInactivityInterval() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        XCTAssertEqual(controller.noteActivity(now: 4), [.cancelTimer, .schedule(deadline: 9, token: 2)])
        XCTAssertEqual(controller.timerFired(token: 1, now: 5), [])
        XCTAssertEqual(controller.timerFired(token: 2, now: 8), [.schedule(deadline: 9, token: 2)])
        XCTAssertEqual(controller.timerFired(token: 2, now: 9), [.cancelTimer, .hideHidden])
        XCTAssertEqual(controller.noteActivity(now: 10), [])
    }

    func testOverlappingHoverAndMenuPauseUntilBothEnd() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        XCTAssertEqual(controller.setPointerInInteractionRegion(true, now: 4), [.cancelTimer])
        XCTAssertEqual(controller.setMenuOpen(true, now: 5), [])
        XCTAssertEqual(controller.timerFired(token: 1, now: 6), [])
        XCTAssertEqual(controller.setPointerInInteractionRegion(false, now: 7), [])
        XCTAssertNil(controller.deadline)
        XCTAssertEqual(controller.noteActivity(now: 40), [])
        XCTAssertEqual(controller.setMenuOpen(false, now: 100), [.schedule(deadline: 105, token: 2)])
        XCTAssertEqual(controller.setMenuOpen(false, now: 101), [])
        XCTAssertEqual(controller.timerFired(token: 2, now: 105), [.cancelTimer, .hideHidden])
    }

    func testMenuAlreadyOpenWhenRevealedNeverSchedulesTimeout() {
        var controller = RevealController()
        _ = controller.setMenuOpen(true, now: 0)
        XCTAssertEqual(controller.toggle(now: 1), [.showHidden])
        XCTAssertNil(controller.timerToken)
        XCTAssertEqual(controller.timerFired(token: 1, now: 100), [])
        XCTAssertEqual(controller.setMenuOpen(false, now: 101), [.schedule(deadline: 106, token: 1)])
    }

    func testDelayChangesRestartFromChangeAndRespectInteraction() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        XCTAssertEqual(controller.setDelay(2, now: 4), [.cancelTimer, .schedule(deadline: 6, token: 2)])
        XCTAssertEqual(controller.timerFired(token: 1, now: 5), [])
        _ = controller.setMenuOpen(true, now: 5)
        XCTAssertEqual(controller.setDelay(10, now: 6), [])
        XCTAssertNil(controller.deadline)
        XCTAssertEqual(controller.setMenuOpen(false, now: 20), [.schedule(deadline: 30, token: 3)])
    }

    func testSuspensionCancelsAndResumeFailsOpenWithFreshInterval() {
        for reason in [RevealController.SuspensionReason.lifecycle, .backendUnavailable, .permissionsUnavailable] {
            var controller = RevealController()
            _ = controller.toggle(now: 0)
            XCTAssertEqual(controller.suspend(reason: reason), [.cancelTimer, .showHidden])
            XCTAssertEqual(controller.state, .suspended(reason))
            XCTAssertNil(controller.deadline)
            XCTAssertEqual(controller.toggle(now: 10), [])
            XCTAssertEqual(controller.timerFired(token: 1, now: 10), [])
            XCTAssertEqual(controller.noteActivity(now: 10), [])
            XCTAssertEqual(controller.resume(now: 100), [.showHidden, .schedule(deadline: 105, token: 2)])
            XCTAssertEqual(controller.timerFired(token: 1, now: 104), [])
            XCTAssertEqual(controller.resume(now: 104), [])
        }
    }

    func testSuspensionPreservesOpenMenuAndObservedVisibility() {
        var controller = RevealController()
        controller.confirmVisibility(.hidden)
        XCTAssertEqual(controller.suspend(reason: .backendUnavailable), [.showHidden])
        _ = controller.setMenuOpen(true, now: 0)
        XCTAssertEqual(controller.resume(now: 5), [.showHidden])
        XCTAssertEqual(controller.observedVisibility, .hidden)
        XCTAssertNil(controller.deadline)
        XCTAssertEqual(controller.setMenuOpen(false, now: 10), [.schedule(deadline: 15, token: 1)])
    }

    func testExplicitHideRecoversFromSuspensionWithoutRevealingAgain() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        _ = controller.suspend(reason: .backendUnavailable)
        XCTAssertEqual(controller.confirmExplicitHide(), [])
        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertEqual(controller.observedVisibility, .hidden)
        XCTAssertNil(controller.deadline)
        XCTAssertEqual(controller.toggle(now: 10), [.showHidden, .schedule(deadline: 15, token: 2)])
    }

    func testDelayBoundsMatchPersistedLayoutPolicy() {
        for invalid in [Double.nan, .infinity, -1, 0, 0.5, 60.1, 100] {
            XCTAssertEqual(RevealController(delay: invalid).delay, 5)
        }
        for valid in [1.0, 5, 60] {
            XCTAssertEqual(RevealController(delay: valid).delay, valid)
        }
        var controller = RevealController(delay: 1)
        _ = controller.toggle(now: 0)
        XCTAssertEqual(controller.setDelay(0, now: 1), [.cancelTimer, .schedule(deadline: 6, token: 2)])
        XCTAssertEqual(controller.delay, 5)
    }

    func testExplicitCollapseWaitsForMenuCloseEvenWhileHovering() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        _ = controller.setPointerInInteractionRegion(true, now: 1)
        _ = controller.setMenuOpen(true, now: 2)
        XCTAssertEqual(controller.toggle(now: 3), [])
        XCTAssertTrue(controller.pendingCollapse)
        XCTAssertEqual(controller.state, .revealed)
        XCTAssertEqual(controller.timerFired(token: 1, now: 10), [])
        XCTAssertEqual(controller.setMenuOpen(false, now: 11), [.hideHidden])
        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertFalse(controller.pendingCollapse)
        XCTAssertNil(controller.deadline)
    }

    func testSecondToggleCancelsDeferredCollapseAndMenuCloseStartsFullDelay() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        _ = controller.setMenuOpen(true, now: 1)
        _ = controller.toggle(now: 2)
        XCTAssertEqual(controller.toggle(now: 3), [])
        XCTAssertFalse(controller.pendingCollapse)
        XCTAssertEqual(controller.setMenuOpen(false, now: 10), [.schedule(deadline: 15, token: 2)])
        XCTAssertEqual(controller.state, .revealed)
    }

    func testSuspensionDiscardsDeferredCollapse() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        _ = controller.setMenuOpen(true, now: 1)
        _ = controller.toggle(now: 2)
        XCTAssertEqual(controller.suspend(reason: .lifecycle), [.showHidden])
        XCTAssertFalse(controller.pendingCollapse)
        XCTAssertEqual(controller.resume(now: 5), [.showHidden])
        XCTAssertEqual(controller.setMenuOpen(false, now: 10), [.schedule(deadline: 15, token: 2)])
    }

    func testHoverAloneDoesNotDeferExplicitCollapse() {
        var controller = RevealController()
        _ = controller.toggle(now: 0)
        _ = controller.setPointerInInteractionRegion(true, now: 1)
        XCTAssertEqual(controller.toggle(now: 2), [.hideHidden])
        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertFalse(controller.pendingCollapse)
    }
}
