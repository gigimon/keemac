import AppKit
import SwiftUI

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(light: NSColor(hex: lightHex), dark: NSColor(hex: darkHex))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func white(_ alpha: CGFloat) -> NSColor {
        NSColor(white: 1, alpha: alpha)
    }

    static func black(_ alpha: CGFloat) -> NSColor {
        NSColor(white: 0, alpha: alpha)
    }
}

enum KM {
    static let accent = Color(lightHex: 0x007AFF, darkHex: 0x0A84FF)
    static let textPrimary = Color(lightHex: 0x1D1D1F, darkHex: 0xF5F5F7)
    static let textSecondary = Color(lightHex: 0x6E6E73, darkHex: 0xA1A1A6)
    static let textTertiary = Color(lightHex: 0x8E8E93, darkHex: 0x8E8E93)
    static let chevron = Color(lightHex: 0xAEAEB2, darkHex: 0x636366)

    static let windowBackground = Color(lightHex: 0xFFFFFF, darkHex: 0x1E1E20)
    static let sidebarBackground = Color(lightHex: 0xF2F2F5, darkHex: 0x2A2A2D)
    static let cardBackground = Color(lightHex: 0xF5F5F7, darkHex: 0x2A2A2D)
    static let sheetBackground = Color(lightHex: 0xFBFBFD, darkHex: 0x2A2A2D)
    static let unlockBackground = Color(lightHex: 0xFBFBFD, darkHex: 0x262629)
    static let fieldBackground = Color(lightHex: 0xFFFFFF, darkHex: 0x2C2C2F)
    static let raisedFieldBackground = Color(lightHex: 0xFFFFFF, darkHex: 0x323235)
    static let raisedButtonBackground = Color(lightHex: 0xFFFFFF, darkHex: 0x3A3A3D)

    static let selection = Color(light: .black(0.08), dark: .white(0.10))
    static let hairline = Color(light: .black(0.08), dark: .white(0.08))
    static let separator = Color(light: .black(0.10), dark: .white(0.10))
    static let fieldBorder = Color(light: .black(0.20), dark: .white(0.14))
    static let softBorder = Color(light: .black(0.14), dark: .white(0.10))
    static let subtleFill = Color(light: .black(0.05), dark: .white(0.08))
    static let subtleFillHover = Color(light: .black(0.09), dark: .white(0.12))
    static let controlFill = Color(light: .black(0.06), dark: .white(0.10))
    static let controlFillHover = Color(light: .black(0.10), dark: .white(0.14))
    static let insetFill = Color(light: .black(0.035), dark: .white(0.05))
    static let rowHover = Color(light: .black(0.04), dark: .white(0.05))
    static let chromeBackground = Color(light: .white(0.9), dark: NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 62 / 255, alpha: 0.85))
    static let chromeBackgroundHover = Color(lightHex: 0xF2F2F4, darkHex: 0x48484C)
    static let chromeBorder = Color(light: .black(0.12), dark: .white(0.12))
    static let menuBackground = Color(
        light: NSColor(srgbRed: 252 / 255, green: 252 / 255, blue: 253 / 255, alpha: 0.98),
        dark: NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 52 / 255, alpha: 0.98)
    )
    static let dialogBackground = Color(
        light: NSColor(srgbRed: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 0.98),
        dark: NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 48 / 255, alpha: 0.98)
    )
    static let toastBackground = Color(
        light: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 0.92),
        dark: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 240 / 255, alpha: 0.95)
    )
    static let toastText = Color(lightHex: 0xFFFFFF, darkHex: 0x1D1D1F)

    static let danger = Color(lightHex: 0xD70015, darkHex: 0xFF6961)
    static let destructive = Color(lightHex: 0xFF3B30, darkHex: 0xFF3B30)
    static let warning = Color(lightHex: 0xFF9F0A, darkHex: 0xFF9F0A)
    static let success = Color(lightHex: 0x34C759, darkHex: 0x34C759)
    static let touchID = Color(lightHex: 0xFF2D55, darkHex: 0xFF375F)
    static let symbolChar = Color(lightHex: 0xC93400, darkHex: 0xFF9F0A)
    static let placeholderTile = Color(lightHex: 0xC7C7CC, darkHex: 0x48484A)

    static let brandGradient = LinearGradient(
        colors: [Color(nsColor: NSColor(hex: 0x4A95FF)), Color(nsColor: NSColor(hex: 0x0A64E6))],
        startPoint: .top,
        endPoint: .bottom
    )

    static let tagPalette: [Color] = [
        Color(nsColor: NSColor(hex: 0x34C759)),
        Color(nsColor: NSColor(hex: 0x007AFF)),
        Color(nsColor: NSColor(hex: 0xFF9F0A)),
        Color(nsColor: NSColor(hex: 0xAF52DE)),
        Color(nsColor: NSColor(hex: 0xFF2D55)),
        Color(nsColor: NSColor(hex: 0x30B0C7)),
        Color(nsColor: NSColor(hex: 0xFFCC00)),
        Color(nsColor: NSColor(hex: 0x8E8E93))
    ]

    static func tagColor(_ tag: String) -> Color {
        tagPalette[Int(stableHash(tag.lowercased()) % UInt32(tagPalette.count))]
    }

    static func tileColor(for title: String) -> Color {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return placeholderTile
        }
        return oklch(lightness: 0.64, chroma: 0.15, hue: Double(stableHash(trimmed.lowercased()) % 360))
    }

    static func stableHash(_ value: String) -> UInt32 {
        var hash: UInt32 = 5381
        for scalar in value.unicodeScalars {
            hash = (hash &<< 5) &+ hash &+ scalar.value
        }
        return hash
    }

    static func oklch(lightness: Double, chroma: Double, hue: Double) -> Color {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s_ = lightness - 0.0894841775 * a - 1.2914855480 * b

        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        func encode(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }

        return Color(.sRGB, red: encode(red), green: encode(green), blue: encode(blue), opacity: 1)
    }
}

