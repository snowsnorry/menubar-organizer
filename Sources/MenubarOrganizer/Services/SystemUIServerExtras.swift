import Foundation
import Darwin
import OSLog
import OrganizerCore

/// Individual legacy extras only. No operation here filters their shared owner.
@MainActor
final class SystemUIServerExtras {
    enum Failure: Error, LocalizedError {
        case unavailable, ambiguous(String), operation(String, OSStatus), verification(String)
        var diagnosticCode: String {
            switch self {
            case .unavailable: "legacyExtraUnavailable"
            case .ambiguous: "legacyExtraIdentityAmbiguous"
            case .operation: "legacyExtraOperationFailed"
            case .verification: "legacyExtraVerificationFailed"
            }
        }
        var errorDescription: String? {
            switch self {
            case .unavailable: "Legacy menu extra API or restoration bundle is unavailable."
            case .ambiguous(let id): "Legacy menu extra identity is not unique: \(id)."
            case .operation(let id, let status): "Legacy menu extra operation failed: \(id) (\(status))."
            case .verification(let id): "Legacy menu extra visibility could not be verified: \(id)."
            }
        }
    }

    struct API {
        var handle: (String) throws -> UInt32?
        var remove: (UInt32) -> OSStatus
        var add: (URL) -> OSStatus
    }

    struct ReceiptStore {
        var load: () -> Set<String>
        var save: (Set<String>) throws -> Void

        static var standard: ReceiptStore {
            let defaults = UserDefaults.standard
            let key = "LegacyMenuExtrasPendingRestoration"
            return ReceiptStore(load: { Set(defaults.stringArray(forKey: key) ?? []) }, save: { ids in
                defaults.set(ids.sorted(), forKey: key)
                // Persist the recovery intent before mutating SystemUIServer.
                guard defaults.synchronize() else { throw Failure.unavailable }
            })
        }
    }

    private let receiptStore: ReceiptStore
    private let logger = Logger(subsystem: "local.menubarorganizer.app", category: "legacyExtras")
    private let api: API?
    private let bundles: [String: [URL]]
    private let inventory: (Set<String>) async throws -> [DiscoveredItem]
    private let pause: () async throws -> Void
    /// Keep restoration receipts even after a failed remove/add or verification.
    private(set) var removed: Set<String> = []
    var isActive: Bool { !removed.isEmpty }
    /// Transient evidence owned by this backend, never a saved-layout assumption.
    var discoveryRemovedExtraIDs: Set<String> {
        guard let api else { return [] }
        return Set(removed.filter { (try? api.handle($0)) == nil })
    }

    private func readInventory() async throws -> [DiscoveredItem] {
        try await inventory(discoveryRemovedExtraIDs)
    }

