@testable import Data
import Domain
import Foundation
import KeePassKit
@testable import UI
import XCTest

final class AutoTypeSequenceTests: XCTestCase {
    func testDefaultSequence() throws {
        XCTAssertEqual(try AutoTypeSequence.parse(defaultAutoTypeSequence), [
            .placeholder("USERNAME"), .key(.tab, []), .placeholder("PASSWORD"), .key(.enter, [])
        ])
    }

    func testKeysRepeatsAndDelays() throws {
        XCTAssertEqual(try AutoTypeSequence.parse("{tab 3}{F5}{PGDN}{bs}~{DELAY 500}{DELAY=50}{CLEARFIELD}"), [
            .key(.tab, []), .key(.tab, []), .key(.tab, []), .key(.function(5), []), .key(.pageDown, []),
            .key(.backspace, []), .key(.enter, []), .delay(500), .keyDelay(50), .clearField
        ])
    }

    func testModifiersApplyToTheNextItemOrGroup() throws {
        XCTAssertEqual(try AutoTypeSequence.parse("^a{DEL}"), [.character("a", .command), .key(.delete, [])])
        XCTAssertEqual(try AutoTypeSequence.parse("+{TAB}%x@c#d"), [
            .key(.tab, .shift), .character("x", .option), .character("c", .control), .character("d", .control)
        ])
        XCTAssertEqual(try AutoTypeSequence.parse("^+(ab)c"), [
            .character("a", [.command, .shift]), .character("b", [.command, .shift]), .text("c")
        ])
    }

    func testEscapedSpecialCharactersAreText() throws {
        let tokens = try AutoTypeSequence.parse("{+}{^}{%}{~}{{}{}}{(}{PLUS}a b")
        let text = AutoTypeSequence.resolve(tokens) { _ in "" }
        XCTAssertEqual(text, [.text("+^%~{}(+a b")])
    }

    func testPlaceholdersKeepTheirArgument() throws {
        XCTAssertEqual(try AutoTypeSequence.parse("{username}{S:Email Address}{REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C}{TOTP}"), [
            .placeholder("USERNAME"), .placeholder("S:Email Address"), .placeholder("REF:P@I:46C9B1FFBD4ABC4BBB260C6190BAD20C"), .placeholder("TOTP")
        ])
    }

    /// A password full of sequence syntax is typed as it is.
    func testValuesAreNeverReadAsCommands() throws {
        let tokens = try AutoTypeSequence.parse("{USERNAME}{TAB}{PASSWORD}")
        let actions = AutoTypeSequence.resolve(tokens) { $0 == "USERNAME" ? "a+b" : "{TAB}^v~" }
        XCTAssertEqual(actions, [.text("a+b"), .key(.tab, []), .text("{TAB}^v~")])
    }

    func testErrors() {
        XCTAssertEqual(AutoTypeSequence.validate("  "), .empty)
        XCTAssertEqual(AutoTypeSequence.validate("{USERNAME"), .missingClosingBrace)
        XCTAssertEqual(AutoTypeSequence.validate("{USER{NAME}"), .missingClosingBrace)
        XCTAssertEqual(AutoTypeSequence.validate("abc}"), .unexpectedClosingBrace)
        XCTAssertEqual(AutoTypeSequence.validate("{USERNAME}{TAB}{PASWORD}{ENTER}"), .unknownCommand("{PASWORD}"))
        XCTAssertEqual(AutoTypeSequence.validate("{DELAY abc}"), .unknownCommand("{DELAY abc}"))
        XCTAssertEqual(AutoTypeSequence.validate("{TAB x}"), .unknownCommand("{TAB x}"))
        XCTAssertNil(AutoTypeSequence.validate(defaultAutoTypeSequence))
        XCTAssertEqual(AutoTypeSequenceError.unknownCommand("{X}").message, "Unknown command {X}")
    }
}

