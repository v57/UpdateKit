import ComponentKit
import Foundation

/// Shows a saved update in the file manager, selected. ComponentKit's `KitDesktop` opens links and files and names
/// the file manager; on Linux it only opens the folder, so the freedesktop FileManager1 interface (Files, Dolphin,
/// Thunar, …) selects the file there first.
enum Desktop {
  @MainActor static func reveal(_ file: URL) {
    #if os(Linux)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/dbus-send")
      process.arguments = [
        "--session", "--dest=org.freedesktop.FileManager1", "--type=method_call", "--print-reply",
        "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems",
        "array:string:\(file.absoluteString)", "string:",
      ]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { process in
        guard process.terminationStatus != 0 else { return }
        Task { @MainActor in KitDesktop.reveal([file]) }
      }
      do { try process.run() } catch { KitDesktop.reveal([file]) }
    #else
      KitDesktop.reveal([file])
    #endif
  }
}
