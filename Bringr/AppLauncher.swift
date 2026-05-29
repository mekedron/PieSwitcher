import AppKit
import CoreServices
import Foundation

/// Starting an app by bundle identifier, behind a seam so `RadialNavigator`'s commit
/// path can be unit-tested without launching real apps — a fake records the request
/// instead. Mirrors `WindowControlling`'s injectable design (Bringr-93j.39).
@MainActor
protocol AppLaunching {
    /// Start (or, if already running, bring up) the app with `bundleIdentifier` and make
    /// it frontmost. A no-op when the bundle id doesn't resolve to an installed app.
    func launch(bundleIdentifier: String)
}

/// Live `AppLaunching` over `NSWorkspace`. A not-running app is launched by resolving its
/// bundle id to the on-disk URL — reusing the curated-list resolver so the lookup matches how
/// the wheel rendered the slice — and opening it, which brings it forward and opens its first
/// window. A *running* app (which may be windowless, e.g. Calendar closed to the menu bar) is
/// reopened with the Dock's reopen Apple event instead: `openApplication` would only
/// re-activate it, leaving the user staring at a windowless app, so it never made a new window
/// (Bringr-93j.61).
@MainActor
final class LiveAppLauncher: AppLaunching {
    func launch(bundleIdentifier: String) {
        // Already running: reopen it like a Dock click so a windowless app opens a fresh
        // window. Activate too, so it reliably comes forward even if the reopen is a no-op
        // (e.g. an app that ignores the event). (Bringr-93j.61)
        if let running = CuratedApp.runningApplication(forBundleIdentifier: bundleIdentifier) {
            AppReopen.send(toPID: running.processIdentifier)
            running.activate(options: [])
            return
        }
        // Not running: launch it (it opens its own window) and bring it to the front.
        guard let url = CuratedApp.bundleURL(forBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

/// Posts the standard "reopen" Apple event — the one the Dock sends when you click a running
/// app's icon — to the app with `pid` (Bringr-93j.61). The target's
/// `applicationShouldHandleReopen(_:hasVisibleWindows:)` then decides: a windowless app opens a
/// fresh window, a windowed one just comes forward. `NSWorkspace.openApplication` and
/// `NSRunningApplication.activate` only raise a running app; neither reopens a window.
///
/// `reopen` ('rapp') is part of the standard launch suite, not the scripting suite, so it does
/// not trip the Automation (TCC) consent prompt that custom Apple events do — the same reason
/// the Dock can post it freely. Best-effort: a send failure is swallowed, and callers activate
/// the app anyway so it at least comes forward.
@MainActor
enum AppReopen {
    static func send(toPID pid: pid_t) {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // `.noReply` returns immediately (the event is still delivered), so the timeout is
        // unused and Bringr never blocks waiting on the other app.
        _ = try? event.sendEvent(options: .noReply, timeout: 30)
    }
}
