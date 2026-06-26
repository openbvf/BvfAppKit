import SwiftUI

/// Status icon showing a green lock when ready or an orange warning when not.
public struct ReadyIndicatorView: View {
    /// Whether the indicator shows the ready state.
    public let isReady: Bool

    /// Create an indicator in the given ready state.
    public init(isReady: Bool) {
        self.isReady = isReady
    }

    /// SwiftUI body.
    public var body: some View {
        if isReady {
            Image(systemName: "lock.shield.fill")
                .font(.title)
                .foregroundColor(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundColor(.orange)
        }
    }
}
