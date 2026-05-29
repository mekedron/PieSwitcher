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
    private let log = Logger(subsystem: "com.mekedron.Bringr", category: "WindowControl")

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

    func frame(of window: WindowID) -> CGRect? {
        guard let element = elementCache[window],
              let position = axPoint(element, kAXPositionAttribute),
              let size = axSize(element, kAXSizeAttribute) else { return nil }
        // AX reports a top-left origin (y-down) relative to the primary screen's top.
        // Flip into AppKit-global coordinates (bottom-left origin, y-up) for the dim
        // overlay; the primary screen (index 0) defines that shared origin.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: position.x,
            y: primaryHeight - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    func position(of window: WindowID) -> CGPoint? {
        guard let element = elementCache[window] else { return nil }
        // Native AX top-left coords (y-down), not flipped to AppKit — capture and the
        // off-screen park are symmetric in this space, so no flip is needed.
        return axPoint(element, kAXPositionAttribute)
    }

    func setPosition(_ window: WindowID, _ point: CGPoint) {
        guard let element = cachedElement(for: window, operation: "set position") else { return }
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else {
            log.error("AX could not create position value for window \(window.token)")
            return
        }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        logAXFailure(result, operation: "set position", window: window)
    }

    func size(of window: WindowID) -> CGSize? {
        guard let element = elementCache[window] else { return nil }
        // Width/height are space-agnostic, so no flip is needed (unlike `frame(of:)`).
        return axSize(element, kAXSizeAttribute)
    }

    func setSize(_ window: WindowID, _ size: CGSize) {
        guard let element = cachedElement(for: window, operation: "set size") else { return }
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            log.error("AX could not create size value for window \(window.token)")
            return
        }
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        logAXFailure(result, operation: "set size", window: window)
    }

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let ref = value, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue) // swiftlint:disable:this force_cast
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
