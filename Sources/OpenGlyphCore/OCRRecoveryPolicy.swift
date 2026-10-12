import Foundation

/// Process-local recovery state. No images, text, or persistent preferences are stored.
final class OCRRecoveryPolicy: @unchecked Sendable {
    struct Configuration: Hashable {
        let language: String?
        let revision: Int
        let preferredLanguages: [String]
        let localeIdentifier: String

        init(language: String?, revision: Int, preferredLanguages: [String] = Locale.preferredLanguages,
             localeIdentifier: String = Locale.current.identifier) {
            let explicit = language.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
            self.language = explicit
            self.revision = revision
            self.preferredLanguages = explicit == nil ? preferredLanguages : []
            self.localeIdentifier = explicit == nil ? localeIdentifier : ""
        }
    }

    private struct Entry {
        var consecutiveFailures: Int
        var lastFailure: TimeInterval
        var cooldownUntil: TimeInterval?
        var access: UInt64
    }

    private static let origin = ContinuousClock.now
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private let cooldown: TimeInterval
    private let failureWindow: TimeInterval
    private let capacity: Int
    private var entries: [Configuration: Entry] = [:]
    private var access: UInt64 = 0

    init(cooldown: TimeInterval = 60, failureWindow: TimeInterval = 120, capacity: Int = 32,
         clock: @escaping () -> TimeInterval = {
             let value = origin.duration(to: ContinuousClock.now).components
             return Double(value.seconds) + Double(value.attoseconds) / 1_000_000_000_000_000_000
         }) {
        precondition(cooldown.isFinite && cooldown > 0 && failureWindow.isFinite && failureWindow > 0 && capacity > 0)
        self.cooldown = cooldown
        self.failureWindow = failureWindow
        self.capacity = capacity
        self.clock = clock
    }

    func shouldUseFast(for configuration: Configuration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[configuration] else { return false }
        access &+= 1
        entry.access = access
        entries[configuration] = entry
        return entry.cooldownUntil.map { clock() < $0 } ?? false
    }

    /// Called only after all available accurate engines fail with a known
    /// compute error and Fast actually recognizes nonempty text.
    func recordRecoveredComputeFailure(for configuration: Configuration) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        var entry = entries[configuration] ?? Entry(consecutiveFailures: 0, lastFailure: now,
                                                    cooldownUntil: nil, access: 0)
        // Two isolated failures minutes apart should not activate a cooldown.
        // Once cooling down, each expired interval gets a fresh accurate probe.
        if now - entry.lastFailure > failureWindow {
            entry.consecutiveFailures = 0
            entry.cooldownUntil = nil
        }
        entry.consecutiveFailures = min(2, entry.consecutiveFailures + 1)
        entry.lastFailure = now
        if entry.consecutiveFailures == 2 { entry.cooldownUntil = now + cooldown }
        access &+= 1
        entry.access = access
        if entries[configuration] == nil && entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[configuration] = entry
    }

    /// Accurate success, unrelated errors, cancellation, and unsuccessful Fast
    /// recovery break the failure streak rather than disabling Accurate.
    func reset(for configuration: Configuration) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: configuration)
    }

    var configurationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
