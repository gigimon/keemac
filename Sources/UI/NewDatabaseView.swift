import AppKit
import Data
import Domain
import SwiftUI

struct NewDatabaseView: View {
    private enum Step: Int, CaseIterable {
        case general
        case masterKey
        case encryption

        var title: String {
            switch self {
            case .general:
                return L("General")
            case .masterKey:
                return L("Master Key")
            case .encryption:
                return L("Encryption")
            }
        }
    }

    private enum Preset: String, CaseIterable {
        case recommended
        case compatible
        case custom

        var title: String {
            switch self {
            case .recommended:
                return L("Recommended")
            case .compatible:
                return L("Compatible")
            case .custom:
                return L("Custom")
            }
        }

        var detail: String {
            switch self {
            case .recommended:
                return "KDBX 4 · ChaCha20 · Argon2id"
            case .compatible:
                return "KDBX 3.1 · AES-256 · AES-KDF"
            case .custom:
                return L("Choose every parameter")
            }
        }
    }

    private enum Format: String, CaseIterable {
        case kdbx4 = "KDBX 4"
        case kdbx31 = "KDBX 3.1"
    }

    @Bindable var viewModel: AppViewModel
    let onCancel: () -> Void

    @State private var step: Step = .general
    @State private var name = ""
    @State private var details = ""
    @State private var directory: URL = UITesting.newDatabaseDirectory
        ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    @State private var useTrash = true
    @State private var historyMaxItems = 10
    @State private var password = ""
    @State private var confirmation = ""
    @State private var revealPassword = false
    @State private var keyFileURL: URL?
    @State private var hardwareKey: VaultHardwareKey?
    @State private var preset: Preset = .recommended
    @State private var format: Format = .kdbx4
    @State private var cipher: VaultCipher = .chacha20
    @State private var kdf: VaultKDFAlgorithm = .argon2id
    @State private var unlockSeconds: Double = 1
    @State private var memoryMiB: Double = 64
    @State private var parallelism: Double = 4
    @State private var compress = true
    @State private var calibrated: VaultDatabaseSettings?
    @State private var calibrationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var isCreating = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case details
        case password
        case confirmation
    }

    var body: some View {
        ZStack {
            KM.unlockBackground
                .ignoresSafeArea()
                .overlay(WindowDragRegion())

            VStack(spacing: 0) {
                Text(L("New Database"))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 28)

                stepIndicator
                    .padding(.top, 14)

                Group {
                    switch step {
                    case .general:
                        generalStep
                    case .masterKey:
                        masterKeyStep
                    case .encryption:
                        encryptionStep
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, minHeight: 340, alignment: .top)

                Spacer(minLength: 0)

                footer
            }
            .padding(.top, 0)
            .frame(width: 620)
            .ignoresSafeArea(.container, edges: .top)
        }
        .onAppear {
            focusedField = .name
        }
        .onExitCommand(perform: goBack)
        .onChange(of: step) { _, newStep in
            errorMessage = nil
            switch newStep {
            case .general:
                focusedField = .name
            case .masterKey:
                focusedField = .password
            case .encryption:
                recalibrate()
            }
        }
        .onChange(of: calibrationKey) { _, _ in
            if step == .encryption {
                recalibrate()
            }
        }
        .onDisappear {
            calibrationTask?.cancel()
        }
    }

    // MARK: - Steps

    private var stepIndicator: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                let isDone = item.rawValue < step.rawValue
                let isReached = item.rawValue <= step.rawValue
                Button {
                    if isDone {
                        step = item
                    }
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(isReached ? KM.accent : Color(light: .black(0.08), dark: .white(0.12)))
                            if isDone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(item.rawValue + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(isReached ? Color.white : KM.textSecondary)
                            }
                        }
                        .frame(width: 22, height: 22)
                        Text(item.title)
                            .font(.system(size: 12, weight: item == step ? .semibold : .regular))
                            .foregroundStyle(item == step ? KM.textPrimary : KM.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                if item != Step.allCases.last {
                    Capsule()
                        .fill(isDone ? KM.accent : Color(light: .black(0.10), dark: .white(0.12)))
                        .frame(width: 40, height: 2)
                }
            }
        }
    }

    private var generalStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(L("Name")) {
                TextField(L("e.g. Family"), text: $name)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("newDatabase.name")
                    .kmField(focused: focusedField == .name, background: KM.raisedFieldBackground)
                    .onSubmit(goNext)
            }

            row(L("Description"), alignTop: true) {
                TextField(L("Optional"), text: $details, axis: .vertical)
                    .lineLimit(2...3)
                    .focused($focusedField, equals: .details)
                    .padding(.vertical, 7)
                    .kmField(focused: focusedField == .details, height: nil, background: KM.raisedFieldBackground)
            }

            row(L("Save as")) {
                Text(fileName)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
            }

            row(L("Where")) {
                Button(action: chooseDirectory) {
                    HStack(spacing: 6) {
                        Image(systemName: isICloudDirectory ? "icloud.fill" : "folder.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(KM.accent)
                        Text(isICloudDirectory ? "iCloud Drive" : directory.lastPathComponent)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(KM.textSecondary)
                    }
                    .font(.system(size: 13))
                }
                .buttonStyle(KMButtonStyle(kind: .raised, height: 28, horizontalPadding: 10, fontWeight: .regular))
            }

            row(nil) {
                Text(UnlockView.displayDirectory(of: fileURL) + "/" + fileName)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Rectangle()
                .fill(KM.hairline)
                .frame(height: 0.5)
                .padding(.vertical, 6)

            row(L("Trash")) {
                HStack {
                    Text(L("Keep deleted entries in Trash"))
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $useTrash)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(KM.success)
                }
            }

            row(L("History")) {
                HStack {
                    Text(L("Keep previous versions of each entry"))
                        .font(.system(size: 13))
                    Spacer()
                    Stepper(value: $historyMaxItems, in: 0...100) {
                        Text("\(historyMaxItems)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var masterKeyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(nil) {
                Text(L("The master key encrypts the whole database. If you lose it, the data can’t be recovered."))
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row(L("Password")) {
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Group {
                            if revealPassword {
                                TextField("", text: $password)
                            } else {
                                SecureField("", text: $password)
                            }
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focusedField, equals: .password)
                        .accessibilityIdentifier("newDatabase.password")
                        .onSubmit { focusedField = .confirmation }

                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 24, cornerRadius: 6))
                        .iconHelp(revealPassword ? L("Hide password") : L("Show password"))
                    }
                    .kmField(focused: focusedField == .password, background: KM.raisedFieldBackground, horizontalPadding: 8)

                    Button {
                        let generated = PasswordGenerator.generate({
                            var options = PasswordGeneratorOptions()
                            options.length = 24
                            return options
                        }())
                        password = generated
                        confirmation = generated
                        revealPassword = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(KMIconButtonStyle(cornerRadius: 7, tint: KM.textPrimary, filled: true))
                    .iconHelp(L("Generate"))
                }
            }

            row(L("Confirm")) {
                Group {
                    if revealPassword {
                        TextField("", text: $confirmation)
                    } else {
                        SecureField("", text: $confirmation)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .focused($focusedField, equals: .confirmation)
                .accessibilityIdentifier("newDatabase.confirmation")
                .kmField(focused: focusedField == .confirmation, background: KM.raisedFieldBackground)
                .padding(.trailing, 36)
                .onSubmit(goNext)
            }

            row(nil) {
                HStack(spacing: 8) {
                    if let strength = PasswordStrength.evaluate(password) {
                        StrengthMeter(strength: strength, width: 100)
                        Text(strength.level.label)
                            .fontWeight(.medium)
                            .foregroundStyle(strength.level.color)
                        Text(L("\(Int(strength.entropyBits)) bits"))
                            .foregroundStyle(KM.textSecondary)
                    }
                    if !confirmation.isEmpty {
                        if confirmation == password {
                            Label(L("Match"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color(lightHex: 0x1F9D45, darkHex: 0x30D158))
                                .fixedSize()
                        } else {
                            Text(L("Passwords don’t match"))
                                .foregroundStyle(KM.danger)
                                .fixedSize()
                        }
                    }
                }
                .font(.system(size: 11))
                .frame(minHeight: 16)
            }

            Rectangle()
                .fill(KM.hairline)
                .frame(height: 0.5)
                .padding(.vertical, 6)

            row(L("Key file"), alignTop: true) {
                VStack(alignment: .leading, spacing: 6) {
                    if let keyFileURL {
                        HStack(spacing: 8) {
                            Image(systemName: "key.horizontal")
                                .foregroundStyle(KM.accent)
                            Text(keyFileURL.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                self.keyFileURL = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(KMIconButtonStyle(size: 24, cornerRadius: 6))
                            .iconHelp(L("Remove key file"))
                        }
                        .font(.system(size: 13))
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(light: .black(0.04), dark: .white(0.05)))
                        )
                        .help(keyFileURL.path(percentEncoded: false))
                    } else {
                        HStack(spacing: 8) {
                            Button(L("Choose File…"), action: chooseKeyFile)
                                .buttonStyle(KMButtonStyle(kind: .raised, height: 28, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                            Button(L("Generate New…"), action: generateKeyFile)
                                .buttonStyle(KMButtonStyle(kind: .raised, height: 28, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                        }
                    }
                    Text(L("Optional. Both the password and the file will be required to unlock. Keep a backup of the file."))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, 36)
            }

            row(L("Hardware key"), alignTop: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HardwareKeyPicker(
                        selected: hardwareKey,
                        connected: viewModel.connectedHardwareKeys,
                        isScanning: viewModel.isScanningHardwareKeys,
                        height: 34,
                        cornerRadius: 8,
                        identifierPrefix: "newDatabase.hardwareKey",
                        onSelect: { key in
                            hardwareKey = key
                            if key != nil {
                                setFormat(.kdbx4)
                            }
                        },
                        onRefresh: { Task { await viewModel.refreshHardwareKeys() } }
                    )
                    Text(L("The database will only open with this YubiKey. Compatible with KeePassXC."))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, 36)
            }
        }
    }

    private var encryptionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Preset.allCases, id: \.rawValue) { item in
                    presetCard(item)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            row(L("Unlock time")) {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { unlockSeconds },
                            set: { unlockSeconds = ($0 * 10).rounded() / 10 }
                        ),
                        in: 0.2...5
                    )
                        .controlSize(.small)
                    Text(L("\(String(format: "%.1f", unlockSeconds)) s"))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .padding(.top, 4)

            row(nil) {
                Text(L("Longer is harder to brute-force.") + " " + calibrationNote)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .padding(.top, -6)

            if preset == .custom {
                customParameters
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13))
                    .foregroundStyle(KM.accent)
                Text(summaryLine)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(KM.insetFill)
            )
            .padding(.top, 4)
        }
    }

    private var customParameters: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(L("Format")) {
                KMSegmentedControl(
                    options: Format.allCases.map { ($0, $0.rawValue) },
                    selection: Binding(get: { format }, set: { setFormat($0) }),
                    fontSize: 12,
                    horizontalPadding: 12
                )
            }
            row(L("Cipher")) {
                KMSegmentedControl(
                    options: availableCiphers.map { ($0, $0.displayName) },
                    selection: $cipher,
                    fontSize: 12,
                    horizontalPadding: 12
                )
            }
            row(L("Key derivation")) {
                KMSegmentedControl(
                    options: availableKDFs.map { ($0, $0.displayName) },
                    selection: $kdf,
                    fontSize: 12,
                    horizontalPadding: 12
                )
            }
            row(nil) {
                Text(kdf.isArgon ? L("Memory-hard. Resists GPU and ASIC cracking.") : L("Legacy. Use for KeePass 2.34 and older."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .padding(.top, -4)

            if kdf.isArgon {
                row(L("Memory")) {
                    HStack(spacing: 10) {
                        Slider(value: $memoryMiB, in: 16...1024, step: 16)
                            .controlSize(.small)
                        Text(L("\(Int(memoryMiB)) MB"))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                row(L("Parallelism")) {
                    HStack(spacing: 10) {
                        Slider(value: $parallelism, in: 1...16, step: 1)
                            .controlSize(.small)
                        Text(L("\(Int(parallelism)) threads"))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }

            row(L("Compression")) {
                HStack {
                    Text("GZip")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $compress)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(KM.success)
                }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(KM.hairline).frame(height: 0.5)
        }
    }

    private func presetCard(_ item: Preset) -> some View {
        let isSelected = preset == item
        return Button {
            selectPreset(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? KM.accent : KM.textSecondary)
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? KM.accent.opacity(0.1) : KM.raisedFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? KM.accent : KM.softBorder, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(KM.danger)
                    .lineLimit(2)
                    .accessibilityIdentifier("newDatabase.error")
            }
            Spacer()
            Button(step == .general ? L("Cancel") : L("Back"), action: goBack)
                .buttonStyle(KMButtonStyle(kind: .secondary, height: 30, fontWeight: .regular))
                .disabled(isCreating)
                .accessibilityIdentifier("newDatabase.back")
            Button(action: goNext) {
                HStack(spacing: 6) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(step == .encryption ? (isCreating ? L("Creating…") : L("Create Database")) : L("Continue"))
                }
            }
            .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
            .keyboardShortcut(.defaultAction)
            .disabled(isCreating)
            .accessibilityIdentifier("newDatabase.next")
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private func row<Content: View>(_ label: String?, alignTop: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 12) {
            Text(label ?? "")
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
                .frame(width: 100, alignment: .trailing)
                .padding(.top, alignTop ? 8 : 0)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Derived values

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fileName: String {
        let base = trimmedName.isEmpty ? L("Untitled") : trimmedName
        let sanitized = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return sanitized + ".kdbx"
    }

    private var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    private var isICloudDirectory: Bool {
        directory.path(percentEncoded: false).contains("com~apple~CloudDocs")
    }

    private var availableCiphers: [VaultCipher] {
        format == .kdbx31 ? [.aes256, .twofish] : VaultCipher.allCases
    }

    private var availableKDFs: [VaultKDFAlgorithm] {
        format == .kdbx31 ? [.aes] : [.argon2id, .argon2d, .aes]
    }

    private var baseKeyDerivation: VaultDatabaseSettings {
        VaultDatabaseSettings(
            kdf: kdf,
            argonIterations: 2,
            argonMemoryMiB: UInt64(memoryMiB),
            argonParallelism: UInt32(parallelism)
        )
    }

    private var calibrationKey: String {
        "\(kdf.rawValue)-\(Int(memoryMiB))-\(Int(parallelism))-\(unlockSeconds)"
    }

    private var calibrationNote: String {
        guard let calibrated else {
            return L("Calibrating on this Mac…")
        }
        if calibrated.kdf.isArgon {
            return L("Calibrated on this Mac: \(String(calibrated.argonIterations)) iterations.")
        }
        return L("Calibrated on this Mac: \(String(format: "%.1f", Double(calibrated.aesRounds) / 1_000_000))M rounds.")
    }

    private var summaryLine: String {
        var parts = [format.rawValue, cipher.displayName, kdf.displayName]
        if kdf.isArgon {
            parts.append(L("\(Int(memoryMiB)) MB"))
        }
        parts.append(L("~\(String(format: "%.1f", unlockSeconds)) s to unlock"))
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func selectPreset(_ item: Preset) {
        preset = item
        switch item {
        case .recommended:
            format = .kdbx4
            cipher = .chacha20
            kdf = .argon2id
        case .compatible:
            // KeePassXC's challenge-response scheme needs KDBX 4.
            format = hardwareKey == nil ? .kdbx31 : .kdbx4
            cipher = .aes256
            kdf = .aes
        case .custom:
            break
        }
    }

    private func setFormat(_ newFormat: Format) {
        format = hardwareKey == nil ? newFormat : .kdbx4
        if !availableCiphers.contains(cipher) {
            cipher = .aes256
        }
        if !availableKDFs.contains(kdf) {
            kdf = availableKDFs[0]
        }
    }

    private func recalibrate() {
        calibrationTask?.cancel()
        calibrated = nil
        let base = baseKeyDerivation
        let seconds = unlockSeconds
        calibrationTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                try? KeePassKitVaultLoader.calibrate(base, targetSeconds: seconds)
            }.value
            guard !Task.isCancelled else {
                return
            }
            calibrated = result
        }
    }

    private func goBack() {
        guard !isCreating else {
            return
        }
        if let previous = Step(rawValue: step.rawValue - 1) {
            step = previous
        } else {
            onCancel()
        }
    }

    private func goNext() {
        errorMessage = nil
        switch step {
        case .general:
            guard !trimmedName.isEmpty else {
                errorMessage = L("Enter a name for the database.")
                return
            }
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                errorMessage = L("“\(fileName)” already exists in this folder.")
                return
            }
            step = .masterKey
        case .masterKey:
            guard !password.isEmpty || keyFileURL != nil || hardwareKey != nil else {
                errorMessage = L("Set a password, a key file, or both.")
                return
            }
            guard password == confirmation else {
                errorMessage = L("Passwords don’t match.")
                return
            }
            step = .encryption
        case .encryption:
            create()
        }
    }

    private func create() {
        isCreating = true
        let base = baseKeyDerivation
        let seconds = unlockSeconds
        let existing = calibrated
        let options = { (keyDerivation: VaultDatabaseSettings) in
            VaultCreationOptions(
                fileURL: fileURL,
                name: trimmedName,
                details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                masterPassword: password,
                keyFileURL: keyFileURL,
                hardwareKey: hardwareKey,
                useTrash: useTrash,
                historyMaxItems: historyMaxItems,
                cipher: cipher,
                keyDerivation: keyDerivation,
                compress: compress
            )
        }

        Task {
            do {
                let keyDerivation: VaultDatabaseSettings
                if let existing {
                    keyDerivation = existing
                } else {
                    keyDerivation = try await Task.detached(priority: .userInitiated) {
                        try KeePassKitVaultLoader.calibrate(base, targetSeconds: seconds)
                    }.value
                }
                try await viewModel.createVault(options: options(keyDerivation))
                password = ""
                confirmation = ""
            } catch {
                if case VaultError.hardwareKeyCancelled = error {
                    errorMessage = nil
                } else {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            isCreating = false
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
        }
    }

    private func chooseKeyFile() {
        if let url = VaultFilePicker.chooseKeyFile() {
            keyFileURL = url
        }
    }

    private func generateKeyFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName.replacingOccurrences(of: ".kdbx", with: ".keyx")
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.title = L("Save Key File")
        panel.message = L("Keep a backup of this file. Without it the database can’t be opened.")
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try KeePassKitVaultLoader.generateKeyFile(at: url)
            keyFileURL = url
            CopyFeedbackCenter.shared.show(L("Key file generated"), duration: 2.4)
        } catch {
            errorMessage = L("Could not save the key file: \(error.localizedDescription)")
        }
    }
}
