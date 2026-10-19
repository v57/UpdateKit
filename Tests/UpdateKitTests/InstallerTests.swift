#if os(macOS)
import XCTest

@testable import UpdateKit

final class InstallerTests: XCTestCase {
  private var folder: URL!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UpdateKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

  /// A minimal app bundle: Info.plist and /usr/bin/true as the executable.
  private func makeApp(
    _ name: String = "Test", in parent: URL? = nil, id: String = "dev.v57.test",
    version: String = "2.0", build: String = "2"
  ) throws -> URL {
    let app = (parent ?? folder).appendingPathComponent("\(name).app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(name))
    let plist: [String: Any] = [
      "CFBundleIdentifier": id, "CFBundleExecutable": name, "CFBundleName": name,
      "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
      "CFBundleVersion": build,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
      to: app.appendingPathComponent("Contents/Info.plist"))
    return app
  }

  private func version(of app: URL) -> String? {
    Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
  }

  // MARK: - Extract

  func testExtractsAZip() async throws {
    let source = folder.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let app = try makeApp(in: source)
    let zip = folder.appendingPathComponent("Test.zip")
    try await Shell.check("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
    let extracted = try await Installer.extractApp(
      from: zip, into: folder.appendingPathComponent("out"))
    XCTAssertEqual(extracted.lastPathComponent, "Test.app")
    XCTAssertEqual(version(of: extracted), "2.0")
  }

  func testExtractsADiskImage() async throws {
    let source = folder.appendingPathComponent("dmg-source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try makeApp(in: source)
    let dmg = folder.appendingPathComponent("Test.dmg")
    try await Shell.check(
      "/usr/bin/hdiutil",
      [
        "create", "-quiet", "-srcfolder", source.path, "-format", "UDZO", "-volname", "Test",
        dmg.path,
      ])
    let extracted = try await Installer.extractApp(
      from: dmg, into: folder.appendingPathComponent("out"))
    XCTAssertEqual(version(of: extracted), "2.0")
  }

  func testRejectsAnArchiveWithoutAnApp() async throws {
    let empty = folder.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try Data("not an app".utf8).write(to: empty.appendingPathComponent("readme.txt"))
    let zip = folder.appendingPathComponent("Empty.zip")
    try await Shell.check("/usr/bin/ditto", ["-c", "-k", empty.path, zip.path])
    do {
      _ = try await Installer.extractApp(from: zip, into: folder.appendingPathComponent("out"))
      XCTFail("expected an error")
    } catch UpdateError.invalidArchive {}
  }

  // MARK: - Replace

  func testReplaceSwapsTheBundleAndLeavesNoLeftovers() async throws {
    let installed = folder.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let old = try makeApp(in: installed, version: "1.0")
    let new = try makeApp(in: folder, version: "2.0")
    try await Installer.replace(old, with: new)
    XCTAssertEqual(version(of: old), "2.0")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: installed.path), ["Test.app"],
      "no staging or backup copies left behind")
  }

  func testReplaceInstallsWhereNothingWasBefore() async throws {
    let target = folder.appendingPathComponent("Applications/Test.app")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await Installer.replace(target, with: try makeApp(version: "2.0"))
    XCTAssertEqual(version(of: target), "2.0")
  }

  func testSaveNeverOverwrites() throws {
    let downloads = folder.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    for i in 1...2 {
      let file = folder.appendingPathComponent("tmp\(i)")
      try Data("\(i)".utf8).write(to: file)
      _ = try Installer.save(file, into: downloads, name: "Test.zip")
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: downloads.path).sorted(),
      ["Test 2.zip", "Test.zip"])
  }

  // MARK: - Verify

  func testRejectsADifferentApp() async throws {
    let other = try makeApp(id: "com.example.other")
    do {
      try await Installer.verify(other, replacing: .fixture())
      XCTFail("expected an error")
    } catch let error as UpdateError { XCTAssertEqual(error, .wrongApp("com.example.other")) }
  }

  func testRejectsAnOlderOrSameVersion() async throws {
    for (version, build) in [("0.9", "9"), ("1.0", "1")] {
      let app = try makeApp("Old\(version)", version: version, build: build)
      do {
        try await Installer.verify(app, replacing: .fixture())
        XCTFail("expected an error for \(version)")
      } catch let error as UpdateError { XCTAssertEqual(error, .notNewer(version)) }
    }
  }

  func testSameVersionWithANewerBuildIsNewer() async throws {
    let app = try makeApp(version: "1.0", build: "2")
    do { try await Installer.verify(app, replacing: .fixture()) } catch let error as UpdateError {
      // Passes the version gate; fails on the (missing) signature instead.
      guard case .invalidSignature = error else { return XCTFail("\(error)") }
    }
  }

  func testRejectsAnUnsignedUpdate() async throws {
    let app = try makeApp()
    do {
      try await Installer.verify(app, replacing: .fixture())
      XCTFail("expected an error")
    } catch let error as UpdateError {
      guard case .invalidSignature = error else { return XCTFail("\(error)") }
    }
  }

  /// Signs a bundle with a development identity from the keychain and checks
  /// the team requirement both ways. Skipped on machines without one.
  func testAcceptsOnlyTheSameTeam() async throws {
    let identities = try await Shell.run(
      "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
    guard
      let line = identities.output.split(separator: "\n").first(where: {
        $0.contains("Apple Development") || $0.contains("Developer ID Application")
      }), let hash = line.split(separator: " ").dropFirst().first
    else { throw XCTSkip("no code-signing identity in the keychain") }
    let app = try makeApp()
    try await Shell.check(
      "/usr/bin/codesign", ["--force", "--timestamp=none", "--sign", String(hash), app.path])
    let team = try XCTUnwrap(CodeSignature.teamIdentifier(ofBundleAt: app))

    var current = AppInfo.fixture()
    current.teamIdentifier = team
    current.bundleURL = try makeApp("Current", version: "1.0")  // unsigned: Gatekeeper rejects it
    try await Installer.verify(app, replacing: current)

    current.teamIdentifier = "ZZZZZZZZZZ"
    do {
      try await Installer.verify(app, replacing: current)
      XCTFail("another team's signature must be rejected")
    } catch let error as UpdateError {
      guard case .invalidSignature = error else { return XCTFail("\(error)") }
    }

    // Tampering after signing breaks the seal.
    current.teamIdentifier = team
    try Data("x".utf8).write(to: app.appendingPathComponent("Contents/extra.txt"))
    do {
      try await Installer.verify(app, replacing: current)
      XCTFail("a modified bundle must be rejected")
    } catch let error as UpdateError {
      guard case .invalidSignature = error else { return XCTFail("\(error)") }
    }
  }

  // MARK: - Download

  func testDownloadsAFileURLWithProgress() async throws {
    let source = folder.appendingPathComponent("Test.zip")
    try Data(repeating: 7, count: 300_000).write(to: source)
    let progress = ProgressBox()
    let download = Download(into: folder.appendingPathComponent("dl")) { received, _ in
      progress.set(received)
    }
    let file = try await download.start(source)
    XCTAssertEqual(file.lastPathComponent, "Test.zip")
    XCTAssertEqual(try Data(contentsOf: file).count, 300_000)
    XCTAssertEqual(progress.value, 300_000)
  }
}

private final class ProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Int64 = 0
  var value: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }
  func set(_ v: Int64) {
    lock.lock()
    _value = v
    lock.unlock()
  }
}
#endif
