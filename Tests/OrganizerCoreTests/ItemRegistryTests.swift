import XCTest
@testable import OrganizerCore

final class ItemRegistryTests: XCTestCase {
    private func item(_ bundle: String = "org.app", _ id: String? = nil, accessible: Bool = true) -> DiscoveredItem {
        DiscoveredItem(bundleID: bundle, identifier: id, name: bundle, isDirectlyAccessible: accessible)
    }

    func testNewAppsAreVisibleAndMissingEntriesReturnToTheirSavedGroup() throws {
        let saved = LayoutDocument(entries: [.init(id: "app:org.app", bundleID: "org.app", name: "Old", group: .hidden)])
        let missing = try ItemRegistry.reconcile([item("org.new")], with: saved)
        XCTAssertEqual(missing.items.first?.availability, .absent)
        XCTAssertEqual(missing.layout.entries.last?.group, .visible)
        let returned = try ItemRegistry.reconcile([item()], with: missing.layout)
        XCTAssertEqual(returned.items.first?.availability, .available)
        XCTAssertEqual(ItemRegistry.eligibleHiddenApplications(in: returned), ["org.app"])
    }

    func testOrganizerCanBeReorderedButCannotBeHidden() throws {
        let organizer = item(ItemRegistry.organizerBundleID)
        let snapshot = try ItemRegistry.reconcile([item("org.other"), organizer], with: LayoutDocument())
        let own = try XCTUnwrap(snapshot.items.first { $0.entry.bundleID == ItemRegistry.organizerBundleID })
        XCTAssertTrue(own.canReorder)
        XCTAssertFalse(own.canSetVisibility)
        let reordered = try LayoutEditor.move(own.id, to: .visible, at: 0, in: snapshot.layout)
        XCTAssertEqual(reordered.entries.first?.id, own.id)
        XCTAssertThrowsError(try LayoutEditor.move(own.id, to: .hidden, at: 0, in: reordered))

        let old = LayoutDocument(entries: [LayoutEntry(id: own.id, bundleID: ItemRegistry.organizerBundleID,
            name: "Menubar Organizer", group: .hidden)])
        let recovered = try ItemRegistry.reconcile([organizer], with: old)
        XCTAssertEqual(recovered.layout.entries.first?.group, .visible)
        XCTAssertTrue(ItemRegistry.eligibleHiddenApplications(in: recovered).isEmpty)
    }

    func testOrganizerUsesObservedPositionWhenDiscoveredAndOnNextLaunch() throws {
        let own = item(ItemRegistry.organizerBundleID)
        let observations = [item("org.first"), own, item("org.last")]
        let discovered = try ItemRegistry.reconcile(observations, with: LayoutDocument())
        XCTAssertEqual(discovered.layout.entries.map(\.bundleID),
                       ["org.first", ItemRegistry.organizerBundleID, "org.last"])

        let savedAtEnd = try LayoutEditor.move(discovered.items[1].id, to: .visible, at: 2,
                                               in: discovered.layout)
        let restored = try ItemRegistry.adoptingObservedOrganizerPosition(observations, in: savedAtEnd)
        XCTAssertEqual(restored.entries.map(\.bundleID),
                       ["org.first", ItemRegistry.organizerBundleID, "org.last"])
        XCTAssertEqual(try ReorderPlanner.plan(from: observations.compactMap(ItemRegistry.observationID),
                                               to: restored.entries.map(\.id)), [])
    }

    func testFallbackCollapsesLinkedIconsButDuplicateExplicitIDsAreAmbiguous() throws {
        let linked = try ItemRegistry.reconcile([item(), item("org.app", "")], with: LayoutDocument())
        XCTAssertEqual(linked.items.count, 1)
        XCTAssertEqual(linked.items[0].linkedIconCount, 2)
        XCTAssertFalse(linked.items[0].canReorder)
        let duplicate = try ItemRegistry.reconcile([item("org.app", "one"), item("org.app", "one")], with: LayoutDocument())
        XCTAssertEqual(duplicate.items[0].availability, .ambiguous)
        XCTAssertFalse(duplicate.items[0].canSetVisibility)
    }

