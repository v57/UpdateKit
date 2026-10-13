import Foundation

/// A published version of the app.
public struct AppRelease: Equatable, Sendable {
  /// Version without a leading "v", e.g. "1.2".
  public var version: String
  public var title: String?
  /// Release notes, Markdown.
  public var notes: String?
  /// Web page for the release (release notes, manual download).
  public var pageURL: URL?
  /// The archive to install: a .zip (recommended) or .dmg holding the .app.
  public var downloadURL: URL
  public var downloadSize: Int64?
  public var date: Date?

  public init(
    version: String, title: String? = nil, notes: String? = nil, pageURL: URL? = nil,
    downloadURL: URL, downloadSize: Int64? = nil, date: Date? = nil
  ) {
    self.version = Version(version).description
    self.title = title
    self.notes = notes
    self.pageURL = pageURL
    self.downloadURL = downloadURL
    self.downloadSize = downloadSize
    self.date = date
  }
}

/// Where releases are published.
public protocol UpdateSource: Sendable {
  /// The newest release, or nil when nothing is published yet.
  func latestRelease(for app: AppInfo, includePrereleases: Bool) async throws -> AppRelease?
  /// Page listing the releases (opened when the app cannot check by itself).
  var releasesPageURL: URL? { get }
}

public enum UpdateError: LocalizedError, Equatable {
  case server(String)
  case noDownload
  case invalidArchive(String)
  case wrongApp(String)
  case notNewer(String)
  case invalidSignature(String)
  case notNotarized
  case installFailed(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .server(let message): return "The update server answered: \(message)"
    case .noDownload: return "The release has no downloadable app."
    case .invalidArchive(let message): return "The download is not a valid app archive. \(message)"
    case .wrongApp(let id): return "The download contains a different app (\(id))."
    case .notNewer(let version):
      return "The download is version \(version), not newer than this one."
    case .invalidSignature(let reason): return "The update can't be trusted: \(reason)"
    case .notNotarized: return "macOS Gatekeeper rejected the update (not notarized)."
    case .installFailed(let message): return "The update could not be installed. \(message)"
    case .cancelled: return "Cancelled."
    }
  }
}

// MARK: - GitHub Releases

/// Releases of a GitHub repository. The asset is `assetName`, or else the
/// .zip (then .dmg) whose name best matches the app.
public struct GitHubReleases: UpdateSource {
  public var owner: String
  public var repository: String
  public var assetName: String?

  /// `repository` as "owner/name".
  public init(_ repository: String, assetName: String? = nil) {
    let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
    owner = parts.first ?? ""
    self.repository = parts.count > 1 ? parts[1] : ""
    self.assetName = assetName
  }

  public var releasesPageURL: URL? {
    URL(string: "https://github.com/\(owner)/\(repository)/releases")
  }

  struct Release: Decodable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlURL: URL
    var draft: Bool
    var prerelease: Bool
    var publishedAt: Date?
    var assets: [Asset]

    struct Asset: Decodable {
      var name: String
      var browserDownloadURL: URL
      var size: Int64
      enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
      }
    }
    enum CodingKeys: String, CodingKey {
      case name, body, draft, prerelease, assets
      case tagName = "tag_name"
      case htmlURL = "html_url"
      case publishedAt = "published_at"
    }
  }

  public func latestRelease(for app: AppInfo, includePrereleases: Bool) async throws -> AppRelease?
  {
    // /releases/latest skips drafts and pre-releases; the list includes them. With an asset
    // name the list is searched for the newest release that has it, since a repository may
    // publish other things too (DatabasePro's library binaries are its "latest" release).
    let searchesList = includePrereleases || assetName != nil
    let path = searchesList ? "releases?per_page=20" : "releases/latest"
    var request = URLRequest(
      url: URL(string: "https://api.github.com/repos/\(owner)/\(repository)/\(path)")!,
      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { return nil }  // no release yet
    guard status == 200 else { throw UpdateError.server("HTTP \(status)") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let release: Release?
    if searchesList {
      release = Self.newest(
        in: try decoder.decode([Release].self, from: data), includePrereleases: includePrereleases,
        assetName: assetName)
    } else {
      release = try decoder.decode(Release.self, from: data)
    }
    return try release.map {
      try Self.appRelease(from: $0, appName: app.name, assetName: assetName)
    }
  }

  /// The first (newest) published release in GitHub's list, skipping pre-releases unless
  /// included and, with `assetName`, releases without that asset.
  static func newest(in releases: [Release], includePrereleases: Bool, assetName: String?)
    -> Release?
  {
    releases.first { release in
      !release.draft && (includePrereleases || !release.prerelease)
        && (assetName.map { name in release.assets.contains { $0.name == name } } ?? true)
    }
  }

  static func appRelease(from release: Release, appName: String, assetName: String?) throws
    -> AppRelease
  {
    guard let asset = pickAsset(release.assets.map(\.name), appName: appName, assetName: assetName),
      let match = release.assets.first(where: { $0.name == asset })
    else { throw UpdateError.noDownload }
    return AppRelease(
      version: release.tagName, title: release.name, notes: release.body, pageURL: release.htmlURL,
      downloadURL: match.browserDownloadURL, downloadSize: match.size, date: release.publishedAt)
  }

  /// `assetName` when given; else a .zip, then a .dmg, preferring names that
  /// contain the app name.
  static func pickAsset(_ names: [String], appName: String, assetName: String?) -> String? {
    if let assetName { return names.first { $0 == assetName } }
    let app = appName.lowercased().replacingOccurrences(of: " ", with: "")
    for ext in [".zip", ".dmg"] {
      let candidates = names.filter { $0.lowercased().hasSuffix(ext) }
      if let best = candidates.first(where: {
        $0.lowercased().replacingOccurrences(of: " ", with: "").contains(app)
      }) {
        return best
      }
      if let first = candidates.first { return first }
    }
    return nil
  }
}

// MARK: - JSON feed

/// A JSON document anywhere (https or file URL):
///
///     {"version": "1.2", "url": "https://…/App.zip", "notes": "Markdown",
///      "page": "https://…", "title": "App 1.2", "size": 1234567}
///
/// For apps not on GitHub, and for testing an update locally.
public struct JSONFeed: UpdateSource {
  public var url: URL
  public var releasesPageURL: URL?

  public init(_ url: URL, releasesPageURL: URL? = nil) {
    self.url = url
    self.releasesPageURL = releasesPageURL
  }

  struct Entry: Decodable {
    var version: String
    var url: URL
    var notes: String?
    var page: URL?
    var title: String?
    var size: Int64?
  }

  public func latestRelease(for app: AppInfo, includePrereleases: Bool) async throws -> AppRelease?
  {
    let data: Data
    if url.isFileURL {
      data = try Data(contentsOf: url)
    } else {
      let (body, response) = try await URLSession.shared.data(
        for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else { throw UpdateError.server("HTTP \(status)") }
      data = body
    }
    let entry = try JSONDecoder().decode(Entry.self, from: data)
    return AppRelease(
      version: entry.version, title: entry.title, notes: entry.notes, pageURL: entry.page,
      downloadURL: URL(string: entry.url.relativeString, relativeTo: url)?.absoluteURL ?? entry.url,
      downloadSize: entry.size)
  }
}
