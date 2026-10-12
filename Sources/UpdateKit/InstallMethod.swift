import Foundation

/// How an update gets onto the disk, chosen from the app's situation.
public enum InstallMethod: Equatable, Sendable {
  /// Replace the app bundle at this URL and relaunch (the location is
  /// writable).
  case replace(URL)
  /// The same, through the macOS administrator password prompt (the
  /// location is not writable for this user).
  case replaceAsAdministrator(URL)
  /// Save the download to this folder and show it in Finder: the sandbox
  /// forbids replacing the app, or the running copy cannot be verified.
  case saveToFolder(URL)
  /// Hand the download to the browser (sandboxed without file access).
  case openInBrowser
  /// The App Store updates this copy; the updater stays off.
  case appStore

  /// The facts the choice depends on.
  public struct Context: Sendable {
    public var app: AppInfo
    public var isTranslocated: Bool
    public var isOnReadOnlyVolume: Bool
    public var canWriteBundle: Bool
    public var applicationsFolder: URL
    public var canWriteApplicationsFolder: Bool
    public var downloadsFolder: URL?

    public init(
      app: AppInfo, isTranslocated: Bool, isOnReadOnlyVolume: Bool, canWriteBundle: Bool,
      applicationsFolder: URL, canWriteApplicationsFolder: Bool, downloadsFolder: URL?
    ) {
      self.app = app
      self.isTranslocated = isTranslocated
      self.isOnReadOnlyVolume = isOnReadOnlyVolume
      self.canWriteBundle = canWriteBundle
      self.applicationsFolder = applicationsFolder
      self.canWriteApplicationsFolder = canWriteApplicationsFolder
      self.downloadsFolder = downloadsFolder
    }

    /// The running app's actual situation.
    public static func current(app: AppInfo) -> Context {
      let fm = FileManager.default
      let bundle = app.bundleURL
      let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
      return Context(
        app: app,
        // Gatekeeper runs a quarantined app that was never moved out of its
        // download folder from a randomized read-only path.
        isTranslocated: bundle.path.contains("/AppTranslocation/"),
        isOnReadOnlyVolume: (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
          .volumeIsReadOnly ?? false,
        canWriteBundle: fm.isWritableFile(atPath: bundle.path)
          && fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
        applicationsFolder: applications,
        canWriteApplicationsFolder: fm.isWritableFile(atPath: applications.path),
        downloadsFolder: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first)
    }
  }

  public static func choose(for context: Context) -> InstallMethod {
    let app = context.app
    if app.isAppStoreBuild { return .appStore }
    // The sandbox forbids writing outside the container, so the bundle can't
    // be replaced: save the download for the user to install, or let the
    // browser fetch it.
    if app.isSandboxed {
      if app.hasNetworkAccess, app.hasDownloadsAccess, let downloads = context.downloadsFolder {
        return .saveToFolder(downloads)
      }
      return .openInBrowser
    }
    // An unsigned or ad-hoc copy gives nothing to verify the download against.
    guard app.teamIdentifier != nil else {
      return context.downloadsFolder.map { .saveToFolder($0) } ?? .openInBrowser
    }
    // Running from a disk image or a translocated path: install into
    // /Applications instead, which also moves the app where it belongs.
    if context.isTranslocated || context.isOnReadOnlyVolume {
      let target = context.applicationsFolder.appendingPathComponent(
        app.bundleURL.lastPathComponent)
      return context.canWriteApplicationsFolder ? .replace(target) : .replaceAsAdministrator(target)
    }
    return context.canWriteBundle ? .replace(app.bundleURL) : .replaceAsAdministrator(app.bundleURL)
  }

  /// Installs without user file handling (the updater replaces the app).
  public var replacesApp: Bool {
    switch self {
    case .replace, .replaceAsAdministrator: return true
    default: return false
    }
  }
}
