import CoreGraphics
import Foundation
import os

/// A window discovered at summon time, with the metadata the wheel needs to
/// render and target it. `id` carries the stable, system-assigned window number
/// (stable for the window's lifetime), so a remembered selection (US-012) can be
/// matched across summons.
struct WindowInfo: Equatable, Sendable {
    let id: WindowID
    let title: String

    /// The application that owns this window.
    var app: AppID { id.app }
}

/// An application that currently owns at least one normal, on-screen window,
/// paired with those windows in front-to-back order.
struct AppWindows: Equatable, Sendable {
    let id: AppID
    let name: String
    let windows: [WindowInfo]
}

/// A raw on-screen window record straight from the system window list, before
/// any filtering or grouping. Plain values so `WindowEnumerator`'s logic can be
/// exercised with fixtures and never touches the live window server in tests.
struct RawWindow: Equatable, Sendable {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

/// Source of raw on-screen window records, behind a seam (mirrors
/// `WindowControlling`). The live conformer reads CoreGraphics' window list; the
/// test conformer returns fixtures, so enumeration logic runs with no live
/// system dependency and no permission prompt during tests.
@MainActor
protocol WindowEnumerationSource {
    /// Every on-screen window record, front-to-back, as the system reports them.
    func rawWindows() -> [RawWindow]
    /// This process's pid, so Bringr's own windows can be excluded.
    var selfPID: pid_t { get }
}

/// Reports which apps currently have on-screen windows and the windows each
/// owns, computed fresh on every summon so the wheel reflects live state.
///
/// All grouping/filtering lives here over the injectable `WindowEnumerationSource`
/// seam; the live CoreGraphics access is isolated in `CGWindowSource`.
@MainActor
final class WindowEnumerator {
    /// Smallest width/height a window may have and still count as "normal";
    /// drops the 1×1 / off-size helper surfaces some apps keep on screen.
    static let minimumWindowSize: CGFloat = 40

    private let source: WindowEnumerationSource
    /// The app/window sort orders to apply (Bringr-93j.34), read through closures so
    /// each `enumerate()` picks up the persisted Preferences value fresh at summon time
    /// (mirroring `RevealStrategy.current`), while tests inject fixed orders.
    private let appOrder: () -> AppSortOrder
    private let windowOrder: () -> WindowSortOrder
    private let log = Logger(subsystem: "com.mekedron.Bringr", category: "enumeration")

    /// Wall-clock duration of the most recent `enumerate()` call, recorded so the
    /// summon hot-path budget can be measured. `nil` until the first call. (AC4)
    private(set) var lastDuration: TimeInterval?

    init(
        source: WindowEnumerationSource? = nil,
        appOrder: @escaping () -> AppSortOrder = { AppSortOrder.current() },
        windowOrder: @escaping () -> WindowSortOrder = { WindowSortOrder.current() }
    ) {
        self.source = source ?? CGWindowSource()
        self.appOrder = appOrder
        self.windowOrder = windowOrder
    }

    /// Apps that currently own at least one normal, on-screen window, each with
    /// its windows front-to-back. Excludes Bringr itself and apps whose only
    /// on-screen surfaces are non-normal (menu-bar items, panels, agents).
    func enumerate() -> [AppWindows] {
        let start = DispatchTime.now().uptimeNanoseconds
        let normal = source.rawWindows().filter(isNormalWindow)
        let result = sorted(group(normal))
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        lastDuration = elapsed
        log.debug("Enumerated \(result.count) app(s) in \(Int((elapsed * 1000).rounded())) ms")
        return result
    }

    private func isNormalWindow(_ window: RawWindow) -> Bool {
        window.ownerPID != source.selfPID
            && window.layer == 0
            && window.alpha > 0
            && !window.ownerName.isEmpty
            && window.bounds.width >= Self.minimumWindowSize
            && window.bounds.height >= Self.minimumWindowSize
    }

    private func group(_ windows: [RawWindow]) -> [AppWindows] {
        var pidOrder: [pid_t] = []
        var byPID: [pid_t: [RawWindow]] = [:]
        for window in windows {
            if byPID[window.ownerPID] == nil { pidOrder.append(window.ownerPID) }
            byPID[window.ownerPID, default: []].append(window)
        }

        return pidOrder.map { pid in
            let raws = byPID[pid] ?? []
            let appID = AppID(pid: pid)
            let infos = raws.enumerated().map { index, raw in
                WindowInfo(
                    id: WindowID(app: appID, token: raw.windowNumber),
                    title: title(for: raw, index: index)
                )
            }
            return AppWindows(id: appID, name: raws.first?.ownerName ?? "", windows: infos)
        }
    }

    /// Apply the persisted app/window sort orders (Bringr-93j.34) to the freshly
    /// grouped, front-to-back enumeration. `.recentlyUsed` keeps that live z-order (the
    /// ⌘-Tab-matching default); the alternatives impose a stable arrangement from values
    /// macOS already reports — the app name, the creation-ordered window number — so
    /// positions stop reshuffling without any recency tracking of our own.
    private func sorted(_ apps: [AppWindows]) -> [AppWindows] {
        let windowsSorted = apps.map { app in
            AppWindows(id: app.id, name: app.name, windows: sortWindows(app.windows))
        }
        switch appOrder() {
        case .recentlyUsed:
            return windowsSorted
        case .name:
            return windowsSorted.sorted { lhs, rhs in
                switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.id.pid < rhs.id.pid
                }
            }
        }
    }

    /// Order one app's windows by the persisted window sort order. `.fixed` sorts by
    /// window number, which macOS assigns in creation order, so the oldest window keeps
    /// the first spot summon to summon.
    private func sortWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        switch windowOrder() {
        case .recentlyUsed:
            return windows
        case .fixed:
            return windows.sorted { $0.id.token < $1.id.token }
        }
    }

    /// CoreGraphics window titles need Screen Recording permission, which Bringr
    /// does not request in v1, so titles are usually empty; fall back to a
    /// 1-based index label, which US-006 permits for window slices.
    private func title(for window: RawWindow, index: Int) -> String {
        let trimmed = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Window \(index + 1)" : trimmed
    }
}

/// Live `WindowEnumerationSource` backed by CoreGraphics' on-screen window list.
/// Uses only public API: each record's `windowNumber` is the stable
/// `kCGWindowNumber`. (Titles via `kCGWindowName` require Screen Recording and
/// are normally empty under Accessibility-only permission — see `title(for:)`.)
@MainActor
final class CGWindowSource: WindowEnumerationSource {
    let selfPID = ProcessInfo.processInfo.processIdentifier

    func rawWindows() -> [RawWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return infoList.compactMap(rawWindow(from:))
    }

    private func rawWindow(from info: [String: Any]) -> RawWindow? {
        guard let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }

        return RawWindow(
            windowNumber: windowNumber,
            ownerPID: ownerPID,
            ownerName: (info[kCGWindowOwnerName as String] as? String) ?? "",
            title: (info[kCGWindowName as String] as? String) ?? "",
            layer: layer,
            alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            bounds: bounds
        )
    }
}
