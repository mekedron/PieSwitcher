import CoreGraphics
import Foundation

/// Keyboard-driven navigation over the navigator's live rings (Bringr-93j.71), split out so
/// `RadialNavigator.swift` stays within the file-length budget (mirroring
/// `RadialNavigator+Region.swift`).
///
/// Keyboard focus deliberately reuses the exact hover machinery — `updateHover` to move focus
/// *and* preview the target, `commit` to activate — so a focused window is isolated/previewed
/// identically to a hovered one (the spec's "focusing previews like hovering"), and there is no
/// second reveal/restore path to keep in sync. Mouse hover and keyboard focus therefore share
/// one highlighted region: whichever moved it last owns it, and the controller only tints the
/// result so keyboard focus reads distinctly. `expandedAppIndex`, `rings`, and `hasWindowSubWheel`
/// are all readable here, so these methods stay pure decisions over the live tree.
extension RadialNavigator {
    /// Move keyboard focus one step in `arrow`'s direction, previewing the new target. Left/
    /// Right move within the current ring (wrapping around the wheel); Down drills from an app
    /// into its windows; Up steps a window back to its parent app. The first arrow press while
    /// nothing is focused lands on the top app (12 o'clock).
    func keyboardMove(_ arrow: KeyboardArrow) -> KeyboardNavOutcome {
        guard let appsRing = rings.first, !appsRing.nodes.isEmpty else { return .ignored }
        let appCount = appsRing.nodes.count

        switch hovered {
        case .none:
            updateHover(.slice(level: 0, index: 0))
            return .handled
        case .slice(level: 0, let index):
            switch arrow {
            case .left:
                updateHover(.slice(level: 0, index: KeyboardNavMath.wrap(index - 1, count: appCount)))
            case .right:
                updateHover(.slice(level: 0, index: KeyboardNavMath.wrap(index + 1, count: appCount)))
            case .down where hasWindowSubWheel:
                updateHover(.slice(level: 1, index: 0))
            case .down, .up:
                break // Up at the top level, or Down into a window-less app, is a no-op.
            }
            return .handled
        case .slice(level: 1, let index):
            keyboardMoveOnWindows(arrow, index: index)
            return .handled
        case .slice:
            return .ignored
        }
    }

    private func keyboardMoveOnWindows(_ arrow: KeyboardArrow, index: Int) {
        guard rings.count > 1 else { return }
        let windowCount = rings[1].nodes.count
        switch arrow {
        case .left where windowCount > 0:
            updateHover(.slice(level: 1, index: KeyboardNavMath.wrap(index - 1, count: windowCount)))
        case .right where windowCount > 0:
            updateHover(.slice(level: 1, index: KeyboardNavMath.wrap(index + 1, count: windowCount)))
        case .up:
            updateHover(.slice(level: 0, index: expandedAppIndex ?? 0))
        case .left, .right, .down:
            break // Down has no deeper level in v1; left/right no-op on an empty ring.
        }
    }

    /// React to a pressed app/window number. The active context follows the focused level: at
    /// the apps level (or with nothing focused yet) the digit picks an app; once focus is on a
    /// window it picks a window — app numbers stay disabled until Escape steps back up
    /// (Bringr-93j.71). `requireConfirmation` turns an otherwise instant activation into a focus.
    func keyboardNumber(_ digit: Int, requireConfirmation: Bool) -> KeyboardNavOutcome {
        guard let index = KeyboardNavMath.index(forDigit: digit), !rings.isEmpty else { return .ignored }
        if case .slice(level: 1, _) = hovered {
            return keyboardWindowNumber(at: index, requireConfirmation: requireConfirmation)
        }
        return keyboardAppNumber(at: index, requireConfirmation: requireConfirmation)
    }

    private func keyboardAppNumber(at index: Int, requireConfirmation: Bool) -> KeyboardNavOutcome {
        guard let appsRing = rings.first, index >= 0, index < appsRing.nodes.count else { return .handled }
        // Focus + preview the app: this expands it and resolves its live windows sub-wheel,
        // which is what tells us how many windows it has.
        updateHover(.slice(level: 0, index: index))
        let windowCount = hasWindowSubWheel ? rings[1].nodes.count : 0

        if windowCount == 0 {
            // No window to drill into: behave as if the app slice itself was chosen.
            if requireConfirmation { return .handled }
            guard let result = commit(.slice(level: 0, index: index)) else { return .handled }
            return .committed(result)
        }
        if windowCount == 1, !requireConfirmation {
            // Exactly one window: open it straight away.
            guard let result = commit(.slice(level: 1, index: 0)) else { return .handled }
            return .committed(result)
        }
        // Several windows (or a single one awaiting confirmation): drop into the windows and
        // preview the first, so the next number addresses windows.
        updateHover(.slice(level: 1, index: 0))
        return .handled
    }

    private func keyboardWindowNumber(at index: Int, requireConfirmation: Bool) -> KeyboardNavOutcome {
        guard rings.count > 1, index >= 0, index < rings[1].nodes.count else { return .handled }
        if requireConfirmation {
            updateHover(.slice(level: 1, index: index)) // focus + preview; Return commits.
            return .handled
        }
        guard let result = commit(.slice(level: 1, index: index)) else { return .handled }
        return .committed(result)
    }

    /// Activate whatever is focused (Return). A dead-zone / nothing-focused Return is consumed as
    /// a no-op rather than leaking to the app underneath.
    func keyboardConfirm() -> KeyboardNavOutcome {
        guard let result = commit(hovered) else { return .handled }
        return .committed(result)
    }

    /// Escape: from a focused window, step back up to its parent app — restoring that window's
    /// preview and keeping the menu open; from the apps level, ask the controller to close.
    func keyboardEscape() -> KeyboardNavOutcome {
        if case .slice(level: 1, _) = hovered {
            updateHover(.slice(level: 0, index: expandedAppIndex ?? 0))
            return .handled
        }
        return .close
    }
}
