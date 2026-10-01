import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AudioModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var popoverController: PopoverViewController!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appliedSymbol: String?
    private var ignoreResignUntil = Date.distantPast
    private var menuTracking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("AudioBar stays in the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        installMainMenu()

        popoverController = PopoverViewController(model: model)
        popover.contentViewController = popoverController
        // Height follows the content; the controller keeps preferredContentSize in sync.
        _ = popoverController.view
        popover.contentSize = popoverController.preferredContentSize
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "AudioBar"
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = Symbols.image("speaker.wave.2.fill", pointSize: 16, description: "AudioBar")
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Mouse-up so the click that opens the panel is not also an outside click that closes it.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("AudioBar")
        }

        model.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.popoverController.render()
        }
        model.start()
        updateStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingBegan(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingEnded(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func menuTrackingBegan(_ notification: Notification) {
        menuTracking = true
    }

    @objc private func menuTrackingEnded(_ notification: Notification) {
        menuTracking = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMonitors()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    @objc private func appDidResignActive(_ notification: Notification) {
        if menuTracking || Date() < ignoreResignUntil {
            return
        }
        closePopover()
    }

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        ignoreResignUntil = Date().addingTimeInterval(0.35)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installMonitors()
    }

    private func closePopover() {
        removeMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Don't remove the monitor from inside its own callback.
            DispatchQueue.main.async {
                guard let self, !self.menuTracking else { return }
                self.closePopover()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    self?.closePopover()
                }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol = model.snapshot.statusSymbol
        if appliedSymbol != symbol {
            appliedSymbol = symbol
            button.image = Symbols.image(symbol, pointSize: 16, description: "AudioBar")
        }
        let tip = model.snapshot.statusToolTip
        if button.toolTip != tip {
            button.toolTip = tip
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit AudioBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
