import CoreGraphics
import XCTest
@testable import PieSwitcher

/// Exercises the CGEventFlags → SidedModifier parser. We can't synthesize real `CGEvent`s
/// in unit tests so we drive the parser with raw flag values directly — that's what the
/// monitor ultimately reads from the live event.
final class SidedModifierParserTests: XCTestCase {

    func testParsesRightOptionWhenDeviceBitSet() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | DeviceFlagMask.rightOption)
        let mods = SidedModifierParser.modifiers(from: flags)
        XCTAssertEqual(mods, [SidedModifier(.option, .right)])
    }

    func testParsesLeftCommandWhenDeviceBitSet() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DeviceFlagMask.leftCommand)
        XCTAssertEqual(SidedModifierParser.modifiers(from: flags), [SidedModifier(.command, .left)])
    }

    func testParsesBothSidesWhenBothDeviceBitsSet() {
        let raw = CGEventFlags.maskShift.rawValue | DeviceFlagMask.leftShift | DeviceFlagMask.rightShift
        let mods = SidedModifierParser.modifiers(from: CGEventFlags(rawValue: raw))
        XCTAssertEqual(mods, [SidedModifier(.shift, .left), SidedModifier(.shift, .right)])
    }

    func testFnHasNoSide() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertEqual(SidedModifierParser.modifiers(from: flags), [SidedModifier(.function, .either)])
    }

    func testMissingDeviceBitsFallsBackToEither() {
        // High-level mask set, no device bits — synthesized events behave like this.
        let flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(SidedModifierParser.modifiers(from: flags), [SidedModifier(.option, .either)])
    }

    func testIgnoresIrrelevantFlags() {
        let raw = CGEventFlags.maskAlphaShift.rawValue
            | CGEventFlags.maskNumericPad.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | DeviceFlagMask.leftOption
        XCTAssertEqual(
            SidedModifierParser.modifiers(from: CGEventFlags(rawValue: raw)),
            [SidedModifier(.option, .left)]
        )
    }
}
