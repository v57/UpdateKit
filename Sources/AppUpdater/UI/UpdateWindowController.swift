import AppKit
import SwiftUI

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
      if #available(macOS 14, *) {
        NSApp.activate()
      } else {
        NSApp.activate(ignoringOtherApps: true)
      }
      window.makeKeyAndOrderFront(nil)
    } else {
      window.orderFront(nil)
    }
  }

  func close() { window?.close() }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 200), styleMask: [.titled, .closable],
      backing: .buffered, defer: true)
    window.title = "Software Update"
    window.isReleasedWhenClosed = false
    window.delegate = self
    let host = NSHostingView(rootView: UpdateView(updater: updater))
    // The window follows the content's size as the phase changes (macOS 13+;
    // on 12 it is sized once, when shown).
    if #available(macOS 13, *) { host.sizingOptions = [.preferredContentSize] }
    window.contentView = host
    window.setContentSize(host.fittingSize)
    return window
  }

  func windowWillClose(_ notification: Notification) { updater.windowClosed() }
}
