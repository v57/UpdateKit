# UpdateKit

In-app updates for Mac apps distributed outside the App Store, as a small Swift package (no
frameworks to embed, about 0.25 MB in the app). The app names where its releases are published; the
library reads everything else from the app, picks the installation method that the app's situation
allows, and brings its own update window and menu items.

```swift
import UpdateKit

@main struct MyApp: App {
  private let updater = AppUpdater(github: "owner/MyApp", accent: .orange)  // the window's accent

  init() { updater.start() }  // daily checks, once the user turns them on

  var body: some Scene {
    WindowGroup { ContentView().componentKit(accent: .orange) }
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
| Unsigned or ad-hoc signed | Saved to Downloads once its minisign signature checks out (see below), else the release page opens |
| From the App Store | The updater stays off (the App Store updates it) |

Before anything is replaced, the downloaded app must have the same bundle identifier, be newer, pass
strict code-signature validation (every architecture, nested code) against a requirement for the same
team's Developer ID (Apple Development and Distribution certificates don't qualify), and pass Gatekeeper
(notarization) whenever the running copy is Developer ID signed or passes Gatekeeper itself. The copy staged next to
the app is checked against the same requirement again right before the swap (as root, after it became root's,
on the administrator path), since the user may click Install long after the download was checked. The old app is
restored if the swap fails.

## Linux, Windows and unsigned copies: minisign

Where there is no code signature to hold a download to (Linux, Windows, and a Mac copy without a team), every
release file needs a minisign signature next to it, `<file>.minisig` in the same release, made with the release
key whose public half is built in (`Minisign.PublicKey.v57Release`, key id `4B34449C5FA3E909`; pass `releaseKey:`
for another). The download is checked before it is kept: a prehashed Ed25519 signature (BLAKE2b-512, minisign's
`ED`; the legacy format is refused) by that key, whose trusted comment names this file and this version
(`timestamp:…<tab>file:<name><tab>version:<version>`), so a signed file of another app, platform or older release
can't stand in for it. A missing or bad signature is refused with a message, and the file is deleted. The same
files check with `minisign -Vm <file> -P RWQJ6aNfnEQ0S8QbwuKNHC2GRVVtX/QBZUDBkqjl2JH1KOqlwZyVgJsF`.

Releases are signed by Dev's release (`Minisign.sign(file:secretKey:trustedComment:)` with
`Minisign.releaseComment(fileName:version:)`), the secret key in that Mac's keychain.

## Where releases come from

- `GitHubReleases("owner/repo", assetName:)`: the latest GitHub release. The tag is the version
  (`v1.2` or `1.2`), the body is the release notes (Markdown), and the asset is `assetName` or the `.zip`
  (else `.dmg`) that best matches the app name. An in-place install takes a `.zip`; a `.dmg` is mounted only
  once its minisign signature has been checked, since mounting has the kernel parse the download first. With `assetName`, it is the newest release that has
  that asset, so the repository can publish other releases too. A `.zip` made with
  `ditto -c -k --keepParent MyApp.app MyApp.zip` is recommended.
- `JSONFeed(url)`: `{"version": "1.2", "url": "MyApp.zip", "notes": "…", "page": "https://…",
  "signature": "MyApp.zip.minisig"}` at any https or file URL (`url` and `signature` may be relative to the feed).
- Anything else: conform to `UpdateSource`.

## Testing an update locally

Build two versions, zip the newer one next to a `feed.json` that points at it, and run the older one, a debug
build, with `APP_UPDATER_FEED=file:///path/to/feed.json`. `APP_UPDATER_DISABLED=1` turns the updater off
(automated runs). Release builds ignore both, so nothing that sets the app's environment can switch updates off or
point them elsewhere.

## Requirements

macOS 14 or later, Swift 6. The update window is drawn with
[ComponentKit](https://github.com/v57/Component), v57's shared design.

## License

[MIT](LICENSE)
