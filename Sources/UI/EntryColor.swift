import SwiftUI

/// Helpers for the per-entry foreground/background colors stored in KDBX as
/// `#RRGGBB` hex strings.
enum EntryColor {
    /// Preset palette offered in the editor. Soft tints that read well on both
    /// light and dark backgrounds.
    static let palette: [String] = [
        "#E57373", // red
        "#FFB74D", // orange
        "#FFF176", // yellow
        "#AED581", // green
        "#4FC3F7", // blue
        "#9575CD", // purple
        "#F06292", // pink
        "#A1887F", // brown
        "#90A4AE"  // gray
    ]

    static func color(fromHex hex: String?) -> Color? {
        guard let hex else {
            return nil
        }
        var normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") {
            normalized.removeFirst()
        }
        guard normalized.count == 6, let value = UInt32(normalized, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    static func sameHex(_ lhs: String?, _ rhs: String?) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    private static func normalize(_ hex: String?) -> String? {
        guard let hex else {
            return nil
        }
        var normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalized.hasPrefix("#") {
            normalized = "#" + normalized
        }
        return normalized
    }
}

/// A row of selectable color swatches plus a "None" option.
struct ColorSwatchPicker: View {
    let title: String
    @Binding var selectionHex: String?

    var body: some View {
        HStack(spacing: 8) {
            noneSwatch
            ForEach(EntryColor.palette, id: \.self) { hex in
                swatch(hex: hex)
            }
        }
    }

    private var noneSwatch: some View {
        Button {
            selectionHex = nil
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                Image(systemName: "slash.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 22, height: 22)
            .overlay {
                if selectionHex == nil {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .iconHelp(L("No color"))
    }

    private func swatch(hex: String) -> some View {
        let isSelected = EntryColor.sameHex(selectionHex, hex)
        return Button {
            selectionHex = hex
        } label: {
            Circle()
                .fill(EntryColor.color(fromHex: hex) ?? .clear)
                .frame(width: 22, height: 22)
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.6),
                        lineWidth: isSelected ? 2 : 1
                    )
                }
        }
        .buttonStyle(.plain)
    }
}