    func testAmbiguousSiblingKeepsWholeApplicationVisible() throws {
        var snapshot = try ItemRegistry.reconcile([item("org.app", "one"), item("org.app", "two"), item("org.app", "two")], with: LayoutDocument())
        snapshot.layout = try LayoutEditor.move(snapshot.items[0].id, to: .hidden, at: 0, in: snapshot.layout)
        snapshot = try ItemRegistry.reconcile([item("org.app", "one"), item("org.app", "two"), item("org.app", "two")], with: snapshot.layout)
        XCTAssertTrue(ItemRegistry.eligibleHiddenApplications(in: snapshot).isEmpty)
    }

    func testOverflowDisablesReorderButPreservesVisibilityPreference() throws {
        let original = try ItemRegistry.reconcile([item()], with: LayoutDocument())
        let hidden = try LayoutEditor.move(original.items[0].id, to: .hidden, at: 0, in: original.layout)
        let overflow = try ItemRegistry.reconcile([item(accessible: false)], with: hidden)
        XCTAssertEqual(overflow.items[0].availability, .overflow)
        XCTAssertFalse(overflow.items[0].canReorder)
        XCTAssertEqual(ItemRegistry.eligibleHiddenApplications(in: overflow), ["org.app"])
        let returned = try ItemRegistry.reconcile([item()], with: overflow.layout)
        XCTAssertTrue(returned.items[0].canReorder)
        XCTAssertEqual(returned.layout, hidden)
    }

    func testProtectedAndUnknownOwnersAreNotAddedToPersistentLayout() throws {
        let snapshot = try ItemRegistry.reconcile([item("com.apple.controlcenter"),
            DiscoveredItem(bundleID: nil, identifier: "one", name: "Unknown")], with: LayoutDocument())
        XCTAssertTrue(snapshot.layout.entries.isEmpty)
        XCTAssertEqual(snapshot.items.first?.availability, .unsupported)
        XCTAssertEqual(snapshot.unknownOwnerCount, 1)
    }

    func testCrossGroupMoveCarriesAllLinkedApplicationIconsAndReorderDoesNot() throws {
        let snapshot = try ItemRegistry.reconcile([item("org.app", "a"), item("org.other"), item("org.app", "b")], with: LayoutDocument())
        let hidden = try LayoutEditor.move(snapshot.items[2].id, to: .hidden, at: 0, in: snapshot.layout)
        XCTAssertEqual(hidden.entries(in: .hidden).map(\.id), [snapshot.items[0].id, snapshot.items[2].id])
        XCTAssertEqual(hidden.entries(in: .visible).map(\.bundleID), ["org.other"])
        let reordered = try LayoutEditor.move(snapshot.items[2].id, to: .hidden, at: 0, in: hidden)
        XCTAssertEqual(reordered.entries(in: .hidden).map(\.id), [snapshot.items[2].id, snapshot.items[0].id])
        XCTAssertThrowsError(try LayoutEditor.move(snapshot.items[2].id, to: .visible, at: 8, in: hidden))
    }

    func testDirectUserOrderCanBeAdoptedWithoutMovingAbsentSlots() throws {
        let document = LayoutDocument(entries: ["a", "missing", "b"].map {
            LayoutEntry(id: $0, bundleID: "org.\($0)", name: $0)
        })
        let adopted = try LayoutEditor.adoptObservedOrder(["b", "a"], group: .visible, in: document)
        XCTAssertEqual(adopted.entries.map(\.id), ["b", "missing", "a"])
        XCTAssertThrowsError(try LayoutEditor.adoptObservedOrder(["b", "b"], group: .visible, in: document))
    }

    func testNewSiblingInheritsApplicationWideVisibility() throws {
        let saved = LayoutDocument(entries: [LayoutEntry(id: ItemRegistry.key(bundleID: "org.app", identifier: "a"),
            bundleID: "org.app", name: "App", group: .hidden)])
        let result = try ItemRegistry.reconcile([item("org.app", "a"), item("org.app", "b")], with: saved)
        XCTAssertEqual(result.layout.entries.map(\.group), [.hidden, .hidden])
    }

