import AppKit
import CoreFoundation
import OrganizerCore
import os

/// macOS 27's private position table. File access is explicitly granted with
/// NSOpenPanel; only uniquely matched status items may be written.
@MainActor
final class MenuBarPositionStore {
    enum Failure: Error {
        case accessRequired, wrongFile, unreadable, unmatched, ambiguous, stale, noSpace, writeFailed, noReflow
    }

    private let preferenceKey = "TrailingItemPreferredPositions" as CFString
    private let logger = Logger(subsystem: "local.menubarorganizer.app", category: "position")
    private let bookmarkKey = "MenuBarPositionTableBookmark"
    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    private var grantedURL: URL?
    private var scoped = false

    func ensureAccess(promptIfNeeded: Bool = true) throws {
        if let grantedURL {
            if (try? Data(contentsOf: grantedURL)) != nil { return }
            closeAccess()
        }
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               !stale, url.standardizedFileURL == fileURL.standardizedFileURL {
                let started = url.startAccessingSecurityScopedResource()
                if started, (try? Data(contentsOf: url)) != nil {
                    grantedURL = url; scoped = true
                    return
                }
                if started { url.stopAccessingSecurityScopedResource() }
            }
        }
        // A prior open-panel grant may still be valid even when this
        // unsandboxed development build cannot restore its scoped bookmark.
        if (try? Data(contentsOf: fileURL)) != nil {
            grantedURL = fileURL
            scoped = false
            return
        }
        guard promptIfNeeded else { throw Failure.accessRequired }
        let panel = NSOpenPanel()
        panel.title = L10n.text("positionAccess.title")
        panel.message = L10n.text("positionAccess.message")
        panel.prompt = L10n.text("positionAccess.choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { throw Failure.accessRequired }
        guard url.standardizedFileURL == fileURL.standardizedFileURL else { throw Failure.wrongFile }
        let started = url.startAccessingSecurityScopedResource()
        guard (try? Data(contentsOf: url)) != nil else {
            if started { url.stopAccessingSecurityScopedResource() }
            throw Failure.unreadable
        }
        grantedURL = url
        scoped = started
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
    }

    func closeAccess() {
        if scoped { grantedURL?.stopAccessingSecurityScopedResource() }
        grantedURL = nil
        scoped = false
    }

    private var domain: CFString { fileURL.deletingPathExtension().path as CFString }

    private func positions() throws -> [String: NSNumber] {
        guard grantedURL != nil else { throw Failure.accessRequired }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              let values = CFPreferencesCopyValue(preferenceKey, domain,
                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: NSNumber] else {
            throw Failure.unreadable
        }
        return values
    }

    /// These read-only modules can remain configured while macOS omits their
    /// AX items from the collapsed menu bar.
    func configuredUnsupportedModules() throws -> Set<String> {
        try ensureAccess(promptIfNeeded: false)
        let keys = Set(try positions().keys)
        return keys.intersection(UnsupportedModulePresence.keys)
    }

    private func tableKey(for item: NativeItem, in positions: [String: NSNumber],
                          inventory: [NativeItem]) throws -> String {
        if let key = item.item.positionTableKey {
            guard positions[key] != nil else { throw Failure.unmatched }
            guard inventory.filter({ $0.item.positionTableKey == key }).count == 1 else { throw Failure.ambiguous }
            return key
        }
        return try PositionTableKeyResolver.resolve(item: item.item, inventory: inventory.map(\.item),
                                                    tableKeys: Set(positions.keys))
    }

