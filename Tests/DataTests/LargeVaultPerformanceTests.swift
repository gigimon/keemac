import AppKit
@testable import Data
import Domain
import Foundation
import SwiftUI
@testable import UI
import XCTest

/// Timings on large databases: thousands of entries in one group, spread over groups, and hundreds of groups.
/// Every measurement prints `PERF <scenario> <step>: median … ms` and fails when the median is over its budget.
/// Budgets are loose on purpose: they catch regressions that make navigation feel slow, not milliseconds.
/// Shared CI runners are slower and noisier, so there (`CI` set) the budgets are tripled;
/// `KEEMAC_PERF_BUDGET_SCALE` sets the factor explicitly.
@MainActor
final class LargeVaultPerformanceTests: XCTestCase {
    private struct Shape {
        let name: String
        let entryCount: Int
        /// Top-level groups × subgroups in each; 0 × 0 puts every entry in one group.
        let topGroups: Int
        let subgroups: Int
    }

    private static let oneGroup = Shape(name: "one-group-3000", entryCount: 3000, topGroups: 0, subgroups: 0)
    private static let spread = Shape(name: "spread-3000x150", entryCount: 3000, topGroups: 10, subgroups: 15)
    private static let manyGroups = Shape(name: "groups-500", entryCount: 1500, topGroups: 20, subgroups: 25)

    private static let budgetScale: Double = {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["KEEMAC_PERF_BUDGET_SCALE"].flatMap(Double.init) {
            return value
        }
        return environment["CI"] == nil ? 1 : 3
    }()

    /// One step of navigation (arrow key, click on an entry). Debug builds take about a third of it.
    private static let navigationBudget: Double = 75 * budgetScale
    /// Switching the sidebar rebuilds the list; allowed a bit more.
    private static let sidebarBudget: Double = 150 * budgetScale
    /// Building the browser from scratch, as after unlocking.
    private static let openBudget: Double = 600 * budgetScale

    // MARK: - Scenarios

    func testEntriesInOneGroup() async throws {
        let app = try await makeVault(Self.oneGroup)
        let bigGroup = try XCTUnwrap(app.vault.entries.first?.groupPath)
        // A second, small group to switch to and back from.
        let root = try XCTUnwrap(app.vault.groups.first { !$0.path.contains(".") }?.path)
        try await app.model.createGroup(inParentPath: root, title: "Other", iconID: nil)
        try await app.model.createEntry(inGroupPath: "\(root).Other", form: VaultEntryForm(title: "Router", password: "pw"))
        try await measureData(app, shape: Self.oneGroup)
        try measureBrowser(app.vault, shape: Self.oneGroup, groups: [bigGroup, "\(root).Other"])
    }

    func testEntriesSpreadOverGroups() async throws {
        let app = try await makeVault(Self.spread)
        let vault = try app.vault
        XCTAssertGreaterThanOrEqual(vault.groups.count, 160)
        let groups = Array(Set(vault.entries.map(\.groupPath))).sorted().prefix(3)
        try await measureData(app, shape: Self.spread)
        try measureBrowser(vault, shape: Self.spread, groups: Array(groups))
    }

    func testManyGroups() async throws {
        let app = try await makeVault(Self.manyGroups)
        let vault = try app.vault
        XCTAssertGreaterThanOrEqual(vault.groups.count, 520)
        let groups = Array(Set(vault.entries.map(\.groupPath))).sorted().prefix(3)
        try await measureData(app, shape: Self.manyGroups)
        try measureBrowser(vault, shape: Self.manyGroups, groups: Array(groups), expandsAllGroups: true)
    }

    // MARK: - Data layer

