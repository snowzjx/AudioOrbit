import Foundation
import XCTest
@testable import AudioOrbit

final class OnboardingStateTests: XCTestCase {
    func testCompletionPersistsAcrossStoreInstances() throws {
        let suiteName = "AudioOrbit-OnboardingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = OnboardingStateStore(defaults: defaults)

        XCTAssertFalse(first.isCompleted)
        first.setCompleted(true)

        XCTAssertTrue(OnboardingStateStore(defaults: defaults).isCompleted)
    }
}
