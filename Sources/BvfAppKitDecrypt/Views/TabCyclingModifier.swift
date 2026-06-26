import SwiftUI

/// Adds tab-cycling keyboard shortcuts to any `View`.
public extension View {
    /// Wires Cmd-Shift-] (next) and Cmd-Shift-[ (previous) to cycle tabs,
    /// wrapping at the ends. `count` is the number of currently visible tabs.
    func tabCyclingShortcuts(selection: Binding<Int>, count: Int) -> some View {
        background {
            Button("") {
                guard count > 0 else { return }
                selection.wrappedValue = (selection.wrappedValue + 1) % count
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(count < 2)
            .hidden()
            Button("") {
                guard count > 0 else { return }
                selection.wrappedValue = (selection.wrappedValue - 1 + count) % count
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(count < 2)
            .hidden()
        }
    }
}