    private func measureData(_ app: AppScenario, shape: Shape) async throws {
        let vault = try app.vault

        let load = try await measureAsync("\(shape.name) load", iterations: 3) {
            _ = try await KeePassKitVaultLoader().loadVault(from: app.url, masterPassword: app.password, keyFileURL: nil)
        }
        XCTAssertLessThan(load, 3000, "loading \(shape.name)")

        let entry = try XCTUnwrap(vault.entries.first { !$0.isTrashed })
        var form = VaultEntryForm(entry: entry)
        var revision = 0
        let edit = try await measureAsync("\(shape.name) edit+save", iterations: 3) {
            revision += 1
            form.notes = "revision \(revision)"
            try await app.model.updateEntry(id: entry.id, form: form)
        }
        XCTAssertLessThan(edit, 3000, "editing an entry in \(shape.name)")

        let entries = try app.vault.entries
        let search = measure("\(shape.name) search", iterations: 10) {
            let query = VaultEntrySearch("user 12")
            _ = entries.filter { query.matches($0) }
        }
        XCTAssertLessThan(search, Self.navigationBudget, "searching \(shape.name)")
    }

    // MARK: - Browser view

    private func measureBrowser(_ vault: LoadedVault, shape: Shape, groups: [String], expandsAllGroups: Bool = false) throws {
        let host = BrowserHost(vault: vault, expandedGroups: expandsAllGroups ? Set(vault.groups.map(\.path)) : [])

        let open = measure("\(shape.name) open All Entries (new browser)", iterations: 3) {
            host.show(sidebar: "library.all")
        }
        XCTAssertLessThan(open, Self.openBudget, "building the browser for \(shape.name)")

        // Going to an entry in another group, like "Go to Entry": the sidebar selection and the list change.
        let entriesByGroup = Dictionary(grouping: vault.entries.filter { !$0.isTrashed }, by: \.groupPath)
        let targets = try groups.map { try XCTUnwrap(entriesByGroup[$0]?.first, "no entries in \($0)") }
        var step = 0
        let switching = try measure("\(shape.name) switch group", iterations: 10) {
            step += 1
            let target = targets[step % targets.count]
            host.reveal(target)
            XCTAssertEqual(host.sidebarSelection, "group.\(target.groupPath)", "the browser didn't switch")
        }
        XCTAssertLessThan(switching, Self.sidebarBudget, "switching groups in \(shape.name)")

        // Picking entries one after another in the biggest group: the selection changes and the entry is marked viewed.
        let group = try XCTUnwrap(groups.max { (entriesByGroup[$0]?.count ?? 0) < (entriesByGroup[$1]?.count ?? 0) })
        let siblings = try XCTUnwrap(entriesByGroup[group])
        host.reveal(siblings[0])
        let picking = measure("\(shape.name) select entry in group (\(siblings.count) entries)", iterations: 20) {
            step += 1
            let entry = siblings[step % siblings.count]
            host.reveal(entry)
            host.update(recentViewed: [entry.id])
        }
        XCTAssertLessThan(picking, Self.navigationBudget, "selecting an entry in \(shape.name)")

        // The same with All Entries open: every state change runs the whole body again.
        host.show(sidebar: "library.all")
        let ids = vault.entries.map(\.id)
        let viewed = measure("\(shape.name) re-render All Entries", iterations: 20) {
            step += 1
            host.update(recentViewed: [ids[step % ids.count]])
        }
        XCTAssertLessThan(viewed, Self.navigationBudget, "re-render of All Entries in \(shape.name)")
    }

    // MARK: - Fixtures

    /// Builds the database with one import, so it is saved once instead of once per entry.
    private func makeVault(_ shape: Shape) async throws -> AppScenario {
        let app = try AppScenario(self)
        try await app.createVault()
        let items = (0..<shape.entryCount).map { index -> VaultImportItem in
            var folder: [String] = []
            if shape.topGroups > 0 {
                let groupIndex = index % (shape.topGroups * shape.subgroups)
                folder = ["Team \(groupIndex / shape.subgroups)", "Project \(groupIndex % shape.subgroups)"]
            }
            return VaultImportItem(
                title: "Service \(String(format: "%05d", (index * 7919) % shape.entryCount))",
                username: "user \(index)",
                password: "pw-\(index)-\(UUID().uuidString.prefix(8))",
                url: "https://service\(index).example.com/login",
                notes: index.isMultiple(of: 5) ? "Notes for entry \(index)" : "",
                tags: index.isMultiple(of: 3) ? ["tag\(index % 20)"] : [],
                folder: folder
            )
        }
        let file = VaultImportFile(format: .chrome, items: items)
        let started = ContinuousClock.now
        _ = try await app.model.importEntries(file, options: VaultImportOptions(destination: .newGroup(title: "Imported"), keepsFolders: true, skipsDuplicates: false))
        print("PERF \(shape.name) fixture: \(milliseconds(ContinuousClock.now - started)) ms")
        return app
    }

