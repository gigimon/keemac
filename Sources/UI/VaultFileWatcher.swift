import AppKit
import Foundation

/// Reports that the database file may have changed on disk.
///
/// Combines a file presenter (coordinated writes, e.g. iCloud Drive), a watcher on the
/// containing folder (atomic replaces by Dropbox, Syncthing and other KeePass clients)
/// and a watcher on the file itself (in-place writes). Events are debounced because sync
/// clients often write in several steps; callers still compare file fingerprints, so
/// spurious events — including KeeMac's own saves — are harmless.
@MainActor
final class VaultFileWatcher {
    private let fileURL: URL
    private let debounce: Duration
    private let onChange: @MainActor () -> Void

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var presenter: Presenter?
    private var pendingNotification: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init(fileURL: URL, debounce: Duration = .seconds(1), onChange: @escaping @MainActor () -> Void) {
        self.fileURL = fileURL.standardizedFileURL
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        stop()
        directorySource = makeSource(for: fileURL.deletingLastPathComponent(), events: [.write, .rename, .delete])
        watchFile()

        let presenter = Presenter(url: fileURL) { [weak self] in
            Task { @MainActor in
                self?.scheduleNotification()
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleNotification()
            }
        }
    }

    func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter = nil
        pendingNotification?.cancel()
        pendingNotification = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(for: fileURL, events: [.write, .extend, .rename, .delete])
    }

    private func makeSource(for url: URL, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleNotification()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    private func scheduleNotification() {
        pendingNotification?.cancel()
        pendingNotification = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else {
                return
            }
            // An atomic replace swaps the inode, so the per-file watcher has to be re-attached.
            self.watchFile()
            self.onChange()
        }
    }

    private final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        private let onChange: @Sendable () -> Void

        init(url: URL, onChange: @escaping @Sendable () -> Void) {
            self.presentedItemURL = url
            self.onChange = onChange
            super.init()
            presentedItemOperationQueue.maxConcurrentOperationCount = 1
        }

        func presentedItemDidChange() {
            onChange()
        }
    }
}
