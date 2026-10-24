import XCTest
import PGSCore
import VisionOCR

final class VisionAvailabilityTests: XCTestCase {
    func testVisionIsAvailableOnlyOnMacOS() {
        #if os(macOS)
        XCTAssertTrue(VisionOCRAvailability.isAvailable)
        #else
        XCTAssertFalse(VisionOCRAvailability.isAvailable)
        #endif
    }
}
