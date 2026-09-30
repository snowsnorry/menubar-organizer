import AppKit
import Darwin
import ObjectiveC
import OSLog
import OrganizerCore

/// Bundle-wide private assessment adapter, restricted to the tested OS build.
/// Successful activation means the service accepted the request, not that every
/// icon or system interaction has been independently verified.
@MainActor
final class VisibilityDriver {
    enum DriverError: Error, LocalizedError, Sendable {
        case unsupportedBuild
        case runtimeUnavailable
        case competingManager
        case invalidTarget(String)
        case targetNotRunning(String)
        case allocationFailed
        case activationFailed(String)
        case activationTimedOut
        case superseded
        case inventoryChanged

        var errorDescription: String? {
            switch self {
            case .unsupportedBuild: "Visibility control is supported only on the tested macOS build 26A428."
            case .runtimeUnavailable: "The menu bar service is unavailable or its interface has changed."
            case .competingManager: "Another menu bar manager is running."
            case .invalidTarget(let bundle): "This application cannot be hidden: \(bundle)."
            case .targetNotRunning(let bundle): "This application is not running: \(bundle)."
            case .allocationFailed: "The menu bar visibility request could not be created."
            case .activationFailed(let message): "The menu bar visibility request failed: \(message)"
            case .activationTimedOut: "The menu bar service did not respond in time."
            case .superseded: "A newer visibility request replaced this request."
            case .inventoryChanged: "The running applications changed; hidden items were requested to be revealed."
            }
        }
    }

    private var assessmentActive = false
    private let legacyExtras: SystemUIServerExtras
    private let assessmentApply: (@MainActor (Set<String>) async throws -> Void)?
    private(set) var legacyWarnings: [VisibilityWarning] = []
    var isActive: Bool { assessmentActive || legacyExtras.isActive }
    var discoveryRemovedLegacyExtraIDs: Set<String> { legacyExtras.discoveryRemovedExtraIDs }
    /// Called when an active or pending request is invalidated by an error or
    /// application inventory change. The model must clear its hidden-state UI.
    var onInvalidated: (@MainActor (DriverError) -> Void)?

    private var runtime: Runtime?
    private var session: Session?
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var sessionBundles: Set<String> = []
    private var launchInvalidationTask: Task<Void, Never>?

