# UpdateKit

In-app updates from GitHub Releases (or a JSON feed) for Mac apps distributed outside the App Store. The
[README](../README.md) explains how updates are installed in each situation; this page is the reference for the API,
what a release must contain, and the checks a download goes through.

## Purpose

`UpdateKit` checks where the app's releases are published, shows an update window, downloads the new version,
verifies it, and replaces the running app and relaunches it, or saves the download for the user when the app can't
replace itself (sandboxed, unsigned, or not on a Mac). The app names its release source; everything else is read from
the app's bundle, code signature and entitlements.

It is not an App Store or package-manager client, it has no delta updates, and it never contacts a server until the
user asks: automatic checks are off until the user turns them on.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/UpdateKit.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "UpdateKit", package: "UpdateKit")]),
]
```

`UpdateKit` depends on [ComponentKit](https://github.com/v57/Component) for its window, from GitHub's `main`; with
`V57_LOCAL=1` it builds against a `../Component` checkout instead.

```swift
import SwiftUI
import UpdateKit

@main struct MyApp: App {
  private let updater = AppUpdater(github: "owner/MyApp", assetName: "MyApp.zip")

  init() { updater.start() }   // background checks run only once the user turns them on

  var body: some Scene {
    WindowGroup { ContentView() }
      .commands { UpdaterCommands(updater: updater) }   // Check for Updates…, Check for Updates Automatically
  }
}
```

In an AppKit app, call `start()` at launch and point a menu item at `#selector(AppUpdater.checkForUpdates(_:))` with
the updater as its target. Show `UpdateCheckCard(updater:)` in the app's settings so the user can see and change the
automatic check.

## Main API

### AppUpdater

`AppUpdater` is a main-actor, `@Observable` class.

