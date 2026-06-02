import Foundation
import IOKit
import IOKit.hid

// MARK: - Variant

/// Which text variant the onboarding screen-2 should show (Bringr-93j.112). The
/// detector picks one of these from the live HID enumeration; screen 2 shows the
/// matching copy. Distinct from the existing `ExternalMouseDetector` (used by
/// the haptic policy) because that one treats every non-built-in pointer as
/// "external" — for onboarding we additionally exclude Apple-vendor devices
/// (Magic Mouse / Magic Trackpad) because those don't have extra buttons to
/// summon the wheel with.
enum OnboardingMouseVariant: Equatable {
    /// A non-Apple external mouse is connected — acknowledge it in the copy.
    case externalNonAppleMouse
    /// Only the built-in trackpad and/or Apple peripherals are present (or the
    /// scan was inconclusive). Show the generic "if you ever connect a mouse"
    /// variant so the screen is never skipped.
    case generic
}

// MARK: - Pure descriptor

/// A lightweight, testable descriptor of a single HID device. The live scan
/// (`detectLive`) converts an `IOHIDDevice` into one of these and the pure
/// decision (`variant(forDevices:)`) operates on a list of these — that's
/// where unit tests inject fixtures without any IOKit dependency.
struct OnboardingHIDDevice: Equatable {
    /// Whether the device reports itself as built-in (laptop trackpad / keyboard).
    let isBuiltIn: Bool
    /// USB/Bluetooth vendor ID, or `nil` if the device didn't report one.
    let vendorID: Int?
}

// MARK: - Detector

/// Decides whether the user's setup includes a non-Apple external mouse so the
/// onboarding screen-2 copy can acknowledge it. Lives in its own type so the
/// whole decision tree — including "scan failed / inconclusive" — is
/// unit-tested without any live IOKit dependency.
enum OnboardingMouseDetector {
    /// Apple's USB vendor ID (0x05AC). Magic Mouse and Magic Trackpad report
    /// this; third-party mice don't, so the filter just compares this constant.
    static let appleVendorID = 0x05AC

    /// Pure decision: given a list of HID devices, choose the text variant.
    /// `externalNonAppleMouse` requires at least one device that is *not* built
    /// in and *not* Apple-vendor. Everything else (only built-in, only Apple,
    /// or an empty list from a failed scan) falls back to `.generic` — the
    /// screen is never skipped silently (AC).
    static func variant(forDevices devices: [OnboardingHIDDevice]) -> OnboardingMouseVariant {
        let hasNonAppleExternal = devices.contains { device in
            guard !device.isBuiltIn else { return false }
            // No vendor ID reported = treat as non-Apple external. Better to
            // acknowledge a real mouse with a missing vendor entry than to fall
            // back to generic and pretend it's not there.
            guard let vendor = device.vendorID else { return true }
            return vendor != appleVendorID
        }
        return hasNonAppleExternal ? .externalNonAppleMouse : .generic
    }

    /// Live enumeration: scan the system's HID mouse devices and decide the
    /// variant. Returns `.generic` if the IOKit scan fails — the onboarding
    /// screen still shows the generic copy in that case, never an error.
    static func detectLive() -> OnboardingMouseVariant {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard let raw = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return .generic
        }
        let devices: [OnboardingHIDDevice] = raw.map { device in
            let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool ?? false
            let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
            return OnboardingHIDDevice(isBuiltIn: builtIn, vendorID: vendor)
        }
        return variant(forDevices: devices)
    }
}
