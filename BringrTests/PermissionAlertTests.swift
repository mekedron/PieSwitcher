import XCTest
@testable import Bringr

/// The launch-time decision for whether to surface the permission alert. The window
/// and view themselves are AppKit/SwiftUI glue verified by build & run; this covers
/// the one pure branch — when the modal should appear.
final class PermissionAlertTests: XCTestCase {
    func testPresentsWhenUntrustedAndNotSuppressed() {
        XCTAssertTrue(AppDelegate.shouldPresentPermissionAlert(isTrusted: false, suppressed: false))
    }

    func testDoesNotPresentWhenTrusted() {
        XCTAssertFalse(AppDelegate.shouldPresentPermissionAlert(isTrusted: true, suppressed: false))
    }

    func testDoesNotPresentWhenSuppressed() {
        XCTAssertFalse(AppDelegate.shouldPresentPermissionAlert(isTrusted: false, suppressed: true))
    }

    func testDoesNotPresentWhenTrustedEvenIfSuppressed() {
        XCTAssertFalse(AppDelegate.shouldPresentPermissionAlert(isTrusted: true, suppressed: true))
    }

    func testSuppressDefaultsKeyIsStable() {
        // The AppDelegate read and the view's @AppStorage must agree on this key.
        XCTAssertEqual(PermissionAlertWindow.suppressDefaultsKey, "suppressPermissionAlert")
    }
}
