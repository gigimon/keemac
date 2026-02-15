import AppKit

@MainActor
public final class MainWindowStore {
    public static let shared = MainWindowStore()

    public weak var window: NSWindow?

    private init() {}

    public func register(window: NSWindow?) {
        guard let window, isMainCandidate(window) else {
            return
        }

        self.window = window
        if !window.collectionBehavior.contains(.moveToActiveSpace) {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }

    public func focusWindow() -> Bool {
        guard let window else {
            return false
        }

        if !window.collectionBehavior.contains(.moveToActiveSpace) {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }

        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        _ = NSRunningApplication.current.unhide()

        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible {
            window.orderFront(nil)
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard self.window === window else {
                return
            }
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    public func isMainWindow(_ window: NSWindow) -> Bool {
        self.window === window
    }

    public func clearIfMainWindow(_ window: NSWindow) {
        guard isMainWindow(window) else {
            return
        }
        self.window = nil
    }

    private func isMainCandidate(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !window.title.localizedCaseInsensitiveContains("settings")
    }
}
