import XCTest
@testable import OrganizerCore

final class LayoutDraftTests: XCTestCase {
    private var original: LayoutDocument {
        LayoutDocument(entries: [LayoutEntry(id: "a", bundleID: "org.a", name: "A"),
                                 LayoutEntry(id: "b", bundleID: "org.b", name: "B")])
    }

    func testReorderGroupAndPreferencesRemainUncommittedUntilOK() throws {
        var draft = LayoutDraft(original)
        draft.value = try LayoutEditor.move("b", to: .hidden, at: 0, in: draft.value)
        draft.value.hideDelay = 12
        draft.value.launchAtLogin = true
        XCTAssertEqual(draft.committed, original)
        XCTAssertTrue(draft.hasChanges)
        draft.cancel()
        XCTAssertEqual(draft.value, original)
        XCTAssertFalse(draft.hasChanges)
    }

    func testCancelAfterAcceptedEditRestoresLastOKNotInitialLaunch() throws {
        var draft = LayoutDraft(original)
        draft.value = try LayoutEditor.move("b", to: .visible, at: 0, in: draft.value)
        let accepted = draft.value
        draft.accept(accepted)
        draft.value.hideDelay = 20
        draft.cancel()
        XCTAssertEqual(draft.value, accepted)
        XCTAssertEqual(draft.value.entries.map(\.id), ["b", "a"])
        XCTAssertFalse(draft.hasChanges)
    }

    func testLifecycleRefreshPreservesDraftAndUpdatesCancelBaseline() {
        var draft = LayoutDraft(original)
        draft.value.hideDelay = 17
        var refreshed = original
        refreshed.entries.append(LayoutEntry(id: "c", bundleID: "org.c", name: "C"))
        draft.updateCommitted(refreshed, preservingChanges: true)
        XCTAssertEqual(draft.value.hideDelay, 17)
        XCTAssertEqual(draft.value.entries.last?.id, "c")
        XCTAssertEqual(draft.committed, refreshed)
        draft.cancel()
        XCTAssertEqual(draft.value, refreshed)
    }

    func testNewLinkedIconFollowsDraftVisibilityWithoutChangingCommittedGroup() throws {
        var draft = LayoutDraft(original)
        draft.value = try LayoutEditor.move("a", to: .hidden, at: 0, in: draft.value)
        var refreshed = original
        refreshed.entries.append(LayoutEntry(id: "a2", bundleID: "org.a", name: "A2"))
        draft.updateCommitted(refreshed, preservingChanges: true)
        XCTAssertEqual(draft.value.entries.last?.group, .hidden)
        XCTAssertEqual(draft.committed.entries.last?.group, .visible)
        XCTAssertNoThrow(try draft.value.validated())
    }

    func testNewSystemRowKeepsObservedNeighborsDuringUnsavedEdit() throws {
        var draft = LayoutDraft(original)
        draft.value.hideDelay = 12
        var refreshed = original
        refreshed.entries.insert(LayoutEntry(id: "system-position:input", bundleID: "com.apple.TextInputMenuAgent",
                                            name: "Input Sources"), at: 1)
        draft.updateCommitted(refreshed, preservingChanges: true)
        XCTAssertEqual(draft.value.entries.map(\.id), ["a", "system-position:input", "b"])
        XCTAssertEqual(draft.value.hideDelay, 12)
    }
}