- `init(github:assetName:configuration:accent:)`: releases of a GitHub repository, `"owner/name"`.
- `init(source:configuration:app:defaults:accent:releaseKey:)`: any `UpdateSource`, and the minisign key release
  files are signed with (default `Minisign.PublicKey.v57Release`, built in: v57's own apps). Another publisher passes
  its own public key here: `try Minisign.PublicKey(<the text of your minisign .pub file>)`.
- `start()`: starts background checks: one at launch if due, then hourly whether one is due. They run only while
  `automaticallyChecksForUpdates` is on.
- `checkForUpdates(_:)`: a user-initiated check that shows its result, "up to date" included. A sandboxed copy without
  network access opens the releases page instead.
- `automaticallyChecksForUpdates`: persisted in `defaults` (`AppUpdater.automaticChecks`), off until the user turns it
  on. There is no way to start with it on.
- `phase`: `.idle`, `.checking(userInitiated:)`, `.upToDate`, `.updateAvailable`, `.downloading(_:received:expected:)`,
  `.verifying`, `.readyToInstall`, `.installing`, `.saved(_:file:)`, `.failed(_:message:)`.
- `isEnabled` (not an App Store build and not disabled), `isBusy`, `lastCheckDate`, `app` (`AppInfo`), `source`,
  `installMethod`, `configuration`, `releaseKey`, `accent` (the window's accent; nil uses the app's AccentColor).
- `AppUpdater.Configuration`: `checkInterval` (default 24 hours) and `includesPrereleases` (default false).

The update window itself is internal: `AppUpdater` opens it for a user-initiated check, and when a background check
finds a newer version that the user hasn't skipped.

### UI

- `UpdaterCommands(updater:)`: "Check for Updates…" and the "Check for Updates Automatically" toggle after the app
  menu's About item. Shows nothing when the updater is off.
- `UpdateCheckCard(updater:)`: a ComponentKit card for a Privacy settings pane: the automatic check's switch, who it
  contacts, what it sends and when it last ran. Shows nothing when the updater is off.
- The update window: a ComponentKit sheet in the app's accent with the app icon and phase, the release notes
  (Markdown), the automatic-check switch, and progress. Its buttons follow the phase: Install Update (or Download, when
  the update is saved rather than installed), Skip This Version and Remind Me Later; Install and Relaunch once the
  download is verified; Show in Finder for a saved file; Download Manually after a failure.

### Sources

- `GitHubReleases(_:assetName:)`: see [What a release must contain](#what-a-release-must-contain).
- `JSONFeed(_:releasesPageURL:)`: a JSON document at an https or file URL:
  `{"version": "1.2", "url": "MyApp.zip", "notes": "…", "page": "https://…", "title": "MyApp 1.2", "size": 1234567,
  "signature": "MyApp.zip.minisig"}`. `url` and `signature` may be relative to the feed.
- `UpdateSource` (protocol): `latestRelease(for:includePrereleases:) async throws -> AppRelease?` and
  `releasesPageURL`.
- `AppRelease(version:title:notes:pageURL:downloadURL:downloadSize:date:signatureURL:)`; `assetName` is the
  download's file name.

### Lower level

- `AppInfo.current(bundle:)`: what the updater knows about the app (see below).
- `InstallMethod`: `.replace(URL)`, `.replaceAsAdministrator(URL)`, `.saveToFolder(URL)`, `.openInBrowser`,
  `.appStore`; `InstallMethod.choose(for:)` with an `InstallMethod.Context`; `replacesApp`.
- `Version(_:)`: dotted versions compared numerically (`"1.10" > "1.9"`, `"1.0" == "1"`, a leading `v` ignored); a
  pre-release (`-beta.2`) sorts before the same version without one.
- `Minisign`: `PublicKey`, `Signature`, `sign(file:secretKey:trustedComment:untrustedComment:)`,
  `sign(data:…)`, `releaseComment(fileName:version:date:)`, `verify(file:signature:publicKey:)`,
  `verify(data:…)`, `verifyRelease(file:signature:publicKey:fileName:version:)`, `publicKey(secretKey:)`.
- `UpdateError`, `MinisignError`: the failures, each with a message for the user.

## What the app must contain

`AppInfo.current()` reads:

| What | From |
|---|---|
| Name | `CFBundleDisplayName`, else `CFBundleName`, else the bundle's file name |
| Version | `CFBundleShortVersionString` (compared with `Version`; `"0"` when missing) |
| Build | `CFBundleVersion` (breaks a tie between equal versions) |
| Bundle identifier | the bundle; an update must have the same one |
| Signing team | the running app's code signature; none for unsigned or ad-hoc builds |
| Sandboxed | the `com.apple.security.app-sandbox` entitlement |
| Network, Downloads access | `com.apple.security.network.client`, `com.apple.security.files.downloads.read-write` (always on outside the sandbox) |
| App Store build | an App Store receipt in the bundle: the updater stays off |

On Linux and Windows the app's name and version come from an `Info.plist` next to the executable; there is no
sandbox, team or receipt there.

Nothing goes in the app's `Info.plist` for UpdateKit itself: the release source is the `AppUpdater` initializer, and
the minisign public key is built in or passed as `releaseKey:`.

## What a release must contain

### GitHub releases

- **Tag**: the version, `v1.2` or `1.2`. It must be newer than the running app's `CFBundleShortVersionString`.
- **Body**: the release notes, Markdown.
- **Drafts** are never offered; **pre-releases** only with `includesPrereleases`.
- **Asset**:
  - macOS: `assetName` when given, else the `.zip` (then the `.dmg`) whose name best contains the app's name. A `.zip`
    with the `.app` at its top level (or one folder down) is what an in-place install takes; make it with
    `ditto -c -k --keepParent MyApp.app MyApp.zip`.
  - Windows: `<name>-Windows-<arch>.zip`; Linux: `<name>-Linux-<arch>.tar.gz`. `<name>` is `assetName` without its
    extension, else the app's name without spaces; `<arch>` is `arm64` or `x64`.
  - Without `assetName` (and without pre-releases) the latest release is read (`/releases/latest`). With `assetName`,
    or with pre-releases, the newest of the last 20 releases that has that asset is taken, so the repository can
    publish other releases too.
- **Signature**: `<asset>.minisig` in the same release. Required on Linux, Windows and for a Mac copy without a team;
  checked whenever it is there.

### The minisign signature

A prehashed Ed25519 signature (minisign's `ED`: Ed25519 over the file's BLAKE2b-512; the legacy format is refused)
by the release key, whose trusted comment is
`timestamp:<unix time><TAB>file:<asset file name><TAB>version:<version>`, as `Minisign.releaseComment(fileName:version:)`
writes it. The file name must be the download's, and the version must equal the release's, so a signed file of
another app, platform or release can't stand in for it. Sign with `Minisign.sign(file:secretKey:trustedComment:)` (the
secret key is the 8-byte key id followed by the 32-byte Ed25519 seed) or with the minisign command line using the
same trusted comment. Keep the secret key off the repository; v57's is in the keychain of the Mac that runs Dev's
release.

### Mac code signature

For an in-place install the downloaded app must:

- have the running app's bundle identifier;
- be newer (a higher version, or the same version and a higher build);
- pass strict code-signature validation (every architecture, nested code) against a requirement for the same team's
  **Developer ID Application** certificate (Apple Development and Distribution certificates don't qualify);
- pass Gatekeeper (notarized) whenever the running copy is Developer ID signed or passes Gatekeeper itself.

## Security behaviour

- **No request without the user**: automatic checks start off; `APP_UPDATER_FEED` and `APP_UPDATER_DISABLED` are read
  in debug builds only, so nothing that sets a release build's environment can turn updates off or point them
  elsewhere.
- **Signatures**: Mac in-place installs are held to the code-signature requirement above, checked on the download and
  again on the staged copy right before the swap (on the administrator path, as root after it became root's). A
  download that needs a minisign signature and has none is not fetched: the release page opens on the Mac, an error
  shows elsewhere. A file that fails its signature is deleted at once.
- **Disk images**: a `.dmg` is mounted only after its minisign signature checked out, since mounting has the kernel
  parse the download first; otherwise only `.zip` installs in place.
- **Size limits**: a download stops past its release's stated size plus a tenth (at least 1 MB more), or past 2 GB
  when no size is stated. A zip that says it unpacks to more than twenty times its size (at least 16 MB), or writes
  more than that anyway, is refused. A `.minisig` over 16 KB is refused.
- **File names**: a saved update's name comes from the server, so it is reduced to one plain file name (separators,
  leading dots and control characters become underscores) and must land directly in the target folder.
- **Links**: links in release notes open only when they are https; `file:`, `http:` and other apps' URL schemes stay
  plain text.
- **Install target**: installing into /Applications refuses to overwrite a different app with the same name. The old
  app is restored if the swap fails.
- Downloads use an ephemeral `URLSession`. The download URL itself isn't required to be https: GitHub's always are,
  and a `JSONFeed` should name https URLs.

## Platform notes

- **macOS 14+**: everything above. The package declares macOS only; in a multiplatform app, link it to the Mac target.
- **iOS**: not supported (the App Store updates iOS apps).
- **Linux**: builds on v57/SwiftUI (and its CryptoKit stand-in). Checks for `<name>-Linux-<arch>.tar.gz`, requires its
  minisign signature, saves it to Downloads and shows it selected through the freedesktop `FileManager1` interface
  (the folder opens without one).
- **Windows**: builds on v57/SwiftUI. Checks for `<name>-Windows-<arch>.zip`, requires its minisign signature, saves it
  to Downloads and shows it in Explorer.
- **Android**: not supported.

## Testing

```bash
swift test
V57_LOCAL=1 swift test     # against ../Component
swift test --filter MinisignTests
```

- `InstallerTests` (macOS) signs a test bundle with an identity from the keychain and skips a case when the identity
  it needs (Apple Development, Developer ID) isn't there.
- One `MinisignTests` case checks that minisign's command line accepts what `Minisign.sign` makes; it skips without
  `minisign` (`brew install minisign`).

End to end: build two versions of an app, zip the newer one next to a `feed.json` that points at it, and run the
older one as a debug build with `APP_UPDATER_FEED=file:///path/to/feed.json`. `APP_UPDATER_DISABLED=1` turns the
updater off for automated runs. Don't test the administrator-prompt path by entering a password in automation.
