import Foundation
import os

// MARK: - Detector (pure)

/// What a frame of finger counts means for the three-finger gesture.
///
/// - `none`: nothing changed (the gesture is neither beginning nor ending).
/// - `press`: the required number of fingers just landed — summon.
/// - `release`: the fingers lifted back below the required count — the signal
///   hold-to-select uses to commit (US-009).
enum ThreeFingerReaction: Equatable, Sendable {
    case none
    case press
    case release
}

/// Recognises a three-finger trackpad press from a stream of per-frame finger
/// counts, and reports when it begins and ends.
///
/// This is the host-independent half of the activation (AC4): it never touches the
/// trackpad or any private framework, it only consumes integer finger counts, so
/// all of its behaviour is unit-tested directly. A press is the rising edge to
/// exactly `requiredFingerCount` fingers; the press is held (latched) until the
/// count drops back below that, which is the release. Counts of one or two fingers
/// are therefore ignored entirely (AC2), as is a four-or-more-finger gesture
/// (which never equals the required count on a settled frame).
struct ThreeFingerPressDetector {
    /// The number of simultaneous fingers that counts as a press. Configurable so
    /// the recognised gesture is tunable and testable; v1 uses three.
    let requiredFingerCount: Int

    /// Whether a press is currently latched, awaiting the fingers to lift.
    private var isPressed = false

    init(requiredFingerCount: Int = 3) {
        self.requiredFingerCount = requiredFingerCount
    }

    /// Feed one frame's finger count and get what it means for the gesture.
    mutating func handle(fingerCount: Int) -> ThreeFingerReaction {
        if isPressed {
            guard fingerCount < requiredFingerCount else { return .none }
            isPressed = false
            return .release
        }
        guard fingerCount == requiredFingerCount else { return .none }
        isPressed = true
        return .press
    }

    /// Clear all state, so a stale press from a previous session never resolves
    /// into a new one. Called when the monitor (re)starts.
    mutating func reset() {
        isPressed = false
    }
}

// MARK: - MultitouchSupport private API (resolved at runtime)

private typealias MTDeviceRef = UnsafeMutableRawPointer

/// The contact-frame callback MultitouchSupport invokes per frame. The second
/// argument is the touch array; we never dereference it (its struct ABI is
/// private and fragile), reading only `numTouches`, so it is an opaque pointer.
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

private typealias MTDeviceCreateDefaultFunc = @convention(c) () -> MTDeviceRef?
private typealias MTRegisterCallbackFunc = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTUnregisterCallbackFunc = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
private typealias MTDeviceStartFunc = @convention(c) (MTDeviceRef?, Int32) -> Void
private typealias MTDeviceStopFunc = @convention(c) (MTDeviceRef?) -> Void

/// The C contact callback. It cannot capture context — MultitouchSupport's
/// callback has no refcon parameter — and it fires on a private MultitouchSupport
/// thread, so it reads the frame's finger count, hops to the main actor (FIFO via
/// the main queue, so edge detection sees frames in order), and routes through the
/// single active monitor.
private let threeFingerContactCallback: MTContactCallback = { _, _, numTouches, _, _ in
    let count = Int(numTouches)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            ThreeFingerMonitor.active?.handleFrame(touchCount: count)
        }
    }
    return 0
}

// MARK: - Live monitor (MultitouchSupport)

/// Observes the trackpad through the private MultitouchSupport framework, feeds
/// each frame's finger count into a `ThreeFingerPressDetector`, and fires
/// `onPress` when a three-finger press is recognised (and `onRelease` when it
/// ends).
///
/// The framework is loaded at runtime with `dlopen`/`dlsym` rather than linked, so
/// if it (or any symbol, or any trackpad) is missing, `start()` fails gracefully,
/// logs, and the app keeps running with three-finger activation simply disabled
/// (AC3). The monitor is purely observational — it never consumes events — so one-
/// and two-finger gestures pass through to the system untouched (AC2).
@MainActor
final class ThreeFingerMonitor {
    /// The single active monitor, so the context-free C callback can route frames
    /// back to it. There is only ever one, owned by `AppDelegate` for the app's
    /// lifetime; held weakly so a late frame after `stop()` is a no-op.
    fileprivate static weak var active: ThreeFingerMonitor?

    private var detector: ThreeFingerPressDetector
    private let onPress: () -> Void
    private let onRelease: () -> Void

    private var dlHandle: UnsafeMutableRawPointer?
    private var device: MTDeviceRef?
    private var stopFunc: MTDeviceStopFunc?
    private var unregisterFunc: MTUnregisterCallbackFunc?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private let log = Logger(subsystem: "com.mekedron.Bringr", category: "ThreeFinger")

    init(
        requiredFingerCount: Int = 3,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void = {}
    ) {
        self.detector = ThreeFingerPressDetector(requiredFingerCount: requiredFingerCount)
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Whether the trackpad monitor is currently installed and running.
    var isRunning: Bool { device != nil }

    /// Load MultitouchSupport, register the contact callback, and start the
    /// default trackpad. Idempotent; returns `false` (and logs) when the framework,
    /// a symbol, or a trackpad is unavailable, leaving the app running normally.
    @discardableResult
    func start() -> Bool {
        guard device == nil else { return true }

        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            log.error("MultitouchSupport unavailable — three-finger activation disabled on this host.")
            return false
        }

        guard
            let createSym = dlsym(handle, "MTDeviceCreateDefault"),
            let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
            let startSym = dlsym(handle, "MTDeviceStart"),
            let stopSym = dlsym(handle, "MTDeviceStop"),
            let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback")
        else {
            log.error("MultitouchSupport symbols missing — three-finger activation disabled.")
            dlclose(handle)
            return false
        }

        let create = unsafeBitCast(createSym, to: MTDeviceCreateDefaultFunc.self)
        let register = unsafeBitCast(registerSym, to: MTRegisterCallbackFunc.self)
        let startDevice = unsafeBitCast(startSym, to: MTDeviceStartFunc.self)
        let stop = unsafeBitCast(stopSym, to: MTDeviceStopFunc.self)
        let unregister = unsafeBitCast(unregisterSym, to: MTUnregisterCallbackFunc.self)

        guard let newDevice = create() else {
            log.error("No multitouch device found — three-finger activation disabled (no trackpad?).")
            dlclose(handle)
            return false
        }

        Self.active = self
        detector.reset()
        register(newDevice, threeFingerContactCallback)
        startDevice(newDevice, 0)

        dlHandle = handle
        device = newDevice
        stopFunc = stop
        unregisterFunc = unregister
        log.info("Three-finger trackpad monitor installed.")
        return true
    }

    /// Stop the device, unregister the callback, and unload the framework.
    func stop() {
        if let device {
            stopFunc?(device)
            unregisterFunc?(device, threeFingerContactCallback)
        }
        if Self.active === self { Self.active = nil }
        device = nil
        stopFunc = nil
        unregisterFunc = nil
        if let dlHandle { dlclose(dlHandle) }
        dlHandle = nil
        detector.reset()
    }

    /// Feed one frame's finger count to the detector and perform its verdict.
    /// `fileprivate` so the C callback can reach it; runs on the main actor.
    fileprivate func handleFrame(touchCount: Int) {
        switch detector.handle(fingerCount: touchCount) {
        case .press: onPress()
        case .release: onRelease()
        case .none: break
        }
    }
}
