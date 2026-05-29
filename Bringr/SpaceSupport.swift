import ApplicationServices
import CoreGraphics
import Foundation
import os

// MARK: - Private CoreGraphics / SkyLight symbols

/// A SkyLight/CoreGraphics window-server connection handle.
private typealias CGSConnectionID = UInt32

/// The current process's window-server connection — the handle every CGS query takes.
@_silgen_name("CGSMainConnectionID")
private func cgsMainConnectionID() -> CGSConnectionID

/// The managed Spaces a set of windows live on. Returns a `CFArray` of Space ids (the
/// "Copy" naming means we own the +1 result, hence `Unmanaged` + `takeRetainedValue`).
/// This is the only API that answers "which Space is this window on" — and, crucially,
/// it answers for windows on *other* Spaces, which `kAXWindowsAttribute` never enumerates.
/// `mask` 0x7 spans every Space class (current + others + fullscreen).
@_silgen_name("CGSCopySpacesForWindows")
private func cgsCopySpacesForWindows(
    _ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray
) -> Unmanaged<CFArray>?

// The two SkyLight focus symbols live in a private framework that can't be link-time bound
// (`ld` rejects it as "not an allowed client"), so resolve them at runtime via `dlsym` — the
// long-standing approach for these. `nil` if a future macOS drops them, making the cross-Space
// focus a logged no-op rather than a link failure. `RTLD_DEFAULT` (-2) searches every loaded
// image, including SkyLight, which AppKit has already pulled in.
private typealias SLPSSetFrontProcessFn =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
private typealias SLPSPostEventFn =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

private func resolveSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
}

/// Make `pid`'s window `wid` the front process. `mode` 0x200 = user-generated. The first
/// half of the cross-Space focus recipe; `slpsPostEventRecordTo` then makes the window key.
private let slpsSetFrontProcessWithOptions =
    resolveSymbol("_SLPSSetFrontProcessWithOptions", as: SLPSSetFrontProcessFn.self)

/// Post a synthetic window-server event record to a process — used to deliver the two
/// activation events that make a specific window key, even when it lives on another Space.
private let slpsPostEventRecordTo =
    resolveSymbol("SLPSPostEventRecordTo", as: SLPSPostEventFn.self)

/// Resolve a pid to its `ProcessSerialNumber`. The public `GetProcessForPID` is marked
/// unavailable in Swift (deprecated since 10.9) but the symbol is still present, so bind
/// it directly — `_SLPSSetFrontProcessWithOptions` needs a PSN, not a pid.
@_silgen_name("GetProcessForPID")
private func getProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

// MARK: - Space-membership probe (collection)

/// Classifies windows by managed-Space membership (Bringr-93j.54). A *real* window — on any
/// Space, including ones the current-Space AX query can't see — is assigned to a managed
/// Space by the window server; a *phantom* background/helper surface (the kind Chrome and
/// Ghostty keep, which `isNormalWindow` can't tell apart) is not. So Space membership is the
/// reliable "is this a real, focusable window" signal across Spaces, where AX-window-list
/// membership (Bringr-93j.52) fails because AX never enumerates other Spaces' windows.
///
/// Live shell over the private CGS API; the pure keep-rule that consumes the stamp lives in
/// `WindowEnumerator.shouldCollect` and is unit-tested. Verified by build & run.
@MainActor
enum CGWindowSpaces {
    /// Every Space class, so a window counts as managed wherever it lives.
    private static let allSpacesMask: Int32 = 0x7

    /// Of `numbers` (CG window numbers), those the window server reports as living on at
    /// least one managed Space — i.e. the real windows, with phantoms dropped. Queried one
    /// window at a time because `CGSCopySpacesForWindows` returns the *union* of Spaces for
    /// the whole input, not a per-window map. Only ever called for the off-screen records of
    /// the broadened path (see `CGWindowSource.classify`), so the cost is bounded and paid
    /// once per summon.
    static func managedWindowNumbers(among numbers: [Int]) -> Set<Int> {
        guard !numbers.isEmpty else { return [] }
        let cid = cgsMainConnectionID()
        var managed: Set<Int> = []
        for number in numbers where isManaged(number, connection: cid) {
            managed.insert(number)
        }
        return managed
    }

    private static func isManaged(_ number: Int, connection cid: CGSConnectionID) -> Bool {
        let windows = [number] as CFArray
        guard let spaces = cgsCopySpacesForWindows(cid, allSpacesMask, windows)?
            .takeRetainedValue() as? [Int] else { return false }
        return !spaces.isEmpty
    }
}

// MARK: - Cross-Space focus (commit)

/// Raises and focuses a window that lives on another Space, switching to that Space
/// (Bringr-93j.54). The Accessibility path can't do this: `kAXWindowsAttribute` doesn't
/// surface other-Space windows, so there's no AX element to act on. The window-server
/// front-process call plus two synthetic activation events — the long-standing recipe
/// window switchers use — raise the window *by its CG number* and bring its Space forward.
///
/// Used only as the commit-time fallback for a window absent from its app's AX window list
/// (`WindowController.commit`), so the proven Accessibility path for same-Space windows is
/// untouched. Live shell, verified by build & run.
@MainActor
enum CrossSpaceFocus {
    private static let log = Logger(subsystem: "com.mekedron.Bringr", category: "spaces")

    /// User-generated front-process activation, so the switch behaves like a deliberate click.
    private static let userGeneratedMode: UInt32 = 0x200

    static func raise(windowNumber: Int, pid: pid_t) {
        guard let setFront = slpsSetFrontProcessWithOptions, slpsPostEventRecordTo != nil else {
            log.error("cross-Space focus: SkyLight symbols unavailable")
            return
        }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else {
            log.error("cross-Space focus: no PSN for pid \(pid)")
            return
        }
        let wid = UInt32(windowNumber)
        _ = setFront(&psn, wid, userGeneratedMode)
        makeKeyWindow(&psn, wid)
    }

    /// Deliver the two synthetic activation events that make `wid` the key window. The byte
    /// offsets are the documented window-server event-record layout: 0x04 length, 0x08 the
    /// event subtype (0x01 then 0x02), 0x3a a flag, 0x3c the window id, and 0x20 a 16-byte
    /// marker.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: UInt32) {
        for subtype: UInt8 in [0x01, 0x02] {
            var wid = wid
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = subtype
            bytes[0x3a] = 0x10
            withUnsafeBytes(of: &wid) { src in
                bytes.replaceSubrange(0x3c..<0x40, with: src)
            }
            for index in 0x20..<0x30 { bytes[index] = 0xff }
            _ = slpsPostEventRecordTo?(&psn, &bytes)
        }
    }
}
