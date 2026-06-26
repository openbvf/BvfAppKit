import Foundation

/// A single file-level failure paired with its error description, used in batched error reporting.
public struct FileFailure: Sendable {
    /// File that failed.
    public let url: URL
    /// Human-readable failure reason.
    public let errorDescription: String
}

/// Severity classification for a `ResponseMessage`.
public enum MessageType: Sendable, Hashable {
    case error
    case success
    case info

    /// Capitalized human-readable name for the severity.
    public var displayName: String {
        switch self {
        case .error: return "Error"
        case .success: return "Success"
        case .info: return "Information"
        }
    }
}

/// A short status line plus optional detail body and severity, used as the standard UI message envelope across BVF apps.
public struct ResponseMessage: Equatable, Sendable {
    /// Short, single-line summary suitable for inline UI.
    public let text: String
    /// Severity classification.
    public let type: MessageType
    /// Optional longer detail body shown in a disclosure or detail sheet.
    public let detail: String?

    /// Create a message with the given text, type, and optional detail.
    public init(_ text: String, type: MessageType = .info, detail: String? = nil) {
        self.text = text
        self.type = type
        self.detail = detail
    }

    /// Build a multi-line error-detail string from a header and a list of per-file failures, truncating at `BvfAppKitConfig.maxErrorEntries`.
    public static func buildErrorDetails(
        header: String,
        failures: [FileFailure]
    ) -> String {
        var message = header
        let displayCount = min(failures.count, BvfAppKitConfig.maxErrorEntries)

        for failure in failures.prefix(displayCount) {
            message += "\n\(failure.url.path): \(failure.errorDescription)"
        }

        let remainingCount = failures.count - displayCount
        if remainingCount > 0 {
            message += "\n... and \(remainingCount) more"
        }

        return message
    }

    /// Build a multi-line import-report detail string grouped into Failed / Skipped / Imported sections.
    public static func buildImportReportDetails(
        imported: [URL],
        skipped: [URL],
        failed: [FileFailure]
    ) -> String {
        var message = "\(failed.count) failed, \(skipped.count) skipped, \(imported.count) imported"

        if !failed.isEmpty {
            message += "\n\n--- Failed ---"
            for failure in failed {
                message += "\n\(failure.url.path): \(failure.errorDescription)"
            }
        }

        if !skipped.isEmpty {
            message += "\n\n--- Skipped ---"
            for url in skipped {
                message += "\n\(url.path)"
            }
        }

        if !imported.isEmpty {
            message += "\n\n--- Imported ---"
            for url in imported {
                message += "\n\(url.path)"
            }
        }

        return message
    }
}
