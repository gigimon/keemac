import SwiftUI

struct HoverHighlightModifier: ViewModifier {
    @State private var isHovered: Bool = false
    let cornerRadius: CGFloat
    let tint: Color
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered ? tint.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isHovered ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    func hoverHighlight(
        cornerRadius: CGFloat = 8,
        tint: Color = .accentColor,
        padding: CGFloat = 0
    ) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius, tint: tint, padding: padding))
    }
}
