import CryptoKit
import Foundation

/// Ed25519 signatures in minisign's format (https://jedisct1.github.io/minisign/), for release files that have
/// no code signature to check: the Linux and Windows downloads, and any download a Mac copy without a team saves.
/// Only prehashed signatures ("ED": Ed25519 over the file's BLAKE2b-512) are made and accepted, and the trusted
/// comment, which the global signature covers, names the file and the version.
///
/// Dev's release signs with `sign(file:secretKey:trustedComment:)`, its key held in this Mac's keychain; apps
/// check with `verifyRelease(file:signature:publicKey:fileName:version:)` against `PublicKey.v57Release`, which is
/// built into UpdateKit. `minisign -Vm <file> -P <key>` checks the same files.
public enum Minisign {
  /// A public key: two algorithm bytes ("Ed"), the 8-byte key id and the 32-byte Ed25519 key.
  public struct PublicKey: Sendable, Equatable {
    public let keyID: Data
    public let key: Data

    /// v57's release key (id 4B34449C5FA3E909). Its secret half is in the keychain of the Mac that runs Dev's
    /// release, nowhere else.
    public static let v57Release = try! PublicKey("RWQJ6aNfnEQ0S8QbwuKNHC2GRVVtX/QBZUDBkqjl2JH1KOqlwZyVgJsF")

    /// The key from a `.pub` file's text, or its base64 line alone.
    public init(_ text: String) throws {
      guard let line = Minisign.lines(text).last(where: { !$0.hasPrefix("untrusted comment:") }),
        let data = Data(base64Encoded: line), data.count == 42, data.prefix(2) == Data("Ed".utf8)
      else { throw MinisignError.malformedKey }
      keyID = data.subdata(in: 2..<10)
      key = data.subdata(in: 10..<42)
    }

    init(keyID: Data, key: Data) {
      self.keyID = keyID
      self.key = key
    }

    /// The id as minisign prints it (hex, most significant byte first).
    public var id: String { Minisign.hex(keyID) }

    /// The `.pub` file minisign reads.
    public var text: String {
      "untrusted comment: minisign public key \(id)\n\((Data("Ed".utf8) + keyID + key).base64EncodedString())\n"
    }
  }

  /// A `.minisig` file.
  public struct Signature: Sendable, Equatable {
    public var untrustedComment: String
    public var keyID: Data
    /// Ed25519 over the file's BLAKE2b-512.
    public var signature: Data
    public var trustedComment: String
    /// Ed25519 over `signature` followed by `trustedComment`'s bytes.
    public var globalSignature: Data

    public init(_ text: String) throws {
      let lines = Minisign.lines(text)
      guard lines.count >= 4, lines[0].hasPrefix("untrusted comment:"), lines[2].hasPrefix("trusted comment: "),
        let body = Data(base64Encoded: lines[1]), body.count == 74,
        let global = Data(base64Encoded: lines[3]), global.count == 64
      else { throw MinisignError.malformedSignature }
      // "Ed" signs the file itself (minisign's legacy format): refused, so every signature covers a hash of a
      // fixed size however large the file.
      guard body.prefix(2) == Data("ED".utf8) else { throw MinisignError.unsupportedAlgorithm }
      untrustedComment = String(lines[0].dropFirst("untrusted comment:".count)).trimmingCharacters(in: .whitespaces)
      keyID = body.subdata(in: 2..<10)
      signature = body.subdata(in: 10..<74)
      trustedComment = String(lines[2].dropFirst("trusted comment: ".count))
      globalSignature = global
    }

    init(untrustedComment: String, keyID: Data, signature: Data, trustedComment: String, globalSignature: Data) {
      self.untrustedComment = untrustedComment
      self.keyID = keyID
      self.signature = signature
      self.trustedComment = trustedComment
      self.globalSignature = globalSignature
    }

    public var text: String {
      """
      untrusted comment: \(untrustedComment)
      \((Data("ED".utf8) + keyID + signature).base64EncodedString())
      trusted comment: \(trustedComment)
      \(globalSignature.base64EncodedString())

      """
    }
  }

  // MARK: - Signing

  /// The public half of a secret key given as the 8-byte key id followed by the 32-byte Ed25519 seed (the form
  /// Dev keeps in the keychain).
  public static func publicKey(secretKey: Data) throws -> PublicKey {
    let (keyID, key) = try split(secretKey)
    return PublicKey(keyID: keyID, key: key.publicKey.rawRepresentation)
  }

  /// Signs a file. `secretKey` is the key id (8 bytes) followed by the Ed25519 seed (32 bytes); the trusted
  /// comment must be one line, e.g. `releaseComment(fileName:version:)`.
  public static func sign(
    file: URL, secretKey: Data, trustedComment: String,
    untrustedComment: String = "signature from minisign secret key"
  ) throws -> Signature {
    try sign(hash: hash(file: file), secretKey: secretKey, trustedComment: trustedComment, untrustedComment: untrustedComment)
  }

