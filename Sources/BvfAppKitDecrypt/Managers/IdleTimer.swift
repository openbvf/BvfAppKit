import Foundation
import AppKit

/// Watches AppKit input events and fires `onIdleAction` when no activity is detected for the configured threshold.
@MainActor
public class IdleTimer {
    private var timer: Timer?
    private var eventMonitor: Any?
    private var lastActivityTime: Date = Date()
    private let threshold: @MainActor () -> TimeInterval

    /// Called on the main actor when the idle threshold elapses without input activity.
    public var onIdleAction: (() -> Void)?

    /// Create a timer with a closure that returns the idle threshold in seconds (re-evaluated each poll).
    public init(threshold: @escaping @MainActor () -> TimeInterval) {
        self.threshold = threshold
        setupEventMonitor()
    }

    /// Reset activity and start the polling timer.
    public func start() {
        lastActivityTime = Date()
        startPollingTimer()
    }

    /// Stop the polling timer. Event monitoring remains installed.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Treat as if the user just interacted (resets the idle clock).
    public func userDidInteract() {
        lastActivityTime = Date()
    }

    func timeSinceLastActivity() -> TimeInterval {
        return Date().timeIntervalSince(lastActivityTime)
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .scrollWheel,
            .keyDown,
            .leftMouseDragged,
            .rightMouseDragged
        ]) { [weak self] event in
            self?.lastActivityTime = Date()
            return event
        }
    }

    private func startPollingTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: BvfAppKitConfig.idleTimerPollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let elapsed = Date().timeIntervalSince(self.lastActivityTime)
                if elapsed >= self.threshold() {
                    self.onIdleAction?()
                }
            }
        }
    }
}