    /// Returns after the native AX coordinates show the requested relation.
    /// On failure, restores only the source weight if it is still our write.
    func move(source: NativeItem, target: NativeItem, inventory: [NativeItem], placement: ItemMovePlacement,
              checkSession: () throws -> Void) async throws -> [NativeItem] {
        try checkSession()
        let values = try positions()
        let sourceKey = try tableKey(for: source, in: values, inventory: inventory)
        let targetKey = try tableKey(for: target, in: values, inventory: inventory)
        guard sourceKey != targetKey, let old = values[sourceKey]?.doubleValue,
              let targetWeight = values[targetKey]?.doubleValue,
              old.isFinite, targetWeight.isFinite, old != targetWeight,
              abs(source.frame.midY - target.frame.midY) <= 1,
              source.displays == target.displays,
              source.displays.contains(where: { display in
                  display.bounds.contains(CGPoint(x: source.frame.midX, y: source.frame.midY)) &&
                  display.bounds.contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
              }) else {
            logger.error("Position move rejected before write: stale geometry or weights")
            throw Failure.stale
        }
        // Calibrate the numeric axis against this Mac's observed AX order.
        let higherIsLeft = (old > targetWeight) == (source.frame.midX < target.frame.midX)
        let towardHigher = (placement == .before) == higherIsLeft
        guard let display = source.displays.first(where: {
            $0.bounds.contains(CGPoint(x: source.frame.midX, y: source.frame.midY))
        }) else { throw Failure.stale }
        func orderedIDs(_ entries: [NativeItem]) -> [String] {
            entries.filter { entry in
                entry.item.isSupported && entry.item.isDirectlyAccessible &&
                !entry.frame.isNull && abs(entry.frame.midY - source.frame.midY) <= 1 &&
                display.bounds.contains(CGPoint(x: entry.frame.midX, y: entry.frame.midY))
            }.sorted { $0.frame.midX < $1.frame.midX }.compactMap { ItemRegistry.observationID($0.item) }
        }
        var expected = orderedIDs(inventory)
        guard let sourceID = ItemRegistry.observationID(source.item),
              let targetID = ItemRegistry.observationID(target.item) else { throw Failure.unmatched }
        guard let oldIndex = expected.firstIndex(of: sourceID) else { throw Failure.stale }
        expected.remove(at: oldIndex)
        guard let targetIndex = expected.firstIndex(of: targetID) else { throw Failure.stale }
        expected.insert(sourceID, at: targetIndex + (placement == .after ? 1 : 0))
        let otherWeights = values.filter { $0.key != sourceKey }.values.map(\.doubleValue)
            .filter(\.isFinite)
        let neighbor = towardHigher
            ? otherWeights.filter { $0 > targetWeight }.min()
            : otherWeights.filter { $0 < targetWeight }.max()
        let candidate = neighbor.map { ($0 + targetWeight) / 2 }
            ?? (targetWeight + (towardHigher ? 1 : -1))
        guard candidate.isFinite, candidate != targetWeight, candidate != old,
              !otherWeights.contains(candidate) else { throw Failure.noSpace }
        var changed = values
        changed[sourceKey] = NSNumber(value: candidate)
        try checkSession()
        // CFPreferences persists the table as one value. Re-read just before
        // replacement and abort if MenuBarAgent changed any entry while we
        // planned the move; never apply a known-stale whole-dictionary write.
        guard try positions() == values else {
            logger.error("Position move rejected before write: position table changed")
            throw Failure.stale
        }
        CFPreferencesSetValue(preferenceKey, changed as CFDictionary, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw Failure.writeFailed
        }
        do {
            let hasSystemModule = source.item.positionTableKey?.hasPrefix("module:") == true ||
                target.item.positionTableKey?.hasPrefix("module:") == true
            let deadline = ContinuousClock.now.advanced(by: hasSystemModule ? .seconds(5) : .seconds(4))
            func sameItem(_ current: NativeItem, _ original: NativeItem) -> Bool {
                current.pid == original.pid && current.launchDate == original.launchDate &&
                    current.item.bundleID == original.item.bundleID &&
                    ItemRegistry.observationID(current.item) == ItemRegistry.observationID(original.item)
            }
            while ContinuousClock.now < deadline {
                try checkSession()
                let endpoints = try await NativeDiscovery.refresh(items: [source, target],
                    timeBudget: .milliseconds(400), verifyHits: false)
                let movedMatches = endpoints.filter { sameItem($0, source) }
                let anchorMatches = endpoints.filter { sameItem($0, target) }
                guard movedMatches.count == 1, anchorMatches.count == 1,
                      let moved = movedMatches.first, let anchor = anchorMatches.first,
                      !moved.frame.isNull, !anchor.frame.isNull,
                      abs(moved.frame.midY - anchor.frame.midY) <= 1 else {
                    logger.error("Position move verification: endpoint identity or geometry changed; sourceMatches=\(movedMatches.count, privacy: .public) targetMatches=\(anchorMatches.count, privacy: .public)")
                    throw Failure.stale
                }
                let correct = placement == .before
                    ? moved.frame.midX < anchor.frame.midX
                    : moved.frame.midX > anchor.frame.midX
                if correct, abs(moved.frame.midX - source.frame.midX) > 1 {
                    let fresh = try await NativeDiscovery.refresh(items: inventory,
                        validateMembership: true, timeBudget: .seconds(3), verifyHits: false)
                    guard fresh.count == inventory.count else { throw Failure.stale }
                    let restored = fresh.map { entry -> NativeItem in
                        let matches = inventory.filter { sameItem(entry, $0) }
                        guard matches.count == 1, let old = matches.first else { return entry }
                        return NativeItem(item: old.item, pid: entry.pid, frame: entry.frame,
                                          launchDate: entry.launchDate, displays: entry.displays)
                    }
                    let actual = orderedIDs(restored)
                    if actual.filter({ $0 == sourceID }).count == 1,
                       actual.filter({ $0 == targetID }).count == 1,
                       let movedIndex = actual.firstIndex(of: sourceID),
                       let anchorIndex = actual.firstIndex(of: targetID),
                       (placement == .before ? movedIndex < anchorIndex
                                             : movedIndex > anchorIndex) {
                        if actual != expected {
                            // macOS can rearrange other items while crossing a
                            // read-only module. The caller saves the full
                            // observed order after this verified relation.
                            logger.notice("Position move succeeded with menu-bar reflow; expectedAdjacent=\(abs(movedIndex - anchorIndex) == 1, privacy: .public)")
                        }
                        return restored
                    }
                    // AX can report an intermediate order during reflow. Keep
                    // checking until the deadline instead of rolling back on
                    // the first inconsistent full scan.
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw Failure.noReflow
        } catch {
            if var latest = try? positions(), latest[sourceKey]?.doubleValue == candidate {
                latest[sourceKey] = NSNumber(value: old)
                CFPreferencesSetValue(preferenceKey, latest as CFDictionary, domain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            throw error
        }
    }
}
