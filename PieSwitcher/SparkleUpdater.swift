import AppKit
import Sparkle

/// Wraps Sparkle's `SPUStandardUpdaterController` so the rest of the app talks to a small,
/// status-bar-friendly surface (Bringr-jz4). Bails out cleanly when no `SUFeedURL` is set in
/// Info.plist — the same path a debug build with no appcast wired up takes — so launching
/// without a feed URL configured does not crash or spam logs.
@MainActor
final class SparkleUpdater {
    private(set) static var shared: SparkleUpdater?

    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        guard Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        SparkleUpdater.shared = self
    }

    /// Trigger a user-initiated update check. Activates the app first so Sparkle's update
    /// dialog comes to the front of a status-bar-only app that otherwise has no key window.
    func checkForUpdates() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}
