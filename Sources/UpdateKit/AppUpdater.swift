import Combine
import Foundation

/// Checks for new versions of the running app, shows the update window and
/// installs the update the way the app's situation allows (InstallMethod):
/// in place with a relaunch, through the administrator prompt, into
/// Downloads for a sandboxed app, or through the browser.
///
///     let updater = AppUpdater(github: "v57/Player")
///     updater.start()                       // daily checks, once the user turns them on
///     // SwiftUI: .commands { UpdaterCommands(updater: updater) }
///     // AppKit: a menu item with action #selector(AppUpdater.checkForUpdates(_:))
///
/// Everything else (name, version, icon, signing team, sandbox, App Store)
/// is read from the app. `APP_UPDATER_FEED=<url>` swaps the source for a
/// JSONFeed (testing); `APP_UPDATER_DISABLED=1` turns the updater off.
@MainActor public final class AppUpdater: NSObject, ObservableObject {
  public struct Configuration: Sendable {
    /// Time between background checks.
    public var checkInterval: TimeInterval = 24 * 60 * 60
    /// Offer pre-releases too.
    public var includesPrereleases = false
    public init() {}
  }

  public enum Phase: Equatable {
    case idle
    case checking(userInitiated: Bool)
    /// A user-initiated check found nothing newer.
    case upToDate
    case updateAvailable(AppRelease)
    case downloading(AppRelease, received: Int64, expected: Int64?)
    case verifying(AppRelease)
    case readyToInstall(AppRelease)
    case installing(AppRelease)
    /// Saved to a folder for the user to install (sandboxed apps).
    case saved(AppRelease, file: URL)
    case failed(AppRelease?, message: String)
  }

  public let app: AppInfo
  public let source: UpdateSource
  public let configuration: Configuration
  /// How updates get installed in this app's situation.
  public let installMethod: InstallMethod

  @Published public private(set) var phase: Phase = .idle

  /// The updater does anything at all: not an App Store build, not disabled.
  public var isEnabled: Bool {
    installMethod != .appStore && ProcessInfo.processInfo.environment["APP_UPDATER_DISABLED"] != "1"
  }

  /// Background checks; persisted, shown as a menu toggle and in the update
  /// window. Off until the user turns them on: an app never contacts the
  /// update server without the user asking, so there is deliberately no
  /// way to start with them on.
  @Published public var automaticallyChecksForUpdates: Bool {
    didSet { defaults.set(automaticallyChecksForUpdates, forKey: Keys.automatic) }
  }

  public var lastCheckDate: Date? { defaults.object(forKey: Keys.lastCheck) as? Date }

  /// A check or an install is running.
  public var isBusy: Bool {
    switch phase {
    case .checking, .downloading, .verifying, .installing: return true
    default: return false
    }
  }

  private enum Keys {
    static let automatic = "AppUpdater.automaticChecks"
    static let lastCheck = "AppUpdater.lastCheck"
    static let skipped = "AppUpdater.skippedVersion"
  }

  private let defaults: UserDefaults
  private var timer: Timer?
  private var work: Task<Void, Never>?
  private var download: Download?
  private var newApp: URL?
  private lazy var window = UpdateWindowController(updater: self)

  public init(
    source: UpdateSource, configuration: Configuration = Configuration(), app: AppInfo = .current(),
    defaults: UserDefaults = .standard
  ) {
    self.app = app
    self.configuration = configuration
    self.defaults = defaults
    if let feed = ProcessInfo.processInfo.environment["APP_UPDATER_FEED"],
      let url = URL(string: feed), url.scheme != nil
    {
      self.source = JSONFeed(url)
    } else {
      self.source = source
    }
    installMethod = InstallMethod.choose(for: .current(app: app))
    automaticallyChecksForUpdates = defaults.bool(forKey: Keys.automatic)
    super.init()
  }

  /// Releases of a GitHub repository, "owner/name".
  public convenience init(
    github repository: String, assetName: String? = nil,
    configuration: Configuration = Configuration()
  ) {
    self.init(
      source: GitHubReleases(repository, assetName: assetName), configuration: configuration)
  }

  // MARK: - Checking