    init(legacyExtras: SystemUIServerExtras = SystemUIServerExtras(),
         assessmentApply: (@MainActor (Set<String>) async throws -> Void)? = nil,
         observeApplications: Bool = true) {
        self.legacyExtras = legacyExtras
        self.assessmentApply = assessmentApply
        guard observeApplications else { return }
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let launched = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, self.session != nil else { return }
                guard let launched, self.sessionBundles.contains(launched) else {
                    self.launchInvalidationTask?.cancel()
                    self.launchInvalidationTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                        guard let self, !Task.isCancelled, self.session != nil else { return }
                        Logger(subsystem: "local.menubarorganizer.app", category: "visibility")
                            .notice("Visibility filter released after application launch burst")
                        self.invalidate(reason: .inventoryChanged)
                    }
                    return
                }
            }
        }
        observers.append(observer)
    }

    isolated deinit {
        invalidate(reason: nil)
        legacyExtras.restoreBestEffort()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func setHiddenApplications(_ targets: Set<String>) async throws {
        let legacy = Set(targets.filter { $0.hasPrefix(ItemRegistry.legacyExtraTargetPrefix) })
        let ids = Set(legacy.map { String($0.dropFirst(ItemRegistry.legacyExtraTargetPrefix.count)) })
        guard ids.isSubset(of: ItemRegistry.legacyExtraBundleIDs) else {
            throw DriverError.invalidTarget(legacy.sorted().first ?? "legacy-extra")
        }
        if assessmentApply == nil, !legacy.isEmpty, NSWorkspace.shared.runningApplications.contains(where: {
            !$0.isTerminated && Self.isCompetingManager(($0.bundleIdentifier ?? "") + " " + ($0.localizedName ?? ""))
        }) { throw DriverError.competingManager }
        // Only assessment failures propagate to the general visibility policy.
        // Its validated filter survives any subsequent legacy extra failure.
        try await setAssessmentHiddenApplications(targets.subtracting(legacy))
        legacyWarnings = []
        do {
            try await legacyExtras.setHidden(ids)
        } catch {
            if error is CancellationError { throw error }
            let affected = ids.union(legacyExtras.removed)
            let reason = legacyExtras.removed.isEmpty
                ? (error as? SystemUIServerExtras.Failure)?.diagnosticCode ?? "legacyExtraInventoryFailed"
                : "legacyExtraRecoveryFailed"
            legacyWarnings = affected.sorted().map {
                VisibilityWarning(target: ItemRegistry.legacyExtraTargetPrefix + $0, reason: reason)
            }
            Logger(subsystem: "local.menubarorganizer.app", category: "legacyExtras")
                .error("Legacy request failed; reason=\(reason, privacy: .public); assessmentPreserved=\(self.assessmentActive, privacy: .public); targets=\(affected.sorted().joined(separator: ","), privacy: .public)")
            // SystemUIServerExtras has already attempted uncancelled rollback.
            // Keep any failed restoration receipts available for the next reveal.
        }
    }

    private func setAssessmentHiddenApplications(_ targets: Set<String>) async throws {
        try Task.checkCancellation()
        if let assessmentApply {
            try await assessmentApply(targets)
            assessmentActive = !targets.isEmpty
            return
        }
        guard !targets.isEmpty else { invalidate(reason: nil); return }
        let loaded = try runtime ?? Runtime.load()
        runtime = loaded
        let ownBundle = Bundle.main.bundleIdentifier
        let systemIDs = Set(targets.compactMap { target -> Int? in
            guard target.hasPrefix("system-item:") else { return nil }
            return Int(target.dropFirst("system-item:".count))
        })
        let bundles = Set(targets.filter { !$0.hasPrefix("system-item:") })
        let permittedAppleOwners: Set<String> = [
            "com.apple.TextInputMenuAgent", "com.apple.weather.menu", "com.apple.campo"
        ]
        for target in targets where target.hasPrefix("system-item:") {
            guard let id = Int(target.dropFirst("system-item:".count)), (0...8).contains(id) else {
                throw DriverError.invalidTarget(target)
            }
        }
        for target in bundles {
            guard target.range(of: #"\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil,
                  (!target.lowercased().hasPrefix("com.apple.") || permittedAppleOwners.contains(target)),
                  target != ownBundle,
                  !target.lowercased().hasPrefix("local.menubarorganizer."),
                  !Self.isCompetingManager(target) else { throw DriverError.invalidTarget(target) }
        }
        let applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        // Avoid conflicting visibility changes while another menu bar manager is running.
        guard !applications.contains(where: {
            $0.bundleIdentifier != ownBundle &&
            Self.isCompetingManager(($0.bundleIdentifier ?? "") + " " + ($0.localizedName ?? ""))
        }) else { throw DriverError.competingManager }
        let knownBundles = Set(applications.compactMap(\.bundleIdentifier).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        guard let ownBundle, !ownBundle.isEmpty else { throw DriverError.invalidTarget("MenubarOrganizer") }
        for target in bundles where !knownBundles.contains(target) { throw DriverError.targetNotRunning(target) }
        let created = try loaded.makeSession(allowedBundles: knownBundles.union([ownBundle])
            .subtracting(bundles).sorted(), hiddenSystemItems: systemIDs)
        try Task.checkCancellation()
        // Keep the old assertion if validation or allocation fails. Replacing
        // it still requires a release because this private API has no update.
        invalidate(reason: nil)
        sessionBundles = knownBundles.union([ownBundle])
        let id = UUID()
        requestID = id
        session = created
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                guard !Task.isCancelled else {
                    invalidate(reason: nil, completionError: CancellationError()); return
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, self.requestID == id, self.pending != nil else { return }
                    self.invalidate(reason: .activationTimedOut)
                }
                created.activate { [weak self, weak created] errorText in
                    guard let self, self.requestID == id else {
                        created?.invalidate()
                        return
                    }
                    if let errorText {
                        self.invalidate(reason: .activationFailed(errorText))
                    } else {
                        Task { @MainActor [weak self] in
                            guard let self, self.requestID == id else { created?.invalidate(); return }
                            self.timeout?.cancel(); self.timeout = nil
                            self.assessmentActive = true
                            let continuation = self.pending; self.pending = nil
                            continuation?.resume()
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                self.invalidate(reason: nil, completionError: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    /// Invalidates only the assertion owned by this driver. No callback exists
    /// for invalidate: return is not an independent guarantee of visual recovery.
    /// Launch must not reconcile a partial inventory after failed recovery.
    func recoverLegacyExtras() async throws { try await legacyExtras.restoreAll() }

    func revealAll() async throws { try await setHiddenApplications([]) }

    /// AppDelegate must invoke this from applicationWillTerminate even if the
    /// settings window is closed. SIGKILL cannot execute app-level cleanup.
    func invalidateForTermination() { invalidate(reason: nil); legacyExtras.restoreBestEffort() }

    private func invalidate(reason: DriverError?, completionError: (any Error)? = nil) {
        launchInvalidationTask?.cancel(); launchInvalidationTask = nil
        requestID = nil
        sessionBundles = []
        timeout?.cancel(); timeout = nil
        let old = session; session = nil
        assessmentActive = false
        let continuation = pending; pending = nil
        old?.invalidate()
        continuation?.resume(throwing: completionError ?? reason ?? .superseded)
        if let reason {
            legacyExtras.restoreBestEffort()
            if old != nil || legacyExtras.isActive { onInvalidated?(reason) }
        }
    }

    private static func isCompetingManager(_ identity: String) -> Bool {
        let value = identity.lowercased()
        return ["bartender", "jordanbaird.ice", "hiddenbar", "minimalbar", "dozer", "vanilla", "menubarhider", "ibar"].contains { value.contains($0) }
    }

    // All private ABI use stays below this boundary.
    @MainActor
    private struct Runtime {
        let configType: AnyClass
        let assertionType: AnyClass
        let configAlloc: IMP
        let assertionAlloc: IMP
        let configInit: IMP
        let assertionInit: IMP
        let activate: IMP
        let invalidate: IMP

        static func load() throws -> Runtime {
            var count = 0
            guard sysctlbyname("kern.osversion", nil, &count, nil, 0) == 0, count > 0 else { throw DriverError.unsupportedBuild }
            var bytes = [CChar](repeating: 0, count: count)
            guard sysctlbyname("kern.osversion", &bytes, &count, nil, 0) == 0,
                  String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "26A428" else {
                throw DriverError.unsupportedBuild
            }
            func method(_ type: AnyClass, _ name: String, _ encoding: String) -> IMP? {
                guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
                      let actual = method_getTypeEncoding(method), String(cString: actual) == encoding else { return nil }
                return method_getImplementation(method)
            }
            // Keep the image loaded for the lifetime of all ObjC objects.
            guard dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL) != nil,
                  let configType = NSClassFromString("MBAssessmentModeConfiguration"),
                  let assertionType = NSClassFromString("MBAssessmentModeAssertion"),
                  let configMeta = object_getClass(configType), let assertionMeta = object_getClass(assertionType),
                  let configAlloc = method(configMeta, "alloc", "@16@0:8"),
                  let assertionAlloc = method(assertionMeta, "alloc", "@16@0:8"),
                  let configInit = method(configType, "initWithAllowedSystemItems:allowedBundleIdentifiers:", "@32@0:8@16@24"),
                  let assertionInit = method(assertionType, "init", "@16@0:8"),
                  let activate = method(assertionType, "activateWithConfiguration:completionHandler:", "v32@0:8@16@?24"),
                  let invalidate = method(assertionType, "invalidate", "v16@0:8") else { throw DriverError.runtimeUnavailable }
            return Runtime(configType: configType, assertionType: assertionType, configAlloc: configAlloc,
                assertionAlloc: assertionAlloc, configInit: configInit, assertionInit: assertionInit,
                activate: activate, invalidate: invalidate)
        }

        func makeSession(allowedBundles: [String], hiddenSystemItems: Set<Int>) throws -> Session {
            typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            typealias ConfigInit = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> Unmanaged<AnyObject>?
            typealias ObjectInit = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            guard let rawConfig = unsafeBitCast(configAlloc, to: Allocate.self)(configType, NSSelectorFromString("alloc")),
                  let configuration = unsafeBitCast(configInit, to: ConfigInit.self)(rawConfig.takeUnretainedValue(),
                    NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
                    (0..<64).filter { !hiddenSystemItems.contains($0) }.map { NSNumber(value: $0) } as NSArray,
                    allowedBundles as NSArray)?.takeRetainedValue(),
                  let rawAssertion = unsafeBitCast(assertionAlloc, to: Allocate.self)(assertionType, NSSelectorFromString("alloc")),
                  let assertion = unsafeBitCast(assertionInit, to: ObjectInit.self)(rawAssertion.takeUnretainedValue(),
                    NSSelectorFromString("init"))?.takeRetainedValue() else { throw DriverError.allocationFailed }
            // 0..<64 is the tested candidate's range, not an exhaustive public
            // system-item contract. It cannot protect future/unknown items.
            return Session(assertion: assertion, configuration: configuration, activate: activate, invalidate: invalidate)
        }
    }

    @MainActor
    private final class Session {
        private let assertion: AnyObject
        private let configuration: AnyObject
        private let activateIMP: IMP
        private let invalidateIMP: IMP

        init(assertion: AnyObject, configuration: AnyObject, activate: IMP, invalidate: IMP) {
            self.assertion = assertion; self.configuration = configuration
            activateIMP = activate; invalidateIMP = invalidate
        }

        isolated deinit { invalidate() }

        func activate(completion: @escaping @MainActor (String?) -> Void) {
            typealias Completion = @convention(block) (NSError?) -> Void
            typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, Completion) -> Void
            let callback: Completion = { error in
                let text = error?.localizedDescription
                DispatchQueue.main.async { completion(text) }
            }
            unsafeBitCast(activateIMP, to: Activate.self)(assertion,
                NSSelectorFromString("activateWithConfiguration:completionHandler:"), configuration, callback)
        }

        func invalidate() {
            typealias Invalidate = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(invalidateIMP, to: Invalidate.self)(assertion, NSSelectorFromString("invalidate"))
        }
    }
}
