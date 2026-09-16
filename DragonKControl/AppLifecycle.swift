import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusBarController: StatusBarController?
    private var openMainWindowAction: (() -> Void)?
    private weak var mainWindow: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?
    private var mainWindowIsClosed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(model: model) { [weak self] in
            self?.openMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    func setOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func registerMainWindow(_ window: NSWindow) {
        guard !mainWindowIsClosed else { return }
        guard mainWindow !== window else { return }

        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        mainWindow = window
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self] in self?.mainWindowDidClose(window) }
        }
        NSApp.setActivationPolicy(.regular)
    }

    func openMainWindow() {
        mainWindowIsClosed = false
        model.setBackgroundMode(false)
        NSApp.setActivationPolicy(.regular)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func mainWindowDidClose(_ window: NSWindow) {
        guard mainWindow === window else { return }
        mainWindowIsClosed = true
        mainWindow = nil
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        model.setBackgroundMode(true)
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let openMainWindow: () -> Void
    private var loadCancellable: AnyCancellable?
    private var loadPercentage = 0

    init(model: AppModel, openMainWindow: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.openMainWindow = openMainWindow
        super.init()

        configureStatusButton()

        let panel = MenuBarPanel(model: model) { [weak self] in
            self?.popover.performClose(nil)
            self?.openMainWindow()
        }
        let hostingController = NSHostingController(rootView: panel)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true

        loadCancellable = model.$loadPercentage
            .removeDuplicates()
            .sink { [weak self] value in self?.updateStatusButton(load: value) }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                 weight: .semibold)

        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        button.image = NSImage(systemSymbolName: "snowflake.circle.fill",
                               accessibilityDescription: "DragonK")?
            .withSymbolConfiguration(configuration)
        updateStatusButton(load: 0)
    }

    private func updateStatusButton(load: Int) {
        loadPercentage = load
        guard let button = statusItem.button else { return }
        button.title = " \(load)%"
        button.toolTip = "DragonK 综合负载 \(load)%\n左键查看，右键退出"
        button.setAccessibilityLabel("DragonK 综合负载 \(load)%")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            showContextMenu(relativeTo: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        let status = NSMenuItem(title: "DragonK 综合负载 \(loadPercentage)%",
                                action: nil,
                                keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 DragonK Control",
                              action: #selector(quitApplication),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.minY),
                   in: button)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

struct AppLifecycleBridge: View {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    var body: some View {
        WindowReader { window in
            appDelegate.registerMainWindow(window)
        }
        .frame(width: 0, height: 0)
        .onAppear {
            appDelegate.setOpenMainWindowAction {
                openWindow(id: "main")
            }
        }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(for: nsView)
    }

    private func resolveWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onResolve(window)
        }
    }
}