    func testUnknownOwnerPreventsGlobalHidingAndConflictingSavedOwnerCannotHideAnotherApp() throws {
        let saved = LayoutDocument(entries: [.init(id: "app:org.app", bundleID: "org.app", name: "App", group: .hidden)])
        let unknown = try ItemRegistry.reconcile([item(), .init(bundleID: nil, identifier: nil, name: "Unknown")], with: saved)
        XCTAssertTrue(ItemRegistry.eligibleHiddenApplications(in: unknown).isEmpty)
        let conflicting = LayoutDocument(entries: [.init(id: "app:org.app", bundleID: "org.other", name: "Other", group: .hidden)])
        let result = try ItemRegistry.reconcile([item()], with: conflicting)
        XCTAssertEqual(result.items[0].availability, .unsupported)
        XCTAssertTrue(ItemRegistry.eligibleHiddenApplications(in: result).isEmpty)
    }
    func testSystemPresentationIDsSeparateIconsWithoutPersistingTransientIdentity() throws {
        let observations = [
            item("org.a"),
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Wi-Fi", presentationID: "display2:x100"),
            item("org.b"),
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Clock", presentationID: "display2:x200"),
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Battery", presentationID: "display2:x300")
        ]
        let snapshot = try ItemRegistry.reconcile(observations, with: LayoutDocument())
        XCTAssertEqual(snapshot.items.map(\.entry.name), ["org.a", "Wi-Fi", "org.b", "Clock", "Battery"])
        XCTAssertEqual(Set(snapshot.items.map(\.id)).count, 5)
        let system = snapshot.items.filter { $0.entry.bundleID.hasPrefix("com.apple.") }
        XCTAssertEqual(system.map(\.presentationSlot), [1, 2, 2])
        XCTAssertTrue(system.allSatisfy { !$0.canReorder && !$0.canSetVisibility && $0.linkedIconCount == 1 })
        XCTAssertEqual(snapshot.layout.entries.map(\.bundleID), ["org.a", "org.b"])
        let encoded = String(decoding: try JSONEncoder().encode(snapshot.layout), as: UTF8.self)
        XCTAssertFalse(encoded.contains("display2"))
        XCTAssertFalse(encoded.contains("system-presentation"))
    }

    func testSystemSlotsSurviveDraftReorderHideAndRepeatedPublication() throws {
        let observations = [item("org.a"),
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Wi-Fi", presentationID: "wifi"),
            item("org.b"),
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Clock", presentationID: "clock"),
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Battery", presentationID: "battery")]
        let snapshot = try ItemRegistry.reconcile(observations, with: LayoutDocument())
        let reordered = try LayoutEditor.move("app:org.b", to: .visible, at: 0, in: snapshot.layout)
        let merged = ItemRegistry.mergingDraft(snapshot.items, with: reordered)
        XCTAssertEqual(merged.map(\.entry.name), ["org.b", "Wi-Fi", "org.a", "Clock", "Battery"])
        XCTAssertEqual(ItemRegistry.mergingDraft(merged, with: reordered), merged)
        let hidden = try LayoutEditor.move("app:org.b", to: .hidden, at: 0, in: reordered)
        let hiddenRows = ItemRegistry.mergingDraft(merged, with: hidden)
        XCTAssertEqual(hiddenRows.filter { $0.entry.group == .visible }.map(\.entry.name), ["org.a", "Wi-Fi", "Clock", "Battery"])
        XCTAssertEqual(ItemRegistry.mergingDraft(hiddenRows, with: snapshot.layout).map(\.entry.name),
                       ["org.a", "Wi-Fi", "org.b", "Clock", "Battery"])
    }

    func testPresentationIdentityDoesNotChangeEditableFallbackGrouping() throws {
        let snapshot = try ItemRegistry.reconcile([
            DiscoveredItem(bundleID: "org.app", identifier: nil, name: "First", presentationID: "one"),
            DiscoveredItem(bundleID: "org.app", identifier: nil, name: "Second", presentationID: "two")
        ], with: LayoutDocument())
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.id, "app:org.app")
        XCTAssertEqual(snapshot.items.first?.linkedIconCount, 2)
    }

