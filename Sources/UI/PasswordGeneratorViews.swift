import SwiftUI

// MARK: - Panel under password fields

/// Generator controls under a password field (entry editor, New Entry and typed-entry sheets).
/// Changing an option generates a new value right away.
struct PasswordGeneratorPanel: View {
    let password: String
    /// The field holds a generated value; its strength comes from the generator's exact entropy.
    let isGenerated: Bool
    let onGenerate: (String) -> Void

    @State private var settings = PasswordGeneratorSettings.shared
    @State private var showsOptions = false

    private var options: PasswordGeneratorOptions { settings.options }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                KMSegmentedControl(
                    options: PasswordGeneratorOptions.Mode.allCases.map { ($0, $0.title) },
                    selection: optionBinding(\.mode),
                    fontSize: 11,
                    horizontalPadding: 10
                )
                Spacer(minLength: 0)
                GeneratorStrengthLabel(strength: strength, meterWidth: 44)
            }

            switch options.mode {
            case .password:
                LengthRow(length: optionBinding(\.length), labelWidth: 58)
            case .passphrase:
                WordsRow(words: optionBinding(\.words), labelWidth: 58)
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showsOptions.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(KM.textSecondary)
                        .rotationEffect(.degrees(showsOptions ? 90 : 0))
                        .frame(width: 16)
                    Text(L("Options"))
                        .foregroundStyle(KM.textPrimary)
                    if !showsOptions {
                        Text(PasswordGenerator.summary(options))
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 6)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsOptions {
                GeneratorOptionsView(options: optionBinding(\.self), layout: .compact)
                    .padding(.leading, 19)
                    .padding(.bottom, 2)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(KM.insetFill)
        )
    }

    private var strength: PasswordStrength? {
        isGenerated ? .forEntropy(PasswordGenerator.entropyBits(options)) : PasswordStrength.evaluate(password)
    }

    /// Writes an option and generates a new value with it.
    private func optionBinding<Value>(_ keyPath: WritableKeyPath<PasswordGeneratorOptions, Value>) -> Binding<Value> {
        Binding(
            get: { settings.options[keyPath: keyPath] },
            set: { value in
                settings.options[keyPath: keyPath] = value
                onGenerate(settings.generate())
            }
        )
    }
}

// MARK: - Shared pieces

struct GeneratorStrengthLabel: View {
    let strength: PasswordStrength?
    var meterWidth: CGFloat = 52

    var body: some View {
        HStack(spacing: 6) {
            StrengthMeter(strength: strength, width: meterWidth)
            if let strength {
                Text(strength.level.label)
                    .fontWeight(.medium)
                    .foregroundStyle(strength.level.color)
                    .lineLimit(1)
                Text(L("≈ \(Int(strength.entropyBits.rounded())) bits"))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(KM.textSecondary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .fixedSize()
    }
}

struct LengthRow: View {
    @Binding var length: Int
    var labelWidth: CGFloat
    var labelAlignment: Alignment = .leading

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Length"))
                .foregroundStyle(KM.textSecondary)
                .frame(width: labelWidth, alignment: labelAlignment)
            Slider(
                value: Binding(
                    get: { Double(length) },
                    set: { value in
                        let rounded = Int(value.rounded())
                        if rounded != length {
                            length = rounded
                        }
                    }
                ),
                in: Double(PasswordGeneratorOptions.lengthRange.lowerBound)...Double(PasswordGeneratorOptions.lengthRange.upperBound)
            )
            .controlSize(.small)
            Text("\(length)")
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
        }
    }
}

struct WordsRow: View {
    @Binding var words: Int
    var labelWidth: CGFloat
    var labelAlignment: Alignment = .leading

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Words"))
                .foregroundStyle(KM.textSecondary)
                .frame(width: labelWidth, alignment: labelAlignment)
            HStack(spacing: 0) {
                stepButton("minus", help: L("Fewer words"), enabled: words > PasswordGeneratorOptions.wordsRange.lowerBound) {
                    words -= 1
                }
                Text("\(words)")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(minWidth: 20)
                stepButton("plus", help: L("More words"), enabled: words < PasswordGeneratorOptions.wordsRange.upperBound) {
                    words += 1
                }
            }
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(KM.raisedButtonBackground))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(KM.softBorder, lineWidth: 0.5))
            Text(L("from the EFF word list"))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func stepButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(KM.textPrimary)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .iconHelp(help)
    }
}

/// The options hidden behind "Options" in the panel and shown in full in the generator window.
struct GeneratorOptionsView: View {
    enum Layout {
        /// Under a password field: no labels column, words are in the main row.
        case compact
        /// Generator window: right-aligned labels, two-column character grid.
        case window
    }

    @Binding var options: PasswordGeneratorOptions
    let layout: Layout

