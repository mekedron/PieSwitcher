import AppKit
import IOKit
import IOKit.hid

// MARK: - Performer seam

/// Plays a single haptic tap of a given strength. A seam so the controller's hover→tap
/// wiring is unit-tested with a recording fake, while the live tap stays a build-and-run
/// shell (the haptic engine can't be observed from a test).
protocol HapticPerforming {
    func perform(_ intensity: HapticIntensity)
}

/// Drives the real trackpad haptic engine via `NSHapticFeedbackManager`. Each strength
/// maps to one of the three public feedback patterns (lightest→firmest). On hardware with
/// no haptic-capable trackpad (e.g. a desktop Mac) `perform` is a silent no-op, so the
/// feature degrades gracefully with no extra check.
struct LiveHapticPerformer: HapticPerforming {
    func perform(_ intensity: HapticIntensity) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch intensity {
        case .light: pattern = .alignment
        case .medium: pattern = .generic
        case .strong: pattern = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

// MARK: - External mouse detection

/// Whether an external (non-built-in) mouse is currently connected (Bringr-93j.44). The
/// hover haptic suppresses itself when one is — the user's hand is on the mouse, not the
/// trackpad, so there's nothing to feel. Built-in Force Touch trackpads either don't
/// enumerate as a mouse or carry `Built-In = true`; either way they're excluded, so a
/// matching device that isn't built-in is a real external mouse. Live IOKit shell, verified
/// by build-and-run; returns false (allow the haptic) if enumeration fails, since the haptic
/// is itself a no-op without trackpad hardware.
enum ExternalMouseDetector {
    static func isPresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return false
        }
        return devices.contains { device in
            let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool ?? false
            return !builtIn
        }
    }
}

// MARK: - Per-summon haptic policy

/// Owns the trackpad-haptic policy for the radial menu (Bringr-93j.44): it resolves whether
/// haptics should fire for a summon (the setting is on AND no external mouse is connected)
/// and, on each hover move, asks the performer for a tick when the selection advanced to a
/// new slice. Holds the per-summon state so the per-hover check is cheap — no `UserDefaults`
/// read or IOKit enumeration on the hover hot path. Providers are injected so tests drive the
/// policy with a recording performer and no live hardware.
@MainActor
final class HapticController {
    private let enabledProvider: () -> Bool
    private let intensityProvider: () -> HapticIntensity
    private let externalMouseProvider: () -> Bool
    private let performer: HapticPerforming

    /// Resolved at each summon: true only when enabled and no external mouse is present.
    private var active = false
    /// The strength resolved for the current summon.
    private var intensity: HapticIntensity = .default
    /// Last probed external-mouse presence, `nil` until the first probe. The IOKit
    /// device scan behind the probe is too costly for the summon hot path, so each
    /// summon uses this cached value and schedules a refresh for the next one —
    /// plugging a mouse in or out applies one summon late.
    private var externalMousePresent: Bool?
    /// Guards against stacking refresh tasks when summons come faster than probes.
    private var probeRefreshScheduled = false

    init(
        enabledProvider: @escaping () -> Bool = { TrackpadHaptics.isEnabled() },
        intensityProvider: @escaping () -> HapticIntensity = { TrackpadHaptics.intensity() },
        externalMouseProvider: @escaping () -> Bool = { ExternalMouseDetector.isPresent() },
        performer: HapticPerforming = LiveHapticPerformer()
    ) {
        self.enabledProvider = enabledProvider
        self.intensityProvider = intensityProvider
        self.externalMouseProvider = externalMouseProvider
        self.performer = performer
    }

    /// Read the setting fresh for a new summon (mirroring the controller's other per-summon
    /// reads) so a Preferences change applies on the next open. The external-mouse probe is
    /// synchronous only on the very first summon; afterwards the cached value answers and a
    /// deferred task (next run-loop tick, after the wheel is already up) re-probes, keeping
    /// the IOKit scan off both the hover hot path and the open hot path.
    func resolveForSummon() {
        intensity = intensityProvider()
        guard enabledProvider() else {
            active = false
            return
        }
        let present = externalMousePresent ?? externalMouseProvider()
        externalMousePresent = present
        active = !present
        scheduleProbeRefresh()
    }

    /// Re-probe for an external mouse after the current summon has finished opening, so
    /// the next summon reads fresh state without paying the scan while opening.
    private func scheduleProbeRefresh() {
        guard !probeRefreshScheduled else { return }
        probeRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.externalMousePresent = self.externalMouseProvider()
            self.probeRefreshScheduled = false
        }
    }

    /// Fire a tick if the hover advanced to a new slice this move and haptics are active for
    /// this summon. Cheap: a bool check plus the pure transition test.
    func hoverChanged(from previous: HoverRegion, to current: HoverRegion) {
        guard active, HoverHapticTrigger.shouldTap(from: previous, to: current) else { return }
        performer.perform(intensity)
    }
}