struct KMButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case chrome
        case raised
        case destructive
        /// Transparent until hovered, secondary text ("Ignore" in the sync banner).
        case ghost
    }

    var kind: Kind = .secondary
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 16
    var fullWidth: Bool = false
    var fontWeight: Font.Weight = .medium
    var fontSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        KMButtonBody(configuration: configuration, style: self)
    }

    private struct KMButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let style: KMButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: style.fontSize, weight: style.fontWeight))
                .foregroundStyle(foreground)
                .padding(.horizontal, style.horizontalPadding)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .frame(height: style.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(background)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(border, lineWidth: 0.5)
                )
                .shadow(color: shadowColor, radius: style.kind == .chrome ? 3 : 1, y: style.kind == .chrome ? 2 : 1)
                .brightness(brightness)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule(style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }

        private var foreground: Color {
            switch style.kind {
            case .primary, .destructive:
                return .white
            case .secondary, .chrome, .raised:
                return KM.textPrimary
            case .ghost:
                return KM.textSecondary
            }
        }

        private var background: Color {
            let hovered = isHovered && isEnabled
            switch style.kind {
            case .primary:
                return KM.accent
            case .destructive:
                return KM.destructive
            case .secondary:
                return hovered ? KM.controlFillHover : KM.controlFill
            case .chrome:
                return hovered ? KM.chromeBackgroundHover : KM.chromeBackground
            case .raised:
                return KM.raisedButtonBackground
            case .ghost:
                return hovered ? KM.controlFill : .clear
            }
        }

        private var border: Color {
            switch style.kind {
            case .chrome:
                return KM.chromeBorder
            case .raised:
                return KM.softBorder
            case .primary, .secondary, .destructive, .ghost:
                return .clear
            }
        }

        private var shadowColor: Color {
            switch style.kind {
            case .primary, .raised:
                return .black.opacity(0.08)
            case .chrome:
                return .black.opacity(0.08)
            case .secondary, .destructive, .ghost:
                return .clear
            }
        }

        private var brightness: Double {
            guard isEnabled else {
                return 0
            }
            if configuration.isPressed {
                return -0.06
            }
            switch style.kind {
            case .primary, .destructive:
                return isHovered ? 0.05 : 0
            case .raised:
                return isHovered ? -0.02 : 0
            case .secondary, .chrome, .ghost:
                return 0
            }
        }
    }
}

struct KMIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var width: CGFloat?
    var cornerRadius: CGFloat = 8
    var tint: Color = KM.textSecondary
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        KMIconButtonBody(configuration: configuration, style: self)
    }

    private struct KMIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let style: KMIconButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(style.tint)
                .frame(width: style.width ?? style.size, height: style.size)
                .background(
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }

        private var fill: Color {
            if style.filled {
                return isHovered && isEnabled ? KM.subtleFillHover : KM.subtleFill
            }
            return isHovered && isEnabled ? KM.controlFill : .clear
        }
    }
}

private struct KMFieldModifier: ViewModifier {
    let isFocused: Bool
    /// Red border and focus ring for a rejected value (wrong password).
    let isInvalid: Bool
    let height: CGFloat?
    let cornerRadius: CGFloat
    let background: Color
    let horizontalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isFocused || isInvalid ? 1 : 0.5)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                    .stroke((isInvalid ? KM.danger : KM.accent).opacity(isFocused ? 0.25 : 0), lineWidth: 3)
                    .padding(-1.5)
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var borderColor: Color {
        if isInvalid {
            return KM.danger
        }
        return isFocused ? KM.accent : KM.fieldBorder
    }
}