final class AutoTypeMatchingTests: XCTestCase {
    func testAssociationPatterns() {
        XCTAssertTrue(VaultAutoTypeAssociation(windowTitle: "*Steam*").matches(windowTitle: "Steam Sign In"))
        XCTAssertTrue(VaultAutoTypeAssociation(windowTitle: "cisco secure client — *").matches(windowTitle: "Cisco Secure Client — VPN"))
        XCTAssertTrue(VaultAutoTypeAssociation(windowTitle: "Login").matches(windowTitle: "login"))
        XCTAssertFalse(VaultAutoTypeAssociation(windowTitle: "Login").matches(windowTitle: "Login page"), "without * the whole title must match")
        XCTAssertTrue(VaultAutoTypeAssociation(windowTitle: "//^Bank (A|B)$//").matches(windowTitle: "bank b"))
        XCTAssertFalse(VaultAutoTypeAssociation(windowTitle: "a.c").matches(windowTitle: "abc"), "dots are literal")
        XCTAssertFalse(VaultAutoTypeAssociation(windowTitle: "").matches(windowTitle: "anything"))
        let long = String(repeating: "a", count: 5_000) + "!"
        XCTAssertFalse(VaultAutoTypeAssociation(windowTitle: "//^(a+)+!$//").matches(windowTitle: long), "a backtracking pattern gives up instead of hanging")
    }

    func testInheritanceDownTheGroups() {
        let work = VaultAutoTypeInheritance.root.applying(VaultGroupAutoType(enabled: .off, sequence: "{PASSWORD}"), title: "Work")
        XCTAssertFalse(work.isEnabled)
        XCTAssertEqual(work.enabledSource, "Work")
        XCTAssertEqual(work.sequence, "{PASSWORD}")
        XCTAssertEqual(work.sequenceSource, "Work")

        let servers = work.applying(.default, title: "Servers")
        XCTAssertEqual(servers, work, "inherit keeps what the parent decided")

        let on = servers.applying(VaultGroupAutoType(enabled: .on), title: "VPN")
        XCTAssertTrue(on.isEnabled)
        XCTAssertEqual(on.enabledSource, "VPN")
        XCTAssertEqual(on.sequence, "{PASSWORD}")
    }

    private func entry(
        _ title: String,
        url: String? = nil,
        autoType: VaultAutoTypeSettings = .default,
        inheritance: VaultAutoTypeInheritance = .root,
        type: VaultEntryType = .login,
        isTrashed: Bool = false,
        usage: Int = 0,
        fields: [VaultCustomField] = []
    ) -> VaultEntry {
        VaultEntry(
            isTrashed: isTrashed,
            usageCount: usage,
            title: title,
            username: "user",
            password: "pass",
            url: url.flatMap(URL.init(string:)),
            customFields: fields,
            entryType: type,
            autoType: autoType,
            autoTypeInheritance: inheritance
        )
    }

    func testMatchesRankAssociationThenURLThenTitle() {
        let window = AutoTypeWindow(appName: "Safari", title: "Log in to Jira · Atlassian", url: "https://studio.atlassian.net/login")
        let entries = [
            entry("Jira", usage: 9),
            entry("Atlassian", url: "studio.atlassian.net"),
            entry("Google", autoType: VaultAutoTypeSettings(associations: [VaultAutoTypeAssociation(windowTitle: "Log in to Jira*", sequence: "{USERNAME}{ENTER}")])),
            entry("Elsewhere", url: "https://example.com")
        ]
        let matches = AutoTypeMatcher.matches(in: entries, window: window)
        XCTAssertEqual(matches.map(\.entry.title), ["Google", "Atlassian", "Jira"])
        XCTAssertEqual(matches.map(\.reason), [.window, .url, .title])
        XCTAssertEqual(matches.first?.sequence, "{USERNAME}{ENTER}", "the association's own sequence")
        XCTAssertEqual(matches.last?.sequence, defaultAutoTypeSequence)
    }

    func testAdditionalURLFieldsAndShortTitles() {
        let window = AutoTypeWindow(appName: "Chrome", title: "Go", url: "https://shop.example.org/cart")
        let entries = [
            entry("Shop", fields: [VaultCustomField(key: "KP2A_URL_1", value: "https://example.org", isProtected: false)]),
            entry("Go")
        ]
        XCTAssertEqual(AutoTypeMatcher.matches(in: entries, window: window).map(\.entry.title), ["Shop"], "titles shorter than 3 characters don't match")
    }

