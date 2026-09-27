import AppKit
import ApplicationServices
import OrganizerCore

/// Ephemeral AX geometry in global top-left points. Never persist this value.
struct NativeItem: Sendable {
    let item: DiscoveredItem
    let pid: pid_t
    /// `.null` means AX did not supply usable geometry.
    let frame: CGRect
    let launchDate: Date?
    let displays: [NativeDisplay]
}

struct NativeDisplay: Sendable, Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
}

enum NativeDiscoveryError: Error, Equatable, Sendable {
    case permissionDenied
    case timeBudgetExceeded
    case inventoryLimitExceeded
    case staleGeometry
    case ambiguousIdentity
}

/// Read-only inventory. No AX objects escape the detached worker and no AX
/// reads execute on the main actor. Direct access is evidence at scan time,
/// not authorization to reuse these coordinates for a later gesture.
enum NativeDiscovery {
    private struct Target: Sendable {
        let pid: pid_t
        let bundleID: String?
        let name: String
        let launchDate: Date?
    }

    static func scan() async throws -> [NativeItem] {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw NativeDiscoveryError.permissionDenied }
        let targets: [Target] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                return Target(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                              name: app.localizedName ?? app.bundleIdentifier ?? "", launchDate: app.launchDate)
            }.sorted { $0.pid < $1.pid }
        }
        let worker = Task.detached(priority: .utility) { try read(targets) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    /// Refresh only known menu-bar owners. The caller must invalidate its cache
    /// when the process inventory changes; endpoint verification remains mandatory.
    static func refresh(items: [NativeItem], validateMembership: Bool = false,
                        timeBudget: Duration = .seconds(2), verifyHits: Bool = true) async throws -> [NativeItem] {
        let deadline = ContinuousClock.now.advanced(by: timeBudget)
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw NativeDiscoveryError.permissionDenied }
        let owners = Dictionary(grouping: items, by: \.pid)
        let targets: [Target] = try await MainActor.run {
            try owners.map { pid, entries in
                guard let entry = entries.first,
                      let app = NSRunningApplication(processIdentifier: pid),
                      !app.isTerminated, app.bundleIdentifier == entry.item.bundleID,
                      app.launchDate == entry.launchDate else { throw NativeDiscoveryError.staleGeometry }
                return Target(pid: pid, bundleID: app.bundleIdentifier,
                              name: app.localizedName ?? app.bundleIdentifier ?? "", launchDate: app.launchDate)
            }.sorted { $0.pid < $1.pid }
        }
        let otherTargets: [Target] = await MainActor.run {
            guard validateMembership else { return [] }
            return NSWorkspace.shared.runningApplications.compactMap { app in
                guard owners[app.processIdentifier] == nil else { return nil }
                return Target(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                              name: app.localizedName ?? "", launchDate: app.launchDate)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            // Running applications may add their first item without launching.
            // Probe previously empty owners, avoiding full metadata/hit-test work.
            guard otherTargets.count <= 512 else { throw NativeDiscoveryError.inventoryLimitExceeded }
            for target in otherTargets {
                try checkpoint(deadline)
                let root = AXUIElementCreateApplication(target.pid)
                if let raw = try attribute(root, kAXExtrasMenuBarAttribute, deadline),
                   CFGetTypeID(raw) == AXUIElementGetTypeID(),
                   let children = try attribute(unsafeDowncast(raw, to: AXUIElement.self), kAXChildrenAttribute, deadline) as? [AXUIElement],
                   !children.isEmpty { throw NativeDiscoveryError.staleGeometry }
            }
            return try read(targets, deadline: deadline, cached: items, verifyHits: verifyHits)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    private static func read(_ targets: [Target],
                             deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(20)),
                             cached: [NativeItem] = [], verifyHits: Bool = true) throws -> [NativeItem] {
        let displays = try topology()
        guard targets.count <= 512 else { throw NativeDiscoveryError.inventoryLimitExceeded }
        var inventory: [NativeItem] = []
        for target in targets {
            try checkpoint(deadline)
            let root = AXUIElementCreateApplication(target.pid)
            guard let raw = try attribute(root, kAXExtrasMenuBarAttribute, deadline),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let bar = unsafeDowncast(raw, to: AXUIElement.self)
            guard let children = try attribute(bar, kAXChildrenAttribute, deadline) as? [AXUIElement] else { continue }
            guard children.count <= 128, inventory.count + children.count <= 512 else {
                throw NativeDiscoveryError.inventoryLimitExceeded
            }
            for (childIndex, child) in children.enumerated() {
                let (identifier, rectangle) = try identityAndFrame(child, deadline)
                let bundle = target.bundleID.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                let isSystem = bundle?.hasPrefix("com.apple.") == true
                // During one explicit apply, names and classification remain
                // presentation data. Refresh identity/geometry without repeatedly
                // walking the system label subtree for an unchanged child.
                let previous = cached.filter { old in
                    // A system owner may replace its sole status item without
                    // changing PID, index or AX identifier. Reclassify it on
                    // every refresh before using a position-table key.
                    guard !isSystem else { return false }
                    guard old.pid == target.pid, old.launchDate == target.launchDate,
                          old.item.bundleID == bundle, old.item.identifier == identifier else { return false }
                    return identifier?.isEmpty == false || children.count == 1
                }
                if previous.count == 1, let old = previous.first {
                    var item = old.item
                    item.isDirectlyAccessible = false
                    inventory.append(NativeItem(item: item, pid: target.pid, frame: rectangle,
                                                launchDate: target.launchDate, displays: displays))
                    continue
                }
                var metadata = isSystem ? try systemMetadata(child, deadline) : []
                // Legacy SystemUIServer extras can expose no AX label at all.
                // The configured module is unambiguous only with one configured
                // extra and one observed item; never zip preferences to positions.
                if bundle == "com.apple.systemuiserver", children.count == 1,
                   let modules = CFPreferencesCopyAppValue("menuExtras" as CFString, "com.apple.systemuiserver" as CFString) as? [String],
                   modules.count == 1, let module = modules.first {
                    metadata.append(URL(fileURLWithPath: module).lastPathComponent)
                }
                let kind = bundle.flatMap { SystemMenuItemKind.identify(bundleID: $0, metadata: metadata) }
                // Known module names have distinct keys in macOS 27's position
                // table. Duplicate observations are rejected below and by the
                // position store before a write.
                let positionKey: String?
                if bundle == "com.apple.controlcenter" || bundle == "com.apple.MenuBarAgent" {
                    let matches = SystemMenuItemKind.modulePositionKeys(metadata: metadata)
                    if matches.count == 1 {
                        positionKey = matches.first
                    } else if matches.isEmpty, kind == .focus,
                              metadata.contains(where: { value in
                                  let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
                                  return ["focus", "focusmodes", "donotdisturb", "фокусирование"].contains(normalized)
                              }) {
                        // The module's AX label is localized on some systems;
                        // require an exact Focus label, never a substring from
                        // the Control Center host's broader subtree.
                        positionKey = "module:FocusModes"
                    } else {
                        positionKey = nil
                    }
                } else if children.count == 1 {
                    positionKey = switch (bundle, kind) {
                    case ("com.apple.TextInputMenuAgent", .inputSource): "status:com.apple.TextInputMenuAgent::Item-0"
                    case ("com.apple.systemuiserver", .timeMachine): "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine"
                    case ("com.apple.weather.menu", .weather): "status:com.apple.weather.menu::Item-0"
                    case ("com.apple.campo", .spotlight): "status:com.apple.campo::Item-0"
                    default: nil
                    }
                } else {
                    positionKey = nil
                }
                let name = isSystem
                    ? kind.map { L10n.text($0.localizationKey) } ?? metadata.first(where: {
                        !$0.contains("com.apple.") && !$0.contains("MenuExtraHost") && !$0.contains("MenuBarAgent") && $0.count <= 100
                    }) ?? L10n.text("system.other")
                    : target.name
                inventory.append(NativeItem(item: DiscoveredItem(bundleID: bundle, identifier: identifier,
                    name: name, isDirectlyAccessible: false,
                    isSupported: positionKey != nil || (bundle.map { !$0.hasPrefix("com.apple.") } ?? false),
                    presentationID: isSystem ? "\(target.pid):\(childIndex)" : nil,
                    positionTableKey: positionKey),
                    pid: target.pid, frame: rectangle, launchDate: target.launchDate, displays: displays))
            }
        }
        // Bundle fallback is only an individually addressable icon when its
        // bundle has exactly one observed item, including across processes.
        let counts = Dictionary(grouping: inventory, by: { $0.item.bundleID })
        for index in inventory.indices {
            let entry = inventory[index]
            guard entry.item.isSupported, valid(entry.frame) else { continue }
            if entry.item.positionTableKey != nil {
                let unique = inventory.filter { $0.item.positionTableKey == entry.item.positionTableKey }.count == 1
                var item = entry.item
                item.isDirectlyAccessible = unique && displays.contains { display in
                    display.bounds.contains(CGPoint(x: entry.frame.midX, y: entry.frame.midY))
                }
                inventory[index] = NativeItem(item: item, pid: entry.pid, frame: entry.frame,
                                              launchDate: entry.launchDate, displays: displays)
                continue
            }
            guard verifyHits else { continue }
            let explicit = entry.item.identifier?.isEmpty == false
            let single = counts[entry.item.bundleID]?.count == 1
            guard explicit || single else { continue }
            let directlyAccessible = try hitMatches(entry, deadline)
            var item = entry.item
            item.isDirectlyAccessible = directlyAccessible
            inventory[index] = NativeItem(item: item, pid: entry.pid, frame: entry.frame,
                                         launchDate: entry.launchDate, displays: displays)
        }
        try checkpoint(deadline)
        guard AXIsProcessTrusted() else { throw NativeDiscoveryError.permissionDenied }
        guard try topology() == displays else { throw NativeDiscoveryError.staleGeometry }
        return inventory.sorted { left, right in
            let lv = valid(left.frame), rv = valid(right.frame)
            if lv != rv { return lv }
            if lv, left.frame.minX != right.frame.minX { return left.frame.minX < right.frame.minX }
            if lv, left.frame.minY != right.frame.minY { return left.frame.minY < right.frame.minY }
            if left.pid != right.pid { return left.pid < right.pid }
            return (left.item.identifier ?? "") < (right.item.identifier ?? "")
        }
    }

    /// macOS 27 wraps system buttons in AX groups; inspect only the shallow
    /// status-item subtree, never the contents of an opened menu.
    private static func systemMetadata(_ element: AXUIElement, _ deadline: ContinuousClock.Instant) throws -> [String] {
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var identifiers: [String] = [], labels: [String] = []
        var visited: [AXUIElement] = []
        while !queue.isEmpty, visited.count < 24 {
            let (node, depth) = queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            let role = try attribute(node, kAXRoleAttribute, deadline) as? String
            if role == kAXMenuRole { continue }
            if let value = try attribute(node, kAXIdentifierAttribute, deadline) as? String, !value.isEmpty { identifiers.append(value) }
            for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
                if let value = try attribute(node, key, deadline) as? String {
                    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { labels.append(text) }
                }
            }
            if depth < 2, let children = try attribute(node, kAXChildrenAttribute, deadline) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(12).map { ($0, depth + 1) })
            }
        }
        return identifiers + labels
    }

    /// Re-read exact identities and frames, then system-hit-test both endpoints.
    /// The caller must post immediately and discard evidence older than 0.25s.
    /// A fresh scan alone is deliberately not sufficient for gesture execution.
    static func verifyForMove(source: NativeItem, target: NativeItem,
                              sourcePoint: CGPoint, targetPoint: CGPoint,
                              crossings: [NativeItem] = []) async throws -> ContinuousClock.Instant {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        try checkpoint(deadline)
        guard AXIsProcessTrusted() else { throw NativeDiscoveryError.permissionDenied }
        let targets: [Target] = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == source.item.bundleID || $0.bundleIdentifier == target.item.bundleID ||
                    crossings.map(\.pid).contains($0.processIdentifier)
            }.map { Target(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                           name: $0.localizedName ?? "", launchDate: $0.launchDate) }
        }
        let worker = Task.detached(priority: .userInitiated) {
            try checkpoint(deadline)
            guard source.item.isSupported, target.item.isSupported,
                  source.item.isDirectlyAccessible, target.item.isDirectlyAccessible,
                  source.displays == target.displays,
                  try topology() == source.displays else { throw NativeDiscoveryError.staleGeometry }
            // Timestamp the oldest evidence, not the end of a potentially slow
            // second endpoint read. The caller's age limit covers both points.
            let verifiedAt = ContinuousClock.now
            // System status items need not support system-wide hit testing.
            // We never click them: validate their owning process and freshly
            // read menu-bar frame; reserve exact hit tests for the endpoints.
            for crossing in crossings {
                guard crossing.displays == source.displays,
                      targets.contains(where: { $0.pid == crossing.pid && $0.launchDate == crossing.launchDate && $0.bundleID == crossing.item.bundleID }) else {
                    throw NativeDiscoveryError.staleGeometry
                }
                let root = AXUIElementCreateApplication(crossing.pid)
                guard let rawBar = try attribute(root, kAXExtrasMenuBarAttribute, deadline),
                      CFGetTypeID(rawBar) == AXUIElementGetTypeID(),
                      let children = try attribute(unsafeDowncast(rawBar, to: AXUIElement.self), kAXChildrenAttribute, deadline) as? [AXUIElement],
                      children.count <= 128 else { throw NativeDiscoveryError.staleGeometry }
                var matches = 0
                for child in children {
                    if try frame(child, deadline) == crossing.frame,
                       try attribute(child, kAXIdentifierAttribute, deadline) as? String == crossing.item.identifier {
                        matches += 1
                    }
                }
                guard matches == 1 else { throw NativeDiscoveryError.staleGeometry }
            }
            var ownerChildren: [pid_t: [(String?, CGRect)]] = [:]
            for (entry, point) in [(source, sourcePoint), (target, targetPoint)] {
                guard point.x.isFinite, point.y.isFinite, entry.frame.contains(point) else {
                    throw NativeDiscoveryError.staleGeometry
                }
                guard let launchDate = entry.launchDate,
                      targets.contains(where: { $0.pid == entry.pid && $0.launchDate == launchDate && $0.bundleID == entry.item.bundleID }) else {
                    throw NativeDiscoveryError.staleGeometry
                }
                var matches: [(pid_t, CGRect)] = []
                let explicit = entry.item.identifier?.isEmpty == false
                for app in targets where app.bundleID == entry.item.bundleID {
                    if ownerChildren[app.pid] == nil {
                        let root = AXUIElementCreateApplication(app.pid)
                        guard let rawBar = try attribute(root, kAXExtrasMenuBarAttribute, deadline),
                              CFGetTypeID(rawBar) == AXUIElementGetTypeID(),
                              let children = try attribute(unsafeDowncast(rawBar, to: AXUIElement.self), kAXChildrenAttribute, deadline) as? [AXUIElement] else {
                            throw NativeDiscoveryError.ambiguousIdentity
                        }
                        guard children.count <= 128 else { throw NativeDiscoveryError.inventoryLimitExceeded }
                        ownerChildren[app.pid] = try children.map { try identityAndFrame($0, deadline) }
                    }
                    for (identifier, rectangle) in ownerChildren[app.pid] ?? [] {
                        if !explicit || identifier == entry.item.identifier { matches.append((app.pid, rectangle)) }
                    }
                }
                guard matches.count == 1 else { throw NativeDiscoveryError.ambiguousIdentity }
                guard matches[0].0 == entry.pid, matches[0].1 == entry.frame,
                      try hitMatches(entry, deadline, at: point) else { throw NativeDiscoveryError.staleGeometry }
            }
            try checkpoint(deadline)
            guard AXIsProcessTrusted() else { throw NativeDiscoveryError.permissionDenied }
            guard try topology() == source.displays else { throw NativeDiscoveryError.staleGeometry }
            return verifiedAt
        }
        return try await withTaskCancellationHandler {
            let verifiedAt = try await worker.value
            try Task.checkCancellation()
            try checkpoint(deadline)
            return verifiedAt
        } onCancel: { worker.cancel() }
    }

    private static func topology() throws -> [NativeDisplay] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displays, &count) == .success, count > 0, count < 32 else {
            throw NativeDiscoveryError.staleGeometry
        }
        return displays.prefix(Int(count)).map { NativeDisplay(id: $0, bounds: CGDisplayBounds($0)) }.sorted { $0.id < $1.id }
    }

    private static func checkpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw NativeDiscoveryError.timeBudgetExceeded }
    }

    private static func attribute(_ element: AXUIElement, _ name: String,
                                  _ deadline: ContinuousClock.Instant) throws -> CFTypeRef? {
        try checkpoint(deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        AXUIElementSetMessagingTimeout(element, Float(max(0.001, min(0.10, seconds))))
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        // A target can reject AX independently of this process's TCC grant.
        // Keep unavailable targets non-addressable; only global trust loss
        // invalidates the entire inventory. Move verification still requires
        // successful fresh attributes and a matching hit at both endpoints.
        if status == .apiDisabled, !AXIsProcessTrusted() { throw NativeDiscoveryError.permissionDenied }
        return status == .success ? value : nil
    }

    /// One IPC for the attributes needed in geometry refreshes. Individual AX
    /// errors remain unavailable values, never evidence of an addressable icon.
    private static func identityAndFrame(_ element: AXUIElement, _ deadline: ContinuousClock.Instant) throws -> (String?, CGRect) {
        try checkpoint(deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        AXUIElementSetMessagingTimeout(element, Float(max(0.001, min(0.10, seconds))))
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element,
            [kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &raw)
        if status == .apiDisabled, !AXIsProcessTrusted() { throw NativeDiscoveryError.permissionDenied }
        guard status == .success, let values = raw as? [AnyObject], values.count == 3 else {
            // Some custom accessibility providers don't implement batch reads.
            return (try attribute(element, kAXIdentifierAttribute, deadline) as? String,
                    try frame(element, deadline) ?? .null)
        }
        let identifier = values[0] as? String
        guard CFGetTypeID(values[1]) == AXValueGetTypeID(), CFGetTypeID(values[2]) == AXValueGetTypeID() else {
            return (identifier, .null)
        }
        let position = unsafeDowncast(values[1], to: AXValue.self)
        let size = unsafeDowncast(values[2], to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return (identifier, .null) }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else {
            return (identifier, .null)
        }
        let rectangle = CGRect(origin: origin, size: dimensions)
        return (identifier, valid(rectangle) ? rectangle : .null)
    }

    private static func frame(_ element: AXUIElement, _ deadline: ContinuousClock.Instant) throws -> CGRect? {
        guard let rawPosition = try attribute(element, kAXPositionAttribute, deadline),
              let rawSize = try attribute(element, kAXSizeAttribute, deadline),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let position = unsafeDowncast(rawPosition, to: AXValue.self)
        let size = unsafeDowncast(rawSize, to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        let result = CGRect(origin: origin, size: dimensions)
        return valid(result) ? result : nil
    }

    private static func valid(_ rectangle: CGRect) -> Bool {
        [rectangle.origin.x, rectangle.origin.y, rectangle.size.width, rectangle.size.height,
         rectangle.maxX, rectangle.maxY].allSatisfy { $0.isFinite && abs($0) < 1_000_000 } &&
            rectangle.size.width > 0 && rectangle.size.height > 0
    }

    private static func hitMatches(_ entry: NativeItem, _ deadline: ContinuousClock.Instant,
                                   at requestedPoint: CGPoint? = nil) throws -> Bool {
        try checkpoint(deadline)
        let point = requestedPoint ?? CGPoint(x: entry.frame.midX, y: entry.frame.midY)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.10)
        var node: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &node)
        // A target can reject AX independently of this process's TCC grant.
        // Keep unavailable targets non-addressable; only global trust loss
        // invalidates the entire inventory. Move verification still requires
        // successful fresh attributes and a matching hit at both endpoints.
        if status == .apiDisabled, !AXIsProcessTrusted() { throw NativeDiscoveryError.permissionDenied }
        guard status == .success else { return false }
        var seen: [AXUIElement] = []
        for _ in 0..<8 {
            try checkpoint(deadline)
            guard let current = node, !seen.contains(where: { CFEqual($0, current) }) else { return false }
            seen.append(current)
            AXUIElementSetMessagingTimeout(current, 0.10)
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success, owner == entry.pid else { return false }
            let (identifier, actual) = try identityAndFrame(current, deadline)
            let identityMatches = entry.item.identifier?.isEmpty != false || identifier == entry.item.identifier
            if identityMatches, valid(actual), actual.contains(point),
               zip([actual.minX, actual.minY, actual.maxX, actual.maxY],
                   [entry.frame.minX, entry.frame.minY, entry.frame.maxX, entry.frame.maxY])
                    .allSatisfy({ abs($0 - $1) <= 0.5 }) { return true }
            guard let parent = try attribute(current, kAXParentAttribute, deadline),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }
}
