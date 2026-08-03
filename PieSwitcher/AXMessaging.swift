import ApplicationServices
import Foundation
import os

/// Process-wide policy for talking to other apps over the Accessibility API.
///
/// Every AX read and write is a synchronous IPC round-trip that the *target* app
/// answers on its own main thread: an app that is compiling, in GC, or beach-balling
/// answers when it gets around to it, and the caller sits blocked until then. Two
/// things make that unusually expensive here:
///
/// - PieSwitcher's activation tap is an active `.cgSessionEventTap` whose callback runs
///   on the main run loop, so a blocked main thread holds up *system-wide* mouse input,
///   not just the wheel;
/// - the wheel issues AX calls while the user is mid-gesture (hover reveal, sub-wheel
///   titles), where a stall reads as the pointer sticking.
///
/// So: a bounded messaging timeout caps the worst case, and every probe that only feeds
/// display state runs on `probeQueue`, off the main thread.
@MainActor
enum AXMessaging {
    /// Ceiling on any AX message this process sends. Healthy apps answer in single-digit
    /// milliseconds; this is the cap for the ones that don't, chosen so a wedged app costs
    /// a perceptible beat rather than a freeze. Reads that hit it fail with
    /// `kAXErrorCannotComplete` and the caller falls back to its cached/derived value.
    static let timeout: Float = 0.25

    /// Serial queue for AX probes whose results only feed display state (window lists,
    /// minimized flags, titles). Serial, and a `DispatchQueue` rather than a `Task`, so a
    /// wedged target app blocks one dedicated thread instead of occupying threads in
    /// Swift's cooperative pool, which the icon loads and the rest of the app share.
    nonisolated static let probeQueue = DispatchQueue(
        label: "com.mekedron.PieSwitcher.ax-probe", qos: .utility
    )

    /// Apply `timeout` to every AX message this process sends. Called once at launch:
    /// passing the system-wide element sets the process-global default, which every
    /// element inherits, including ones created before this call.
    static func installProcessTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }
}

/// Names the main-thread work in flight, so a stall is attributable to a step rather than
/// guessed at: overruns are logged as they finish, and `HangWatchdog` reads `breadcrumb`
/// to say what a *still-blocked* main thread is inside of.
///
/// `log show --info --predicate 'subsystem == "com.mekedron.PieSwitcher"'`
///
/// Only overruns are logged, so the instrumentation is quiet in ordinary use; the two clock
/// reads and the breadcrumb push cost nanoseconds next to any step worth naming.
enum SlowStep {
    private static let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "summon-perf")

    /// Steps at or under this fit inside a display frame and are never reported.
    static let threshold: TimeInterval = 0.005

    /// The nested steps currently running on the main thread, outermost first. Guarded
    /// because the watchdog thread reads it; the main thread only ever holds the lock for
    /// an append or a removal, so a reader is never left waiting on blocked work.
    private static let breadcrumbLock = NSLock()
    nonisolated(unsafe) private static var activeSteps: [String] = []

    /// The main thread's current step path, e.g. `hover slice(0, 3) › AX raise pid 704`, or
    /// `nothing named` when the block is somewhere no step covers — itself a useful answer.
    static var breadcrumb: String {
        breadcrumbLock.lock()
        let steps = activeSteps
        breadcrumbLock.unlock()
        return steps.isEmpty ? "nothing named" : steps.joined(separator: " › ")
    }

    /// Run `body`, logging its duration when it overruns `threshold` and publishing its name
    /// as a breadcrumb while it runs. `name` is an autoclosure, so building the label costs
    /// nothing when the step is not on the main thread — the only place breadcrumbs mean
    /// anything, since that is the thread the watchdog and the event tap share.
    @discardableResult
    static func measure<T>(_ name: @autoclosure () -> String, _ body: () -> T) -> T {
        guard Thread.isMainThread else { return body() }
        let label = name()
        push(label)
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        pop()
        guard elapsed > threshold else { return result }
        let milliseconds = String(format: "%.1f", elapsed * 1000)
        log.info("slow step: \(label, privacy: .public) took \(milliseconds, privacy: .public)ms")
        return result
    }

    private static func push(_ label: String) {
        breadcrumbLock.lock()
        activeSteps.append(label)
        breadcrumbLock.unlock()
    }

    private static func pop() {
        breadcrumbLock.lock()
        if !activeSteps.isEmpty { activeSteps.removeLast() }
        breadcrumbLock.unlock()
    }
}
