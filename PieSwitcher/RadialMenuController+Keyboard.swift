import AppKit

/// Keyboard-navigation entry point for the controller (Bringr-93j.71), split out so
/// `RadialMenuController.swift` stays within the file-length budget (mirroring
/// `RadialMenuController+Cursor.swift`). The live `KeyboardNavMonitor` calls in here for each
/// key while the menu is open; the controller routes the key to the navigator's keyboard
/// decision logic and performs the resulting side effect, reusing the same commit/cancel paths
/// the mouse uses.
extension RadialMenuController {
    /// Whether keyboard navigation should handle keys right now: the wheel is on screen and either
    /// the main keyboard-nav feature or the close-on-unused-key policy is on (Bringr-93j.95). The
    /// monitor consults this before consuming any key, so when both are off keys pass straight
    /// through. With only close-on-unused on, the monitor still has to fire so it can close the
    /// wheel on every key (all of which are "unused" once the nav feature is off).
    var acceptsKeyboardNav: Bool {
        isVisible && (keyboardConfig.isEnabled || keyboardConfig.closesOnUnsupportedKey)
    }

    /// Handle one navigation key. Returns `true` when the key was consumed (so the monitor stops
    /// it reaching the app underneath), `false` to let it pass through — including keys for a
    /// sub-mode the user disabled.
    @discardableResult
    func handleKeyboardNavKey(_ key: KeyboardNavKey) -> Bool {
        guard acceptsKeyboardNav, let outcome = keyboardOutcome(for: key) else { return false }
        switch outcome {
        case .ignored:
            return false
        case .handled:
            highlightSource = .keyboard
            syncFromNavigator()
            return true
        case .committed:
            // The navigator already raised/focused the target and restored the rest, like the
            // mouse commit path; just mark the machine closed and take the overlay down.
            machine.markClosed()
            hideOverlay()
            return true
        case .close:
            escapePressed() // top-level Escape cancels and restores, in either mode (US-015).
            return true
        }
    }

    /// Map a key to the navigator's decision, gating each key on the sub-mode that owns it:
    /// Escape needs the main switch on (it cancels/steps back via the navigator); arrows need
    /// arrow mode; digits need number mode; Return/Space work whenever either nav mode is on
    /// (commits arrow focus or confirms number focus). A key whose category is off is treated as
    /// unsupported (Bringr-93j.95), so the close-on-unused policy fires on it just like on a key
    /// the wheel never used. `nil` means "not for keyboard nav" — pass it through.
    private func keyboardOutcome(for key: KeyboardNavKey) -> KeyboardNavOutcome? {
        switch key {
        case .escape:
            guard keyboardConfig.isEnabled else { return unsupportedOutcome() }
            return navigator.keyboardEscape()
        case .arrow(let arrow):
            guard keyboardConfig.arrowsEnabled else { return unsupportedOutcome() }
            return navigator.keyboardMove(arrow)
        case .digit(let digit):
            guard keyboardConfig.numbersEnabled else { return unsupportedOutcome() }
            return navigator.keyboardNumber(
                digit, requireConfirmation: keyboardConfig.requiresConfirmation,
                autoCommitsApp: keyboardConfig.commitsAppWithoutWindowChoice
            )
        case .confirm:
            guard keyboardConfig.arrowsEnabled || keyboardConfig.numbersEnabled else {
                return unsupportedOutcome()
            }
            return navigator.keyboardConfirm()
        case .unsupported:
            return unsupportedOutcome()
        }
    }

    /// The outcome for a key with no function in the wheel: close on press when the policy is on
    /// (a full cancel/restore via `escapePressed`), otherwise pass it through (Bringr-93j.73/.95).
    private func unsupportedOutcome() -> KeyboardNavOutcome? {
        keyboardConfig.closesOnUnsupportedKey ? .close : nil
    }

    /// Commit the app a numeric jump landed on but never picked a window in, when "don't require a
    /// window choice" is on (Bringr-93j.73): in hold-to-select, releasing the trigger over that
    /// auto-previewed multi-window app activates the app (and its active window) instead of
    /// cancelling on the dead-zone cursor. Returns whether it committed, so the normal release
    /// handling runs only when it didn't.
    func commitPendingAppOnRelease() -> Bool {
        guard machine.mode == .holdToSelect, let appIndex = navigator.pendingAppCommit,
              navigator.commit(.slice(level: 0, index: appIndex)) != nil else { return false }
        machine.markClosed()
        hideOverlay()
        return true
    }
}
