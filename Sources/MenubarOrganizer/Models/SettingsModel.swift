import AppKit
@preconcurrency import ApplicationServices
import Observation
import OSLog
import OrganizerCore
import ServiceManagement

@MainActor @Observable
final class SettingsModel {
    private static let manualRetryKey = "LayoutNeedsManualRetry"
    private(set) var items: [RegistryItem] = []
    var selectedID: String?
    private(set) var isBusy = false
    private(set) var accessibilityGranted = false
    private(set) var statusMessage: String?
    @ObservationIgnored private var lastExplicitApplyFailure: String?
    private(set) var hideDelay = 5.0
    private(set) var launchAtLogin = false
    var layoutEntries: [LayoutEntry] { document.entries }
    let isPreview: Bool
    @ObservationIgnored private let store: LayoutStore
    @ObservationIgnored let backend: NativeBackend
    @ObservationIgnored private let coordinator: LayoutCoordinator
    private var draft = LayoutDraft()
    private var document: LayoutDocument {
        get { draft.value }
        set { draft.value = newValue }
    }
    var hasUnsavedChanges: Bool { draft.hasChanges }
    @ObservationIgnored var onDismissSettings: (() -> Void)?
    @ObservationIgnored var onApplyingSettings: ((Bool) -> Void)?
    @ObservationIgnored private var reveal = RevealController()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var visibilityRevision: UInt64 = 0
    @ObservationIgnored private var awaitingReveal = false
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var consentPresented = false
    @ObservationIgnored private var confirming = false
    @ObservationIgnored private var lifecycleSuspended = false
    @ObservationIgnored private var pendingRestore = false
    @ObservationIgnored private var pendingLaunchOrderRestore = false
    @ObservationIgnored private var requiresManualRetry = UserDefaults.standard.bool(forKey: manualRetryKey)
    @ObservationIgnored private var restoreRevision: UInt64 = 0
    @ObservationIgnored private var refreshAfterBusy = false
    // Keep the user's actual row gestures separate from a saved order that may
    // predate changes made by macOS or another menu-bar app.
    @ObservationIgnored private var pendingUserMoves: [ReorderMove]? = []
    @ObservationIgnored private var positionedNewlyVisibleIDs: Set<String> = []

    init(preview: Bool = CommandLine.arguments.contains("--preview")) {
        isPreview = preview
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenubarOrganizer/layout.json")
        store = LayoutStore(url: url)
        backend = NativeBackend()
        coordinator = LayoutCoordinator(backend: backend)
        backend.visibility.onInvalidated = { [weak self] error in
            guard let self, !self.stopped, !self.isPreview else { return }
            self.timer?.cancel(); self.timer = nil
            self.visibilityRevision &+= 1
            _ = self.reveal.suspend(reason: .backendUnavailable)
            self.statusMessage = self.backendErrorMessage(error)
            Task { [weak self] in
                guard let self else { return }
                await self.suspend(reason: .backendUnavailable)
                // Only inventory changes can be repaired by rebuilding the
                // allow-list. Backend failures require a manual retry.
                if case .inventoryChanged = error {
                    await self.refresh(adoptObserved: false, restoreSaved: true)
                }
            }
        }
    }

    func start() async {
        guard !loaded, !stopped else { return }
        if isPreview {
            let candidates = [(ItemRegistry.organizerBundleID, "Menubar Organizer"),
                              ("com.openai.codex", "ChatGPT"), ("ru.keepcoder.Telegram", "Telegram"),
                              ("com.google.Chrome", "Google Chrome"), ("com.1password.1password", "1Password"), ("com.apple.Safari", "Safari")]
            let installed = candidates.filter {
                $0.0 == ItemRegistry.organizerBundleID || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil
            }
            let samples = Array(installed.prefix(5))
            let observations = samples.map { DiscoveredItem(bundleID: $0.0, identifier: nil, name: $0.1) }
            document = LayoutDocument(entries: samples.enumerated().map { index, app in
                LayoutEntry(id: ItemRegistry.key(bundleID: app.0, identifier: nil), bundleID: app.0,
                            name: app.1, group: index < 2 ? .visible : .hidden)
            })
            items = (try? ItemRegistry.reconcile(observations, with: document).items) ?? []
            draft.accept(document)
            selectedID = items.first?.id
            accessibilityGranted = true
            statusMessage = L10n.text("status.preview")
            loaded = true
            return
        }
        do {
            let result = try store.load()
            document = try ItemRegistry.recoveringUnsupportedVisibility(in: result.document)
            if document != result.document {
                do { try store.save(document) }
                catch {
                    // The safe in-memory state remains usable. Retry persistence
                    // on the next explicit save or application launch.
                    Logger(subsystem: "local.menubarorganizer.app", category: "visibility")
                        .error("Could not persist recovered system visibility: \(error.localizedDescription)")
                }
            }
            hideDelay = document.hideDelay
            launchAtLogin = SMAppService.mainApp.status == .enabled
            document.launchAtLogin = launchAtLogin
            reveal = RevealController(delay: hideDelay)
            draft.accept(document)
            loaded = true
        } catch { statusMessage = L10n.text("status.loadFailed"); return }
        // Launch is read-only until discovery and permissions are verified.
        await refresh(adoptObserved: false, restoreSaved: true, restoreSavedOrder: true)
    }

