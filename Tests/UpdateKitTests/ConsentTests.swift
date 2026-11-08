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

  /// A release build ignores the environment's switches (a process that sets them can't turn updates off or
  /// point them at another feed); a debug build reads them.
  func testEnvironmentSwitchesAreForDebugBuildsOnly() {
    let environment = ["APP_UPDATER_DISABLED": "1", "APP_UPDATER_FEED": "http://evil.example/feed.json"]
    XCTAssertNil(AppUpdater.debugSwitch("APP_UPDATER_DISABLED", environment: environment, isDebug: false))
    XCTAssertNil(AppUpdater.debugSwitch("APP_UPDATER_FEED", environment: environment, isDebug: false))
    XCTAssertEqual(AppUpdater.debugSwitch("APP_UPDATER_DISABLED", environment: environment, isDebug: true), "1")
  }
}
