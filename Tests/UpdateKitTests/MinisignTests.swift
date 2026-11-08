import Foundation
import XCTest

@testable import UpdateKit

final class BLAKE2bTests: XCTestCase {
  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  /// RFC 7693 Appendix A, and the empty input.
  func testRFCVectors() {
    XCTAssertEqual(
      hex(BLAKE2b.hash(Data("abc".utf8))),
      "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
    )
    XCTAssertEqual(
      hex(BLAKE2b.hash(Data())),
      "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
    )
  }

  /// Around the 128-byte block boundary, against Python's hashlib.blake2b, fed whole and in odd pieces.
  func testBlockBoundaries() {
    let expected: [Int: String] = [
      127: "b6292669ccd38d5f01caae96ba272c76a879a45743afa0725d83b9ebb26665b731f1848c52f11972b6644f554c064fa90780dbbbf3a89d4fc31f67df3e5857ef",
      128: "2319e3789c47e2daa5fe807f61bec2a1a6537fa03f19ff32e87eecbfd64b7e0e8ccff439ac333b040f19b0c4ddd11a61e24ac1fe0f10a039806c5dcc0da3d115",
      129: "f59711d44a031d5f97a9413c065d1e614c417ede998590325f49bad2fd444d3e4418be19aec4e11449ac1a57207898bc57d76a1bcf3566292c20c683a5c4648f",
      255: "fe2c02da499516b0e9fb2dd70c49eb3629039f632e20a880946fb7bc97a7ab09deb7d48774d7f0648141c9d9ede19ae6e0dbf07863a128cf4b00195f0f179f74",
      256: "93463ac058b6163eb43be3f5bb32b28541498f4e3366f1effe253ad44e1e076e41c3616046027c82a7124f8f4746668ad10b12e8e25a95ac8f3151df01cd5a93",
      1000: "c11e1c0340bd7e5a1b275f1230c962fad215ecb1391486e74e31b960a2f2996381a5fad092da06841d5f26e38f6ecfeaf441acbcd1c2de61aef121e7927175f5",
    ]
    for (count, digest) in expected {
      let data = Data((0..<count).map { UInt8($0 % 251) })
      XCTAssertEqual(hex(BLAKE2b.hash(data)), digest, "\(count) bytes")
      var hasher = BLAKE2b()
      var rest = data[...]
      var piece = 1
      while !rest.isEmpty {
        hasher.update(rest.prefix(piece))
        rest = rest.dropFirst(piece)
        piece = piece * 3 + 1
      }
      XCTAssertEqual(hex(hasher.finalize()), digest, "\(count) bytes in pieces")
    }
  }
}

final class MinisignTests: XCTestCase {
  /// A test key (key id 0807060504030201, seed 0x11…): never the release key.
  static let secretKey = Data([1, 2, 3, 4, 5, 6, 7, 8] + [UInt8](repeating: 0x11, count: 32))
  static var publicKey: Minisign.PublicKey { try! Minisign.publicKey(secretKey: secretKey) }

  /// Made with the minisign 0.12 command line and a throwaway key (`minisign -G -W`, `minisign -S -t …`).
  static let cliKey = """
    untrusted comment: minisign public key 3E870092C3F40DC9
    RWTJDfTDkgCHPggHket4c1DqeVkwucZmDMzbj5kia0JcCGM0hYf9P4Lh
    """
  static let cliFile = Data("hello from v57\n".utf8)
  static let cliSignature = """
    untrusted comment: signature from minisign secret key
    RUTJDfTDkgCHPtZ9Yk6HjqgpcR+iZYEWDSxTqYWCW00vQqNGBqWnU6T6RD7TMPX1FkS3fweY4/pwwenqt2NRkqAnJOJumkZukws=
    trusted comment: timestamp:1762560000\tfile:Hello-Linux-x64.tar.gz\tversion:1.2
    +jUsEY89g0iJn+sqhcscZ2UTwCPgCH06NflbqihjYvfXdgc9SC1m9wJtBTT9L5JV9lHbRsWAGFZ2HF2Q+NFNAw==

    """

