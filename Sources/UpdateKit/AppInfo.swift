import AppKit
import Foundation
import Security

/// Everything the updater needs to know about the running app, read from
/// its bundle, code signature and entitlements: the app provides none of it.
public struct AppInfo: Sendable {
  /// Display name (CFBundleDisplayName, else CFBundleName, else the bundle's
  /// file name).
  public var name: String
  public var bundleIdentifier: String
  /// CFBundleShortVersionString, e.g. "1.2".
  public var version: String
  /// CFBundleVersion, e.g. "45".
  public var build: String
  public var bundleURL: URL
  /// Team of the code signature; nil for unsigned or ad-hoc builds, whose
  /// updates cannot be verified (they are never installed automatically).
  public var teamIdentifier: String?
  public var isSandboxed: Bool
  /// May reach the network (always, outside the sandbox).
  public var hasNetworkAccess: Bool
  /// May write to ~/Downloads (always, outside the sandbox).
  public var hasDownloadsAccess: Bool
  /// Installed by the App Store (it carries a receipt): the App Store
  /// updates it, so the updater stays off.
  public var isAppStoreBuild: Bool

  public init(
    name: String, bundleIdentifier: String, version: String, build: String, bundleURL: URL,
    teamIdentifier: String?, isSandboxed: Bool, hasNetworkAccess: Bool, hasDownloadsAccess: Bool,
    isAppStoreBuild: Bool
  ) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.version = version
    self.build = build
    self.bundleURL = bundleURL
    self.teamIdentifier = teamIdentifier
    self.isSandboxed = isSandboxed
    self.hasNetworkAccess = hasNetworkAccess
    self.hasDownloadsAccess = hasDownloadsAccess
    self.isAppStoreBuild = isAppStoreBuild
  }

  /// The running app.
  public static func current(bundle: Bundle = .main) -> AppInfo {
    let info = bundle.infoDictionary ?? [:]
    let name =
      info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
      ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
    let sandboxed =
      Entitlements.bool("com.apple.security.app-sandbox")
      ?? (ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
    let receipt = bundle.appStoreReceiptURL.map { FileManager.default.fileExists(atPath: $0.path) }
    return AppInfo(
      name: name, bundleIdentifier: bundle.bundleIdentifier ?? "",
      version: info["CFBundleShortVersionString"] as? String ?? "0",
      build: info["CFBundleVersion"] as? String ?? "0", bundleURL: bundle.bundleURL,
      teamIdentifier: CodeSignature.teamIdentifierOfRunningApp(), isSandboxed: sandboxed,
      hasNetworkAccess: !sandboxed
        || Entitlements.bool("com.apple.security.network.client") == true,
      hasDownloadsAccess: !sandboxed
        || Entitlements.bool("com.apple.security.files.downloads.read-write") == true,
      isAppStoreBuild: receipt ?? false)
  }

  /// The app icon, for the update window.
  @MainActor public var icon: NSImage { NSWorkspace.shared.icon(forFile: bundleURL.path) }
}

/// Entitlements of the running process.
enum Entitlements {
  static func bool(_ name: String) -> Bool? {
    guard let task = SecTaskCreateFromSelf(nil) else { return nil }
    return SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? Bool
  }
}
