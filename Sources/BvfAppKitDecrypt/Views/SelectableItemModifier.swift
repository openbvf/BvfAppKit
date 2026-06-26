import SwiftUI

/// Adds a tap-to-select gesture and selection overlay to any `View`.
public extension View {
    /// Wrap a row in a tap-to-select gesture and a selection overlay.
    func selectableItem(
        date: Date,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        self.modifier(SelectableItemModifier(date: date, isSelected: isSelected, onSelect: onSelect))
    }
}

private struct SelectableItemModifier: ViewModifier {
    let date: Date
    let isSelected: Bool
    let onSelect: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                onSelect()
            })
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            )
    }
}
