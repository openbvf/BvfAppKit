import SwiftUI

/// Tracks the currently-selected tab index, persisted to `UserDefaults`.
@Observable
@MainActor
public class TabSelection {
    /// Index of the selected tab. Persisted on change.
    public var selected: Int {
        didSet { UserDefaults.standard.set(selected, forKey: "selectedTab") }
    }
    /// Restore the previously-selected tab from `UserDefaults` (or 0 if none).
    public init() { self.selected = UserDefaults.standard.integer(forKey: "selectedTab") }
}
