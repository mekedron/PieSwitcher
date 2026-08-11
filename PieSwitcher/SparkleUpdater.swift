import AppKit
import Sparkle

/// Wraps Sparkle's `SPUStandardUpdaterController` so the rest of the app talks to a small,
/// status-bar-friendly surface (Bringr-jz4). Bails out cleanly when no `SUFeedURL` is set in
/// Info.plist — the same path a debug build with no appcast wired up takes — so launching
/// without a feed URL configured does not crash or spam logs.
@MainActor
final class SparkleUpdater: NSObject {
    private(set) static var shared: SparkleUpdater?

    private var controller: SPUStandardUpdaterController?
    private var dockIcon: DockIconManager?
    /// Whether this updater currently holds one `windowOpened()` claim on the Dock
    /// icon. Sparkle's windows are not part of the SwiftUI scene that normally drives
    /// `DockIconManager`, so the updater claims when an update session is about to
    /// show UI and releases when that UI finishes; the flag keeps claim and release
    /// strictly paired however the session ends.
    private var holdsDockIconClaim = false

    func start(dockIcon: DockIconManager) {
        guard controller == nil else { return }
        self.dockIcon = dockIcon
        guard Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        SparkleUpdater.shared = self
    }

    /// Trigger a user-initiated update check. Sparkle's dialogs are ordinary windows,
    /// so like the app's own they must open in a `.regular`, activated app or they
    /// land behind the frontmost app's windows and the check looks like it did
    /// nothing. Claim the Dock icon (which flips the policy) before the check, and
    /// activate one runloop pass later — see `AppActivation` for why the deferral.
    func checkForUpdates() {
        guard let controller else { return }
        claimDockIcon()
        AppActivation.activate()
        controller.checkForUpdates(nil)
    }

    private func claimDockIcon() {
        guard !holdsDockIconClaim else { return }
        holdsDockIconClaim = true
        dockIcon?.windowOpened()
    }

    private func releaseDockIconClaim() {
        guard holdsDockIconClaim else { return }
        holdsDockIconClaim = false
        dockIcon?.windowClosed()
    }
}

extension SparkleUpdater: SPUStandardUserDriverDelegate {
    /// An update session (user-initiated or scheduled) is about to show its first
    /// window. Claiming here covers the scheduled path too, so a background-found
    /// update's alert also belongs to a visible, activatable app instead of a
    /// Dock-less accessory whose window can be refused the foreground.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            claimDockIcon()
        }
    }

    /// The session's UI is finishing (update dismissed, no-update alert closed, or
    /// install handed off) — release the claim so the Dock icon hides again unless a
    /// real window still holds it.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            releaseDockIconClaim()
        }
    }
}