private struct KMCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(KM.cardBackground)
            )
    }
}

extension View {
    func kmField(
        focused: Bool = false,
        invalid: Bool = false,
        height: CGFloat? = 30,
        cornerRadius: CGFloat = 7,
        background: Color = KM.fieldBackground,
        horizontalPadding: CGFloat = 10
    ) -> some View {
        modifier(KMFieldModifier(
            isFocused: focused,
            isInvalid: invalid,
            height: height,
            cornerRadius: cornerRadius,
            background: background,
            horizontalPadding: horizontalPadding
        ))
    }

    func kmCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(KMCardModifier(cornerRadius: cornerRadius))
    }

    func kmFloatingPanel(cornerRadius: CGFloat, background: Color) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(KM.softBorder, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
    }
}

struct KMSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
    }
}

struct KMCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? KM.accent : KM.raisedButtonBackground)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : Color(light: .black(0.3), dark: .white(0.25)), lineWidth: 0.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
        }
    }
}

/// The app icon laid out by the size of its rounded square. The icon image has
/// transparent margins and its own shadow (824 of 1024 px is the body), so it is
/// drawn larger and the overflow doesn't take part in layout.
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        let imageSize = (size * 1024 / 824).rounded()
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: imageSize, height: imageSize)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct LetterTile: View {
    let title: String
    var size: CGFloat = 34
    var cornerRadius: CGFloat = 9
    var fontSize: CGFloat = 15
    var colorHex: String?
    var iconPNGData: Data?
    var iconID: Int?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tileColor)
            if let iconPNGData, let image = NSImage(data: iconPNGData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.2)
            } else if let symbol = customSymbol {
                Image(systemName: symbol)
                    .font(.system(size: fontSize * 0.95, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(letter)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var letter: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    private var customSymbol: String? {
        guard let iconID, iconID != 0 else {
            return nil
        }
        return DefaultKeePassIconMapper.symbolName(for: iconID)
    }

    private var tileColor: Color {
        if iconPNGData != nil {
            return KM.raisedButtonBackground
        }
        if let color = EntryColor.color(fromHex: colorHex) {
            return color
        }
        return KM.tileColor(for: title)
    }
}

struct StrengthMeter: View {
    let strength: PasswordStrength?
    var width: CGFloat = 44

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color(light: .black(0.08), dark: .white(0.12)))
            Capsule(style: .continuous)
                .fill(strength?.level.color ?? .clear)
                .frame(width: width * (strength?.fraction ?? 0))
        }
        .frame(width: width, height: 4)
        .accessibilityElement()
        .accessibilityLabel(L("Password strength"))
        .accessibilityValue(strength?.level.label ?? L("None"))
    }
}

struct OTPRing: View {
    let remaining: Int
    let period: Int
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(light: .black(0.10), dark: .white(0.14)), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(remaining <= 5 ? KM.destructive : KM.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
        .frame(width: size * 0.8, height: size * 0.8)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fraction: CGFloat {
        guard period > 0 else {
            return 0
        }
        return min(max(CGFloat(remaining) / CGFloat(period), 0), 1)
    }
}

struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        /// Only drags the window; nothing to announce.
        override func isAccessibilityElement() -> Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
                return
            }
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum KMLayout: String, CaseIterable {
    case tahoe
    case classic
    case compact

    static let storageKey = "keemac.appearance.layout"
    static let showIconsKey = "keemac.appearance.showIcons"

    var title: String {
        switch self {
        case .tahoe:
            return "Tahoe"
        case .classic:
            return L("Classic")
        case .compact:
            return L("Compact")
        }
    }

    var hasFloatingSidebar: Bool {
        self == .tahoe
    }

    var usesCompactRows: Bool {
        self == .compact
    }

    var usesFormDetail: Bool {
        self == .classic
    }
}

extension View {
    /// Tooltip and VoiceOver label for a control that shows only an icon.
    /// The shortcut in parentheses ("Lock Database (⌘L)") stays in the tooltip only.
    func iconHelp(_ text: String) -> some View {
        help(text).accessibilityLabel(Text(spokenLabel(text)))
    }
}

/// "Lock Database (⌘L)" → "Lock Database"; the shortcut is announced by the menu, not the button.
private func spokenLabel(_ text: String) -> String {
    guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else {
        return text
    }
    let inside = text[open.upperBound..<text.index(before: text.endIndex)]
    let shortcutMarks = CharacterSet(charactersIn: "⌘⌥⇧⌃←→↑↓")
    guard inside == "Esc" || inside.unicodeScalars.contains(where: shortcutMarks.contains) else {
        return text
    }
    return String(text[..<open.lowerBound])
}
