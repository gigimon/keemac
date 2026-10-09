import SwiftUI

enum KeeMacControlMetrics {
    static let fieldHeight: CGFloat = 40
    static let tallFieldHeight: CGFloat = 44
    static let buttonHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 8
}

private struct BoxedFieldModifier: ViewModifier {
    let minHeight: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary)
            )
    }
}

private struct PrimaryActionButtonModifier: ViewModifier {
    let minWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: minWidth, minHeight: KeeMacControlMetrics.buttonHeight)
            .hoverHighlight(cornerRadius: 10, tint: .blue)
    }
}

private struct SecondaryActionButtonModifier: ViewModifier {
    let minWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(minWidth: minWidth, minHeight: KeeMacControlMetrics.buttonHeight)
            .hoverHighlight(cornerRadius: 10)
    }
}

extension View {
    func keemacBoxedField(
        minHeight: CGFloat = KeeMacControlMetrics.fieldHeight,
        cornerRadius: CGFloat = KeeMacControlMetrics.cornerRadius
    ) -> some View {
        modifier(BoxedFieldModifier(minHeight: minHeight, cornerRadius: cornerRadius))
    }

    func keemacPrimaryActionButton(minWidth: CGFloat? = nil) -> some View {
        modifier(PrimaryActionButtonModifier(minWidth: minWidth))
    }

    func keemacSecondaryActionButton(minWidth: CGFloat? = nil) -> some View {
        modifier(SecondaryActionButtonModifier(minWidth: minWidth))
    }
}
