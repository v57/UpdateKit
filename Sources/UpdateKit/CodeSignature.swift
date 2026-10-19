#if os(macOS)
import Foundation
import Security

/// Code-signature checks for downloaded updates.
enum CodeSignature {
  /// Team identifier of the running app's signature; nil when unsigned or
  /// ad-hoc signed.
  static func teamIdentifierOfRunningApp() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
    else { return nil }
    return teamIdentifier(of: staticCode)
  }

  static func teamIdentifier(ofBundleAt url: URL) -> String? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }
    return teamIdentifier(of: staticCode)
  }

  private static func teamIdentifier(of code: SecStaticCode) -> String? {
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
  }

  /// The requirement a genuine update must satisfy: same bundle identifier,
  /// signed by an Apple-issued certificate of the same team.
  static func requirement(identifier: String, team: String) -> String {
    "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
  }

  /// Validates the whole bundle (every architecture, nested code, strict)
  /// against `requirement(identifier:team:)`.
  static func validate(bundleAt url: URL, identifier: String, team: String) throws {
    var staticCode: SecStaticCode?
    var req: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode,
      SecRequirementCreateWithString(
        requirement(identifier: identifier, team: team) as CFString, [], &req) == errSecSuccess,
      let req
    else { throw UpdateError.invalidSignature("The update's signature could not be read.") }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    var error: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, req, &error)
    guard status == errSecSuccess else {
      _ = error?.takeRetainedValue()
      throw UpdateError.invalidSignature(reason(for: status))
    }
  }

  /// Plain words for the usual failures; the code for the rest.
  static func reason(for status: OSStatus) -> String {
    switch status {
    case errSecCSUnsigned: return "it is not signed."
    case errSecCSReqFailed: return "it is signed by a different developer."
    case errSecCSSignatureFailed, errSecCSInfoPlistFailed, errSecCSBadResource,
      errSecCSResourcesNotSealed, errSecCSResourcesInvalid, errSecCSResourceDirectoryFailed,
      errSecCSBadMainExecutable:
      return "it was modified after it was signed."
    default: return "code signing error \(status)."
    }
  }

  /// Whether Gatekeeper would let the app run (Developer ID + notarization).
  static func gatekeeperAccepts(_ url: URL) async -> Bool {
    let result = try? await Shell.run(
      "/usr/sbin/spctl", ["--assess", "--type", "execute", url.path])
    return result?.status == 0
  }
}
#endif
