# UpdateKit

In-app updates for Mac apps distributed outside the App Store, as a small Swift package (no
frameworks to embed, about 0.25 MB in the app). The app names where its releases are published; the
library reads everything else from the app, picks the installation method that the app's situation
allows, and brings its own update window and menu items.

```swift
import UpdateKit

@main struct MyApp: App {
  private let updater = AppUpdater(github: "owner/MyApp")

  init() { updater.start() }  // daily checks, once the user turns them on

  var body: some Scene {
    WindowGroup { ContentView() }
      .commands { UpdaterCommands(updater: updater) }  // Check for Updates…, Check Automatically
  }
}
```

In an AppKit app, call `updater.start()` at launch and point a menu item at
`#selector(AppUpdater.checkForUpdates(_:))` with the updater as its target.

The app contacts the update server only when the user asks: automatic checks are off until the user
turns on Check for Updates Automatically (in the menu or the update window), and nothing turns them
on for them.

## What it reads from the app

| | From |
|---|---|
| Name, version, build, bundle ID, icon | `Info.plist`, the bundle |
| Signing team | the running app's code signature |
| Sandboxed, network and Downloads access | the app's entitlements |
| App Store build | the App Store receipt |
| Translocated, on a disk image, writable | the bundle's location |

## How it installs

| The app is… | Then |
|---|---|
| Not sandboxed, in a writable folder | Download, verify, replace the app, relaunch |
| Not sandboxed, in a folder this user can't write | The same through the macOS administrator prompt |
| Run from a disk image or translocated (never moved out of Downloads) | Installed into /Applications instead |
| Sandboxed with network and Downloads access | The update is saved to Downloads and shown in Finder |
| Sandboxed without them | The browser downloads it |
| Unsigned or ad-hoc signed | Saved to Downloads: nothing to verify it against |
| From the App Store | The updater stays off (the App Store updates it) |

Before anything is replaced, the downloaded app must have the same bundle identifier, be newer, pass
strict code-signature validation (every architecture, nested code) against a requirement for the same
signing team, and pass Gatekeeper (notarization) whenever the running copy does. The old app is
restored if the swap fails.

## Where releases come from

- `GitHubReleases("owner/repo", assetName:)`: the latest GitHub release. The tag is the version
  (`v1.2` or `1.2`), the body is the release notes (Markdown), and the asset is `assetName` or the `.zip`
  (else `.dmg`) that best matches the app name. With `assetName`, it is the newest release that has
  that asset, so the repository can publish other releases too. A `.zip` made with
  `ditto -c -k --keepParent MyApp.app MyApp.zip` is recommended.
- `JSONFeed(url)`: `{"version": "1.2", "url": "MyApp.zip", "notes": "…", "page": "https://…"}` at any
  https or file URL (`url` may be relative to the feed).
- Anything else: conform to `UpdateSource`.

## Testing an update locally

Build two versions, zip the newer one next to a `feed.json` that points at it, and run the older one
with `APP_UPDATER_FEED=file:///path/to/feed.json`. `APP_UPDATER_DISABLED=1` turns the updater off
(automated runs).

## Requirements

macOS 12 or later, Swift 6.

## License

[MIT](LICENSE)
