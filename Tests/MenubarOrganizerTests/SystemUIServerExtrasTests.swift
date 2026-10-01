import XCTest
import OrganizerCore
@testable import MenubarOrganizer

@MainActor
final class SystemUIServerExtrasTests: XCTestCase {
    private let tm = "com.apple.menuextra.TimeMachine"
    private let vpn = "com.apple.menuextra.vpn"

    @MainActor
    private final class Host {
        var receipts: Set<String> = []
        var receiptWriteFails = false
        var loaded: Set<String> = ItemRegistry.legacyExtraBundleIDs
        var rows: Set<String> = ItemRegistry.legacyExtraBundleIDs
        var removeCalls: [String] = []
        var addCalls: [String] = []
        var removeStatus: Int32 = 0
        var failingRemovalID: String?
        var changedHandleAfterFirstRemoval = false
        var failInventoryAfterRemoval = false
        var events: [String] = []
        var addStatus: Int32 = 0
        var staleRemoval = false
        var duplicate = false
        var missingRestoration = false
        var cancelledRemoval = false
        var removeSibling = false
        var unknownSibling = false
        var failGet = false
        var sharedHandle = false
        var inventoryRemovalEvidence: [Set<String>] = []
        var unlabelledTimeMachine = false
        var unsettledScansAfterRemove = 0
        var unidentifiedAfterRemove = false
        let ids = ["com.apple.menuextra.TimeMachine", "com.apple.menuextra.vpn"]