    // MARK: - Timing

    @discardableResult
    private func measure(_ name: String, iterations: Int, _ block: () throws -> Void) rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let started = ContinuousClock.now
            try block()
            samples.append(milliseconds(ContinuousClock.now - started))
        }
        return report(name, samples)
    }

    @discardableResult
    private func measureAsync(_ name: String, iterations: Int, _ block: () async throws -> Void) async rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let started = ContinuousClock.now
            try await block()
            samples.append(milliseconds(ContinuousClock.now - started))
        }
        return report(name, samples)
    }

    private func report(_ name: String, _ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "PERF %@: median %.1f ms, min %.1f ms, max %.1f ms", name, median, sorted.first ?? 0, sorted.last ?? 0))
        return median
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// `VaultBrowserView` in an offscreen window, laid out and drawn synchronously like a frame on screen.
@MainActor
private final class BrowserHost {
    private let vault: LoadedVault
    private let expandedGroups: Set<String>
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>
    private var sidebar = "library.all"
    private var recentViewed: [UUID] = []

    init(vault: LoadedVault, expandedGroups: Set<String>) {
        _ = NSApplication.shared
        self.vault = vault
        self.expandedGroups = expandedGroups
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
    }

    deinit {
        MainActor.assumeIsolated {
            window.close()
        }
    }

    /// The sidebar selection the browser last reported.
    private(set) var sidebarSelection: String?
    private var revealRequest: AppViewModel.RevealRequest?

    /// A new browser with this sidebar selection, as after unlocking.
    func show(sidebar: String) {
        self.sidebar = sidebar
        sidebarSelection = sidebar
        identity = UUID()
        render()
    }

    /// Goes to the entry like "Go to Entry" does, then clears the request like AppViewModel.
    func reveal(_ entry: VaultEntry) {
        revealRequest = AppViewModel.RevealRequest(entryIDs: [entry.id])
        render()
        revealRequest = nil
        render()
    }

    /// Changes an input without changing the selection, so only the body runs again.
    func update(recentViewed: [UUID]) {
        self.recentViewed = recentViewed
        render()
    }

    private var identity = UUID()

    private func render() {
        hostingView.rootView = AnyView(makeBrowser().id(identity))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()
    }

    private func makeBrowser() -> VaultBrowserView {
        VaultBrowserView(
            vault: vault,
            favoriteEntryIDs: [],
            recentViewedEntryIDs: recentViewed,
            includeSubgroupEntries: true,
            revealRequest: revealRequest,
            initialSidebarSelectionID: sidebar,
            initialExpandedGroupPaths: expandedGroups,
            onCreateGroup: { _, _, _, _ in },
            onUpdateGroup: { _, _, _, _ in },
            onDeleteGroup: { _ in },
            onCreateEntry: { _, _ in },
            onUpdateEntry: { _, _ in },
            onDuplicateEntry: { id, _ in id },
            onDeleteEntry: { _ in },
            onEmptyTrash: { _ in },
            onMoveEntry: { _, _ in },
            onMoveGroup: { _, _ in },
            onRestoreEntry: { _ in },
            onRevertEntry: { _, _ in },
            onToggleFavorite: { _ in },
            onEntryViewed: { _ in },
            onEntryUsed: { _ in },
            onLockVault: {},
            onSidebarSelectionChanged: { [weak self] in self?.sidebarSelection = $0 },
            onExpandedGroupsChanged: { _ in }
        )
    }
}
