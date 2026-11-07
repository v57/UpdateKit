import ComponentKit
import SwiftUI

/// The Privacy pane's card for the automatic update check: its switch, off until the user turns it on, what it sends
/// and when it last ran. Shows nothing when the updater is off (App Store build, APP_UPDATER_DISABLED).
///
/// ```swift
/// #if os(macOS)
///   UpdateCheckCard(updater: updater)
/// #endif
/// ```
public struct UpdateCheckCard: View {
  let updater: AppUpdater

  public init(updater: AppUpdater) { self.updater = updater }

  private var isAutomatic: Binding<Bool> {
    Binding(
      get: { updater.automaticallyChecksForUpdates },
      set: { updater.automaticallyChecksForUpdates = $0 })
  }

  /// Who answers: "github.com", or the update server's name.
  private var server: String { updater.source.releasesPageURL?.host() ?? String(localized: "the update server") }

  private var lastCheck: LocalizedStringKey {
    if let date = updater.lastCheckDate { "Last checked \(date.kitFormatted(.ago))" } else { "Never checked" }
  }

  public var body: some View {
    if updater.isEnabled {
      FormCard(
        "Updates",
        footer: """
          Once a day \(updater.app.name) asks \(server) for its latest release, which shows the server your IP \
          address and nothing else about you. Off, it only asks when you choose Check for Updates.
          """
      ) {
        FormRow("Check for updates automatically", help: lastCheck, systemImage: "arrow.down.circle", hue: .blue) {
          Toggle("Check for updates automatically", isOn: isAutomatic)
            .toggleStyle(.kitSwitch)
            .kitLabelsHidden()
        }
      }
    }
  }
}
