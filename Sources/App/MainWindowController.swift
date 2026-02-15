import AppKit
import SwiftUI
import UI

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private weak var viewModel: AppViewModel?
    private var window: NSWindow?

    private init() {}

    func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
        if let window {
            window.contentViewController = NSHostingController(rootView: RootView(viewModel: viewModel))
            MainWindowStore.shared.register(window: window)
        }
    }

    func show() {
        guard let viewModel else {
            return
        }

        let window = window ?? makeWindow(viewModel: viewModel)
        if self.window == nil {
            self.window = window
        }

        MainWindowStore.shared.register(window: window)
        focus(window)
    }

    func hide() {
        guard let window else {
            return
        }
        window.orderOut(nil)
    }

    private func makeWindow(viewModel: AppViewModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "KeeMac"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentViewController = NSHostingController(rootView: RootView(viewModel: viewModel))
        window.center()
        DispatchQueue.main.async {
            self.pruneAutomaticSplitViewToolbarItems(in: window)
        }
        return window
    }

    private func focus(_ window: NSWindow) {
        pruneAutomaticSplitViewToolbarItems(in: window)

        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        _ = NSRunningApplication.current.unhide()
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.pruneAutomaticSplitViewToolbarItems(in: window)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func pruneAutomaticSplitViewToolbarItems(in window: NSWindow) {
        guard let toolbar = window.toolbar else {
            return
        }

        let unwantedIdentifiers: Set<NSToolbarItem.Identifier> = [
            .toggleInspector,
            .inspectorTrackingSeparator,
            .sidebarTrackingSeparator
        ]
        let shouldRemove: (NSToolbarItem) -> Bool = { item in
            if unwantedIdentifiers.contains(item.itemIdentifier) {
                return true
            }

            let rawID = item.itemIdentifier.rawValue.lowercased()
            if rawID.contains("inspector") || rawID.contains("trackingseparator") {
                return true
            }

            if item.action == #selector(NSSplitViewController.toggleInspector(_:)) {
                return true
            }

            let className = String(describing: type(of: item)).lowercased()
            if className.contains("trackingseparator") {
                return true
            }

            return false
        }

        for index in toolbar.items.indices.reversed() where shouldRemove(toolbar.items[index]) {
            toolbar.removeItem(at: index)
        }

        var seenSidebarToggle = false
        for index in toolbar.items.indices.reversed() {
            let item = toolbar.items[index]
            let isSidebarToggle = item.itemIdentifier == .toggleSidebar
                || item.action == #selector(NSSplitViewController.toggleSidebar(_:))
                || item.itemIdentifier.rawValue.lowercased().contains("togglesidebar")

            guard isSidebarToggle else {
                continue
            }

            if seenSidebarToggle {
                toolbar.removeItem(at: index)
            } else {
                seenSidebarToggle = true
            }
        }
    }
}
