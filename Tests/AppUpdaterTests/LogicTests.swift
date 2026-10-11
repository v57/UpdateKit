import XCTest

@testable import AppUpdater

final class VersionTests: XCTestCase {
  func testNumericOrdering() {
    XCTAssertLessThan(Version("1.9"), Version("1.10"))
    XCTAssertLessThan(Version("1.2"), Version("1.2.1"))
    XCTAssertLessThan(Version("0.9.9"), Version("1"))
    XCTAssertEqual(Version("1.0"), Version("1"))
    XCTAssertEqual(Version("v2.3"), Version("2.3"))
  }

  func testPrereleaseSortsBeforeRelease() {
    XCTAssertLessThan(Version("2.0-beta.2"), Version("2.0"))
    XCTAssertLessThan(Version("2.0-beta.2"), Version("2.0-beta.10"))
    XCTAssertLessThan(Version("1.9"), Version("2.0-beta.1"))
  }

  func testDescriptionDropsTheV() {
    XCTAssertEqual(Version("v1.2").description, "1.2")
    XCTAssertEqual(
      AppRelease(version: "v1.2", downloadURL: URL(string: "https://x/a.zip")!).version, "1.2")
  }
}

final class GitHubReleasesTests: XCTestCase {
  func testParsesRepository() {
    let source = GitHubReleases("v57/Player")
    XCTAssertEqual(source.owner, "v57")
    XCTAssertEqual(source.repository, "Player")
    XCTAssertEqual(source.releasesPageURL?.absoluteString, "https://github.com/v57/Player/releases")
  }

