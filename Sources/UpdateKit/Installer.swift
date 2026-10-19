import Foundation

#if os(macOS)
  import AppKit
#endif
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Download -> extract -> verify -> install -> relaunch.
enum Installer {
  #if os(macOS)
  // MARK: - Extract

  /// The .app inside a .zip or .dmg, copied into `folder`.
  static func extractApp(from archive: URL, into folder: URL) async throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    switch archive.pathExtension.lowercased() {
    case "zip":
      // ditto keeps the code signature intact (symlinks, extended attributes).
      try await Shell.check("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
      return try findApp(in: folder)
    case "dmg":
      let mount = folder.appendingPathComponent("mount", isDirectory: true)
      try fm.createDirectory(at: mount, withIntermediateDirectories: true)
      try await Shell.check(
        "/usr/bin/hdiutil",
        [
          "attach", archive.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint",
          mount.path,
        ])
      defer {
        Task.detached {
          _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        }
      }
      let app = try findApp(in: mount)
      let copy = folder.appendingPathComponent(app.lastPathComponent)
      try await Shell.check("/usr/bin/ditto", [app.path, copy.path])
      return copy
    default:
      throw UpdateError.invalidArchive("Unsupported file type: \(archive.lastPathComponent).")
    }
  }

  /// The first .app at the top level of `folder` or one level below.
  static func findApp(in folder: URL) throws -> URL {
    let fm = FileManager.default
    let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    if let app = top.first(where: { $0.pathExtension == "app" }) { return app }
    for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    {
      let inner = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
      if let app = inner.first(where: { $0.pathExtension == "app" }) { return app }
    }
    throw UpdateError.invalidArchive("No app inside.")
  }

  // MARK: - Verify

  /// A download may replace the running app only if it is the same app
  /// (bundle identifier), newer, signed by the same team, and — when the
  /// running copy passes Gatekeeper — passes Gatekeeper too (notarized).
  static func verify(_ newApp: URL, replacing app: AppInfo) async throws {
    guard let bundle = Bundle(url: newApp), let info = bundle.infoDictionary else {
      throw UpdateError.invalidArchive("The app has no Info.plist.")
    }
    let identifier = bundle.bundleIdentifier ?? ""
    guard identifier == app.bundleIdentifier else { throw UpdateError.wrongApp(identifier) }
    let version = info["CFBundleShortVersionString"] as? String ?? "0"
    let build = info["CFBundleVersion"] as? String ?? "0"
    let newer =
      Version(version) > Version(app.version)
      || (Version(version) == Version(app.version) && Version(build) > Version(app.build))
    guard newer else { throw UpdateError.notNewer(version) }
    guard let team = app.teamIdentifier else {
      throw UpdateError.invalidSignature("this copy of \(app.name) is not signed by a team.")
    }
    try CodeSignature.validate(bundleAt: newApp, identifier: identifier, team: team)
    if await CodeSignature.gatekeeperAccepts(app.bundleURL) {
      guard await CodeSignature.gatekeeperAccepts(newApp) else { throw UpdateError.notNotarized }
    }
  }

  // MARK: - Install

  /// Moves `newApp` to `target`, replacing what is there. The new copy is
  /// staged next to the target first (same volume, so the swap is two
  /// renames), and the old app is restored if the swap fails.
  static func replace(_ target: URL, with newApp: URL) async throws {
    let fm = FileManager.default
    let parent = target.deletingLastPathComponent()
    let id = UUID().uuidString.prefix(8)
    let stage = parent.appendingPathComponent(".\(target.lastPathComponent)-update-\(id)")
    let backup = parent.appendingPathComponent(".\(target.lastPathComponent)-old-\(id)")
    try await Shell.check("/usr/bin/ditto", [newApp.path, stage.path])
    let hadOld = fm.fileExists(atPath: target.path)
    do {
      if hadOld { try fm.moveItem(at: target, to: backup) }
      do { try fm.moveItem(at: stage, to: target) } catch {
        if hadOld { try? fm.moveItem(at: backup, to: target) }
        throw error
      }
    } catch {
      try? fm.removeItem(at: stage)
      throw UpdateError.installFailed(error.localizedDescription)
    }
    if hadOld { try? fm.removeItem(at: backup) }
  }

