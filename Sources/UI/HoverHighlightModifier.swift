import SwiftUI

struct HoverHighlightModifier: ViewModifier {
    @State private var isHovered: Bool = false
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered ? tint.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isHovered ? tint.opacity(0.14) : Color.clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 8, tint: Color = .accentColor) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius, tint: tint))
    }
}
