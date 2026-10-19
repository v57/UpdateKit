import Foundation

#if os(macOS)
  import AppKit
#elseif os(Windows)
  import WinSDK
#endif

/// Hands URLs and files to the desktop: the browser, the file manager.
enum Desktop {
  /// Opens a web page or file with its default app.
  @MainActor static func open(_ url: URL) {
    #if os(macOS)
      NSWorkspace.shared.open(url)
    #elseif os(Windows)
      let target = url.isFileURL ? url.path : url.absoluteString
      _ = target.withCString(encodedAs: UTF16.self) { file in
        "open".withCString(encodedAs: UTF16.self) { verb in ShellExecuteW(nil, verb, file, nil, nil, SW_SHOWNORMAL) }
      }
    #else
      run("/usr/bin/xdg-open", [url.isFileURL ? url.path : url.absoluteString])
    #endif
  }

  /// Shows a file in the file manager (Finder, Explorer), selected.
  @MainActor static func reveal(_ file: URL) {
    #if os(macOS)
      NSWorkspace.shared.activateFileViewerSelecting([file])
    #elseif os(Windows)
      run(#"C:\Windows\explorer.exe"#, ["/select,\(file.path.replacingOccurrences(of: "/", with: "\\"))"])
    #else
      open(file.deletingLastPathComponent())
    #endif
  }

  /// What the file manager is called.
  static var fileManagerName: String {
    #if os(macOS)
      "Finder"
    #elseif os(Windows)
      "Explorer"
    #else
      "Files"
    #endif
  }

  private static func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try? process.run()
  }
}
