import ComponentKit
import SwiftUI

extension UpdateView {
  /// The window's root: on the kit, in the app's accent.
  @MainActor static func root(_ updater: AppUpdater) -> some View {
    UpdateView(updater: updater).componentKit(accent: updater.accent ?? .accentColor)
  }
}

#if os(macOS)
  import AppKit

/// The single "Software Update" window. Works in SwiftUI and AppKit apps
/// alike; the window is created on first use.
@MainActor final class UpdateWindowController: NSObject, NSWindowDelegate {
  private unowned let updater: AppUpdater
  private var window: NSWindow?

  init(updater: AppUpdater) { self.updater = updater }

  var isVisible: Bool { window?.isVisible ?? false }

  func show(activate: Bool) {
    let window = self.window ?? makeWindow()
    self.window = window
    if !window.isVisible { window.center() }
    if activate {
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    } else {
      window.orderFront(nil)
    }
  }

  func close() { window?.close() }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
    window.title = "Software Update"
    // The sheet's header names the phase; its panel ground runs up under the title bar.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.delegate = self
    // The hosting view's size constraints (its default sizing) make the window follow the content's size as the
    // phase changes; `.preferredContentSize` alone left its fitting size at zero.
    let host = NSHostingView(rootView: UpdateView.root(updater))
    window.contentView = host
    window.setContentSize(host.fittingSize)
    return window
  }

  func windowWillClose(_ notification: Notification) { updater.windowClosed() }
}
#else
  /// The single "Software Update" window, opened from code (`HostingWindow`, v57/SwiftUI's).
  @MainActor final class UpdateWindowController {
    private unowned let updater: AppUpdater
    private var window: HostingWindow?

    init(updater: AppUpdater) { self.updater = updater }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(activate: Bool) {
      let window = self.window ?? makeWindow()
      self.window = window
      window.show()
    }

    func close() { window?.close() }

    private func makeWindow() -> HostingWindow {
      let updater = self.updater
      let window = HostingWindow(title: "Software Update", defaultSize: CGSize(width: 520, height: 220)) {
        UpdateView.root(updater)
      }
      window.onClose = { [weak updater] in updater?.windowClosed() }
      return window
    }
  }
#endif
