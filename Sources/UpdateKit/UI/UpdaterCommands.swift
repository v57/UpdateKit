import SwiftUI

/// "Check for Updates…" and "Check for Updates Automatically" under the app
/// menu's About item. Shows nothing when the updater is off (App Store build,
/// APP_UPDATER_DISABLED).
///
///     .commands { UpdaterCommands(updater: updater) }
public struct UpdaterCommands: Commands {
  let updater: AppUpdater

  public init(updater: AppUpdater) { self.updater = updater }

  public var body: some Commands {
    CommandGroup(after: .appInfo) { UpdaterMenuItems(updater: updater) }
  }
}

/// A view of its own, so that the items' state is tracked by a view, whatever a `Commands` body tracks.
private struct UpdaterMenuItems: View {
  @Bindable var updater: AppUpdater

  var body: some View {
    if updater.isEnabled {
      Button("Check for Updates…") { updater.checkForUpdates() }.disabled(updater.isBusy)
      Toggle("Check for Updates Automatically", isOn: $updater.automaticallyChecksForUpdates)
    }
  }
}