    func testDisabledTrashedAndOtherTypesAreLeftOut() {
        let window = AutoTypeWindow(appName: "Steam", title: "Steam Sign In")
        let groupOff = VaultAutoTypeInheritance(isEnabled: false, enabledSource: "Games")
        let entries = [
            entry("Steam", autoType: VaultAutoTypeSettings(isEnabled: false)),
            entry("Steam", inheritance: groupOff),
            entry("Steam", isTrashed: true),
            entry("Steam", type: .note),
            entry("Steam", usage: 1)
        ]
        let matches = AutoTypeMatcher.matches(in: entries, window: window)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.entry.usageCount, 1)
    }

    func testSequenceForAPickedEntry() {
        let custom = entry("Bank", autoType: VaultAutoTypeSettings(sequence: "{PASSWORD}{ENTER}"))
        XCTAssertEqual(AutoTypeMatcher.sequence(for: custom, window: AutoTypeWindow(appName: "X", title: "Other")), "{PASSWORD}{ENTER}")
        let inherited = entry("Bank", inheritance: VaultAutoTypeInheritance(sequence: "{USERNAME}", sequenceSource: "Work"))
        XCTAssertEqual(inherited.effectiveAutoTypeSequence, "{USERNAME}")
        XCTAssertEqual(AutoTypeWindow(appName: "Safari", title: "T", url: "https://a.example.com/x").place, "a.example.com")
        XCTAssertEqual(AutoTypeWindow(appName: "Steam", title: "Steam Sign In").place, "Steam Sign In")
    }

    func testFieldValues() {
        let value = entry("Bank", url: "https://bank.example", fields: [VaultCustomField(key: "Email", value: "a@b.c", isProtected: false)])
        XCTAssertEqual(value.autoTypeValue(of: "USERNAME"), "user")
        XCTAssertEqual(value.autoTypeValue(of: "PASSWORD"), "pass")
        XCTAssertEqual(value.autoTypeValue(of: "URL"), "https://bank.example")
        XCTAssertEqual(value.autoTypeValue(of: "S:email"), "a@b.c")
        XCTAssertEqual(value.autoTypeValue(of: "S:Password"), "pass")
        XCTAssertEqual(value.autoTypeValue(of: "UUID")?.count, 32)
        XCTAssertNil(value.autoTypeValue(of: "S:Missing"))
        XCTAssertNil(value.autoTypeValue(of: "TOTP"))
    }
}

final class AutoTypeLoaderTests: XCTestCase {
    private var directory: URL!
    private var vaultURL: URL!
    private let password = "auto-type"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vaultURL = directory.appendingPathComponent("AutoType.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        _ = try await KeePassKitVaultLoader().createVault(options: VaultCreationOptions(
            fileURL: vaultURL,
            name: "AutoType",
            masterPassword: password,
            keyDerivation: fastKDF
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func open() async throws -> (KeePassKitVaultLoader, LoadedVault) {
        let loader = KeePassKitVaultLoader()
        let vault = try await loader.loadVault(from: vaultURL, masterPassword: password, keyFileURL: nil)
        return (loader, vault)
    }

    private func readTree() throws -> KPKTree {
        let key = KPKCompositeKey(keys: [try XCTUnwrap(KPKPasswordKey(password: password))])
        return try KPKTree(data: Data(contentsOf: vaultURL), key: key)
    }

    private var rootPath: String {
        "AutoType"
    }

    func testEntrySettingsRoundTripInKeePassFields() async throws {
        let (loader, _) = try await open()
        let settings = VaultAutoTypeSettings(
            isEnabled: false,
            sequence: "{PASSWORD}{ENTER}",
            associations: [
                VaultAutoTypeAssociation(windowTitle: "*Steam*"),
                VaultAutoTypeAssociation(windowTitle: "Cisco Secure Client — *", sequence: "{PASSWORD}{ENTER}")
            ]
        )
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "VPN", username: "anna", autoType: settings))

        let (_, reopened) = try await open()
        let entry = try XCTUnwrap(reopened.entries.first { $0.title == "VPN" })
        XCTAssertEqual(entry.autoType, settings)