  /// `replace(_:with:)` as root, through the macOS administrator prompt.
  /// Keeps the old app's owner. Throws `.cancelled` when the user cancels.
  static func replaceAsAdministrator(_ target: URL, with newApp: URL) async throws {
    let parent = target.deletingLastPathComponent()
    let id = UUID().uuidString.prefix(8)
    let stage = parent.appendingPathComponent(".\(target.lastPathComponent)-update-\(id)").path
    let backup = parent.appendingPathComponent(".\(target.lastPathComponent)-old-\(id)").path
    let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
    let owner = (attributes?[.ownerAccountID] as? NSNumber)?.intValue ?? Int(getuid())
    let group = (attributes?[.groupOwnerAccountID] as? NSNumber)?.intValue ?? Int(getgid())
    let q = Shell.quote
    let script = [
      "set -e", "/usr/bin/ditto \(q(newApp.path)) \(q(stage))",
      "/usr/sbin/chown -R \(owner):\(group) \(q(stage))",
      "if [ -e \(q(target.path)) ]; then /bin/mv \(q(target.path)) \(q(backup)); fi",
      "/bin/mv \(q(stage)) \(q(target.path)) || { /bin/mv \(q(backup)) \(q(target.path)); exit 1; }",
      "/bin/rm -rf \(q(backup))",
    ].joined(separator: "\n")
    let result = try await Shell.run(
      "/usr/bin/osascript",
      ["-e", "do shell script \(Shell.appleScriptString(script)) with administrator privileges"])
    if result.status != 0 {
      if result.output.contains("-128") { throw UpdateError.cancelled }
      throw UpdateError.installFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  #endif

  /// Moves the downloaded archive into `folder` (unique name) and returns
  /// where it landed.
  static func save(_ archive: URL, into folder: URL, name: String) throws -> URL {
    let fm = FileManager.default
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var target = folder.appendingPathComponent(name)
    var n = 2
    while fm.fileExists(atPath: target.path) {
      target = folder.appendingPathComponent("\(base) \(n).\(ext)")
      n += 1
    }
    try fm.moveItem(at: archive, to: target)
    return target
  }

  #if os(macOS)
  // MARK: - Relaunch

  /// Opens `app` once this process has exited, then quits. A detached shell
  /// waits up to 30 s for the exit; if the app refuses to quit, the new
  /// version simply starts next time.
  @MainActor static func relaunch(_ app: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      """
      i=0
      while /bin/kill -0 "$1" 2>/dev/null && [ $i -lt 300 ]; do /bin/sleep 0.1; i=$((i+1)); done
      /bin/kill -0 "$1" 2>/dev/null || /usr/bin/open "$2"
      """, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path,
    ]
    try? process.run()
    NSApp.terminate(nil)
  }
  #endif
}

// MARK: - Download

/// One download with progress, cancellable.
final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, Error>?
  private var finishedFile: URL?
  private var moveError: Error?
  private var task: URLSessionDownloadTask?
  private let folder: URL
  private let progress: @Sendable (Int64, Int64?) -> Void

  init(into folder: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
    self.folder = folder
    self.progress = progress
  }

  func start(_ url: URL) async throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        self.continuation = continuation
        let task = session.downloadTask(with: url)
        self.task = task
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() {
    lock.lock()
    let task = task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) { progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil) }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // The temporary file is deleted when this returns: move it now.
    let name =
      downloadTask.response?.suggestedFilename ?? downloadTask.originalRequest?.url?
      .lastPathComponent ?? "update.zip"
    let target = folder.appendingPathComponent(name)
    lock.lock()
    defer { lock.unlock() }
    if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
      moveError = UpdateError.server("HTTP \(status)")
      return
    }
    do {
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: location, to: target)
      finishedFile = target
    } catch { moveError = error }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    let file = finishedFile
    let moveError = moveError
    lock.unlock()
    if let error = error as? URLError, error.code == .cancelled {
      continuation?.resume(throwing: UpdateError.cancelled)
    } else if let error = error ?? moveError {
      continuation?.resume(throwing: error)
    } else if let file {
      continuation?.resume(returning: file)
    } else {
      continuation?.resume(throwing: UpdateError.noDownload)
    }
  }
}
