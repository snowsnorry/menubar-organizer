import AppKit
import ApplicationServices

/// Complements the conservative mouse-click latch with actual external menu events.
/// Silence, failed registration, and unmatched closes never mean a menu closed.
@MainActor
final class MenuInteractionObserver {
    var onMenuOpenChanged: ((Bool) -> Void)?

    private var worker: MenuObservationWorker?
    private var notifications: [NSObjectProtocol] = []
    private var generation = UUID()
    private var lastSequence: UInt64 = 0

    func start() {
        guard worker == nil else { return }
        let epoch = UUID()
        generation = epoch
        lastSequence = 0
        let created = MenuObservationWorker { [weak self] open, sequence in
            Task { @MainActor [weak self] in
                guard let self, self.worker != nil, self.generation == epoch,
                      sequence > self.lastSequence else { return }
                self.lastSequence = sequence
                self.onMenuOpenChanged?(open)
            }
        }
        worker = created
        refreshApplications()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshApplications() }
            })
        }
        created.start()
    }

    func stop() {
        generation = UUID()
        let center = NSWorkspace.shared.notificationCenter
        notifications.forEach(center.removeObserver)
        notifications.removeAll()
        worker?.stop()
        worker = nil
        // Do not infer a closed menu from stopping observation.
    }

    private func refreshApplications() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications.compactMap { application -> MenuApplication? in
            guard application.processIdentifier != ownPID, !application.isTerminated else { return nil }
            return MenuApplication(pid: application.processIdentifier, launchedAt: application.launchDate)
        }
        worker?.update(applications)
    }
}

private struct MenuApplication: Hashable, Sendable {
    let pid: pid_t
    let launchedAt: Date?
}

/// AX objects and callbacks belong exclusively to this worker's dedicated run loop.
/// Only the command mailbox crosses threads, under `lock`.
private final class MenuObservationWorker: @unchecked Sendable {
    private struct Registration {
        let application: MenuApplication
        let observer: AXObserver
        var openMenus: [AXUIElement] = []
    }

    private let lock = NSLock()
    private var pendingApplications: [MenuApplication]?
    private var shouldStop = false
    private let changed: @Sendable (Bool, UInt64) -> Void

    // Worker-thread-only state below.
    private var registrations: [pid_t: Registration] = [:]
    private var attempted: Set<MenuApplication> = []
    private var pending: [MenuApplication] = []
    private var sequence: UInt64 = 0
    private var reportedOpen = false

    init(changed: @escaping @Sendable (Bool, UInt64) -> Void) {
        self.changed = changed
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "MenubarOrganizer.MenuObservation"
        thread.qualityOfService = .utility
        thread.start()
    }

    func update(_ applications: [MenuApplication]) {
        lock.lock()
        pendingApplications = applications
        lock.unlock()
    }

    func stop() {
        lock.lock()
        shouldStop = true
        lock.unlock()
    }

    private func run() {
        // Keep the run loop alive even when no application supports notifications.
        let heartbeat = Timer(timeInterval: 0.1, repeats: true) { _ in }
        RunLoop.current.add(heartbeat, forMode: .default)
        defer {
            heartbeat.invalidate()
            for registration in registrations.values {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(registration.observer), .defaultMode)
            }
            registrations.removeAll()
        }

        while true {
            lock.lock()
            let stopped = shouldStop
            let applications = pendingApplications
            pendingApplications = nil
            lock.unlock()
            if stopped { return }
            if let applications { reconcile(applications) }

            // At most one app and two bounded remote registrations per iteration.
            // An unsupported or unresponsive owner never blocks the main thread.
            if !pending.isEmpty { register(pending.removeFirst()) }
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }
    }

    private func reconcile(_ applications: [MenuApplication]) {
        let live = Set(applications)
        let removed = registrations.values.filter { !live.contains($0.application) }.map { $0.application.pid }
        for pid in removed {
            guard let registration = registrations.removeValue(forKey: pid) else { continue }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(registration.observer), .defaultMode)
        }
        attempted.formIntersection(live)
        pending = applications.filter { !attempted.contains($0) }
        // Termination is positive evidence that that process's tracked menus ended.
        publishIfChanged()
    }

    private func register(_ application: MenuApplication) {
        attempted.insert(application)
        let element = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var observer: AXObserver?
        let result = AXObserverCreate(application.pid, { observer, element, notification, context in
            guard let context else { return }
            let worker = Unmanaged<MenuObservationWorker>.fromOpaque(context).takeUnretainedValue()
            worker.receive(observer: observer, element: element, notification: notification)
        }, &observer)
        guard result == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let opened = AXObserverAddNotification(observer, element, kAXMenuOpenedNotification as CFString, context)
        let closed = AXObserverAddNotification(observer, element, kAXMenuClosedNotification as CFString, context)
        guard opened == .success, closed == .success else {
            // Releasing the observer removes registrations; never synthesize close.
            return
        }
        registrations[application.pid] = Registration(application: application, observer: observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func receive(observer: AXObserver, element: AXUIElement, notification: CFString) {
        guard let pid = registrations.first(where: { CFEqual($0.value.observer, observer) })?.key,
              var registration = registrations[pid] else { return }
        if notification as String == kAXMenuOpenedNotification as String {
            if !registration.openMenus.contains(where: { CFEqual($0, element) }) {
                registration.openMenus.append(element)
            }
        } else if notification as String == kAXMenuClosedNotification as String {
            guard let index = registration.openMenus.firstIndex(where: { CFEqual($0, element) }) else { return }
            registration.openMenus.remove(at: index)
        } else {
            return
        }
        registrations[pid] = registration
        publishIfChanged()
    }

    private func publishIfChanged() {
        let open = registrations.values.contains { !$0.openMenus.isEmpty }
        guard open != reportedOpen else { return }
        reportedOpen = open
        sequence &+= 1
        changed(open, sequence)
    }
}
