import ComponentKit
import SwiftUI

/// Content of the "Software Update" window, one layout per phase: a kit sheet with the app's icon, the phase as its
/// title and meta, the release notes or the error as the body, and the footer bar with the work's live icon and the
/// buttons.
struct UpdateView: View {
  @ObservedObject var updater: AppUpdater

  private var app: AppInfo { updater.app }

  var body: some View {
    KitSheet(title: title, meta: meta, width: 520) {
      KitAppIcon(size: 36)
    } content: {
      details
    } footer: {
      footer
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Header

  private var title: String {
    switch updater.phase {
    case .idle: app.name
    case .checking: "Checking for updates…"
    case .upToDate: "You're up to date!"
    case .updateAvailable: "A new version of \(app.name) is available!"
    case .downloading(let release, _, _): "Downloading \(app.name) \(release.version)…"
    case .verifying: "Verifying the update…"
    case .readyToInstall(let release): "Ready to install \(app.name) \(release.version)"
    case .installing: "Installing…"
    case .saved(let release, _): "\(app.name) \(release.version) is downloaded"
    case .failed(let release, _): release == nil ? "Couldn't check for updates" : "The update failed"
    }
  }

  private var meta: String? {
    switch updater.phase {
    case .upToDate: "\(app.name) \(app.version) is the newest version available."
    case .updateAvailable(let release):
      "\(app.name) \(release.version) is available — you have \(app.version). \(methodText)"
    case .readyToInstall: readyText
    case .saved(_, let file):
      "It is in \(file.deletingLastPathComponent().lastPathComponent) as “\(file.lastPathComponent)”. \(installHint)"
    default: nil
    }
  }

  // MARK: - Body

  @ViewBuilder private var details: some View {
    switch updater.phase {
    case .updateAvailable(let release):
      if let notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
        FormCard("Release Notes") {
          ScrollView {
            Text(markdown(notes))
              .kitFont(.body)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
          }
          .frame(height: 180)
        }
      }
      FormCard {
        FormRow("Check for updates automatically", systemImage: "arrow.triangle.2.circlepath") {
          Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            .toggleStyle(.kitSwitch)
            .kitLabelsHidden()
        }
      }
    case .downloading(_, let received, let expected):
      if let expected, expected > 0 {
        // The amount is the information here: the bar, with the bytes in the footer's status.
        KitProgressBar(value: Double(received) / Double(expected))
          .padding(.horizontal, KitMetrics.gutter)
          .padding(.vertical, KitMetrics.cardPadding)
      }
    case .failed(_, let message):
      Text(message)
        .kitFont(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .kitSurface(.card)
    default: EmptyView()
    }
  }

  // MARK: - Footer

  @ViewBuilder private var footer: some View {
    switch updater.phase {
    case .idle: EmptyView()
    case .checking:
      SheetStatus("\(app.name) \(app.version)", systemImage: "arrow.triangle.2.circlepath", status: .working)
      Button("Cancel") { updater.close() }.keyboardShortcut(.cancelAction)
    case .upToDate:
      Button("OK") { updater.close() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    case .updateAvailable(let release):
      Button("Skip This Version") { updater.skip(release) }
      Button("Remind Me Later") { updater.close() }.keyboardShortcut(.cancelAction)
      Button(updater.installMethod.replacesApp ? "Install Update" : "Download") { updater.install(release) }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    case .downloading(_, let received, let expected):
      if let expected, expected > 0 {
        SheetStatus(
          "\(bytes(received)) of \(bytes(expected))", systemImage: "arrow.down",
          status: .working(progress: Double(received) / Double(expected)))
      } else {
        SheetStatus(bytes(received), systemImage: "arrow.down", status: .working)
      }
      Button("Cancel") { updater.close() }.keyboardShortcut(.cancelAction)
    case .verifying:
      SheetStatus("Checking its signature", systemImage: "checkmark.shield", status: .working)
    case .readyToInstall(let release):
      SheetStatus("Verified", systemImage: "checkmark.shield", status: .done)
      Button("Later") { updater.close() }.keyboardShortcut(.cancelAction)
      Button("Install and Relaunch") { updater.installAndRelaunch(release) }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    case .installing(let release):
      SheetStatus("\(app.name) \(release.version)", systemImage: "arrow.down.app", status: .working)
    case .saved(_, let file):
      SheetStatus("Downloaded", systemImage: "arrow.down", status: .done)
      Button("Show in \(KitDesktop.fileManagerName)") { Desktop.reveal(file) }
      Button("Done") { updater.close() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    case .failed(let release, let message):
      SheetStatus(release == nil ? "Not checked" : "Not installed", status: .failed(message))
      Button("Download Manually") { updater.downloadManually(release) }
      Button("Close") { updater.close() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  // MARK: - Text

  private var installHint: String {
    #if os(macOS)
      "Quit \(app.name), open the file and move the new \(app.name) to Applications, replacing the old one."
    #else
      "Quit \(app.name), then unpack the file over the folder \(app.name) runs from."
    #endif
  }

  private var methodText: String {
    switch updater.installMethod {
    case .replace(let url) where url != app.bundleURL:
      return "It will be installed in \(url.deletingLastPathComponent().path)."
    case .replaceAsAdministrator: return "Installing it needs an administrator password."
    case .saveToFolder(let folder):
      return "It will be saved to your \(folder.lastPathComponent) folder."
    case .openInBrowser: return "Your browser will download it."
    default: return "Would you like to install it now?"
    }
  }

  private var readyText: String {
    if case .replaceAsAdministrator = updater.installMethod {
      return "macOS will ask for an administrator password, then \(app.name) quits and reopens."
    }
    return "\(app.name) will quit and reopen with the new version."
  }

  private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }

  private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

#if DEBUG
  extension UpdateView {
    /// The window in one phase, with a made-up app and release (previews, render checks).
    @MainActor static func preview(_ phase: (AppRelease) -> AppUpdater.Phase) -> some View {
      let app = AppInfo(
        name: "Get", bundleIdentifier: "dev.v57.get", version: "1.2", build: "12",
        bundleURL: URL(fileURLWithPath: "/Applications/Get.app"), teamIdentifier: nil, isSandboxed: false,
        hasNetworkAccess: true, hasDownloadsAccess: true, isAppStoreBuild: false)
      let release = AppRelease(
        version: "1.3",
        notes: """
          - **Download on…** runs a download on another of your devices.
          - Faster resume for large torrents.
          - Fixed the dock badge after a failed download.
          """,
        downloadURL: URL(string: "https://github.com/v57/Get/releases/download/v1.3/Get.zip")!,
        downloadSize: 24_000_000)
      let updater = AppUpdater(
        source: JSONFeed(URL(fileURLWithPath: "/dev/null")), app: app,
        defaults: UserDefaults(suiteName: "UpdateKitPreview") ?? .standard)
      updater.phase = phase(release)
      return UpdateView(updater: updater).componentKit()
    }
  }

  #Preview("Available") { UpdateView.preview { .updateAvailable($0) } }
  #Preview("Downloading") { UpdateView.preview { .downloading($0, received: 9_600_000, expected: 24_000_000) } }
  #Preview("Ready") { UpdateView.preview { .readyToInstall($0) } }
  #Preview("Failed") { UpdateView.preview { .failed($0, message: "The download's signature is from another team.") } }
#endif