    func testSystemOnlyInventoryKeepsObservedOrderWhenNoEditableRowsExist() throws {
        let snapshot = try ItemRegistry.reconcile([
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Clock", presentationID: "one"),
            DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil, name: "Battery", presentationID: "two")
        ], with: LayoutDocument())
        XCTAssertEqual(snapshot.items.map(\.entry.name), ["Clock", "Battery"])
        XCTAssertTrue(snapshot.layout.entries.isEmpty)
    }

    func testPositionKeySystemItemCanBeReorderedAndHidden() throws {
        let input = DiscoveredItem(bundleID: "com.apple.TextInputMenuAgent", identifier: nil,
            name: "Input Sources", isSupported: true, presentationID: "old-process:0",
            positionTableKey: "status:com.apple.TextInputMenuAgent::Item-0")
        let snapshot = try ItemRegistry.reconcile([item("org.razer"), input, item("org.next")],
            with: LayoutDocument())
        XCTAssertEqual(snapshot.items.map(\.entry.name), ["org.razer", "Input Sources", "org.next"])
        XCTAssertEqual(snapshot.layout.entries.map(\.name), ["org.razer", "Input Sources", "org.next"])
        XCTAssertTrue(snapshot.items[1].canReorder)
        XCTAssertTrue(snapshot.items[1].canSetVisibility)
        let movedRazer = try LayoutEditor.move("app:org.razer", to: .visible, at: 2, in: snapshot.layout)
        XCTAssertEqual(ItemRegistry.mergingDraft(snapshot.items, with: movedRazer).map(\.entry.name),
                       ["Input Sources", "org.next", "org.razer"])
        let movedSystem = try LayoutEditor.move(snapshot.items[1].id, to: .visible, at: 2, in: snapshot.layout)
        XCTAssertEqual(movedSystem.entries.map(\.name), ["org.razer", "org.next", "Input Sources"])
        let hiddenSystem = try LayoutEditor.move(snapshot.items[1].id, to: .hidden, at: 0, in: snapshot.layout)
        XCTAssertEqual(hiddenSystem.entries(in: .hidden).map(\.id), [snapshot.items[1].id])
        XCTAssertEqual(ItemRegistry.eligibleHiddenApplications(in: try ItemRegistry.reconcile([input], with: hiddenSystem)),
                       ["com.apple.TextInputMenuAgent"])
        var restarted = input
        restarted.presentationID = "new-process:0"
        let refreshed = try ItemRegistry.reconcile([item("org.razer"), item("org.next"), restarted], with: movedSystem)
        XCTAssertEqual(refreshed.layout.entries.map(\.name), ["org.razer", "org.next", "Input Sources"])
    }

    func testTimeMachineCanBeReorderedAndHiddenByExactIdentity() throws {
        let timeMachine = DiscoveredItem(bundleID: "com.apple.systemuiserver", identifier: nil,
            name: "Time Machine", positionTableKey: "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine")
        let initial = try ItemRegistry.reconcile([timeMachine], with: LayoutDocument())
        XCTAssertEqual(initial.items[0].id, ItemRegistry.timeMachinePositionID)
        XCTAssertTrue(initial.items[0].canReorder)
        XCTAssertTrue(initial.items[0].canSetVisibility)
        let hidden = try LayoutEditor.move(ItemRegistry.timeMachinePositionID, to: .hidden, at: 0, in: initial.layout)
        XCTAssertEqual(ItemRegistry.systemVisibilityTarget(for: hidden.entries[0]), "com.apple.systemuiserver")
        XCTAssertEqual(ItemRegistry.eligibleHiddenApplications(in: try ItemRegistry.reconcile([timeMachine], with: hidden)),
                       ["com.apple.systemuiserver"])
        let disappeared = try ItemRegistry.reconcile([], with: hidden)
        XCTAssertEqual(disappeared.items[0].availability, .absent)
        XCTAssertTrue(disappeared.items[0].canSetVisibility)
        XCTAssertTrue(ItemRegistry.eligibleHiddenApplications(in: disappeared).isEmpty)
        let revealed = try ItemRegistry.recoveringUnsupportedVisibility(in: hidden)
        XCTAssertEqual(revealed.entries[0].group, .hidden)
        XCTAssertTrue(try ItemRegistry.reconcile([timeMachine], with: revealed).items[0].canSetVisibility)

        var second = hidden
        second.entries.append(LayoutEntry(id: "system-position:legacy-extra", bundleID: "com.apple.systemuiserver",
                                          name: "Legacy extra", group: .hidden))
        let recoveredBoth = try ItemRegistry.recoveringUnsupportedVisibility(in: second)
        XCTAssertEqual(recoveredBoth.entries.first(where: { $0.id == ItemRegistry.timeMachinePositionID })?.group, .hidden)
        XCTAssertEqual(recoveredBoth.entries.first(where: { $0.id == "system-position:legacy-extra" })?.group, .visible)
        XCTAssertNil(ItemRegistry.systemVisibilityTarget(for: LayoutEntry(id: "system-position:legacy-extra",
            bundleID: "com.apple.systemuiserver", name: "Legacy extra")))
    }

    func testSupportedModuleTargetsUseExactPositionKeysAndIndependentGroups() throws {
        let names = ["Battery", "Bluetooth", "Clock", "Displays", "KeyboardBrightness",
                     "Sound", "WiFi", "ScreenMirroring", "BentoBox-0"]
        for (index, name) in names.enumerated() {
            let entry = LayoutEntry(id: "system-position:module:\(name)", bundleID: "com.apple.controlcenter", name: name)
            XCTAssertEqual(ItemRegistry.systemVisibilityTarget(for: entry), "system-item:\(index)")
            XCTAssertNil(ItemRegistry.systemVisibilityTarget(for: LayoutEntry(id: entry.id,
                bundleID: "com.apple.systemuiserver", name: name)))
        }
        XCTAssertNil(ItemRegistry.systemVisibilityTarget(for: LayoutEntry(
            id: "system-position:module:FocusModes", bundleID: "com.apple.controlcenter", name: "Focus")))

        let battery = DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil,
            name: "Battery", positionTableKey: "module:Battery")
        let clock = DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil,
            name: "Clock", positionTableKey: "module:Clock")
        let focus = DiscoveredItem(bundleID: "com.apple.controlcenter", identifier: nil,
            name: "Focus", positionTableKey: "module:FocusModes")
        let initial = try ItemRegistry.reconcile([battery, clock, focus], with: LayoutDocument())
        XCTAssertEqual(initial.items.map(\.canSetVisibility), [true, true, false])
        let hidden = try LayoutEditor.move("system-position:module:Battery", to: .hidden, at: 0, in: initial.layout)
        XCTAssertEqual(hidden.entries(in: .hidden).map(\.id), ["system-position:module:Battery"])
        XCTAssertEqual(hidden.entries(in: .visible).map(\.id),
                       ["system-position:module:Clock", "system-position:module:FocusModes"])
        XCTAssertNoThrow(try hidden.validated())
        let refreshed = try ItemRegistry.reconcile([battery, clock, focus], with: hidden)
        XCTAssertEqual(ItemRegistry.eligibleHiddenApplications(in: refreshed), ["system-item:0"])
        XCTAssertThrowsError(try LayoutEditor.move("system-position:module:FocusModes", to: .hidden, at: 1, in: hidden))
    }

    func testSingleIconOwnersRequireTheirExactPositionIdentity() throws {
        let owners = [
            ("com.apple.TextInputMenuAgent", "status:com.apple.TextInputMenuAgent::Item-0"),
            ("com.apple.weather.menu", "status:com.apple.weather.menu::Item-0"),
            ("com.apple.campo", "status:com.apple.campo::Item-0")
        ]
        for (bundle, key) in owners {
            let item = DiscoveredItem(bundleID: bundle, identifier: nil, name: bundle, positionTableKey: key)
            let snapshot = try ItemRegistry.reconcile([item], with: LayoutDocument())
            XCTAssertTrue(snapshot.items[0].canSetVisibility)
            let hidden = try LayoutEditor.move(snapshot.items[0].id, to: .hidden, at: 0, in: snapshot.layout)
            XCTAssertEqual(ItemRegistry.eligibleHiddenApplications(in: try ItemRegistry.reconcile([item], with: hidden)), [bundle])
            XCTAssertNil(ItemRegistry.systemVisibilityTarget(for: LayoutEntry(
                id: "system-position:status:\(bundle)::Other", bundleID: bundle, name: "Other")))
        }
    }

}