        func makeBackend(available: Bool = true, duplicateBundle: Bool = false) -> SystemUIServerExtras {
            let api = SystemUIServerExtras.API(handle: { id in
                if self.failGet { throw SystemUIServerExtras.Failure.operation(id, -10003) }
                if self.changedHandleAfterFirstRemoval, !self.removeCalls.isEmpty, id == self.ids[1], self.loaded.contains(id) { return 99 }
                return self.loaded.contains(id) ? (self.sharedHandle ? 1 : UInt32(self.ids.firstIndex(of: id)! + 1)) : nil
            }, remove: { handle in
                let id = self.ids[Int(handle) - 1]
                self.removeCalls.append(id)
                self.events.append("remove:" + id)
                self.loaded.remove(id)
                if !self.staleRemoval { self.rows.remove(id) }
                if self.removeSibling {
                    self.loaded = []
                    self.rows = []
                }
                return self.failingRemovalID == id ? -1 : self.removeStatus
            }, add: { url in
                let id = url.lastPathComponent
                self.addCalls.append(id)
                self.events.append("add:" + id)
                if self.addStatus == 0 {
                    self.loaded.insert(id)
                    if !self.missingRestoration { self.rows.insert(id) }
                }
                return self.addStatus
            })
            return SystemUIServerExtras(api: available ? api : nil,
                bundles: Dictionary(uniqueKeysWithValues: ids.map { id in
                    (id, Array(repeating: URL(fileURLWithPath: "/fixture/\(id)"), count: duplicateBundle ? 2 : 1))
                }), inventory: { removed in
                    self.inventoryRemovalEvidence.append(removed)
                    self.events.append("scan")
                    if self.failInventoryAfterRemoval, !self.removeCalls.isEmpty, self.addCalls.isEmpty {
                        throw NativeDiscoveryError.staleGeometry
                    }
                    let ordered = self.rows.sorted()
                    let keys = SystemMenuItemKind.legacyPositionKeys(metadataByChild: ordered.map { id in
                        id == "com.apple.menuextra.TimeMachine" ? [] : ["VPN"]
                    }, configuredExtras: ["/System/Library/CoreServices/Menu Extras/TimeMachine.menu",
                                          "/System/Library/CoreServices/Menu Extras/VPN.menu"], removedExtraIDs: removed)
                    let result = ordered.enumerated().map { index, id in
                        DiscoveredItem(bundleID: "com.apple.systemuiserver",
                            identifier: self.unlabelledTimeMachine ? nil : id, name: id,
                            positionTableKey: self.unlabelledTimeMachine ? keys[index] : "status:com.apple.systemuiserver::\(id)")
                    }
                    if !self.removeCalls.isEmpty, self.addCalls.isEmpty, self.unsettledScansAfterRemove > 0 {
                        self.unsettledScansAfterRemove -= 1
                        if self.unidentifiedAfterRemove {
                            return result + [DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
                                name: "Unsettled", isSupported: false)]
                        }
                        return result + result
                    }
                    if self.unknownSibling {
                        return result + [DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
                            name: "Unknown", isSupported: false)]
                    }
                    return self.duplicate ? result + result : result
                }, pause: {
                    if self.cancelledRemoval { throw CancellationError() }
                }, receiptStore: .init(load: { self.receipts }, save: { ids in
                    if self.receiptWriteFails { throw SystemUIServerExtras.Failure.unavailable }
                    self.receipts = ids
                }))
        }
    }

    func testEachExtraCanBeRemovedAndRestoredWithoutItsSibling() async throws {
        for id in [tm, vpn] {
            let host = Host()
            let backend = host.makeBackend()
            try await backend.setHidden([id])
            XCTAssertEqual(host.loaded, ItemRegistry.legacyExtraBundleIDs.subtracting([id]))
            XCTAssertEqual(host.rows, host.loaded)
            XCTAssertEqual(host.removeCalls, [id])
            XCTAssertTrue(backend.isActive)
            try await backend.setHidden([])
            XCTAssertEqual(host.loaded, ItemRegistry.legacyExtraBundleIDs)
            XCTAssertEqual(host.addCalls, [id])
            XCTAssertFalse(backend.isActive)
        }
    }

    func testStableHideUsesOnePreflightAndOneVerificationForSingleOrBothExtras() async throws {
        for ids: Set<String> in [[tm], [vpn], [tm, vpn]] {
            let host = Host()
            let backend = host.makeBackend()
            try await backend.setHidden(ids)
            XCTAssertEqual(host.events, ["scan"] + ids.sorted().map { "remove:" + $0 } + ["scan"])
            XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs.subtracting(ids))
            let count = host.inventoryRemovalEvidence.count
            try await backend.setHidden(ids)
            XCTAssertEqual(host.inventoryRemovalEvidence.count, count, "An unchanged request needs no extra scan")
            host.events = []
            try await backend.restoreAll()
            XCTAssertEqual(host.events, ids.sorted().map { "add:" + $0 } + ["scan"])
            XCTAssertTrue(backend.removed.isEmpty)
        }
    }

    func testPartialBatchFailureRestoresEveryRemovedExtra() async {
        let host = Host()
        host.failingRemovalID = vpn
        let backend = host.makeBackend()
        do { try await backend.setHidden([tm, vpn]); XCTFail("Expected partial batch failure") } catch { }
        XCTAssertEqual(host.removeCalls, [tm, vpn])
        XCTAssertEqual(host.addCalls, [tm, vpn])
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertFalse(backend.isActive)
    }

    func testChangedHandleStopsBatchAndRestoresEarlierRemoval() async {
        let host = Host()
        host.changedHandleAfterFirstRemoval = true
        let backend = host.makeBackend()
        do { try await backend.setHidden([tm, vpn]); XCTFail("Expected changed identity") } catch { }
        XCTAssertEqual(host.removeCalls, [tm])
        XCTAssertEqual(host.addCalls, [tm])
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertFalse(backend.isActive)
    }

    func testUnavailablePostRemovalInventoryCannotConfirmEmptyOwner() async {
        let host = Host()
        host.failInventoryAfterRemoval = true
        let backend = host.makeBackend()
        do { try await backend.setHidden([tm, vpn]); XCTFail("Expected unavailable AX rollback") } catch { }
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertEqual(host.addCalls, [tm, vpn])
        XCTAssertFalse(backend.isActive)
    }

    func testRestartRecoversBothExtrasFromPersistedReceipts() async throws {
        let host = Host()
        let old = host.makeBackend()
        try await old.setHidden([tm, vpn])
        XCTAssertEqual(host.receipts, [tm, vpn])
        XCTAssertTrue(host.rows.isEmpty)
        let restarted = host.makeBackend()
        XCTAssertEqual(restarted.removed, [tm, vpn])
        try await restarted.setHidden([])
        XCTAssertEqual(host.addCalls, [tm, vpn])
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertTrue(host.receipts.isEmpty)
        XCTAssertFalse(restarted.isActive)
    }

    func testReceiptWriteFailureNeverRemovesAnExtra() async {
        let host = Host()
        host.receiptWriteFails = true
        let backend = host.makeBackend()
        do { try await backend.setHidden([vpn]); XCTFail("Expected persistence failure") } catch { }
        XCTAssertTrue(host.removeCalls.isEmpty)
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
    }

    func testLaunchRecoveryPropagatesFailureAndRetriesPersistedReceipts() async throws {
        let host = Host()
        host.receipts = [vpn]
        host.loaded = [tm]
        host.rows = [tm]
        host.addStatus = -1
        let extras = host.makeBackend()
        let driver = VisibilityDriver(legacyExtras: extras, assessmentApply: { _ in }, observeApplications: false)
        do { try await driver.recoverLegacyExtras(); XCTFail("Launch must reject incomplete inventory") } catch { }
        XCTAssertEqual(host.receipts, [vpn])
        host.addStatus = 0
        try await driver.recoverLegacyExtras()
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertTrue(host.receipts.isEmpty)
    }

    func testFailedRestorationRetainsReceiptAcrossRestart() async throws {
        let host = Host()
        let backend = host.makeBackend()
        try await backend.setHidden([vpn])
        host.addStatus = -1
        do { try await backend.restoreAll(); XCTFail("Expected add failure") } catch { }
        XCTAssertEqual(host.receipts, [vpn])
        host.addStatus = 0
        let restarted = host.makeBackend()
        try await restarted.restoreAll()
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertTrue(host.receipts.isEmpty)
    }

    func testUnavailableAPIAndAmbiguousIdentityNeverRemove() async {
        for mode in 0..<4 {
            let host = Host()
            host.duplicate = mode == 1
            host.unknownSibling = mode == 3
            let backend = host.makeBackend(available: mode != 0, duplicateBundle: mode == 2)
            do { try await backend.setHidden([tm]); XCTFail("Expected fail-open") } catch { }
            XCTAssertTrue(host.removeCalls.isEmpty)
            XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        }
    }

    func testTransientAXAmbiguityAfterRemovalDoesNotRestoreSuccessfullyHiddenVPN() async throws {
        for unidentified in [false, true] {
            let host = Host()
            host.unsettledScansAfterRemove = 2
            host.unidentifiedAfterRemove = unidentified
            let backend = host.makeBackend()
            try await backend.setHidden([vpn])
            XCTAssertEqual(host.rows, [tm])
            XCTAssertEqual(host.removeCalls, [vpn])
            XCTAssertTrue(host.addCalls.isEmpty)
            XCTAssertEqual(host.unsettledScansAfterRemove, 0)
            XCTAssertTrue(backend.isActive)
            XCTAssertEqual(host.inventoryRemovalEvidence.first, [])
            XCTAssertEqual(host.inventoryRemovalEvidence.last, [vpn])
            try await backend.restoreAll()
            XCTAssertEqual(host.inventoryRemovalEvidence.last, [])
            XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        }
    }

    func testVPNStaysHiddenWithUnlabelledTimeMachineAndStaleConfiguredPreferences() async throws {
        let host = Host()
        host.unlabelledTimeMachine = true
        let backend = host.makeBackend()
        try await backend.setHidden([vpn])
        XCTAssertEqual(host.loaded, [tm])
        XCTAssertTrue(host.addCalls.isEmpty)
        XCTAssertEqual(backend.discoveryRemovedExtraIDs, [vpn])
        try await backend.restoreAll()
        XCTAssertEqual(host.loaded, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertTrue(backend.discoveryRemovedExtraIDs.isEmpty)
    }

    func testPersistentAXAmbiguityAfterRemovalStillRestoresVPN() async {
        let host = Host()
        host.unsettledScansAfterRemove = 20
        let backend = host.makeBackend()
        do { try await backend.setHidden([vpn]); XCTFail("Expected fail-open rollback") } catch { }
        XCTAssertEqual(host.unsettledScansAfterRemove, 10)
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertEqual(host.addCalls, [vpn])
        XCTAssertFalse(backend.isActive)
    }

    func testGetFailureAndSharedHandlesNeverAuthorizeRemoval() async {
        for shared in [false, true] {
            let host = Host()
            host.sharedHandle = shared
            host.failGet = !shared
            let backend = host.makeBackend()
            do { try await backend.setHidden([tm]); XCTFail("Expected identity failure") } catch { }
            XCTAssertTrue(host.removeCalls.isEmpty)
            XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        }
    }

    func testTerminationRestorationKeepsReceiptUntilAXVerification() async throws {
        let host = Host()
        let backend = host.makeBackend()
        try await backend.setHidden([vpn])
        backend.restoreBestEffort()
        XCTAssertEqual(host.loaded, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertTrue(backend.isActive)
        try await backend.restoreAll()
        XCTAssertFalse(backend.isActive)
        XCTAssertEqual(host.addCalls, [vpn])
    }

    func testRemoveErrorIncludingPartialMutationRestoresTarget() async {
        let host = Host()
        host.removeStatus = -1
        let backend = host.makeBackend()
        do { try await backend.setHidden([tm]); XCTFail("Expected remove error") } catch { }
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertEqual(host.addCalls, [tm])
        XCTAssertFalse(backend.isActive)
    }

    func testStaleAXRowRollsBackInsteadOfClaimingSuccess() async {
        let host = Host()
        host.staleRemoval = true
        let backend = host.makeBackend()
        do { try await backend.setHidden([tm]); XCTFail("Expected verification error") } catch { }
        XCTAssertEqual(host.loaded, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertEqual(host.addCalls, [tm])
        XCTAssertFalse(backend.isActive)
    }

    func testCancellationDuringVerificationStillRestores() async {
        let host = Host()
        host.staleRemoval = true
        host.cancelledRemoval = true
        let backend = host.makeBackend()
        do { try await backend.setHidden([vpn]); XCTFail("Expected cancellation") } catch { }
        XCTAssertEqual(host.loaded, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertEqual(host.addCalls, [vpn])
    }

    func testUnexpectedSiblingDisappearanceRollsBackBothExtras() async {
        let host = Host()
        host.removeSibling = true
        let backend = host.makeBackend()
        do { try await backend.setHidden([tm]); XCTFail("Expected verification error") } catch { }
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertEqual(Set(host.addCalls), ItemRegistry.legacyExtraBundleIDs)
        XCTAssertFalse(backend.isActive)
    }

    func testAddErrorRetainsReceiptAndCanBeRetried() async throws {
        let host = Host()
        let backend = host.makeBackend()
        try await backend.setHidden([tm])
        host.addStatus = -2
        do { try await backend.restoreAll(); XCTFail("Expected add error") } catch { }
        XCTAssertTrue(backend.removed.contains(tm))
        host.addStatus = 0
        try await backend.restoreAll()
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertFalse(backend.isActive)
    }

    func testSuccessfulAddRequiresAXReappearance() async throws {
        let host = Host()
        let backend = host.makeBackend()
        try await backend.setHidden([vpn])
        host.missingRestoration = true
        do { try await backend.restoreAll(); XCTFail("Expected verification error") } catch { }
        XCTAssertTrue(backend.removed.contains(vpn))
        host.rows.insert(vpn)
        try await backend.restoreAll()
        XCTAssertFalse(backend.isActive)
        XCTAssertEqual(host.addCalls, [vpn])
    }

    func testLegacyFailurePreservesAssessmentAndRevealCollapseStillWorks() async throws {
        let host = Host()
        host.staleRemoval = true
        var assessmentRequests: [Set<String>] = []
        let driver = VisibilityDriver(legacyExtras: host.makeBackend(), assessmentApply: {
            assessmentRequests.append($0)
        }, observeApplications: false)
        var invalidations = 0
        driver.onInvalidated = { _ in invalidations += 1 }
        let targets: Set<String> = ["org.example.hidden", ItemRegistry.legacyExtraTargetPrefix + vpn]
        try await driver.setHiddenApplications(targets)
        XCTAssertTrue(driver.isActive)
        XCTAssertEqual(assessmentRequests, [["org.example.hidden"]])
        XCTAssertEqual(driver.legacyWarnings, [VisibilityWarning(target: ItemRegistry.legacyExtraTargetPrefix + vpn,
            reason: "legacyExtraVerificationFailed")])
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
        XCTAssertEqual(invalidations, 0)

        try await driver.revealAll(intent: .userToggle)
        XCTAssertFalse(driver.isActive)
        XCTAssertTrue(driver.legacyWarnings.isEmpty)
        try await driver.setHiddenApplications(targets)
        XCTAssertTrue(driver.isActive)
        XCTAssertEqual(assessmentRequests, [["org.example.hidden"], [], ["org.example.hidden"]])
        XCTAssertEqual(invalidations, 0)
    }

    func testLegacyRollbackFailureDoesNotReleaseOtherApplications() async throws {
        let host = Host()
        host.removeStatus = -1
        host.addStatus = -2
        var assessmentRequests: [Set<String>] = []
        let backend = host.makeBackend()
        let driver = VisibilityDriver(legacyExtras: backend, assessmentApply: {
            assessmentRequests.append($0)
        }, observeApplications: false)
        try await driver.setHiddenApplications(["org.example.hidden", ItemRegistry.legacyExtraTargetPrefix + vpn])
        XCTAssertEqual(assessmentRequests, [["org.example.hidden"]])
        XCTAssertTrue(driver.isActive)
        XCTAssertEqual(driver.legacyWarnings.first?.reason, "legacyExtraRecoveryFailed")
        XCTAssertTrue(backend.removed.contains(vpn))
        host.addStatus = 0
        try await driver.revealAll(intent: .userToggle)
        XCTAssertFalse(driver.isActive)
        XCTAssertEqual(host.rows, ItemRegistry.legacyExtraBundleIDs)
    }

    func testAutomaticRequestsCannotReleaseOrReplaceAcceptedFilterOrRestoreLegacyExtras() async throws {
        let host = Host()
        var assessmentRequests: [Set<String>] = []
        let driver = VisibilityDriver(legacyExtras: host.makeBackend(), assessmentApply: {
            assessmentRequests.append($0)
        }, observeApplications: false)
        let targets: Set<String> = ["org.example.hidden", ItemRegistry.legacyExtraTargetPrefix + vpn]
        try await driver.setHiddenApplications(targets)
        for request: Set<String> in [[], targets, ["org.other.hidden"]] {
            do {
                try await driver.setHiddenApplications(request, intent: .automatic)
                XCTFail("Automatic mutation must be rejected")
            } catch VisibilityDriver.DriverError.userActionRequired {}
            XCTAssertTrue(driver.isActive)
            XCTAssertEqual(assessmentRequests, [["org.example.hidden"]])
            XCTAssertTrue(host.addCalls.isEmpty)
            XCTAssertFalse(host.rows.contains(vpn))
        }
        try await driver.revealAll(intent: .userToggle)
        XCTAssertFalse(driver.isActive)
        XCTAssertEqual(assessmentRequests, [["org.example.hidden"], []])
        XCTAssertEqual(host.addCalls, [vpn])
    }

    func testAssessmentFailureStillPropagatesWithoutAttemptingLegacyRemoval() async {
        let host = Host()
        let driver = VisibilityDriver(legacyExtras: host.makeBackend(), assessmentApply: { _ in
            throw VisibilityDriver.DriverError.activationTimedOut
        }, observeApplications: false)
        do {
            try await driver.setHiddenApplications(["org.example.hidden", ItemRegistry.legacyExtraTargetPrefix + vpn])
            XCTFail("Expected assessment failure")
        } catch {
            XCTAssertTrue(error is VisibilityDriver.DriverError)
        }
        XCTAssertTrue(host.removeCalls.isEmpty)
        XCTAssertTrue(driver.legacyWarnings.isEmpty)
    }

}