  /// Signs bytes in memory, as `sign(file:…)` does a file.
  public static func sign(
    data: Data, secretKey: Data, trustedComment: String,
    untrustedComment: String = "signature from minisign secret key"
  ) throws -> Signature {
    try sign(hash: BLAKE2b.hash(data), secretKey: secretKey, trustedComment: trustedComment, untrustedComment: untrustedComment)
  }

  private static func sign(hash: Data, secretKey: Data, trustedComment: String, untrustedComment: String) throws -> Signature {
    guard !trustedComment.contains(where: \.isNewline), !untrustedComment.contains(where: \.isNewline) else {
      throw MinisignError.badTrustedComment
    }
    let (keyID, key) = try split(secretKey)
    let signature = try key.signature(for: hash)
    let global = try key.signature(for: signature + Data(trustedComment.utf8))
    return Signature(
      untrustedComment: untrustedComment, keyID: keyID, signature: signature, trustedComment: trustedComment,
      globalSignature: global)
  }

  /// The trusted comment of a release file: when it was signed, its name and the version it belongs to, which
  /// `verifyRelease` holds the download to.
  public static func releaseComment(fileName: String, version: String, date: Date = Date()) -> String {
    "timestamp:\(Int(date.timeIntervalSince1970))\tfile:\(fileName)\tversion:\(version)"
  }

  // MARK: - Verifying

  /// Checks a signature of a file and answers its trusted comment.
  @discardableResult
  public static func verify(file: URL, signature: Signature, publicKey: PublicKey) throws -> String {
    try verify(hash: hash(file: file), signature: signature, publicKey: publicKey)
  }

  @discardableResult
  public static func verify(data: Data, signature: Signature, publicKey: PublicKey) throws -> String {
    try verify(hash: BLAKE2b.hash(data), signature: signature, publicKey: publicKey)
  }

  private static func verify(hash: Data, signature: Signature, publicKey: PublicKey) throws -> String {
    guard signature.keyID == publicKey.keyID else { throw MinisignError.wrongKey(Minisign.hex(signature.keyID)) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey.key)
    guard key.isValidSignature(signature.signature, for: hash) else { throw MinisignError.badSignature }
    guard key.isValidSignature(signature.globalSignature, for: signature.signature + Data(signature.trustedComment.utf8))
    else { throw MinisignError.badTrustedComment }
    return signature.trustedComment
  }

  /// Checks a release file: a good signature by `publicKey` whose trusted comment names this very file and
  /// version, so a signed file of another app, platform or older version can't stand in for it.
  public static func verifyRelease(
    file: URL, signature: String, publicKey: PublicKey = .v57Release, fileName: String, version: String
  ) throws {
    let comment = try verify(file: file, signature: Signature(signature), publicKey: publicKey)
    var fields: [String: String] = [:]
    for field in comment.split(separator: "\t") {
      guard let colon = field.firstIndex(of: ":") else { continue }
      fields[String(field[..<colon])] = String(field[field.index(after: colon)...])
    }
    guard fields["file"] == fileName else { throw MinisignError.wrongFile(fields["file"] ?? "") }
    guard let signed = fields["version"], Version(signed) == Version(version), !signed.isEmpty else {
      throw MinisignError.wrongVersion(fields["version"] ?? "")
    }
  }

  // MARK: - Helpers

  /// BLAKE2b-512 of a file, read a megabyte at a time.
  static func hash(file: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = BLAKE2b()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
    return hasher.finalize()
  }

  private static func split(_ secretKey: Data) throws -> (Data, Curve25519.Signing.PrivateKey) {
    guard secretKey.count == 40 else { throw MinisignError.malformedKey }
    let bytes = Data(secretKey)
    return (bytes.prefix(8), try Curve25519.Signing.PrivateKey(rawRepresentation: bytes.suffix(32)))
  }

  static func lines(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  static func hex(_ keyID: Data) -> String {
    keyID.reversed().map { String(format: "%02X", $0) }.joined()
  }
}

public enum MinisignError: LocalizedError, Equatable {
  case malformedKey
  case malformedSignature
  case unsupportedAlgorithm
  case wrongKey(String)
  case badSignature
  case badTrustedComment
  case wrongFile(String)
  case wrongVersion(String)

  public var errorDescription: String? {
    switch self {
    case .malformedKey: return "The signing key is not a minisign key."
    case .malformedSignature: return "The signature file is not a minisign signature."
    case .unsupportedAlgorithm: return "The signature is in minisign's legacy format, which isn't accepted."
    case .wrongKey(let id): return "The file is signed with another key (\(id))."
    case .badSignature: return "The file doesn't match its signature: it was changed after it was signed."
    case .badTrustedComment: return "The signature's comment was changed after it was signed."
    case .wrongFile(let name): return "The signature belongs to another file (\(name))."
    case .wrongVersion(let version): return "The signature belongs to another version (\(version))."
    }
  }
}
