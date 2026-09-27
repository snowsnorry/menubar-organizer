import AppKit
import SwiftUI
import OrganizerCore

@MainActor
final class OrganizerAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var model: SettingsModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var pulse: Timer?
    private var monitor: Any?
    private var localMonitor: Any?
    private var notifications: [NSObjectProtocol] = []
    private let menuObserver = MenuInteractionObserver()
    private var observingMenus = false
    private var observedExternalMenuOpen = false
    private var menuInteraction = false
    private var lastPointerInMenuBar: NSPoint?
    private var ownMenuOpen = false
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app intentionally lives in the menu bar, without a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--preview") {
            if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.delegate = self
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let settingsCommand = NSMenuItem(title: L10n.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsCommand.target = self
        appMenu.addItem(settingsCommand)
        let revealCommand = NSMenuItem(title: L10n.text("menu.toggleHidden"), action: #selector(toggleHidden), keyEquivalent: "h")
        revealCommand.keyEquivalentModifierMask = [.command, .shift]
        revealCommand.target = self
        appMenu.addItem(revealCommand)
        let quitCommand = NSMenuItem(title: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitCommand.target = self
        appMenu.addItem(quitCommand)
        NSApp.mainMenu = mainMenu
        model = SettingsModel()
        model.onDismissSettings = { [weak self] in self?.window?.orderOut(nil) }
        model.onApplyingSettings = { [weak self] applying in
            // Keep the settings/progress visible during an explicitly accepted
            // system operation. Editing and cancellation never enter this path.
            self?.window?.level = applying ? .floating : .normal
        }
        menuObserver.onMenuOpenChanged = { [weak self] open in
            guard let self else { return }
            // AX notification delivery cannot identify which mouse click
            // opened this menu. Never clear a newer unsupported-menu latch.
            self.observedExternalMenuOpen = open
            Task { await self.updateInteraction() }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Preserve the control icon's chosen position across launches.
        statusItem.autosaveName = "MenubarOrganizerControl"
        if let button = statusItem.button {
            button.setAccessibilityIdentifier("local.menubarorganizer.control")
            button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L10n.text("menu.showHidden"))
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Menubar Organizer"
        }
        installLifecycle()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A click in a menu bar may open an external menu. Until a click
                // outside that region, keep items revealed rather than interrupt it.
                self.menuInteraction = self.pointerInMenuBar()
                await self.updateInteraction()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // The control handles its own click. It cannot open an external menu.
            if event.window === self.statusItem.button?.window {
                self.menuInteraction = false
                self.observedExternalMenuOpen = false
                return event
            }
            Task { @MainActor in
                self.menuInteraction = self.pointerInMenuBar()
                await self.updateInteraction()
            }
            return event
        }
        pulse = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateInteraction()
            }
        }
        RunLoop.main.add(pulse!, forMode: .common)
        Task { await model.start(); openSettings() }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.delegate = self
            let settings = NSMenuItem(title: L10n.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self; menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
            quit.target = self; menu.addItem(quit)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleHidden()
        }
    }

    @objc private func toggleHidden() {
        menuInteraction = false
        Task { await updateInteraction(); await model.toggle() }
    }

    @objc func openSettings() {
        if window == nil {
            let view = SettingsView(model: model)
            let controller = NSHostingController(rootView: view)
            let created = NSWindow(contentViewController: controller)
            created.title = "Menubar Organizer"
            created.titleVisibility = .hidden
            created.setContentSize(CommandLine.arguments.contains("--small") ? NSSize(width: 740, height: 520) : NSSize(width: 860, height: 640))
            created.minSize = NSSize(width: 740, height: 520)
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.delegate = self
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.isBusy else { return false }
        model.cancelSettings()
        return true
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func menuWillOpen(_ menu: NSMenu) { ownMenuOpen = true; Task { await updateInteraction() } }
    func menuDidClose(_ menu: NSMenu) { ownMenuOpen = false; Task { await updateInteraction() } }

    private func pointerInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            let bar = CGRect(x: screen.frame.minX, y: screen.frame.maxY - 38,
                             width: screen.frame.width, height: 38)
            return bar.contains(point)
        }
    }

    private func updateInteraction() async {
        guard model != nil, !terminating else { return }
        let pointer = NSEvent.mouseLocation
        let pointerInside = pointerInMenuBar()
        let movedInside = pointerInside && lastPointerInMenuBar != nil && lastPointerInMenuBar != pointer
        lastPointerInMenuBar = pointerInside ? pointer : nil
        if model.accessibilityGranted && !model.isPreview {
            if !observingMenus { menuObserver.start(); observingMenus = true }
        } else if observingMenus {
            menuObserver.stop(); observingMenus = false
            menuInteraction = menuInteraction || observedExternalMenuOpen
            observedExternalMenuOpen = false
        }
        await model.interaction(pointerInside: pointerInside, menuOpen: ownMenuOpen || observedExternalMenuOpen || menuInteraction)
        if movedInside { await model.noteMenuBarActivity() }
    }

    private func installLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notifications.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.model.suspend(reason: .lifecycle) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            notifications.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.model.resumeLifecycle() }
            })
        }
        notifications.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                  object: nil, queue: .main) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in await self?.model.runningApplicationsChanged(launchedBundleID: bundleID) }
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.runningApplicationsChanged(launchedBundleID: nil) }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.model.suspend(reason: .backendUnavailable)
                await self?.model.refresh(adoptObserved: false, restoreSaved: true)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        })
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        pulse?.invalidate()
        menuObserver.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        Task { await model.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.backend.visibility.invalidateForTermination()
    }
}

let application = NSApplication.shared
let delegate = OrganizerAppDelegate()
application.delegate = delegate
application.run()