    func icon(for item: RegistryItem) -> NSImage? {
        if item.entry.bundleID == ItemRegistry.organizerBundleID {
            return NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        }
        if item.entry.bundleID.hasPrefix("com.apple.") {
            let symbol = SystemMenuItemKind.identify(bundleID: item.entry.bundleID, metadata: [item.entry.name])?.symbol ?? "menubar.rectangle"
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return icon(bundleID: item.entry.bundleID)
    }

    private func icon(bundleID: String) -> NSImage? {
        if let value = icons[bundleID] { return value }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    func requestAccessibility() {
        guard !isPreview else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh(adoptObserved: Bool = true, restoreSaved: Bool = false,
                 restoreSavedOrder: Bool = false, retryPendingRestore: Bool = false) async {
        guard !stopped, !isPreview else { return }
        if restoreSavedOrder { pendingLaunchOrderRestore = true }
        // Record lifecycle/start intent before the busy/permission guards. The
        // next successful manual refresh must not erase an unfulfilled layout.
        if restoreSaved {
            pendingRestore = true
            restoreRevision &+= 1
            if isBusy { refreshAfterBusy = true }
        }
        guard !confirming else { refreshAfterBusy = true; return }
        guard loaded, !isBusy, !lifecycleSuspended else { return }
        let editing = hasUnsavedChanges
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else {
            await suspend(reason: .permissionsUnavailable)
            statusMessage = L10n.text("status.accessibilityRequired")
            return
        }
        isBusy = true
        revision &+= 1
        let token = revision
        var savedOrderNeedsRestore = false
        do {
            let observations = try await backend.discover()
            guard !stopped, token == revision else { return }
            var snapshot = try ItemRegistry.reconcile(observations, with: draft.committed)
            if pendingLaunchOrderRestore {
                snapshot.layout = try ItemRegistry.adoptingObservedOrganizerPosition(observations, in: snapshot.layout)
                snapshot.items = ItemRegistry.mergingDraft(snapshot.items, with: snapshot.layout)
                savedOrderNeedsRestore = savedOrderDiffers(from: observations, snapshot: snapshot)
            }
            // Passive refresh adopts only directly verified, unambiguous order.
            // It never sends a reorder back to the user's menu bar.
            for group in ItemGroup.allCases where adoptObserved && !pendingRestore && !editing {
                let permitted = Set(snapshot.items.filter { $0.entry.group == group && $0.canReorder }.map(\.id))
                let ids = observations.compactMap { item -> String? in
                    guard let id = ItemRegistry.observationID(item) else { return nil }
                    return permitted.contains(id) ? id : nil
                }
                snapshot.layout = try LayoutEditor.adoptObservedOrder(ids, group: group, in: snapshot.layout)
            }
            try store.save(snapshot.layout)
            draft.updateCommitted(snapshot.layout, preservingChanges: editing)
            items = try ItemRegistry.reconcile(observations, with: document).items
            if selectedID == nil { selectedID = items.first?.id }
            statusMessage = lastExplicitApplyFailure ?? (hasUnsavedChanges ? L10n.text("status.unsaved")
                : requiresManualRetry ? L10n.text("status.manualRetry") : nil)
        } catch {
            guard token == revision, !stopped else { return }
            Logger(subsystem: "local.menubarorganizer.app", category: "discovery").error("Discovery failed: \(String(describing: error), privacy: .public)")
            if let discoveryError = error as? NativeDiscoveryError, discoveryError == .permissionDenied {
                statusMessage = L10n.text("status.accessibilityRequired")
            } else {
                statusMessage = lastExplicitApplyFailure ?? L10n.text("status.failed")
            }
            finishBusy(token: token)
            return
        }
        guard token == revision, !stopped else { return }
        if case .suspended = reveal.state { await run(reveal.resume(now: now)) }
        guard token == revision, !stopped else { return }
        if pendingRestore && (!requiresManualRetry || retryPendingRestore) {
            // No await separates releasing this discovery operation from taking
            // the apply busy state; a queued lifecycle refresh drains afterward.
            isBusy = false
            if pendingLaunchOrderRestore {
                var restored = false
                if savedOrderNeedsRestore {
                    do {
                        try backend.preparePositionTableAccess(promptIfNeeded: false)
                        try backend.beginExplicitReordering()
                        defer { backend.endExplicitReordering() }
                        restored = await applyLayout(allowReordering: true, explicit: true,
                                                     restoreOrderBeforeHiding: true)
                    } catch {
                        let visibilityApplied = await applyLayout(explicit: true, preserveSavedOrder: true)
                        pendingRestore = true
                        if visibilityApplied { statusMessage = L10n.text("status.orderSavedNotApplied") }
                    }
                } else {
                    restored = await applyLayout(explicit: true, preserveSavedOrder: true)
                }
                pendingLaunchOrderRestore = !restored
            } else {
                await applyLayout()
            }
        } else {
            finishBusy(token: token)
        }
    }

    private func savedOrderDiffers(from observations: [DiscoveredItem], snapshot: RegistrySnapshot) -> Bool {
        let present = Set(observations.compactMap(ItemRegistry.observationID))
        for group in ItemGroup.allCases {
            let desired = snapshot.layout.entries(in: group).map(\.id).filter { present.contains($0) }
            let members = Set(desired)
            let observed = observations.compactMap(ItemRegistry.observationID).filter { members.contains($0) }
            if observed != desired { return true }
        }
        return false
    }

    func runningApplicationsChanged(launchedBundleID: String?) async {
        let savedHiddenAppStarted = launchedBundleID.map { bundleID in
            draft.committed.entries.contains { $0.group == .hidden && $0.bundleID == bundleID }
        } ?? false
        // When every hidden app was closed, no assertion existed to observe
        // this launch. Apply saved visibility now that its target is running.
        await refresh(adoptObserved: false, restoreSaved: savedHiddenAppStarted && !backend.visibility.isActive)
    }

    func move(id: String, to group: ItemGroup, at index: Int, applyPosition: Bool = true) async {
        guard !isBusy, !confirming, loaded, !stopped,
              let item = items.first(where: { $0.id == id }),
              (item.entry.group != group ? item.canSetVisibility : item.canReorder) else { return }
        do {
            let previous = document
            let edited = try LayoutEditor.move(id, to: group, at: index, in: previous)
            if item.entry.group == group, edited != previous, pendingUserMoves != nil {
                let old = previous.entries(in: group)
                let next = edited.entries(in: group)
                if let oldIndex = old.firstIndex(where: { $0.id == id }),
                   let newIndex = next.firstIndex(where: { $0.id == id }), oldIndex != newIndex {
                    let intent: ReorderMove?
                    if newIndex > oldIndex, newIndex > 0 {
                        intent = ReorderMove(id: id, targetID: next[newIndex - 1].id, placement: .after)
                    } else if newIndex < oldIndex, newIndex + 1 < next.count {
                        intent = ReorderMove(id: id, targetID: next[newIndex + 1].id, placement: .before)
                    } else { intent = nil }
                    if let intent { pendingUserMoves?.append(intent) }
                    else { pendingUserMoves = nil }
                }
            } else if item.entry.group != group { pendingUserMoves = nil }
            if edited != previous {
                let beforeVisible = Set(previous.entries(in: .visible).map(\.id))
                let afterVisible = Set(edited.entries(in: .visible).map(\.id))
                positionedNewlyVisibleIDs.subtract(beforeVisible.subtracting(afterVisible))
                if applyPosition {
                    positionedNewlyVisibleIDs.formUnion(afterVisible.subtracting(beforeVisible))
                    if afterVisible.contains(id) { positionedNewlyVisibleIDs.insert(id) }
                } else {
                    positionedNewlyVisibleIDs.subtract(afterVisible.subtracting(beforeVisible))
                }
            }
            document = edited
            lastExplicitApplyFailure = nil
            publishDraft()
            selectedID = id
            statusMessage = L10n.text("status.unsaved")
        } catch { statusMessage = L10n.text("status.failed") }
    }

    private func publishDraft() {
        items = ItemRegistry.mergingDraft(items, with: document)
        hideDelay = document.hideDelay
        launchAtLogin = document.launchAtLogin
    }

    func cancelSettings() {
        guard !isBusy, !confirming, !stopped else { return }
        lastExplicitApplyFailure = nil
        draft.cancel()
        pendingUserMoves = []
        positionedNewlyVisibleIDs = []
        publishDraft()
        statusMessage = isPreview ? L10n.text("status.preview") : nil
        onDismissSettings?()
    }

    func confirmSettings() async -> Bool {
        guard loaded, !isBusy, !confirming, !stopped, !lifecycleSuspended else { return false }
        let applyStarted = ContinuousClock.now
        defer {
            let duration = applyStarted.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            Logger(subsystem: "local.menubarorganizer.app", category: "reorderTiming")
                .notice("settingsOKSeconds=\(seconds, privacy: .public)")
        }
        if isPreview {
            draft.accept(document)
            statusMessage = L10n.text("status.preview")
            onDismissSettings?()
            return true
        }
        let plan = SettingsApplyPlan(committed: draft.committed, draft: document,
                                     pendingLayout: pendingRestore,
                                     reorderNewlyVisibleIDs: positionedNewlyVisibleIDs)
        let needsReordering = plan.needsReordering || (pendingRestore && !positionedNewlyVisibleIDs.isEmpty)
        let needsLayout = plan.needsLayout || (
            document.entries.contains(where: { $0.group == .hidden }) &&
            !backend.visibility.isActive
        )
        if !plan.needsSave, !needsLayout {
            onDismissSettings?()
            return true
        }
        if needsLayout { lastExplicitApplyFailure = nil }
        guard !needsLayout || AXIsProcessTrusted() else {
            statusMessage = L10n.text("status.accessibilityRequired")
            return false
        }
        if needsLayout, document.entries.contains(where: { $0.group == .hidden }),
           backend.visibility.unknownOwnerPolicy == .requireIdentifiedOwners,
           unidentifiedOwnerCount > 0 {
            guard requestSessionVisibilityConsent(), !lifecycleSuspended, !stopped else { return false }
        }
        confirming = true
        // A group-only change can still require a native move after hidden
        // applications are revealed. Preflight before saving the new layout.
        if needsReordering {
            do { try backend.preparePositionTableAccess() }
            catch {
                confirming = false
                statusMessage = L10n.text("status.positionAccessRequired")
                return false
            }
        }
        if let pendingUserMoves, !pendingUserMoves.isEmpty,
           isVisibleReorderWithPreferences(from: draft.committed, to: document) {
            return await confirmFocusedReorder(pendingUserMoves)
        }
        isBusy = true
        revision &+= 1
        let token = revision
        onApplyingSettings?(true)
        defer {
            confirming = false
            onApplyingSettings?(false)
            if token == revision { isBusy = false }
            if refreshAfterBusy, !stopped, !lifecycleSuspended {
                refreshAfterBusy = false
                Task { [weak self] in await self?.refresh(adoptObserved: false) }
            }
        }
        let previousLogin = SMAppService.mainApp.status == .enabled
        var changedLogin = false
        var failureMessage = L10n.text("status.saveFailed")
        do {
            let accepted = try document.validated()
            if accepted.launchAtLogin != previousLogin {
                failureMessage = L10n.text("status.loginFailed")
                if accepted.launchAtLogin { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                changedLogin = true
                guard accepted.launchAtLogin == (SMAppService.mainApp.status == .enabled) else {
                    throw CancellationError()
                }
            }
            guard token == revision, !stopped, !lifecycleSuspended, (!needsLayout || AXIsProcessTrusted()) else {
                throw CancellationError()
            }
            failureMessage = L10n.text("status.saveFailed")
            let store = self.store
            try await Task.detached(priority: .userInitiated) { try store.save(accepted) }.value
            // The file has been committed even if a lifecycle interruption now
            // cancels system application. Never re-enable a cancelled gesture.
            draft.accept(accepted)
            pendingUserMoves = []
            if needsLayout {
                pendingRestore = true
                restoreRevision &+= 1
            }
            guard token == revision, !stopped, !lifecycleSuspended, (!needsLayout || AXIsProcessTrusted()) else { return false }
        } catch {
            if changedLogin {
                do {
                    if previousLogin { try SMAppService.mainApp.register() }
                    else { try await SMAppService.mainApp.unregister() }
                } catch {
                    // Keep Cancel truthful even if the system refuses rollback.
                    var baseline = draft.committed
                    baseline.launchAtLogin = SMAppService.mainApp.status == .enabled
                    draft.updateCommitted(baseline, preservingChanges: true)
                    failureMessage = L10n.text("status.loginFailed")
                }
            }
            if token == revision {
                lastExplicitApplyFailure = failureMessage
                statusMessage = failureMessage
            }
            return false
        }
        await run(reveal.setDelay(draft.committed.hideDelay, now: now))
        guard token == revision, !stopped, !lifecycleSuspended, (!needsLayout || AXIsProcessTrusted()) else { return false }
        if !needsLayout {
            statusMessage = lastExplicitApplyFailure ?? L10n.text("status.applied")
            onDismissSettings?()
            return true
        }
        if needsReordering {
            do { try backend.beginExplicitReordering() }
            catch {
                lastExplicitApplyFailure = L10n.text("status.failed")
                statusMessage = lastExplicitApplyFailure
                return false
            }
        }
        defer { if needsReordering { backend.endExplicitReordering() } }
        let applied = await applyLayout(allowReordering: needsReordering, explicit: true)
        if applied { positionedNewlyVisibleIDs = [] }
        if applied { onDismissSettings?() }
        return applied
    }

    private func isVisibleReorderWithPreferences(from committed: LayoutDocument, to proposed: LayoutDocument) -> Bool {
        guard committed.entries.count == proposed.entries.count,
              committed.entries(in: .hidden).map(\.id) == proposed.entries(in: .hidden).map(\.id) else { return false }
        let old = committed.entries(in: .visible)
        let new = proposed.entries(in: .visible)
        guard old.map(\.id) != new.map(\.id), Set(old.map(\.id)) == Set(new.map(\.id)) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.bundleID) })
        return new.allSatisfy { byID[$0.id] == $0.bundleID }
    }

    /// Apply only the row gestures the user made. A previously saved order may
    /// contain unrelated stale items; replaying it first can fail before the
    /// selected icon is ever reached.
    private func confirmFocusedReorder(_ moves: [ReorderMove]) async -> Bool {
        confirming = true
        isBusy = true
        revision &+= 1
        let token = revision
        onApplyingSettings?(true)
        defer {
            confirming = false
            onApplyingSettings?(false)
            if token == revision { isBusy = false }
            if refreshAfterBusy, !stopped, !lifecycleSuspended {
                refreshAfterBusy = false
                Task { [weak self] in await self?.refresh(adoptObserved: false) }
            }
        }
        do { try backend.beginExplicitReordering() }
        catch {
            statusMessage = layoutErrorMessage(String(describing: error))
            return false
        }
        defer { backend.endExplicitReordering() }
        var completedMoves = 0
        let previousLogin = SMAppService.mainApp.status == .enabled
        var changedLogin = false
        do {
            if document.launchAtLogin != previousLogin {
                if document.launchAtLogin { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                changedLogin = true
                guard document.launchAtLogin == (SMAppService.mainApp.status == .enabled) else {
                    throw CancellationError()
                }
            }
            for move in moves {
                guard token == revision, !stopped, !lifecycleSuspended, AXIsProcessTrusted() else {
                    throw CancellationError()
                }
                let observed = try await backend.discover()
                let snapshot = try ItemRegistry.reconcile(observed, with: document)
                let movable = Set(snapshot.items.filter { $0.canReorder && $0.entry.group == .visible }.map(\.id))
                guard movable.contains(move.id), movable.contains(move.targetID) else {
                    throw MenuBarPositionStore.Failure.unmatched
                }
                let actual = observed.compactMap { item -> String? in
                    guard let id = ItemRegistry.observationID(item) else { return nil }
                    return movable.contains(id) ? id : nil
                }
                guard let source = actual.firstIndex(of: move.id),
                      let target = actual.firstIndex(of: move.targetID) else {
                    throw MenuBarPositionStore.Failure.unmatched
                }
                let alreadyAdjacent = move.placement == .before ? source + 1 == target : source == target + 1
                if !alreadyAdjacent {
                    try await backend.moveItem(id: move.id, relativeTo: move.targetID, placement: move.placement)
                    completedMoves += 1
                }
            }
            guard token == revision, !stopped, !lifecycleSuspended else { throw CancellationError() }
            let observed = try await backend.discover()
            let normalized = try actualVisibleOrder(from: observed, basedOn: document)
            try store.save(normalized)
            draft.accept(normalized)
            pendingUserMoves = []
            positionedNewlyVisibleIDs = []
            pendingRestore = false
            lastExplicitApplyFailure = nil
            items = try ItemRegistry.reconcile(observed, with: normalized).items
            await run(reveal.setDelay(normalized.hideDelay, now: now))
            statusMessage = L10n.text("status.applied")
            onDismissSettings?()
            return true
        } catch {
            guard token == revision, !stopped else { return false }
            if changedLogin {
                do {
                    if previousLogin { try SMAppService.mainApp.register() }
                    else { try await SMAppService.mainApp.unregister() }
                } catch { /* Preserve the actual login setting in the recovered document. */ }
            }
            // The native store may have rolled back an unsuccessful write. Show
            // and persist what is actually on screen, not the failed proposal.
            var synchronized = false
            var recovered = draft.committed
            recovered.launchAtLogin = SMAppService.mainApp.status == .enabled
            if let observed = try? await backend.discover(),
               let normalized = try? actualVisibleOrder(from: observed, basedOn: recovered),
               (try? store.save(normalized)) != nil,
               let snapshot = try? ItemRegistry.reconcile(observed, with: normalized) {
                draft.accept(normalized)
                pendingUserMoves = []
                positionedNewlyVisibleIDs = []
                pendingRestore = false
                items = snapshot.items
                synchronized = true
            }
            let code = layoutErrorCode(String(describing: error))
            Logger(subsystem: "local.menubarorganizer.app", category: "layout")
                .error("Focused reorder failed: \(code, privacy: .public); completedMoves=\(completedMoves, privacy: .public)")
            if synchronized {
                statusMessage = completedMoves > 0 ? L10n.text("status.reorderPartialSynced")
                    : String(describing: error) == "unmatched" ? L10n.text("status.reorderUnmatchedSynced")
                    : L10n.text("status.reorderFailedSynced")
            } else {
                statusMessage = completedMoves > 0
                    ? L10n.text("status.reorderPartiallyApplied")
                    : layoutErrorMessage(String(describing: error))
            }
            lastExplicitApplyFailure = statusMessage
            return false
        }
    }

    private func actualVisibleOrder(from observed: [DiscoveredItem], basedOn proposed: LayoutDocument) throws -> LayoutDocument {
        let snapshot = try ItemRegistry.reconcile(observed, with: proposed)
        let movable = Set(snapshot.items.filter { $0.entry.group == .visible && $0.canReorder }.map(\.id))
        let ids = observed.compactMap { item -> String? in
            guard let id = ItemRegistry.observationID(item) else { return nil }
            return movable.contains(id) ? id : nil
        }
        return try LayoutEditor.adoptObservedOrder(ids, group: .visible, in: snapshot.layout)
    }

    @discardableResult
    private func applyLayout(allowReordering: Bool = false, explicit: Bool = false,
                             restoreOrderBeforeHiding: Bool = false,
                             preserveSavedOrder: Bool = false) async -> Bool {
        guard !stopped else { return false }
        var applied = false
        isBusy = true
        revision &+= 1
        let token = revision
        let restoreToken = restoreRevision
        let requested = allowReordering ? document : draft.committed
        if allowReordering || lastExplicitApplyFailure == nil {
            statusMessage = L10n.text("status.applying")
        }
        await serialize { [self] in
            guard token == revision else { return }
            let report = restoreOrderBeforeHiding
                ? await coordinator.restoreSavedLayout(requested)
                : await coordinator.apply(requested,
                    revealed: !explicit && reveal.state != .collapsed,
                    allowReordering: allowReordering)
            guard token == revision, !stopped else { return }
            if let snapshot = report.snapshot {
                items = snapshot.items
                if hasUnsavedChanges { publishDraft() }
            }
            // A failed native move can roll back its position-table write while
            // the proposed order has already been saved. Reconcile only the
            // actually observed, movable visible rows so the list does not
            // continue to claim that an unsuccessful reorder took effect.
            if (allowReordering && !restoreOrderBeforeHiding &&
                (report.status == .failed || report.status == .partial)) ||
                (!allowReordering && !preserveSavedOrder && report.status == .applied),
               let snapshot = report.snapshot {
                let movable = Set(snapshot.items.filter { $0.entry.group == .visible && $0.canReorder }.map(\.id))
                let observed = report.observedOrder.filter { movable.contains($0) }
                if let normalized = try? LayoutEditor.adoptObservedOrder(observed, group: .visible, in: document),
                   normalized != document {
                    do {
                        try store.save(normalized)
                        draft.accept(normalized)
                        pendingUserMoves = []
                        positionedNewlyVisibleIDs = []
                        items = ItemRegistry.mergingDraft(snapshot.items, with: normalized)
                    } catch {
                        Logger(subsystem: "local.menubarorganizer.app", category: "layout")
                            .error("Could not persist observed order after unsuccessful apply")
                    }
                }
            }
            if report.error != nil {
                let code = layoutErrorCode(report.error)
                Logger(subsystem: "local.menubarorganizer.app", category: "layout")
                    .error("Layout application failed: \(code, privacy: .public); completedMoves=\(report.movedCount, privacy: .public)")
            }
            switch report.status {
            case .applied:
                applied = true
                if explicit, report.visibilityApplied,
                   requested.entries.contains(where: { $0.group == .hidden }) {
                    await run(reveal.confirmExplicitHide())
                }
                lastExplicitApplyFailure = nil
                if restoreToken == restoreRevision { pendingRestore = false }
                requiresManualRetry = false
                UserDefaults.standard.set(false, forKey: Self.manualRetryKey)
                statusMessage = L10n.text("status.applied")
            case .partial:
                statusMessage = report.error == "systemVisibilityNotVerified"
                    ? L10n.text("status.systemVisibilityNotVerified")
                    : report.error == "unidentifiedMenuBarOwners"
                    ? L10n.text("status.unidentifiedMenuBarOwners")
                    : report.error == "nonintrusiveReorderingUnavailable"
                    ? L10n.text("status.orderSavedNotApplied")
                    : report.error == "obstructed"
                    ? L10n.text("status.partial") + " " + L10n.text("status.reorderObstructed")
                    : allowReordering && report.error != nil
                    ? L10n.text("status.reorderPartiallyApplied")
                    : L10n.text("status.partial")
            case .failed: statusMessage = layoutErrorMessage(report.error)
            case .superseded: break
            }
            if explicit, report.status == .failed || report.status == .partial {
                lastExplicitApplyFailure = statusMessage
                requiresManualRetry = true
                UserDefaults.standard.set(true, forKey: Self.manualRetryKey)
                // A failed move does not invalidate a successfully applied
                // visibility filter. Only clear it when visibility itself failed.
                if !report.visibilityApplied {
                    try? await backend.setHiddenApplications([])
                }
                // The coordinator already discovered the post-move state.
                // Keep the pending layout for an explicit retry without
                // scheduling the same failed operation again.
            } else if !allowReordering, report.status == .partial,
                      report.error == nil || report.error == "nonintrusiveReorderingUnavailable",
                      let lastExplicitApplyFailure {
                // Passive verification cannot explain why the user's last OK
                // failed. Retain its concrete error instead of a generic limit.
                // New permission/backend failures still take precedence above.
                statusMessage = lastExplicitApplyFailure
            }
            if !allowReordering, hasUnsavedChanges, lastExplicitApplyFailure == nil, report.status != .failed {
                statusMessage = L10n.text("status.unsaved")
            }
        }
        finishBusy(token: token)
        return applied
    }

    func setHideDelay(_ value: Double) async {
        guard loaded, !isBusy, !confirming, !stopped, value.isFinite, (1...60).contains(value) else { return }
        lastExplicitApplyFailure = nil
        document.hideDelay = value
        hideDelay = value
        statusMessage = L10n.text("status.unsaved")
    }

    func setLaunchAtLogin(_ value: Bool) async {
        guard loaded, !isBusy, !confirming, !stopped else { return }
        lastExplicitApplyFailure = nil
        document.launchAtLogin = value
        launchAtLogin = value
        statusMessage = L10n.text("status.unsaved")
    }

    func toggle() async {
        guard loaded, !stopped, !isBusy, !isPreview else { return }
        await run(reveal.toggle(now: now))
    }

    func interaction(pointerInside: Bool, menuOpen: Bool) async {
        guard !stopped, !isPreview, !consentPresented else { return }
        if accessibilityGranted, !AXIsProcessTrusted() {
            accessibilityGranted = false
            await suspend(reason: .permissionsUnavailable)
            statusMessage = L10n.text("status.accessibilityRequired")
            return
        }
        let effects = reveal.setMenuOpen(menuOpen, now: now)
            + reveal.setPointerInInteractionRegion(pointerInside, now: now)
        await run(effects)
    }

    func noteMenuBarActivity() async {
        guard loaded, !stopped, !isPreview else { return }
        await run(reveal.noteActivity(now: now))
    }

    func resumeLifecycle() async {
        guard !stopped, !isPreview else { return }
        lifecycleSuspended = false
        await refresh(adoptObserved: false, restoreSaved: true)
    }

    func suspend(reason: RevealController.SuspensionReason) async {
        guard !stopped, !isPreview else { return }
        if reason == .lifecycle { lifecycleSuspended = true; refreshAfterBusy = false }
        revision &+= 1
        let token = revision
        visibilityRevision &+= 1
        timer?.cancel(); timer = nil
        backend.cancelGestures()
        let effects = reveal.suspend(reason: reason)
        backend.visibility.invalidateForTermination()
        await coordinator.cancelPending()
        guard token == revision, !stopped else { return }
        await run(effects)
        finishBusy(token: token)
    }

    func stop() async {
        guard !isPreview else { stopped = true; return }
        stopped = true
        refreshAfterBusy = false
        backend.cancelGestures()
        revision &+= 1
        visibilityRevision &+= 1
        timer?.cancel(); timer = nil
        _ = reveal.suspend(reason: .lifecycle)
        backend.visibility.invalidateForTermination()
        // Cancel/drain existing coordinator work; never apply a layout on exit.
        await coordinator.cancelPending()
        await backend.shutdown()
        if let operationTail { await operationTail.value }
        backend.visibility.invalidateForTermination()
        isBusy = false
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func finishBusy(token: UInt64) {
        guard token == revision else { return }
        isBusy = false
        guard refreshAfterBusy, !confirming, !stopped, !lifecycleSuspended else { return }
        // One coalesced follow-up per external request burst. Failure/partial
        // results retain pendingRestore but never schedule their own retry.
        refreshAfterBusy = false
        Task { [weak self] in
            guard let self, !self.stopped, !self.lifecycleSuspended, token == self.revision else { return }
            if self.isBusy {
                self.refreshAfterBusy = true
                return
            }
            await self.refresh(adoptObserved: false)
        }
    }

    private var unidentifiedOwnerCount: Int {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }.count
    }

    private func backendErrorMessage(_ error: any Error) -> String {
        if let driverError = error as? VisibilityDriver.DriverError {
            switch driverError {
            case .unsupportedBuild: return L10n.text("status.unsupportedOS")
            case .unidentifiedOwners(let count): return L10n.format("status.unknownOwners", count)
            default: return L10n.text("status.backendUnavailable")
            }
        }
        if let discoveryError = error as? NativeDiscoveryError, discoveryError == .permissionDenied {
            return L10n.text("status.accessibilityRequired")
        }
        return L10n.text("status.failed")
    }

    // The coordinator currently erases error types. Interpret only complete known
    // representations; unrelated order failures must not infer a hiding problem
    // from the current process inventory or visibility policy.
    private func unknownOwnerCount(in error: String?) -> Int? {
        let prefix = "unidentifiedOwners(count: "
        guard let error, error.hasPrefix(prefix), error.hasSuffix(")") else { return nil }
        let digits = error.dropFirst(prefix.count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let count = Int(digits) else { return nil }
        return count
    }

    private func layoutErrorMessage(_ error: String?) -> String {
        if error == "unidentifiedMenuBarOwners" { return L10n.text("status.unidentifiedMenuBarOwners") }
        if error == "nonintrusiveReorderingUnavailable" { return L10n.text("status.orderSavedNotApplied") }
        if error == "reorderVerificationFailed" || error == "expired" {
            return L10n.text("status.reorderNotApplied")
        }
        if error == "obstructed" { return L10n.text("status.reorderObstructed") }
        if error == "unsupportedBuild" { return L10n.text("status.unsupportedOS") }
        if let count = unknownOwnerCount(in: error) { return L10n.format("status.unknownOwners", count) }
        return L10n.text("status.failed")
    }

    private func layoutErrorCode(_ error: String?) -> String {
        if unknownOwnerCount(in: error) != nil { return "unidentifiedOwners" }
        // Never emit raw error text: associated values may include application
        // identifiers, names, paths, or messages from another process.
        let permitted: Set<String> = [
            "unsupportedBuild", "runtimeUnavailable", "competingManager",
            "allocationFailed", "activationTimedOut", "superseded", "inventoryChanged",
            "policyChangeWhileActive", "permissionDenied", "timeBudgetExceeded",
            "inventoryLimitExceeded", "staleGeometry", "ambiguousIdentity",
            "unsupported", "unavailable", "inputBusy", "obstructed", "expired", "nonintrusiveReorderingUnavailable",
            "reorderVerificationFailed", "accessRequired", "wrongFile", "unreadable",
            "unmatched", "ambiguous", "stale", "noSpace", "writeFailed", "noReflow",
            "incompatibleIdentities",
            "unidentifiedMenuBarOwners",
            "CancellationError()"
        ]
        guard let error, permitted.contains(error) else { return "unclassified" }
        return error
    }

    private func requestSessionVisibilityConsent() -> Bool {
        guard !isPreview, !stopped else { return false }
        let token = revision
        isBusy = true
        consentPresented = true
        timer?.cancel(); timer = nil
        visibilityRevision &+= 1
        defer {
            consentPresented = false
            finishBusy(token: token)
            if !stopped {
                Task { [weak self] in
                    guard let self, !self.stopped else { return }
                    await self.run(self.reveal.noteActivity(now: self.now))
                }
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("privacy.unknownTitle")
        alert.informativeText = L10n.format("privacy.unknownMessage", unidentifiedOwnerCount)
        // Cancel is the default Return/Escape action; enable requires an explicit choice.
        alert.addButton(withTitle: L10n.text("action.cancel")).keyEquivalent = "\r"
        alert.addButton(withTitle: L10n.text("privacy.enableSession")).keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn, !stopped, token == revision else { return false }
        do {
            try backend.visibility.allowUnidentifiedOwnersForSession()
            return true
        } catch {
            statusMessage = L10n.text("status.policyBusy")
            return false
        }
    }

    private func serialize(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = operationTail
        let task = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, !self.stopped else { return }
            await operation()
        }
        operationTail = task
        await task.value
    }

    private func run(_ effects: [RevealController.Effect]) async {
        guard !stopped else { return }
        let changesVisibility = effects.contains(.showHidden) || effects.contains(.hideHidden)
        if changesVisibility {
            visibilityRevision &+= 1
            awaitingReveal = effects.last(where: { $0 == .showHidden || $0 == .hideHidden }) == .showHidden
            if awaitingReveal { timer?.cancel(); timer = nil }
        }
        let token = visibilityRevision
        // Apply timer effects synchronously. Suspending between showHidden and
        // schedule could otherwise overwrite a newer interaction timer.
        for effect in effects {
            switch effect {
            case .cancelTimer: timer?.cancel(); timer = nil
            case .schedule(let deadline, let token):
                guard !awaitingReveal, reveal.timerToken == token, reveal.deadline == deadline else { continue }
                timer?.cancel()
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
                    catch { return }
                    guard let self, !Task.isCancelled, !self.stopped else { return }
                    await self.run(self.reveal.timerFired(token: token, now: self.now))
                }
            case .showHidden, .hideHidden: break
            }
        }
        guard let effect = effects.last(where: { $0 == .showHidden || $0 == .hideHidden }) else { return }
        await serialize { [self] in
            guard token == visibilityRevision, !stopped else { return }
            do {
                // The active filter removes its own targets from discovery.
                // A repeated hide effect must keep that assertion rather than
                // interpreting the missing icons as an empty hidden set.
                if effect == .hideHidden, backend.visibility.isActive {
                    reveal.confirmVisibility(.hidden)
                    return
                }
                let hidden: Set<String>
                if effect == .showHidden { hidden = [] }
                else {
                    let snapshot = try ItemRegistry.reconcile(try await backend.discover(), with: draft.committed)
                    guard token == visibilityRevision, !stopped, reveal.state == .collapsed else { return }
                    hidden = ItemRegistry.eligibleHiddenApplications(in: snapshot)
                }
                try await backend.setHiddenApplications(hidden)
                Logger(subsystem: "local.menubarorganizer.app", category: "visibility").notice("Applied visibility: hidden applications=\(hidden.count), uptime=\(self.now)")
                guard token == visibilityRevision, !stopped else { return }
                reveal.confirmVisibility(hidden.isEmpty ? .visible : .hidden)
                if effect == .showHidden {
                    awaitingReveal = false
                    // A queued reveal receives its full interval only after
                    // the adapter acknowledges it; interactions can still pause it.
                    await run(reveal.noteActivity(now: now))
                }
            } catch {
                guard token == visibilityRevision, !stopped else { return }
                timer?.cancel(); timer = nil
                awaitingReveal = false
                _ = reveal.suspend(reason: .backendUnavailable)
                try? await backend.setHiddenApplications([])
                guard token == visibilityRevision, !stopped else { return }
                statusMessage = backendErrorMessage(error)
            }
        }
    }
}
