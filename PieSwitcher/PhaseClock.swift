import Foundation
import os

/// Wall-clock lap timer for the summon hot path: each `lap` records the time since
/// the previous one under a name, and `report` emits every phase plus the running
/// total as a single `.info` log line — persisted by the unified log, so a user-felt
/// stutter is attributable to a phase after the fact:
/// `log show --info --predicate 'subsystem == "com.mekedron.PieSwitcher"'`.
///
/// `@unchecked Sendable`: instances are only ever touched on the main thread, but
/// they cross into main-queue `DispatchQueue.async` / `CATransaction` completion
/// closures, which are not statically main-actor.
final class PhaseClock: @unchecked Sendable {
    private let start = CFAbsoluteTimeGetCurrent()
    private var last: CFAbsoluteTime
    private var laps: [(name: String, milliseconds: Double)] = []

    init() {
        last = start
    }

    func lap(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        laps.append((name, (now - last) * 1000))
        last = now
    }

    func report(to log: Logger, label: String) {
        let phases = laps
            .map { String(format: "%@=%.1fms", $0.name, $0.milliseconds) }
            .joined(separator: " ")
        let total = String(format: "%.1f", (last - start) * 1000)
        log.info("\(label, privacy: .public): \(phases, privacy: .public) total=\(total, privacy: .public)ms")
    }
}
