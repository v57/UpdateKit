import XCTest

@testable import UpdateKit

/// The updater never contacts the server on its own until the user turns
/// automatic checks on.
@MainActor final class ConsentTests: XCTestCase {
  func testAutomaticChecksStartOffAndRememberTheUsersChoice() throws {
    let suite = "UpdateKitTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let fresh = AppUpdater(
      source: JSONFeed(URL(fileURLWithPath: "/dev/null")), app: .fixture(), defaults: defaults)
    XCTAssertFalse(fresh.automaticallyChecksForUpdates)

    fresh.automaticallyChecksForUpdates = true
    let reopened = AppUpdater(
      source: JSONFeed(URL(fileURLWithPath: "/dev/null")), app: .fixture(), defaults: defaults)
    XCTAssertTrue(reopened.automaticallyChecksForUpdates)
  }
}