        let stored = try XCTUnwrap(try readTree().allEntries.first { !$0.isHistory && $0.title == "VPN" }?.autotype)
        XCTAssertFalse(stored.enabled)
        XCTAssertEqual(stored.defaultKeystrokeSequence, "{PASSWORD}{ENTER}")
        XCTAssertEqual(stored.associations.map(\.windowTitle), ["*Steam*", "Cisco Secure Client — *"])
        XCTAssertTrue(stored.associations[0].hasDefaultKeystrokeSequence)
        XCTAssertEqual(stored.associations[1].keystrokeSequence, "{PASSWORD}{ENTER}")
    }

    func testFormWithoutAutoTypeKeepsTheEntrysSettings() async throws {
        let (loader, _) = try await open()
        let settings = VaultAutoTypeSettings(sequence: "{USERNAME}{ENTER}", associations: [VaultAutoTypeAssociation(windowTitle: "Bank*")])
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Bank", autoType: settings))
        let id = try XCTUnwrap(vault.entries.first { $0.title == "Bank" }?.id)

        vault = try await loader.updateEntry(id: id, form: VaultEntryForm(title: "Bank 2"))
        XCTAssertEqual(vault.entries.first { $0.id == id }?.autoType, settings, "nil leaves Auto-Type alone")

        let before = vault.entries.first { $0.id == id }
        let unchanged = try XCTUnwrap(before.map { VaultEntryForm(entry: $0) })
        vault = try await loader.updateEntry(id: id, form: unchanged)
        XCTAssertEqual(vault.entries.first { $0.id == id }?.autoType, settings)

        var cleared = unchanged
        cleared.autoType = .default
        vault = try await loader.updateEntry(id: id, form: cleared)
        XCTAssertEqual(vault.entries.first { $0.id == id }?.autoType, .default)
    }

    func testGroupSettingsAndInheritance() async throws {
        let (loader, _) = try await open()
        _ = try await loader.createGroup(inParentPath: nil, title: "Work", iconID: nil, autoType: VaultGroupAutoType(enabled: .inherit, sequence: "{USERNAME}{ENTER}{PASSWORD}{ENTER}"))
        _ = try await loader.createGroup(inParentPath: "\(rootPath).Work", title: "Servers", iconID: nil, autoType: nil)
        var vault = try await loader.createEntry(inGroupPath: "\(rootPath).Work.Servers", form: VaultEntryForm(title: "Box"))

        var box = try XCTUnwrap(vault.entries.first { $0.title == "Box" })
        XCTAssertTrue(box.isAutoTypeEnabled)
        XCTAssertEqual(box.effectiveAutoTypeSequence, "{USERNAME}{ENTER}{PASSWORD}{ENTER}")
        XCTAssertEqual(box.autoTypeInheritance.sequenceSource, "Work")
        let servers = try XCTUnwrap(vault.groups.first { $0.title == "Servers" })
        XCTAssertEqual(servers.autoType, .default)
        XCTAssertEqual(servers.autoTypeInheritance.sequenceSource, "Work")

        vault = try await loader.updateGroup(path: "\(rootPath).Work", title: "Work", iconID: nil, autoType: VaultGroupAutoType(enabled: .off))
        box = try XCTUnwrap(vault.entries.first { $0.title == "Box" })
        XCTAssertFalse(box.isAutoTypeEnabled)
        XCTAssertEqual(box.autoTypeInheritance.enabledSource, "Work")
        XCTAssertEqual(box.effectiveAutoTypeSequence, defaultAutoTypeSequence, "the custom sequence was removed")

        vault = try await loader.updateGroup(path: "\(rootPath).Work", title: "Work", iconID: nil)
        XCTAssertEqual(vault.groups.first { $0.title == "Work" }?.autoType, VaultGroupAutoType(enabled: .off), "nil keeps the group's settings")

        let work = try XCTUnwrap(try readTree().allGroups.first { $0.title == "Work" })
        XCTAssertEqual(work.isAutoTypeEnabled, .NO)
    }

    /// Settings written by another KeePass client (KeePassKit, as MacPass writes them).
    func testReadsSettingsWrittenByOtherClients() async throws {
        let tree = try readTree()
        let root = try XCTUnwrap(tree.root)
        let games = tree.createGroup(root)
        games.add(to: root)
        games.title = "Games"
        games.isAutoTypeEnabled = .NO
        let entry = tree.createEntry(games)
        entry.add(to: games)
        entry.title = "Steam"
        let autotype = try XCTUnwrap(entry.autotype)
        autotype.defaultKeystrokeSequence = "{USERNAME}{TAB}{PASSWORD}{ENTER}{DELAY 2000}{TOTP}{ENTER}"
        autotype.addAssociation(KPKWindowAssociation(windowTitle: "Steam*", keystrokeSequence: ""))
        let key = KPKCompositeKey(keys: [try XCTUnwrap(KPKPasswordKey(password: password))])
        try tree.encrypt(with: key, format: .kdbx).write(to: vaultURL, options: .atomic)

        let (_, vault) = try await open()
        let steam = try XCTUnwrap(vault.entries.first { $0.title == "Steam" })
        XCTAssertEqual(steam.autoType.sequence, "{USERNAME}{TAB}{PASSWORD}{ENTER}{DELAY 2000}{TOTP}{ENTER}")
        XCTAssertEqual(steam.autoType.associations, [VaultAutoTypeAssociation(windowTitle: "Steam*")])
        XCTAssertFalse(steam.isAutoTypeEnabled)
        XCTAssertEqual(vault.groups.first { $0.title == "Games" }?.autoType.enabled, .off)
    }

    func testExportedXMLKeepsAutoType() async throws {
        let (loader, _) = try await open()
        _ = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(
            title: "VPN",
            autoType: VaultAutoTypeSettings(sequence: "{PASSWORD}{ENTER}", associations: [VaultAutoTypeAssociation(windowTitle: "VPN*")])
        ))
        let exported = try await loader.exportDatabase(VaultExportOptions(format: .keePassXML, groupPath: nil, includesTrash: false, includesHistory: false, includesAttachments: false))
        let xml = String(decoding: exported.data, as: UTF8.self)
        XCTAssertTrue(xml.contains("<DefaultSequence>{PASSWORD}{ENTER}</DefaultSequence>"), xml)
        XCTAssertTrue(xml.contains("<Window>VPN*</Window>"))
    }

    func testResolvesReferencesInSequences() async throws {
        let (loader, _) = try await open()
        var vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Source", username: "shared-user"))
        let source = try XCTUnwrap(vault.entries.first { $0.title == "Source" })
        vault = try await loader.createEntry(inGroupPath: nil, form: VaultEntryForm(title: "Target"))
        let target = try XCTUnwrap(vault.entries.first { $0.title == "Target" })

        let reference = VaultFieldReference(field: .username, entryID: source.id).text.dropFirst().dropLast()
        let value = await loader.resolveAutoTypePlaceholder(String(reference), entryID: target.id)
        XCTAssertEqual(value, "shared-user")
        let unknown = await loader.resolveAutoTypePlaceholder("NOPE", entryID: target.id)
        XCTAssertNil(unknown)
    }
}

