import AppKit
import Combine

/// Cache of pre-rasterized app icons for the wheel's slices, so rendering a summon
/// never touches IconServices on the main thread.
///
/// The system icon lookups (`NSRunningApplication.icon`, `NSWorkspace.icon(forFile:)`)
/// return images whose bitmaps IconServices decodes lazily, at first draw — so an
/// uncached wheel pays every icon's disk read and decode inside the summon's first
/// frame, a visible open stall. The store front-loads that cost: icons are resolved
/// AND rasterized to the slice's render size on a detached background task — at
/// launch for everything the next summon could show, on workspace notification for
/// apps launched later, and on demand for anything still missing. The render path is
/// then a dictionary hit; a miss shows the generic placeholder and fills in when its
/// load lands (`generation` bumps, re-rendering observing views).
@MainActor
final class AppIconStore: ObservableObject {
    /// Bumped when a freshly loaded icon lands in the cache, so observing views
    /// re-render and pick up icons that finished after the wheel was on screen.
    @Published private(set) var generation = 0

    /// Icons of running apps, keyed by pid — the handle live enumeration nodes carry.
    private var byPID: [pid_t: NSImage] = [:]
    /// Icons resolved from the on-disk bundle, keyed by bundle id — the handle
    /// curated / Dock launch nodes carry (the app may not be running).
    private var byBundleID: [String: NSImage] = [:]
    /// Keys with a load in flight, so one slice re-rendering every hover doesn't
    /// stack duplicate background loads for the same missing icon.
    private var inFlight: Set<String> = []
    private var workspaceObservers: [any NSObjectProtocol] = []

    /// Slice icons render at 34 pt (`RadialSliceLabel`); rasterizing at 2× keeps them
    /// sharp on Retina while shrinking a typical 1024 px source to a 68 px bitmap.
    nonisolated private static let iconPointSize: CGFloat = 34

    /// The cached icon for a node's handles, `nil` (render the placeholder) while it
    /// loads. Checks the pid cache first — a running app's live icon — matching the
    /// resolution order of `resolveIcon`. A miss schedules one background load.
    func icon(forPID pid: pid_t?, bundleID: String?) -> NSImage? {
        if let pid, let cached = byPID[pid] { return cached }
        if let bundleID, let cached = byBundleID[bundleID] { return cached }
        load(pid: pid, bundleID: bundleID)
        return nil
    }

    /// Warm every icon the next summon could show: the running Dock apps, the curated
    /// My Apps list, and — when the Collection "include all Dock apps" option is on —
    /// the pinned Dock apps. Resolving the Dock entries here also fills
    /// `DockOrder`'s bundle-entry cache, so the first Dock-included summon pays no
    /// Launch Services lookups either.
    func prewarm() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            load(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }
        for curated in CuratedApps.current() {
            load(pid: nil, bundleID: curated.bundleIdentifier)
        }
        if CollectionPreferences.includesAllDockApps() {
            for entry in DockOrder.currentApps() {
                load(pid: nil, bundleID: entry.bundleIdentifier)
            }
        }
    }

    /// Keep the cache warm as apps come and go: a launch loads the new app's icon
    /// before it can appear in a wheel; a termination drops the dead pid's entry
    /// (the bundle-id entry stays — a curated launch node still shows it).
    func startObservingWorkspace() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = Self.application(from: note) else { return }
                self?.load(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = Self.application(from: note) else { return }
                self?.byPID.removeValue(forKey: app.processIdentifier)
            }
        })
    }

    private static func application(from note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    /// Resolve and rasterize off the main thread, then publish the result. The
    /// in-flight key covers both handles so a pid+bundle node loads once; a failed
    /// resolution (dead pid, uninstalled bundle) leaves the key retryable — the
    /// placeholder stays until some later render's re-request succeeds.
    private func load(pid: pid_t?, bundleID: String?) {
        guard pid != nil || bundleID != nil else { return }
        let key = "\(pid.map(String.init) ?? "-"):\(bundleID ?? "-")"
        guard inFlight.insert(key).inserted else { return }
        Task.detached(priority: .userInitiated) {
            let icon = Self.resolveIcon(pid: pid, bundleID: bundleID).map(Self.rasterized)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(key)
                guard let icon else { return }
                if let pid { self.byPID[pid] = icon }
                if let bundleID { self.byBundleID[bundleID] = icon }
                self.generation += 1
            }
        }
    }

    /// Synchronous, uncached icon resolution — the single source of truth for how a
    /// node's handles map to an icon: the running app's live icon by pid first, then
    /// the on-disk bundle icon by bundle id (a curated app that isn't running), `nil`
    /// when neither resolves. `nonisolated` because the store calls it from a detached
    /// task; `NSRunningApplication` and these `NSWorkspace` lookups are thread-safe.
    nonisolated static func resolveIcon(pid: pid_t?, bundleID: String?) -> NSImage? {
        if let pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            return icon
        }
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    /// Draw `image` into a fixed-size bitmap, forcing the IconServices decode to
    /// happen here — on the loading task — rather than at the slice's first on-screen
    /// draw. Safe off the main thread: `NSGraphicsContext.current` is thread-local and
    /// the bitmap is private to this call.
    nonisolated private static func rasterized(_ image: NSImage) -> NSImage {
        let points = iconPointSize
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: points, height: points),
            from: .zero, operation: .copy, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}