    private var labelWidth: CGFloat { layout == .window ? 72 : 52 }

    var body: some View {
        VStack(alignment: .leading, spacing: layout == .window ? 10 : 9) {
            switch options.mode {
            case .password:
                passwordOptions
            case .passphrase:
                passphraseOptions
            }
        }
        .font(.system(size: 12))
    }

    // MARK: Password

    @ViewBuilder
    private var passwordOptions: some View {
        if layout == .window {
            LengthRow(length: $options.length, labelWidth: labelWidth, labelAlignment: .trailing)
            HStack(alignment: .top, spacing: 10) {
                label(L("Characters"))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 7) {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 7) {
                        classToggles
                    }
                    avoidToggle
                    pinNote
                }
            }
            symbolsRow
        } else {
            TagFlowLayout(spacing: 16, lineSpacing: 6) {
                classToggles
            }
            pinNote
            avoidToggle
            symbolsRow
        }
    }

    @ViewBuilder
    private var classToggles: some View {
        classToggle(L("Lowercase"), hint: "a–z", \.lowercase)
        classToggle(L("Uppercase"), hint: "A–Z", \.uppercase)
        classToggle(L("Digits"), hint: "0–9", \.digits)
        classToggle(L("Symbols"), hint: "#$&", \.symbols)
    }

    private func classToggle(_ title: String, hint: String, _ keyPath: WritableKeyPath<PasswordGeneratorOptions, Bool>) -> some View {
        let isLast = options[keyPath: keyPath] && options.enabledClassCount == 1
        return HStack(spacing: 4) {
            KMCheckbox(title: title, isOn: Binding(
                get: { options[keyPath: keyPath] },
                set: { value in
                    if !isLast {
                        options[keyPath: keyPath] = value
                    }
                }
            ))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
        }
        .fixedSize()
        .opacity(isLast ? 0.5 : 1)
        .help(isLast ? L("At least one character type stays on") : "")
    }

    private var avoidToggle: some View {
        HStack(spacing: 4) {
            KMCheckbox(title: L("Avoid look-alike characters"), isOn: $options.avoidLookAlikes)
            Text("0 O o 1 l I |")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(KM.textSecondary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var pinNote: some View {
        if PasswordGenerator.isPIN(options) {
            Text(L("Digits only: generates a numeric PIN."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textSecondary)
        }
    }

    @ViewBuilder
    private var symbolsRow: some View {
        HStack(spacing: layout == .window ? 10 : 6) {
            label(L("Symbols"))
            TextField("", text: $options.symbolSet)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .kmField(height: 26, cornerRadius: 6, background: KM.raisedFieldBackground, horizontalPadding: 8)
                .disabled(!options.symbols)
            if options.symbolSet != PasswordGeneratorOptions.defaultSymbols {
                Button {
                    options.symbolSet = PasswordGeneratorOptions.defaultSymbols
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 6, tint: KM.textPrimary, filled: true))
                .iconHelp(L("Restore default symbols"))
                .disabled(!options.symbols)
            }
        }
        .opacity(options.symbols ? 1 : 0.45)
        if options.symbols, PasswordGenerator.effectiveSymbols(options).isEmpty {
            Text(L("No symbols left, so none are used."))
                .font(.system(size: 11))
                .foregroundStyle(Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
                .padding(.leading, labelWidth + (layout == .window ? 10 : 6))
        }
    }

    // MARK: Passphrase

    @ViewBuilder
    private var passphraseOptions: some View {
        if layout == .window {
            WordsRow(words: $options.words, labelWidth: labelWidth, labelAlignment: .trailing)
        }
        HStack(spacing: layout == .window ? 10 : 6) {
            label(L("Separator"))
            Picker("", selection: $options.separator) {
                ForEach(PasswordGeneratorOptions.Separator.allCases, id: \.self) { separator in
                    Text(separator.title).tag(separator)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            if options.separator == .custom {
                TextField("+", text: Binding(
                    get: { options.customSeparator },
                    set: { value in
                        // Letters and digits would blend into the words.
                        options.customSeparator = String(value.filter { !$0.isLetter && !$0.isNumber }.prefix(3))
                    }
                ))
                .font(.system(size: 12, design: .monospaced))
                .kmField(height: 24, cornerRadius: 6, background: KM.raisedFieldBackground, horizontalPadding: 8)
                .frame(width: 48)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: 16) {
            if layout == .window {
                Color.clear.frame(width: labelWidth - 6, height: 1)
            }
            KMCheckbox(title: L("Capitalize words"), isOn: $options.capitalize)
                .fixedSize()
            KMCheckbox(title: L("Add a number"), isOn: $options.addNumber)
                .fixedSize()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(KM.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: labelWidth, alignment: layout == .window ? .trailing : .leading)
    }
}
