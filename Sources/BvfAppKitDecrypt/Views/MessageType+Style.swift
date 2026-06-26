import SwiftUI

extension MessageType {
    /// Foreground color associated with this message severity.
    public var color: Color {
        switch self {
        case .error: return .red
        case .success: return .green
        case .info: return .primary
        }
    }

    /// SF Symbol name associated with this message severity.
    public var iconName: String {
        switch self {
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}