    init(api: API? = SystemUIServerExtras.loadAPI(), bundles: [String: [URL]] = SystemUIServerExtras.extraBundles(),
         inventory: @escaping (Set<String>) async throws -> [DiscoveredItem] = { removed in
             try await NativeDiscovery.scanSystemUIServer(removedLegacyExtraIDs: removed).map(\.item)
         },
         pause: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) },
         receiptStore: ReceiptStore = .standard) {
        self.api = api; self.bundles = bundles; self.inventory = inventory; self.pause = pause
        self.receiptStore = receiptStore
        self.removed = receiptStore.load().intersection(ItemRegistry.legacyExtraBundleIDs)
        if !removed.isEmpty {
            logger.notice("Legacy recovery loaded; pending=\(self.removed.sorted().joined(separator: ","), privacy: .public)")
        }
    }

    private func recordRemoval(_ id: String) throws {
        let pending = removed.union([id])
        try receiptStore.save(pending)
        removed = pending
    }

    func setHidden(_ ids: Set<String>) async throws {
        logger.info("Legacy request; hidden=\(ids.sorted().joined(separator: ","), privacy: .public)")
        do { try await applyHidden(ids) } catch {
            let code = (error as? Failure)?.diagnosticCode ?? "legacyExtraInventoryFailed"
            logger.error("Legacy apply failed; reason=\(code, privacy: .public); detail=\(String(describing: error), privacy: .private)")
            // Unstructured cleanup does not inherit the caller's cancellation.
            let recovery = Task { @MainActor in try await self.restoreAll() }
            do { try await recovery.value } catch {
                logger.error("Legacy rollback failed; detail=\(String(describing: error), privacy: .private); pending=\(self.removed.sorted().joined(separator: ","), privacy: .public)")
                throw error
            }
            logger.notice("Legacy rollback verified; pending=\(self.removed.count, privacy: .public)")
            throw error
        }
    }

    private func applyHidden(_ ids: Set<String>) async throws {
        guard ids.isSubset(of: ItemRegistry.legacyExtraBundleIDs) else { throw Failure.unavailable }
        try await restore(removed.subtracting(ids))
        let additions = ids.subtracting(removed).sorted()
        guard !additions.isEmpty else { return }
        guard let api else { throw Failure.unavailable }
        // Validate every requested identity and recovery path before mutating any extra.
        let before = try await readInventory()
        logInventory(before, phase: "preflight", id: additions.joined(separator: ","), attempt: 0)
        _ = try Self.ownerIdentities(before)
        var handles: [String: UInt32] = [:]
        for id in additions {
            guard bundles[id]?.count == 1 else { throw Failure.unavailable }
            let matches = before.filter { $0.bundleID == "com.apple.systemuiserver" && $0.positionTableKey == Self.key(id) }
            guard matches.count == 1, matches[0].isSupported, matches[0].isDirectlyAccessible,
                  let handle = try api.handle(id) else { throw Failure.ambiguous(id) }
            handles[id] = handle
        }
        for sibling in ItemRegistry.legacyExtraBundleIDs.subtracting(Set(additions))
            where Self.uniqueVisible(sibling, in: before) {
            guard bundles[sibling]?.count == 1 else { throw Failure.unavailable }
            guard let handle = try api.handle(sibling), !handles.values.contains(handle) else {
                throw Failure.ambiguous(sibling)
            }
        }
        guard Set(handles.values).count == handles.count else { throw Failure.ambiguous(additions.joined(separator: ", ")) }
        let targets = Set(additions)
        let expected = try Self.ownerIdentities(before).subtracting(targets.map { "position:" + Self.key($0) })
        let survivingSiblings = ItemRegistry.legacyExtraBundleIDs.subtracting(targets).filter {
            Self.uniqueVisible($0, in: before)
        }
        do {
            // No AX reads or suspension between mutations: use the validated
            // snapshot, checking each API handle immediately before removal.
            for id in additions {
                try Task.checkCancellation()
                guard let handle = handles[id] else { throw Failure.ambiguous(id) }
                try recordRemoval(id)
                guard try api.handle(id) == handle else { throw Failure.ambiguous(id) }
                let status = api.remove(handle)
                logger.notice("CoreMenuExtra remove; id=\(id, privacy: .public); status=\(status, privacy: .public)")
                guard status == 0 else { throw Failure.operation(id, status) }
            }
            try await verify(additions.joined(separator: ","), phase: "remove") { current in
                guard try Self.ownerIdentities(current) == expected,
                      survivingSiblings.allSatisfy({ Self.uniqueVisible($0, in: current) }) else { return false }
                return try additions.allSatisfy { try api.handle($0) == nil }
            }
        } catch {
            // Recover any known, originally visible sibling affected by the
            // service, including a partial batch failure before verification.
            for sibling in ItemRegistry.legacyExtraBundleIDs where Self.uniqueVisible(sibling, in: before) {
                if (try? api.handle(sibling)) == nil { removed.insert(sibling) }
            }
            // The mutation already happened: keep in-memory recovery intent
            // even if writing the additional sibling receipt fails.
            try? receiptStore.save(removed)
            throw error
        }
    }

    func restoreAll() async throws {
        try await restore(removed)
    }

    private func restore(_ ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        guard let api else { throw Failure.unavailable }
        var firstError: (any Error)?
        var candidates: [String] = []
        // Add every restorable extra before waiting for AX. Keep failed receipts
        // and verify successful additions even if another addition failed.
        for id in ids.sorted() {
            do {
                guard let paths = bundles[id], paths.count == 1 else { throw Failure.unavailable }
                if try api.handle(id) == nil {
                    let status = api.add(paths[0])
                    logger.notice("CoreMenuExtra add; id=\(id, privacy: .public); status=\(status, privacy: .public)")
                    guard status == 0 else { throw Failure.operation(id, status) }
                }
                candidates.append(id)
            } catch { if firstError == nil { firstError = error } }
        }
        if !candidates.isEmpty {
            do {
                try await verify(candidates.joined(separator: ","), phase: "restore") { current in
                    try candidates.allSatisfy {
                        guard Self.uniqueVisible($0, in: current) else { return false }
                        return try api.handle($0) != nil
                    }
                }
                let pending = removed.subtracting(candidates)
                try receiptStore.save(pending)
                removed = pending
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func verify(_ id: String, phase: String, matches: ([DiscoveredItem]) throws -> Bool) async throws {
        var lastIdentityError: Failure?
        for attempt in 0..<10 {
            let current: [DiscoveredItem]
            do { current = try await readInventory() } catch {
                let reason = (error as? NativeDiscoveryError).map { String(describing: $0) } ?? "inventoryReadFailed"
                logger.error("Legacy AX scan failed; phase=\(phase, privacy: .public); id=\(id, privacy: .public); reason=\(reason, privacy: .public); detail=\(String(describing: error), privacy: .private)")
                throw error
            }
            logInventory(current, phase: phase, id: id, attempt: attempt + 1)
            let verified: Bool
            do {
                verified = try matches(current)
                lastIdentityError = nil
            } catch let failure as Failure {
                // Removing a scene can temporarily replace AX children with
                // unnamed or duplicate rows. Such a snapshot proves neither
                // success nor failure; require a later stable snapshot.
                guard phase == "remove", case .ambiguous = failure else { throw failure }
                lastIdentityError = failure
                verified = false
                logger.info("Legacy AX identity is not settled; phase=\(phase, privacy: .public); id=\(id, privacy: .public); attempt=\(attempt + 1, privacy: .public); retrying=true")
            }
            if verified {
                logger.info("Legacy AX verified; phase=\(phase, privacy: .public); id=\(id, privacy: .public); attempts=\(attempt + 1, privacy: .public)")
                return
            }
            if attempt < 9 { try await pause() }
        }
        logger.error("Legacy AX verification timed out; phase=\(phase, privacy: .public); id=\(id, privacy: .public)")
        throw lastIdentityError ?? Failure.verification(id)
    }

    private func logInventory(_ items: [DiscoveredItem], phase: String, id: String, attempt: Int) {
        let owner = items.filter { $0.bundleID == "com.apple.systemuiserver" }
        let unidentified = owner.filter { $0.positionTableKey == nil && $0.identifier?.isEmpty != false }.count
        let identities = owner.compactMap { item -> String? in
            if let key = item.positionTableKey { return "position:" + key }
            if let identifier = item.identifier, !identifier.isEmpty { return "identifier:" + identifier }
            return nil
        }
        let duplicateCount = identities.count - Set(identities).count
        let vpnRows = owner.filter { $0.positionTableKey == Self.key("com.apple.menuextra.vpn") }.count
        let tmRows = owner.filter { $0.positionTableKey == Self.key("com.apple.menuextra.TimeMachine") }.count
        logger.info("Legacy AX inventory; phase=\(phase, privacy: .public); id=\(id, privacy: .public); attempt=\(attempt, privacy: .public); ownerRows=\(owner.count, privacy: .public); unidentifiedRows=\(unidentified, privacy: .public); duplicateIdentities=\(duplicateCount, privacy: .public); vpnRows=\(vpnRows, privacy: .public); timeMachineRows=\(tmRows, privacy: .public)")
    }

    /// Synchronous shutdown/invalidation cannot await AX. Retain receipts so a
    /// subsequent asynchronous reveal still verifies restoration or retries it.
    func restoreBestEffort() {
        guard let api else { return }
        for id in removed.sorted() {
            do {
                guard try api.handle(id) == nil, let paths = bundles[id], paths.count == 1 else { continue }
                let status = api.add(paths[0])
                logger.notice("CoreMenuExtra shutdown add; id=\(id, privacy: .public); status=\(status, privacy: .public)")
                if status != 0 { throw Failure.operation(id, status) }
            } catch {
                Logger(subsystem: "local.menubarorganizer.app", category: "visibility")
                    .error("Legacy extra restoration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func ownerIdentities(_ items: [DiscoveredItem]) throws -> Set<String> {
        let owner = items.filter { $0.bundleID == "com.apple.systemuiserver" }
        let identities = try owner.map { item -> String in
            if let key = item.positionTableKey { return "position:" + key }
            if let identifier = item.identifier, !identifier.isEmpty { return "identifier:" + identifier }
            throw Failure.ambiguous("com.apple.systemuiserver")
        }
        guard Set(identities).count == identities.count else { throw Failure.ambiguous("com.apple.systemuiserver") }
        return Set(identities)
    }

    private static func key(_ id: String) -> String { "status:com.apple.systemuiserver::\(id)" }
    private static func uniqueVisible(_ id: String, in items: [DiscoveredItem]) -> Bool {
        let matches = items.filter { $0.bundleID == "com.apple.systemuiserver" && $0.positionTableKey == key(id) }
        return matches.count == 1 && matches[0].isSupported && matches[0].isDirectlyAccessible
    }

    private static func extraBundles() -> [String: [URL]] {
        let directory = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: [URL]] = [:]
        for url in urls where url.pathExtension == "menu" {
            guard let id = Bundle(url: url)?.bundleIdentifier, ItemRegistry.legacyExtraBundleIDs.contains(id) else { continue }
            result[id, default: []].append(url)
        }
        return result
    }

    /// ABI follows happy666End/MenuBarHider's SystemUIServerExtras.swift.
    /// Keep the framework open for the entire lifetime of the function pointers.
    private static func loadAPI() -> API? {
        typealias Handle = UnsafeMutableRawPointer
        typealias Get = @convention(c) (CFString, UnsafeMutablePointer<Handle?>) -> OSStatus
        typealias Add = @convention(c) (CFURL, Int32, Int32, Int32, Int32, Int32) -> OSStatus
        typealias Remove = @convention(c) (Handle, Int32) -> OSStatus
        guard let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let getSymbol = dlsym(image, "CoreMenuExtraGetMenuExtra"),
              let addSymbol = dlsym(image, "CoreMenuExtraAddMenuExtra"),
              let removeSymbol = dlsym(image, "CoreMenuExtraRemoveMenuExtra") else { dlclose(image); return nil }
        let get = unsafeBitCast(getSymbol, to: Get.self)
        let add = unsafeBitCast(addSymbol, to: Add.self)
        let remove = unsafeBitCast(removeSymbol, to: Remove.self)
        return API(handle: { id in
            var raw: Handle?
            let status = get(id as CFString, &raw)
            Logger(subsystem: "local.menubarorganizer.app", category: "legacyExtras")
                .info("CoreMenuExtra get; id=\(id, privacy: .public); status=\(status, privacy: .public); handlePresent=\(raw != nil, privacy: .public)")
            // Like the reference, an unsuccessful get yields no loaded handle.
            // This never proves absence: AX must independently verify removal,
            // and a preflight without a loaded handle never authorizes hiding.
            guard status == 0 else { return nil }
            // The private API writes only the low 32 bits of this out pointer.
            let value = UInt32(truncatingIfNeeded: UInt(bitPattern: raw))
            return value == 0 ? nil : value
        }, remove: { value in remove(Handle(bitPattern: UInt(value))!, 0) },
        add: { url in add(url as CFURL, 0, 0, 0, 0, 0) })
    }
}