  func testDecodesARelease() throws {
    let json = """
      {"tag_name": "v1.1", "name": "Player 1.1", "body": "- Faster", "draft": false,
       "prerelease": false, "html_url": "https://github.com/v57/Player/releases/tag/v1.1",
       "published_at": "2026-10-12T10:00:00Z",
       "assets": [
         {"name": "Player-1.1.dSYM.zip", "size": 9, "browser_download_url": "https://x/dsym.zip"},
         {"name": "Player.zip", "size": 1168485, "browser_download_url": "https://x/Player.zip"}]}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let release = try decoder.decode(GitHubReleases.Release.self, from: Data(json.utf8))
    let app = try GitHubReleases.appRelease(
      from: release, appName: "Player", assetName: "Player.zip")
    XCTAssertEqual(app.version, "1.1")
    XCTAssertEqual(app.title, "Player 1.1")
    XCTAssertEqual(app.notes, "- Faster")
    XCTAssertEqual(app.downloadURL.absoluteString, "https://x/Player.zip")
    XCTAssertEqual(app.downloadSize, 1_168_485)
    XCTAssertNotNil(app.date)
  }

  func testPicksTheAsset() {
    let names = ["notes.txt", "Other.dmg", "Player-1.1.dmg", "Player-1.1.zip", "symbols.zip"]
    XCTAssertEqual(
      GitHubReleases.pickAsset(names, appName: "Player", assetName: nil), "Player-1.1.zip")
    XCTAssertEqual(
      GitHubReleases.pickAsset(names, appName: "Player", assetName: "Other.dmg"), "Other.dmg")
    XCTAssertNil(GitHubReleases.pickAsset(names, appName: "Player", assetName: "Missing.zip"))
    XCTAssertEqual(
      GitHubReleases.pickAsset(["My App.dmg"], appName: "My App", assetName: nil), "My App.dmg")
    XCTAssertNil(GitHubReleases.pickAsset(["readme.md"], appName: "Player", assetName: nil))
  }

  func testNoMatchingAssetIsAnError() throws {
    let release = GitHubReleases.Release(
      tagName: "v2", name: nil, body: nil, htmlURL: URL(string: "https://x")!, draft: false,
      prerelease: false, publishedAt: nil, assets: [])
    XCTAssertThrowsError(try GitHubReleases.appRelease(from: release, appName: "A", assetName: nil))
  }
}

final class JSONFeedTests: XCTestCase {
  func testReadsAFileFeedWithARelativeDownload() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let feed = folder.appendingPathComponent("feed.json")
    try Data(#"{"version": "v3.0", "url": "Test.zip", "notes": "New"}"#.utf8).write(to: feed)
    let release = try await JSONFeed(feed).latestRelease(for: .fixture(), includePrereleases: false)
    XCTAssertEqual(release?.version, "3.0")
    XCTAssertEqual(release?.notes, "New")
    XCTAssertEqual(release?.downloadURL, folder.appendingPathComponent("Test.zip"))
  }
}

final class InstallMethodTests: XCTestCase {
  private func context(
    _ app: AppInfo = .fixture(), translocated: Bool = false, readOnly: Bool = false,
    writable: Bool = true, applicationsWritable: Bool = true,
    downloads: URL? = URL(fileURLWithPath: "/Users/me/Downloads")
  ) -> InstallMethod.Context {
    InstallMethod.Context(
      app: app, isTranslocated: translocated, isOnReadOnlyVolume: readOnly,
      canWriteBundle: writable, applicationsFolder: URL(fileURLWithPath: "/Applications"),
      canWriteApplicationsFolder: applicationsWritable, downloadsFolder: downloads)
  }

  func testWritableAppIsReplacedInPlace() {
    let app = AppInfo.fixture()
    XCTAssertEqual(InstallMethod.choose(for: context(app)), .replace(app.bundleURL))
  }

  func testUnwritableAppNeedsAnAdministrator() {
    let app = AppInfo.fixture()
    XCTAssertEqual(
      InstallMethod.choose(for: context(app, writable: false)),
      .replaceAsAdministrator(app.bundleURL))
  }

  func testTranslocatedOrDiskImageInstallsIntoApplications() {
    let target = URL(fileURLWithPath: "/Applications/Test.app")
    XCTAssertEqual(InstallMethod.choose(for: context(translocated: true)), .replace(target))
    XCTAssertEqual(InstallMethod.choose(for: context(readOnly: true)), .replace(target))
    XCTAssertEqual(
      InstallMethod.choose(for: context(readOnly: true, applicationsWritable: false)),
      .replaceAsAdministrator(target))
  }

  func testSandboxedAppSavesOrOpensTheBrowser() {
    let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
    var app = AppInfo.fixture(sandboxed: true)
    XCTAssertEqual(InstallMethod.choose(for: context(app)), .saveToFolder(downloads))
    app.hasDownloadsAccess = false
    XCTAssertEqual(InstallMethod.choose(for: context(app)), .openInBrowser)
    app = .fixture(sandboxed: true)
    app.hasNetworkAccess = false
    XCTAssertEqual(InstallMethod.choose(for: context(app)), .openInBrowser)
  }

  func testUnsignedAppNeverReplacesItself() {
    var app = AppInfo.fixture()
    app.teamIdentifier = nil
    XCTAssertEqual(
      InstallMethod.choose(for: context(app)),
      .saveToFolder(URL(fileURLWithPath: "/Users/me/Downloads")))
    XCTAssertEqual(InstallMethod.choose(for: context(app, downloads: nil)), .openInBrowser)
  }

  func testAppStoreBuildTurnsTheUpdaterOff() {
    var app = AppInfo.fixture()
    app.isAppStoreBuild = true
    XCTAssertEqual(InstallMethod.choose(for: context(app)), .appStore)
  }
}

final class ShellTests: XCTestCase {
  func testQuotedWordsSurviveTheShell() async throws {
    for text in ["plain", "with space", "it's", "a'b'c", "$HOME `x` \"q\" \\ ;|&"] {
      let result = try await Shell.run("/bin/sh", ["-c", "printf %s \(Shell.quote(text))"])
      XCTAssertEqual(result.output, text)
    }
  }

  func testAppleScriptStringEscapes() async throws {
    let text = #"a "quoted" \ path"#
    let result = try await Shell.run(
      "/usr/bin/osascript", ["-e", "return \(Shell.appleScriptString(text))"])
    XCTAssertEqual(result.output.trimmingCharacters(in: .newlines), text)
  }

  func testSignatureFailuresInPlainWords() {
    XCTAssertEqual(
      CodeSignature.reason(for: OSStatus(errSecCSInfoPlistFailed)),
      "it was modified after it was signed.")
    XCTAssertEqual(
      CodeSignature.reason(for: OSStatus(errSecCSReqFailed)),
      "it is signed by a different developer.")
    XCTAssertEqual(CodeSignature.reason(for: OSStatus(errSecCSUnsigned)), "it is not signed.")
    XCTAssertEqual(CodeSignature.reason(for: -1), "code signing error -1.")
  }

  func testRequirementString() {
    XCTAssertEqual(
      CodeSignature.requirement(identifier: "dev.v57.player", team: "AUCR797TMH"),
      #"identifier "dev.v57.player" and anchor apple generic and certificate leaf[subject.OU] = "AUCR797TMH""#
    )
  }
}

extension AppInfo {
  static func fixture(sandboxed: Bool = false) -> AppInfo {
    AppInfo(
      name: "Test", bundleIdentifier: "dev.v57.test", version: "1.0", build: "1",
      bundleURL: URL(fileURLWithPath: "/Users/me/Apps/Test.app"), teamIdentifier: "TEAM123456",
      isSandboxed: sandboxed, hasNetworkAccess: true, hasDownloadsAccess: true,
      isAppStoreBuild: false)
  }
}
