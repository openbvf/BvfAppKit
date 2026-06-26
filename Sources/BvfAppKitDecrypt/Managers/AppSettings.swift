import Foundation

/// User-facing security posture. Maps to the inactivity timeout and resign-clearing behavior.
public enum SecurityLevel: String, CaseIterable {
    /// 10-minute timeout. Most permissive.
    case lazy
    /// 5-minute timeout. The default.
    case normal
    /// 1-minute timeout. Also clears on app resignation.
    case paranoid
}

extension SecurityLevel {
    var timeoutInterval: TimeInterval {
        switch self {
        case .lazy: return 600
        case .normal: return 300
        case .paranoid: return 60
        }
    }
}

/// Persistent app-level settings (security level, advanced-UI toggle, onboarding state). Backed by `UserDefaults.standard`.
@MainActor
@Observable public class AppSettings {
    private static let securityLevelKey = "securityLevel"
    private static let hasSkippedOnboardingKey = "hasSkippedOnboarding"
    private static let showAdvancedSettingsKey = "showAdvancedSettings"

    /// Selected security level. Persisted on change.
    public var securityLevel: SecurityLevel {
        didSet {
            UserDefaults.standard.set(securityLevel.rawValue, forKey: Self.securityLevelKey)
        }
    }

    /// True once the user has dismissed onboarding. Persisted on change.
    public var hasSkippedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSkippedOnboarding, forKey: Self.hasSkippedOnboardingKey) }
    }

    /// True when the user has revealed advanced settings. Persisted on change.
    public var showAdvancedSettings: Bool {
        didSet { UserDefaults.standard.set(showAdvancedSettings, forKey: Self.showAdvancedSettingsKey) }
    }

    /// Idle timeout in seconds, derived from `securityLevel`.
    public var idleTimeoutInterval: TimeInterval {
        securityLevel.timeoutInterval
    }

    /// Whether the session should be cleared when the app resigns active.
    public var clearsOnAppResign: Bool {
        securityLevel == .paranoid
    }

    /// Restore settings from `UserDefaults.standard`, defaulting to `.normal` security if unset.
    public init() {
        if let storedLevel = UserDefaults.standard.string(forKey: Self.securityLevelKey),
           let level = SecurityLevel(rawValue: storedLevel) {
            securityLevel = level
        } else {
            securityLevel = .normal
        }

        hasSkippedOnboarding = UserDefaults.standard.bool(forKey: Self.hasSkippedOnboardingKey)
        showAdvancedSettings = UserDefaults.standard.bool(forKey: Self.showAdvancedSettingsKey)
    }

    /// Restore all settings to their defaults.
    public func reset() {
        securityLevel = .normal
        hasSkippedOnboarding = false
        showAdvancedSettings = false
    }
}
