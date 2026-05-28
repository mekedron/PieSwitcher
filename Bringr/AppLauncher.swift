import AppKit
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

/// Live `AppLaunching` over `NSWorkspace`. Resolves the bundle id to its on-disk URL —
/// reusing the curated-list resolver so the lookup matches how the wheel rendered the
/// slice — then opens it, activating it so the launched app comes to the front. Works
/// uniformly for a not-running app (launches it) and a running-but-windowless one
/// (activates / reopens it), which is exactly the "start when chosen" contract.
@MainActor
final class LiveAppLauncher: AppLaunching {
    func launch(bundleIdentifier: String) {
        guard let url = CuratedApp.bundleURL(forBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