@MainActor
final class AutoTypeControllerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "AutoTypeControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func unlockedModel(entries: [VaultEntryForm]) async throws -> AppViewModel {
        let url = directory.appendingPathComponent("Controller.kdbx")
        let fastKDF = VaultDatabaseSettings(kdf: .argon2id, argonIterations: 1, argonMemoryMiB: 8, argonParallelism: 1)
        let loader = KeePassKitVaultLoader()
        _ = try await loader.createVault(options: VaultCreationOptions(fileURL: url, name: "Controller", masterPassword: "pw", keyDerivation: fastKDF))
        for form in entries {
            _ = try await loader.createEntry(inGroupPath: nil, form: form)
        }
        let settings = AppSettingsStore(userDefaults: defaults)
        settings.setTouchIDEnabled(false, for: url)
        let model = AppViewModel(vaultLoader: KeePassKitVaultLoader(), settingsStore: settings, userDefaults: defaults)
        model.selectVault(url: url)
        await model.unlock(masterPassword: "pw")
        XCTAssertTrue(model.loadState.isUnlocked)
        return model
    }

    private func entries(_ model: AppViewModel) -> [VaultEntry] {
        if case .loaded(let vault) = model.loadState {
            return vault.entries
        }
        return []
    }

    func testResolvesFieldsAndUsesUpAnHOTPCodeOnce() async throws {
        let model = try await unlockedModel(entries: [
            VaultEntryForm(
                title: "Bank",
                username: "anna",
                password: "p{a}ss",
                customFields: [VaultCustomFieldForm(key: "PIN", value: "1234", isProtected: true)],
                otp: VaultOTPForm(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", kind: .hotp, counter: 5)
            )
        ])
        let controller = AutoTypeController.shared
        controller.attach(model)
        let bank = try XCTUnwrap(entries(model).first)

        let tokens = try AutoTypeSequence.parse("{USERNAME}{TAB}{PASSWORD}{TAB}{S:PIN}{TAB}{TOTP}{HMACOTP}{ENTER}")
        let actions = try await controller.resolve(tokens, for: bank)
        XCTAssertEqual(actions, [
            .text("anna"), .key(.tab, []), .text("p{a}ss"), .key(.tab, []), .text("1234"), .key(.tab, []),
            .text("254676254676"), .key(.enter, [])
        ], "RFC 4226 code for counter 5, the same for both placeholders")
        XCTAssertEqual(entries(model).first?.otp?.counter, 6, "one code used up")

        do {
            _ = try await controller.resolve(try AutoTypeSequence.parse("{S:Missing}"), for: bank)
            XCTFail("a missing field is an error")
        } catch let error as AutoTypeSequenceError {
            XCTAssertEqual(error, .unknownCommand("{S:Missing}"))
        }
    }

    func testQuickAccessAutoTypeModeListsMatchesThenSearchResults() async throws {
        let model = try await unlockedModel(entries: [
            VaultEntryForm(title: "Jira", username: "anna"),
            VaultEntryForm(title: "Atlassian", url: "https://studio.atlassian.net"),
            VaultEntryForm(title: "Mail", username: "mail-user"),
            VaultEntryForm(title: "Notes", entryType: .note)
        ])
        var typed: [String] = []
        let actions = QuickAccessModel.Actions(close: {}, didUnlock: {}, refocus: {}, showInMainWindow: { _ in }, autoType: { typed.append($0.title) })
        let target = AutoTypeTarget(
            window: AutoTypeWindow(appName: "Safari", title: "Log in to Jira", url: "https://studio.atlassian.net/login"),
            processIdentifier: 1,
            appIcon: nil
        )
        let quickAccess = QuickAccessModel(viewModel: model, suggestionAppName: "Safari", autoTypeTarget: target, actions: actions)

        XCTAssertTrue(quickAccess.isAutoType)
        XCTAssertEqual(quickAccess.autoTypeMatches.map(\.entry.title), ["Atlassian", "Jira"])
        XCTAssertEqual(quickAccess.autoTypeMatches.map(\.reason), [.url, .title])
        XCTAssertTrue(quickAccess.autoTypeOthers.isEmpty, "other entries only while searching")

        quickAccess.query = "ma"
        XCTAssertTrue(quickAccess.autoTypeMatches.isEmpty)
        XCTAssertTrue(quickAccess.hasAutoTypeMatches)
        XCTAssertEqual(quickAccess.autoTypeOthers.map(\.title), ["Mail"], "notes can't be typed")
        XCTAssertEqual(quickAccess.selectedEntry?.title, "Mail")
        quickAccess.autoType(try XCTUnwrap(quickAccess.selectedEntry))
        XCTAssertEqual(typed, ["Mail"])
    }

    func testSettingsDefaults() {
        let settings = AppSettingsStore(userDefaults: defaults)
        XCTAssertTrue(settings.autoTypeEnabled)
        XCTAssertEqual(settings.autoTypeShortcut.displayString, "⌃⌥⌘A")
        XCTAssertEqual(settings.autoTypeKeyDelay, 10)
        settings.autoTypeKeyDelay = 40
        XCTAssertEqual(AppSettingsStore(userDefaults: defaults).autoTypeKeyDelay, 40)
    }

    func testEditorValidationRejectsBadSequences() {
        var form = VaultEntryForm(title: "A", autoType: VaultAutoTypeSettings(sequence: "{PASWORD}"))
        XCTAssertEqual(EntryFormValidation.validate(form), "Auto-Type: Unknown command {PASWORD}")
        form.autoType = VaultAutoTypeSettings(associations: [VaultAutoTypeAssociation(windowTitle: "X", sequence: "{TAB")])
        XCTAssertEqual(EntryFormValidation.validate(form), "Auto-Type: Missing } in sequence")
        form.autoType = VaultAutoTypeSettings(associations: [VaultAutoTypeAssociation(windowTitle: "X")])
        XCTAssertNil(EntryFormValidation.validate(form), "an empty association sequence uses the entry's")
        form.autoType = VaultAutoTypeSettings(associations: [VaultAutoTypeAssociation(windowTitle: "  ")])
        XCTAssertEqual(EntryFormValidation.validate(form), "Auto-Type: a window association needs a window title.")
    }

    func testDetailSummaryShowsOnlyNonDefaultSettings() {
        XCTAssertFalse(AutoTypeDetailSummary.isShown(for: VaultEntry(title: "A")))
        XCTAssertTrue(AutoTypeDetailSummary.isShown(for: VaultEntry(title: "A", autoType: VaultAutoTypeSettings(sequence: "{PASSWORD}"))))
        XCTAssertTrue(AutoTypeDetailSummary.isShown(for: VaultEntry(title: "A", autoTypeInheritance: VaultAutoTypeInheritance(isEnabled: false))))
        XCTAssertFalse(AutoTypeDetailSummary.isShown(for: VaultEntry(title: "A", entryType: .note, autoType: VaultAutoTypeSettings(isEnabled: false))))
    }
}
