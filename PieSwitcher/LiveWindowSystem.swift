import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Accessibility SPI that returns the `CGWindowID` (i.e. `kCGWindowNumber`) backing
/// an `AXUIElement` window. It is the only reliable way to map an AX window element
/// to the stable window number the enumeration service (US-003) keys on.
@_silgen_name("_AXUIElementGetWindow")
private func axUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Live `WindowControlling` backed by `NSRunningApplication` (app visibility and
/// activation) and the Accessibility API (per-window state and control).
///
/// Hiding a single window uses AX minimize, the only reversible per-window hide
/// the API offers; `restore()` un-minimizes it. AX element references are cached
/// by `WindowID` as windows are enumerated.
@MainActor
final class LiveWindowSystem: WindowControlling {
    private var elementCache: [WindowID: AXUIElement] = [:]
    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private let log = Logger(subsystem: "com.mekedron.PieSwitcher", category: "WindowControl")

    func runningApps() -> [AppID] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
            .map { AppID(pid: $0.processIdentifier) }
    }

    func windows(of app: AppID) -> [WindowID] {
        let appElement = AXUIElementCreateApplication(app.pid)
        guard let axWindows = copyWindows(appElement) else { return [] }

        var ids: [WindowID] = []
        for (index, axWindow) in axWindows.enumerated() {
            let id = WindowID(app: app, token: windowNumber(of: axWindow) ?? index)
            elementCache[id] = axWindow
            ids.append(id)
        }
        return ids
    }

    /// Real window titles for `app` from AX, keyed by `kCGWindowNumber` (Bringr-93j.110).
    /// CG's `kCGWindowName` requires Screen Recording — a v1 non-goal — so AX's
    /// `kAXTitleAttribute` is the only way to learn the window title (document name,
    /// browser tab, email subject) the user expects to see in the sub-wheel. Skips
    /// windows AX can't tag with a CG number (rare) and those without a title attribute
    /// (the empty/missing-title case the enumerator falls back from); the result is
    /// empty when AX can't enumerate the app (denied, terminating, etc.). Sibling of
    /// `windows(of:)`, sharing the same AX traversal — separate so a caller that only
    /// needs titles can ask for them without populating `elementCache`.
    func windowTitles(of app: AppID) -> [Int: String] {
        let appElement = AXUIElementCreateApplication(app.pid)
        guard let axWindows = copyWindows(appElement) else { return [:] }

        var titles: [Int: String] = [:]
        for axWindow in axWindows {
            guard let number = windowNumber(of: axWindow),
                  let title = stringAttribute(axWindow, kAXTitleAttribute) else { continue }
            titles[number] = title
        }
        return titles
    }

    func frontmostApp() -> AppID? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != selfPID else { return nil }
        return AppID(pid: app.processIdentifier)
    }

    func isHidden(_ app: AppID) -> Bool {
        runningApplication(app)?.isHidden ?? false
    }

    func setHidden(_ app: AppID, _ hidden: Bool) {
        guard let running = runningApplication(app) else { return }
        if hidden {
            running.hide()
        } else {
            running.unhide()
        }
    }

    func activate(_ app: AppID) {
        let appElement = AXUIElementCreateApplication(app.pid)
        setBool(appElement, kAXFrontmostAttribute, true, app: app)
        guard let running = runningApplication(app) else {
            log.error("NSRunningApplication lookup failed for pid \(app.pid)")
            return
        }
        if running.activate(options: []) != true {
            log.error("NSRunningApplication.activate failed for pid \(app.pid)")
        }
        setBool(appElement, kAXFrontmostAttribute, true, app: app)
    }

    func reopen(_ app: AppID) {
        // Post the Dock's reopen event so a windowless app opens a new window, then activate
        // so it comes forward whether or not it made one (Bringr-93j.61).
        AppReopen.send(toPID: app.pid)
        activate(app)
    }

    func isMinimized(_ window: WindowID) -> Bool {
        guard let element = elementCache[window] else { return false }
        return boolAttribute(element, kAXMinimizedAttribute)
    }

    func setMinimized(_ window: WindowID, _ minimized: Bool) {
        guard let element = cachedElement(for: window, operation: "set minimized") else { return }
        setBool(element, kAXMinimizedAttribute, minimized, window: window)
    }

    func raise(_ window: WindowID) {
        guard let element = cachedElement(for: window, operation: "raise") else { return }
        let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        logAXFailure(result, operation: "raise", window: window)
    }

    func focusWindow(_ window: WindowID) {
        guard let element = cachedElement(for: window, operation: "focus") else { return }
        let appElement = AXUIElementCreateApplication(window.app.pid)
        setElement(appElement, kAXMainWindowAttribute, element, window: window)
        setElement(appElement, kAXFocusedWindowAttribute, element, window: window)
        setBool(element, kAXMainAttribute, true, window: window)
        setBool(element, kAXFocusedAttribute, true, window: window)
    }

    func raiseAcrossSpaces(_ window: WindowID) {
        // No AX element exists for an other-Space window (kAXWindowsAttribute omits them), so
        // defer to the window-server front-process recipe, which raises by CG number and
        // switches Spaces (Bringr-93j.54).
        CrossSpaceFocus.raise(windowNumber: window.token, pid: window.app.pid)
    }

    private func runningApplication(_ app: AppID) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: app.pid)
    }

    private func windowNumber(of element: AXUIElement) -> Int? {
        var windowID: CGWindowID = 0
        let result = axUIElementGetWindow(element, &windowID)
        return result == .success ? Int(windowID) : nil
    }

    private func copyWindows(_ appElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        )
        guard result == .success else {
            logAXFailure(result, operation: "copy windows")
            return nil
        }
        return value as? [AXUIElement]
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    /// Generic AX string-attribute read. Returns `nil` for the absent/wrong-type cases —
    /// the title attribute is missing on background windows, panels, and other surfaces
    /// AX still lists, so a missing read is normal, not an error.
    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func cachedElement(for window: WindowID, operation: String) -> AXUIElement? {
        guard let element = elementCache[window] else {
            log.error("AX missing element \(operation) pid \(window.app.pid) window \(window.token)")
            return nil
        }
        return element
    }

    @discardableResult
    private func setBool(
        _ element: AXUIElement,
        _ attribute: String,
        _ value: Bool,
        app: AppID? = nil,
        window: WindowID? = nil
    ) -> Bool {
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, cfValue)
        logAXFailure(result, operation: "set \(attribute)", app: app, window: window)
        return result == .success
    }

    @discardableResult
    private func setElement(
        _ element: AXUIElement,
        _ attribute: String,
        _ value: AXUIElement,
        window: WindowID
    ) -> Bool {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        logAXFailure(result, operation: "set \(attribute)", window: window)
        return result == .success
    }

    private func logAXFailure(
        _ result: AXError,
        operation: String,
        app: AppID? = nil,
        window: WindowID? = nil
    ) {
        guard result != .success else { return }
        let error = String(describing: result)
        if let window {
            log.error("AX \(operation) failed pid \(window.app.pid) window \(window.token): \(error)")
        } else if let app {
            log.error("AX \(operation) failed pid \(app.pid): \(error)")
        } else {
            log.error("AX \(operation) failed: \(error)")
        }
    }
}
