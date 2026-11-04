import Observation
import XCTest

@testable import UpdateKit

/// Views follow what they read: nothing refreshes them for a neighbouring property any more.
@MainActor final class ObservationTests: XCTestCase {
  private func makeUpdater(feed: URL) throws -> (AppUpdater, UserDefaults, String) {
    let suite = "UpdateKitTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    return (AppUpdater(source: JSONFeed(feed), app: .fixture(), defaults: defaults), defaults, suite)
  }

  func testTheAutomaticSwitchIsTracked() throws {
    let (updater, defaults, suite) = try makeUpdater(feed: URL(fileURLWithPath: "/dev/null"))
    defer { defaults.removePersistentDomain(forName: suite) }
    let changed = expectation(description: "automaticallyChecksForUpdates changed")
    withObservationTracking { _ = updater.automaticallyChecksForUpdates } onChange: { changed.fulfill() }
    updater.automaticallyChecksForUpdates = true
    wait(for: [changed], timeout: 1)
    XCTAssertTrue(defaults.bool(forKey: "AppUpdater.automaticChecks"))
  }

  /// A finished background check reaches a view that shows only "Last checked…", and the next launch reads it back.
  func testLastCheckDateFollowsACheck() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let feed = folder.appendingPathComponent("feed.json")
    try Data(#"{"version": "0.1", "url": "Test.zip"}"#.utf8).write(to: feed)

    let (updater, defaults, suite) = try makeUpdater(feed: feed)
    defer { defaults.removePersistentDomain(forName: suite) }
    updater.automaticallyChecksForUpdates = true
    XCTAssertNil(updater.lastCheckDate)

    let changed = expectation(description: "lastCheckDate changed")
    withObservationTracking { _ = updater.lastCheckDate } onChange: { changed.fulfill() }
    updater.start()
    await fulfillment(of: [changed], timeout: 5)
    XCTAssertNotNil(updater.lastCheckDate)

    let reopened = AppUpdater(source: JSONFeed(feed), app: .fixture(), defaults: defaults)
    XCTAssertEqual(reopened.lastCheckDate, updater.lastCheckDate)
  }
}
