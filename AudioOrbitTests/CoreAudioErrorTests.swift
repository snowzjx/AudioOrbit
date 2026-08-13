import XCTest
@testable import AudioOrbit

final class CoreAudioErrorTests: XCTestCase {
    func testPrintableStatusIncludesFourCharacterCode() {
        let error = CoreAudioError(operation: "Create tap", status: OSStatus(bitPattern: 0x666D743F))

        XCTAssertEqual(error.fourCharacterCode, "fmt?")
        XCTAssertEqual(error.description, "Create tap failed (fmt?, 1718449215).")
    }

    func testNonPrintableStatusUsesNumericForm() {
        let error = CoreAudioError(operation: "Start device", status: -50)

        XCTAssertNil(error.fourCharacterCode)
        XCTAssertEqual(error.description, "Start device failed (OSStatus -50).")
    }
}
