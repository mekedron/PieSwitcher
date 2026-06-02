import XCTest
@testable import PieSwitcher

/// Covers `OnboardingMouseDetector.variant(forDevices:)` — the pure decision
/// that picks the screen-2 text variant from a list of HID devices
/// (Bringr-93j.112). Fixtures are plain `OnboardingHIDDevice` values, so the
/// whole decision tree is exercised without any IOKit dependency.
final class OnboardingMouseDetectorTests: XCTestCase {

    func testEmptyDeviceListFallsBackToGeneric() {
        // A failed scan returns an empty list; the screen must still show
        // generic copy rather than skip silently (AC).
        let variant = OnboardingMouseDetector.variant(forDevices: [])
        XCTAssertEqual(variant, .generic)
    }

    func testOnlyBuiltInTrackpadIsGeneric() {
        let devices = [OnboardingHIDDevice(isBuiltIn: true, vendorID: OnboardingMouseDetector.appleVendorID)]
        XCTAssertEqual(OnboardingMouseDetector.variant(forDevices: devices), .generic)
    }

    func testAppleMagicMouseIsGeneric() {
        // An external Apple Magic Mouse: not built-in, but Apple-vendor. The
        // onboarding skips the acknowledgement because Magic Mouse has no
        // extra buttons to bind to.
        let devices = [OnboardingHIDDevice(isBuiltIn: false, vendorID: OnboardingMouseDetector.appleVendorID)]
        XCTAssertEqual(OnboardingMouseDetector.variant(forDevices: devices), .generic)
    }

    func testThirdPartyMouseTriggersExternal() {
        // Logitech vendor ID (0x046D), arbitrary non-Apple value.
        let devices = [OnboardingHIDDevice(isBuiltIn: false, vendorID: 0x046D)]
        XCTAssertEqual(OnboardingMouseDetector.variant(forDevices: devices), .externalNonAppleMouse)
    }

    func testMixedSetupPrefersExternal() {
        // The user has both an external mouse and Apple peripherals — the
        // detector must still acknowledge the third-party mouse.
        let devices = [
            OnboardingHIDDevice(isBuiltIn: true, vendorID: OnboardingMouseDetector.appleVendorID),
            OnboardingHIDDevice(isBuiltIn: false, vendorID: OnboardingMouseDetector.appleVendorID),
            OnboardingHIDDevice(isBuiltIn: false, vendorID: 0x046D)
        ]
        XCTAssertEqual(OnboardingMouseDetector.variant(forDevices: devices), .externalNonAppleMouse)
    }

    func testMissingVendorIDTreatedAsExternal() {
        // A mouse that didn't report a vendor ID: treat as a real third-party
        // external mouse — better to acknowledge the device than to fall back
        // to generic and pretend it isn't there.
        let devices = [OnboardingHIDDevice(isBuiltIn: false, vendorID: nil)]
        XCTAssertEqual(OnboardingMouseDetector.variant(forDevices: devices), .externalNonAppleMouse)
    }
}
