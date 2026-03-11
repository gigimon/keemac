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
        return window
    }

    private func focus(_ window: NSWindow) {
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
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
