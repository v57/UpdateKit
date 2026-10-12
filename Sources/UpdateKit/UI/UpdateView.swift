import SwiftUI

/// Content of the "Software Update" window, one layout per phase.
struct UpdateView: View {
  @ObservedObject var updater: AppUpdater

  private var app: AppInfo { updater.app }

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(nsImage: app.icon).resizable().frame(width: 64, height: 64)
      VStack(alignment: .leading, spacing: 10) { content }.frame(
        maxWidth: .infinity, alignment: .leading)
    }.padding(20).frame(width: 560).fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var content: some View {
    switch updater.phase {
    case .idle: EmptyView()
    case .checking:
      title("Checking for updates…")
      ProgressView().progressViewStyle(.linear)
      buttons { Button("Cancel") { updater.close() }.keyboardShortcut(.cancelAction) }
    case .upToDate:
      title("You're up to date!")
      Text("\(app.name) \(app.version) is the newest version available.")
      buttons { Button("OK") { updater.close() }.keyboardShortcut(.defaultAction) }
    case .updateAvailable(let release): available(release)
    case .downloading(let release, let received, let expected):
      title("Downloading \(app.name) \(release.version)…")
      if let expected, expected > 0 {
        ProgressView(value: Double(received), total: Double(expected))
        Text("\(bytes(received)) of \(bytes(expected))").font(.caption).foregroundColor(.secondary)
      } else {
        ProgressView().progressViewStyle(.linear)
        Text(bytes(received)).font(.caption).foregroundColor(.secondary)
      }
      buttons { Button("Cancel") { updater.close() }.keyboardShortcut(.cancelAction) }
    case .verifying:
      title("Verifying the update…")
      ProgressView().progressViewStyle(.linear)
    case .readyToInstall(let release):
      title("Ready to install \(app.name) \(release.version)")
      Text(readyText)
      buttons {
        Button("Later") { updater.close() }.keyboardShortcut(.cancelAction)
        Button("Install and Relaunch") { updater.installAndRelaunch(release) }.keyboardShortcut(
          .defaultAction)
      }
    case .installing:
      title("Installing…")
      ProgressView().progressViewStyle(.linear)
    case .saved(let release, let file):
      title("\(app.name) \(release.version) is downloaded")
      Text(
        "It is in \(file.deletingLastPathComponent().lastPathComponent) as “\(file.lastPathComponent)”. Quit \(app.name), open the file and move the new \(app.name) to Applications, replacing the old one."
      )
      buttons {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        Button("Done") { updater.close() }.keyboardShortcut(.defaultAction)
      }
    case .failed(let release, let message):
      title(release == nil ? "Couldn't check for updates" : "The update failed")
      Text(message).textSelection(.enabled)
      buttons {
        Button("Download Manually") { updater.downloadManually(release) }
        Button("Close") { updater.close() }.keyboardShortcut(.defaultAction)
      }
    }
  }

  @ViewBuilder private func available(_ release: AppRelease) -> some View {
    title("A new version of \(app.name) is available!")
    Text("\(app.name) \(release.version) is available — you have \(app.version). \(methodText)")
    if let notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
      Text("Release Notes:").bold().padding(.top, 4)
      ScrollView {
        Text(markdown(notes)).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(8)
      }.frame(height: 180).background(Color(nsColor: .textBackgroundColor)).overlay(
        RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
    }
    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates).padding(
      .top, 4)
    HStack {
      Button("Skip This Version") { updater.skip(release) }
      Spacer()
      Button("Remind Me Later") { updater.close() }.keyboardShortcut(.cancelAction)
      Button(updater.installMethod.replacesApp ? "Install Update" : "Download") {
        updater.install(release)
      }.keyboardShortcut(.defaultAction)
    }.padding(.top, 4)
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

  private func title(_ text: String) -> some View { Text(text).font(.headline) }

  private func buttons<B: View>(@ViewBuilder _ content: () -> B) -> some View {
    HStack {
      Spacer()
      content()
    }.padding(.top, 4)
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