  /// Starts background checks, which only run once the user has turned on
  /// `automaticallyChecksForUpdates`: one at launch if due, then whenever due
  /// while the app runs. Call once, e.g. from the App's init or
  /// applicationDidFinishLaunching (the first check waits for the run loop).
  public func start() {
    guard isEnabled, timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkInBackgroundIfDue() }
    }
    DispatchQueue.main.async { [weak self] in self?.checkInBackgroundIfDue() }
  }

  private func checkInBackgroundIfDue() {
    guard automaticallyChecksForUpdates, !isBusy, window.isVisible == false else { return }
    let last = lastCheckDate ?? .distantPast
    guard Date().timeIntervalSince(last) >= configuration.checkInterval else { return }
    check(userInitiated: false)
  }

  /// "Check for Updates…": shows the result, including "up to date". When
  /// the app cannot check by itself (sandboxed without network access) it
  /// opens the releases page instead.
  #if canImport(ObjectiveC)
    @objc public func checkForUpdates(_ sender: Any? = nil) { checkNow() }
  #else
    public func checkForUpdates(_ sender: Any? = nil) { checkNow() }
  #endif

  private func checkNow() {
    guard isEnabled else { return }
    if case .checking(userInitiated: false) = phase { return }  // finishing in the background
    guard phase == .idle else { return window.show(activate: true) }
    guard app.hasNetworkAccess else {
      if let page = source.releasesPageURL { Desktop.open(page) }
      return
    }
    check(userInitiated: true)
  }

  private func check(userInitiated: Bool) {
    phase = .checking(userInitiated: userInitiated)
    if userInitiated { window.show(activate: true) }
    work = Task {
      do {
        let release = try await source.latestRelease(
          for: app, includePrereleases: configuration.includesPrereleases)
        defaults.set(Date(), forKey: Keys.lastCheck)
        guard let release, isNewer(release) else {
          phase = userInitiated ? .upToDate : .idle
          return
        }
        if !userInitiated, defaults.string(forKey: Keys.skipped) == release.version {
          phase = .idle
          return
        }
        phase = .updateAvailable(release)
        window.show(activate: userInitiated)
      } catch { phase = userInitiated ? .failed(nil, message: error.localizedDescription) : .idle }
    }
  }

  private func isNewer(_ release: AppRelease) -> Bool {
    Version(release.version) > Version(app.version)
  }

  // MARK: - Window actions

  func skip(_ release: AppRelease) {
    defaults.set(release.version, forKey: Keys.skipped)
    close()
  }

  /// Closes the window; the next background check asks again.
  func close() {
    window.close()
    windowClosed()
  }

  /// The window went away (button or close box): stop whatever runs, unless
  /// the app is being replaced.
  func windowClosed() {
    if case .installing = phase { return }
    work?.cancel()
    download?.cancel()
    phase = .idle
  }

  /// Downloads the release, then verifies (in-place installs) or saves it.
  func install(_ release: AppRelease) {
    switch installMethod {
    case .openInBrowser, .appStore:
      Desktop.open(release.downloadURL)
      close()
      return
    default: break
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppUpdater-\(UUID().uuidString)", isDirectory: true)
    let download = Download(into: folder) { [weak self] received, expected in
      Task { @MainActor in
        guard let self, case .downloading(let r, _, _) = self.phase else { return }
        self.phase = .downloading(r, received: received, expected: expected ?? r.downloadSize)
      }
    }
    self.download = download
    phase = .downloading(release, received: 0, expected: release.downloadSize)
    work = Task {
      do {
        let archive = try await download.start(release.downloadURL)
        switch installMethod {
        case .saveToFolder(let target):
          let file = try Installer.save(
            archive, into: target, name: release.downloadURL.lastPathComponent)
          phase = .saved(release, file: file)
          Desktop.reveal(file)
        default:
          #if os(macOS)
            phase = .verifying(release)
            let app = try await Installer.extractApp(
              from: archive, into: folder.appendingPathComponent("extracted"))
            try await Installer.verify(app, replacing: self.app)
            newApp = app
            phase = .readyToInstall(release)
          #else
            phase = .failed(release, message: "This copy can't install updates by itself.")
          #endif
        }
      } catch UpdateError.cancelled {
        if case .downloading = phase { phase = .updateAvailable(release) }
      } catch { phase = .failed(release, message: error.localizedDescription) }
    }
  }

  /// Replaces the app and relaunches.
  func installAndRelaunch(_ release: AppRelease) {
    #if os(macOS)
    guard let newApp else { return }
    phase = .installing(release)
    work = Task {
      do {
        let target: URL
        switch installMethod {
        case .replace(let url):
          target = url
          try checkTarget(url)
          try await Installer.replace(url, with: newApp)
        case .replaceAsAdministrator(let url):
          target = url
          try checkTarget(url)
          try await Installer.replaceAsAdministrator(url, with: newApp)
        default: return
        }
        Installer.relaunch(target)
      } catch UpdateError.cancelled { phase = .readyToInstall(release) } catch {
        phase = .failed(release, message: error.localizedDescription)
      }
    }
    #endif
  }

  /// Installing into /Applications must not overwrite a different app that
  /// happens to have the same name.
  private func checkTarget(_ url: URL) throws {
    guard url != app.bundleURL, FileManager.default.fileExists(atPath: url.path) else { return }
    let existing = Bundle(url: url)?.bundleIdentifier ?? ""
    guard existing == app.bundleIdentifier else {
      throw UpdateError.installFailed("\(url.path) is a different app (\(existing)).")
    }
  }

  /// Opens the release page or the download in the browser.
  func downloadManually(_ release: AppRelease?) {
    if let url = release?.pageURL ?? release?.downloadURL ?? source.releasesPageURL {
      Desktop.open(url)
    }
    close()
  }
}
