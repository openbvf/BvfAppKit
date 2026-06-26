import SwiftUI

/// Shared root view wrapper that applies a red "DEBUG" toolbar marker in debug builds and a plain title elsewhere.
public struct AppRootView<Content: View>: View {
    private let content: Content

    /// Create a root wrapper around the given content.
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// SwiftUI body.
    public var body: some View {
        #if DEBUG
        content
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Text("DEBUG")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
        #else
        content
            .navigationTitle("")
        #endif
    }
}