  private var folder: URL!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("MinisignTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

  private func write(_ data: Data, _ name: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  func testTheBuiltInKeyIsV57sReleaseKey() {
    XCTAssertEqual(Minisign.PublicKey.v57Release.id, "4B34449C5FA3E909")
  }

  func testVerifiesTheCommandLinesSignature() throws {
    let key = try Minisign.PublicKey(Self.cliKey)
    XCTAssertEqual(key.id, "3E870092C3F40DC9")
    let file = try write(Self.cliFile, "Hello-Linux-x64.tar.gz")
    try Minisign.verifyRelease(
      file: file, signature: Self.cliSignature, publicKey: key, fileName: "Hello-Linux-x64.tar.gz", version: "v1.2")
  }

  func testSignsAndVerifiesARelease() throws {
    let file = try write(Data(repeating: 9, count: 3_000_000), "App-Windows-x64.zip")
    let comment = Minisign.releaseComment(fileName: "App-Windows-x64.zip", version: "0.1.0")
    let signature = try Minisign.sign(file: file, secretKey: Self.secretKey, trustedComment: comment)
    // The text round-trips, and it is what a .minisig file holds.
    XCTAssertEqual(try Minisign.Signature(signature.text), signature)
    try Minisign.verifyRelease(
      file: file, signature: signature.text, publicKey: Self.publicKey, fileName: "App-Windows-x64.zip",
      version: "0.1.0")
  }

  /// minisign's own command line accepts what `sign` makes (skipped without it: `brew install minisign`).
  func testTheCommandLineAcceptsOurSignature() throws {
    #if os(macOS)
      let cli = ["/opt/homebrew/bin/minisign", "/usr/local/bin/minisign"].first {
        FileManager.default.isExecutableFile(atPath: $0)
      }
      guard let cli else { throw XCTSkip("no minisign command line") }
      let file = try write(Data("an asset".utf8), "Asset.tar.gz")
      let signature = try Minisign.sign(
        file: file, secretKey: Self.secretKey,
        trustedComment: Minisign.releaseComment(fileName: "Asset.tar.gz", version: "2.0"))
      try signature.text.write(to: file.appendingPathExtension("minisig"), atomically: true, encoding: .utf8)
      let key = try write(Data(Self.publicKey.text.utf8), "test.pub")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: cli)
      process.arguments = ["-V", "-q", "-m", file.path, "-p", key.path]
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
    #else
      throw XCTSkip("checked on the Mac")
    #endif
  }

  func testRefusesAChangedFile() throws {
    let comment = Minisign.releaseComment(fileName: "App.zip", version: "1.0")
    let signature = try Minisign.sign(data: Data("original".utf8), secretKey: Self.secretKey, trustedComment: comment)
    let file = try write(Data("changed!".utf8), "App.zip")
    XCTAssertThrowsError(
      try Minisign.verifyRelease(
        file: file, signature: signature.text, publicKey: Self.publicKey, fileName: "App.zip", version: "1.0")
    ) { XCTAssertEqual($0 as? MinisignError, .badSignature) }
  }

  func testRefusesAChangedTrustedComment() throws {
    let data = Data("asset".utf8)
    var signature = try Minisign.sign(
      data: data, secretKey: Self.secretKey,
      trustedComment: Minisign.releaseComment(fileName: "App.zip", version: "1.0"))
    signature.trustedComment = signature.trustedComment.replacingOccurrences(of: "version:1.0", with: "version:9.0")
    XCTAssertThrowsError(try Minisign.verify(data: data, signature: signature, publicKey: Self.publicKey)) {
      XCTAssertEqual($0 as? MinisignError, .badTrustedComment)
    }
  }

  func testRefusesAnotherKey() throws {
    let file = try write(Self.cliFile, "Hello-Linux-x64.tar.gz")
    XCTAssertThrowsError(
      try Minisign.verifyRelease(
        file: file, signature: Self.cliSignature, publicKey: Self.publicKey, fileName: "Hello-Linux-x64.tar.gz",
        version: "1.2")
    ) { XCTAssertEqual($0 as? MinisignError, .wrongKey("3E870092C3F40DC9")) }
  }

  /// A good signature of another file or version (an older release, another app or platform) doesn't pass.
  func testHoldsTheSignatureToItsFileAndVersion() throws {
    let file = try write(Self.cliFile, "Hello-Linux-x64.tar.gz")
    let key = try Minisign.PublicKey(Self.cliKey)
    XCTAssertThrowsError(
      try Minisign.verifyRelease(
        file: file, signature: Self.cliSignature, publicKey: key, fileName: "Other-Linux-x64.tar.gz", version: "1.2")
    ) { XCTAssertEqual($0 as? MinisignError, .wrongFile("Hello-Linux-x64.tar.gz")) }
    XCTAssertThrowsError(
      try Minisign.verifyRelease(
        file: file, signature: Self.cliSignature, publicKey: key, fileName: "Hello-Linux-x64.tar.gz", version: "1.3")
    ) { XCTAssertEqual($0 as? MinisignError, .wrongVersion("1.2")) }
  }

  /// minisign's legacy "Ed" signatures (over the whole file) are refused.
  func testRefusesLegacySignatures() throws {
    var lines = Self.cliSignature.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var body = try XCTUnwrap(Data(base64Encoded: lines[1]))
    body.replaceSubrange(0..<2, with: Data("Ed".utf8))
    lines[1] = body.base64EncodedString()
    XCTAssertThrowsError(try Minisign.Signature(lines.joined(separator: "\n"))) {
      XCTAssertEqual($0 as? MinisignError, .unsupportedAlgorithm)
    }
  }

  // MARK: - Updates

  /// A release whose file was swapped after signing is refused, and nothing is kept: not in the folder it would
  /// be saved to, not in the download's temporary folder.
  @MainActor func testAChangedDownloadIsNeverSaved() async throws {
    let release = folder.appendingPathComponent("release")
    try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
    let asset = release.appendingPathComponent("Test-Linux-x64.tar.gz")
    let signature = try Minisign.sign(
      data: Data("the real build".utf8), secretKey: Self.secretKey,
      trustedComment: Minisign.releaseComment(fileName: asset.lastPathComponent, version: "2.0"))
    try signature.text.write(to: asset.appendingPathExtension("minisig"), atomically: true, encoding: .utf8)
    try Data("a swapped build".utf8).write(to: asset)

    let downloads = folder.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let suite = "UpdateKitTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var app = AppInfo.fixture()
    app.teamIdentifier = nil
    let updater = AppUpdater(
      source: JSONFeed(URL(fileURLWithPath: "/dev/null")), app: app, defaults: defaults, accent: nil,
      releaseKey: Self.publicKey, installMethod: .saveToFolder(downloads))
    XCTAssertTrue(updater.requiresReleaseSignature)
    let update = AppRelease(
      version: "2.0", downloadURL: asset, signatureURL: asset.appendingPathExtension("minisig"))
    updater.install(update)
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if case .failed(_, let message) = updater.phase {
        XCTAssertTrue(message.contains("changed after it was signed"), message)
        break
      }
      if case .saved = updater.phase { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard case .failed = updater.phase else { return XCTFail("expected a refusal, got \(updater.phase)") }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [])
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
      .filter { $0.hasPrefix("AppUpdater-") }
      .filter {
        FileManager.default.fileExists(
          atPath: FileManager.default.temporaryDirectory.appendingPathComponent($0)
            .appendingPathComponent("Test-Linux-x64.tar.gz").path)
      }
    XCTAssertEqual(leftovers, [])
  }

  /// The good file passes the same check.
  func testTheSignedDownloadPasses() async throws {
    let asset = try write(Data("the real build".utf8), "Test-Linux-x64.tar.gz")
    let signature = try Minisign.sign(
      file: asset, secretKey: Self.secretKey,
      trustedComment: Minisign.releaseComment(fileName: asset.lastPathComponent, version: "2.0"))
    let signatureURL = asset.appendingPathExtension("minisig")
    try signature.text.write(to: signatureURL, atomically: true, encoding: .utf8)
    try await AppUpdater.checkSignature(
      of: asset, release: AppRelease(version: "v2.0", downloadURL: asset), signatureURL: signatureURL,
      key: Self.publicKey)
  }

  func testGitHubReleasesFindTheSignature() throws {
    let json = """
      {"tag_name": "v1.1", "draft": false, "prerelease": false,
       "html_url": "https://github.com/v57/Shell/releases/tag/v1.1",
       "assets": [
         {"name": "Shell-Linux-x64.tar.gz", "size": 10, "browser_download_url": "https://x/Shell-Linux-x64.tar.gz"},
         {"name": "Shell-Linux-x64.tar.gz.minisig", "size": 1, "browser_download_url": "https://x/sig"}]}
      """
    let release = try JSONDecoder().decode(GitHubReleases.Release.self, from: Data(json.utf8))
    let app = try GitHubReleases.appRelease(from: release, appName: "Shell", assetName: "Shell-Linux-x64.tar.gz")
    XCTAssertEqual(app.signatureURL?.absoluteString, "https://x/sig")
    XCTAssertEqual(app.assetName, "Shell-Linux-x64.tar.gz")
  }
}
