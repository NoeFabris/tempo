# Tempo: distribution and updates (design)

Date: 2026-10-01. Status: architecture approved in conversation; spec under review.

Related: `2026-09-30-productive-menubar-design.md` describes the app. Its "Distribution" section is
superseded by this document.

## 1. Goal

1. The source and the releases of Tempo live in a public GitHub repository.
2. A coworker installs Tempo with one Terminal command. No admin rights. No Gatekeeper dialog.
3. The maintainer publishes a new version by pushing a git tag.
4. Installed copies find the new version within a day and install it by themselves at a quiet moment
   (Sparkle 2, §5.7).

## 2. Facts the design rests on

Researched on 2026-10-01 (sources in §15).

- There is no Apple Developer Program membership and there will be none. Builds are signed ad hoc.
  Notarisation is impossible.
- On macOS 15, 26 and 27 a quarantined app that is not notarised is blocked at first launch. The only
  recovery, System Settings › Privacy & Security › Open Anyway, asks for an administrator password.
- Gatekeeper applies that block only to items that carry the `com.apple.quarantine` attribute.
  Browsers, Slack and Mail set it. `curl` does not. Sparkle removes it from the updates it installs.
- Sparkle 2.10.0 (macOS 12+) installs an ad-hoc-signed update when the archive carries a valid EdDSA
  signature made with the key whose public half is in the installed app. Without EdDSA, ad hoc
  updates always fail (the ad hoc designated requirement is a per-build hash).
- An ad hoc app with the hardened runtime cannot load the embedded `Sparkle.framework` (library
  validation). The hardened runtime stays off.
- Sparkle lets the Apple signing identity change later, as long as the EdDSA key stays the same.
  A Developer ID can be added later without a reinstall (§11).
- Release assets of a private repository require a token on every download. Sparkle cannot supply one
  safely, so the repository is public. The app contains no secrets; each user adds their own token.
- Coworkers' Macs are not locked down by MDM, and Terminal is available.
- The package is SwiftPM only, macOS 14+, universal, `LSUIElement`, not sandboxed, no dependencies.

## 3. Non-goals

- Developer ID signing and notarisation (a later layer, §11).
- Homebrew, Mac App Store, DMG or pkg installers.
- Delta updates, update channels, pre-releases.
- A settings migration from the bundle id of early test builds.

## 4. Architecture

Repository: `github.com/NoeFabris/tempo` (public). The slug is a default constant `REPO` in
`scripts/build-app.sh`, `scripts/release.sh` and `install.sh`. CI overrides it with
`GITHUB_REPOSITORY`.

| Component | Responsibility | Input → Output |
|---|---|---|
| `UpdateController` (new, target `Tempo`) | Wraps Sparkle. Exposes `checkForUpdates()`, `canCheckForUpdates`, `updateAvailable`, `version` to SwiftUI. | Sparkle events → published state |
| `scripts/build-app.sh` (extended) | Builds the universal app, embeds `Sparkle.framework`, writes `Info.plist`, signs ad hoc, zips. Verifies its own output. | `VERSION`, `REPO` → `dist/Tempo.app`, `dist/Tempo.zip` |
| `scripts/release.sh` (new) | Extends the previous `appcast.xml` with an EdDSA-signed item, writes release notes, creates the GitHub release. Same script locally and in CI. | `VERSION`, key → release with `Tempo.zip` + `appcast.xml` |
| `.github/workflows/release.yml` (new) | Runs tests and `release.sh` on `macos-26` when a tag `v*` is pushed. | tag → release |
| `.github/workflows/ci.yml` (new) | Runs tests and the universal packaging (the release configuration) on pushes to `main` and on pull requests. Catches toolchain differences early. | push → green/red |
| `install.sh` (new, repo root) | Downloads the latest zip with `curl`, installs to `~/Applications`, opens the app. | — → installed app |
| `README.md`, `docs/release.md` | One-line install for coworkers. A release runbook for the maintainer. | — |

`ProductiveCore` stays free of Sparkle. Only the `Tempo` target depends on it.

### Data flows

```
RELEASE   maintainer: git tag v1.2.0 && git push origin main v1.2.0
          → Actions (macos-26) → swift test → release.sh → build-app.sh → Tempo.zip
          → generate_appcast (EdDSA key from the secret) → appcast.xml
          → gh release create v1.2.0 Tempo.zip appcast.xml

INSTALL   coworker: curl -fsSL https://raw.githubusercontent.com/NoeFabris/tempo/main/install.sh | sh
          → curl …/releases/latest/download/Tempo.zip      (no quarantine attribute)
          → ~/Applications/Tempo.app → open                 (no dialog, no admin)

UPDATE    Tempo, once a day: GET …/releases/latest/download/appcast.xml
          → newer sparkle:version? → download zip → verify EdDSA with the key in the installed app
          → remove quarantine → install and relaunch while the popup is closed (§5.7)
```

### Load-bearing decisions

1. `CFBundleVersion` = `CFBundleShortVersionString` = `VERSION`, for example `1.2.0`. Sparkle compares
   dotted numbers per segment; Apple allows up to three integers. No commit counter: a rebase could
   lower it. `release.sh` refuses a version that is not greater than the newest appcast item.
2. Feed URL = `https://github.com/<REPO>/releases/latest/download/appcast.xml`. Every release carries
   its own `appcast.xml`, which extends the previous one. No GitHub Pages, no bot commits. Each
   enclosure URL points at its own tag, so old items stay valid when a newer release appears.
3. Ad hoc signature, no hardened runtime. The EdDSA signature is the chain of trust. The Sparkle tools
   (`generate_keys`, `generate_appcast`) come from the SwiftPM artifact under `.build/artifacts/`.
4. One private key, three copies: the maintainer's login Keychain (local releases), the GitHub Actions
   secret `SPARKLE_PRIVATE_KEY` (CI), and a password-manager entry (recovery). The public key is a
   constant in `build-app.sh`.

## 5. App: Sparkle integration

### 5.1 Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
],
targets: [
    .target(name: "ProductiveCore"),
    .executableTarget(name: "Tempo", dependencies: ["ProductiveCore", .product(name: "Sparkle", package: "Sparkle")]),
    …
]
```

`Package.resolved` is committed. Sparkle is a binary target; `swift test` does not compile it.

### 5.2 `Sources/Tempo/UpdateController.swift`

```swift
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    /// True while a scheduled (not user-initiated) update waits for the user's attention.
    @Published private(set) var updateAvailable = false
    let version: String   // CFBundleShortVersionString, "dev" when missing

    private var controller: SPUStandardUpdaterController!   // startingUpdater: false, userDriverDelegate: self

    /// Starts Sparkle. Not called in preview, idle-preview or click-test runs.
    func start()                       // try controller.updater.start(); log on failure
    func checkForUpdates()             // NSApp.activate(ignoringOtherApps: true); controller.checkForUpdates(nil)

    // SPUStandardUserDriverDelegate
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { immediateFocus }
    func standardUserDriverWillHandleShowingUpdate(_ handle: Bool, forUpdate: SUAppcastItem, state: SPUUserUpdateState) // updateAvailable = !state.userInitiated
    func standardUserDriverDidReceiveUserAttention(forUpdate: SUAppcastItem)   // updateAvailable = false
    func standardUserDriverWillFinishUpdateSession()                           // updateAvailable = false
}
```

- `canCheckForUpdates` mirrors `controller.updater.canCheckForUpdates` through KVO
  (`publisher(for: \.canCheckForUpdates)`).
- Creating the controller with `startingUpdater: false` has no side effects, so previews and tests can
  construct an `UpdateController` without network access.
- `immediateFocus` is true right after launch. Then Sparkle shows its alert itself (allowed to take
  focus at launch). Later in the day Sparkle hands the reminder to the app: the footer shows a hint,
  and a click runs a user-initiated check, which brings Sparkle's alert to the front.
- Sparkle 2.9.4+ activates the app for user-initiated checks from menu bar apps. The extra
  `NSApp.activate` is harmless.

### 5.3 Start-up wiring (`AppDelegate.swift`)

```swift
private var updates: UpdateController!
…
store = TimeStore()
updates = UpdateController()
statusBar = StatusBarController(store: store, updates: updates)
…                                  // --idle-preview and --click-test return before this line
updates.start()
store.bootstrap()
```

`--render-previews` returns even earlier, so no mode other than a normal run starts Sparkle.

### 5.4 Injection

- `StatusBarController.init(store:updates:)` adds `.environmentObject(updates)` to the
  `PopoverRootView` hosting controller.
- `PreviewRenderer.render` adds `.environmentObject(UpdateController())` so the settings and main
  screens render.

### 5.5 UI

- `SettingsView`: a new `group("About")` before "Sign out" with one row: left `Text("Version \(updates.version)")`
  in `Brand.font(13)`, right a `Button("Check for updates…")` in `SecondaryButtonStyle`, disabled while
  `!updates.canCheckForUpdates`.
- `SettingsView` "About" also has two switches bound to Sparkle's own settings:
  "Check for updates automatically" (`automaticallyChecksForUpdates`) and "Install updates automatically"
  (`automaticallyDownloadsUpdates`, disabled while the first is off). Sparkle stores both.
- `FooterBar`: after the refresh button, `if let version = updates.readyVersion` shows
  `arrow.down.circle.fill` ("Tempo x is ready… Click to install now.", runs `installNow()`); otherwise
  `if updates.updateAvailable { IconButton(systemName: "arrow.down.circle", help: "Update available") { updates.checkForUpdates() } }`.
- `SettingsView.setLaunchAtLogin` error text becomes "… Move Tempo to your Applications folder
  (~/Applications) and try again."
- Sparkle's own windows do the rest: update alert with markdown release notes, progress,
  "Install and Relaunch". The permission prompt never appears (`SUEnableAutomaticChecks`).

### 5.6 Info.plist keys written by `build-app.sh`

| Key | Value |
|---|---|
| `CFBundleShortVersionString` | `$VERSION` |
| `CFBundleVersion` | `$VERSION` |
| `LSMinimumSystemVersion` | `14.0` (read by `generate_appcast`) |
| `SUFeedURL` | `https://github.com/$REPO/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | the base64 public key constant |
| `SUEnableAutomaticChecks` | `true` |
| `SUAutomaticallyUpdate` | `true` (the default; a user who turns the switch off keeps that choice) |

Default kept: `SUScheduledCheckInterval` 86400 s.

### 5.7 Automatic installs

With `SUAutomaticallyUpdate`, Sparkle downloads a new version in the background and then calls
`SPUUpdaterDelegate.updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`. Sparkle alone
installs only on quit, and shows the update after a week without one (`SUScheduledImpatientCheckInterval`).
A menu bar app is rarely quit, so `UpdateController` returns `true` and runs the block itself:

- At once, and then every 30 s, when the popup is closed and `isBusy` is false. `isBusy` is
  `TimeStore.hasPendingWork` (an offline action waits, or a request is on the serial queue) or the idle
  question is open. The block installs and relaunches without a dialog.
- Before the block runs, one more turn of the main queue: a click handled just before (▶ in the menu bar,
  an answer to the idle question) starts its request in a task that runs first and makes `isBusy` true.
- A running timer is safe: it runs in Productive. The relaunched app loads it again.
- The footer shows the ready version. A click installs at once when `isBusy` is false. Otherwise the
  install follows when `isBusy` clears and the popup is closed, so a form in use is never lost.
- An offline action that Productive refuses (HTTP 4xx, for example an entry deleted on the web) is dropped
  and reported in the footer. Kept, it would fail every refresh and hold back every update.
- With the switch off, Sparkle does not download: a new version shows the "Update available" hint (§5.2).
  An update that was downloaded before the switch went off installs on the next quit, or from the footer.

Verified on 2026-10-02 with a local feed: a copy with its own bundle id, a throwaway EdDSA key and
`SUFeedURL` on `localhost` updated from 9.0.0 to 9.0.1 and relaunched in about one second, with no dialog.

## 6. Build: `scripts/build-app.sh`

Interface:

| Variable | Default | Meaning |
|---|---|---|
| `VERSION` | newest tag without `v`, else `0.0.0` | marketing and bundle version |
| `REPO` | `NoeFabris/tempo` | owner/repo for the feed URL |
| `ARCHS` | `universal` | `host` skips the x86_64 slice for quick local builds |

Constants: `SU_PUBLIC_ED_KEY` (filled once, §7.4), `APP=dist/Tempo.app`, `ZIP=dist/Tempo.zip`.

Steps:

1. `swift build -c release` with `--arch arm64 --arch x86_64` when `ARCHS=universal`. Errors are
   visible and fatal. No silent fallback: a release must be universal.
   `BIN_DIR=$(swift build … --show-bin-path)`.
2. Assemble `Contents/MacOS/Tempo`, `Contents/Resources/Fonts/*`, `Contents/Resources/AppIcon.icns`, and
   `ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"` (keeps symlinks
   and executable bits, which Sparkle's installer needs). The icon is drawn by `scripts/make-icon.swift`
   (a rounded square on the macOS grid, so macOS 26 and later show it without a grey plate) and
   committed; `CFBundleIconFile` is `AppIcon`. Sparkle's alert shows it.
3. `install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Tempo"`. SwiftPM
   links `@rpath/Sparkle.framework/…` but adds no rpath for it.
4. Write `Info.plist` (§5.6) with the existing keys plus the Sparkle keys.
5. `codesign --force --sign - "$APP"`. No `--options runtime`, no `--deep`, no entitlements. The nested
   Sparkle items keep the ad hoc signatures they ship with.
6. Self-checks, each fatal: `codesign --verify --deep --strict "$APP"`; `plutil -lint` on the plist;
   `otool -l` shows the rpath; `Sparkle.framework/Versions/B/Autoupdate` is executable;
   `lipo -archs` lists `x86_64 arm64` when universal; `SU_PUBLIC_ED_KEY` is not the placeholder.
7. `ditto -c -k --norsrc --keepParent "$APP" "$ZIP"`. `--norsrc` leaves resource forks and extended
   attributes out of the zip, so it holds only `Tempo.app/` entries. (`--sequesterRsrc` would store them
   in a `__MACOSX` folder, and every file here carries `com.apple.provenance`.)

Removed: the `DEVELOPER_ID` / `NOTARY_PROFILE` branch. With Sparkle embedded it would also have to
re-sign the nested items; it cannot be tested without a Developer ID. §11 records how to add it.

## 7. Release: `scripts/release.sh` and the workflows

### 7.1 `scripts/release.sh`

Interface: `VERSION` (required, or derived from `GITHUB_REF_NAME` as `v1.2.0` → `1.2.0`), `REPO`,
`SPARKLE_PRIVATE_KEY` (optional; when unset the key comes from the login Keychain),
`DRY_RUN=1` (skip the GitHub release, leave `feed/` for inspection). Needs `gh` (logged in, or
`GH_TOKEN`).

Steps, each fatal on failure:

1. Validate `VERSION` against `^[0-9]+\.[0-9]+\.[0-9]+$`. Require tag `v$VERSION` to exist and to point
   at `HEAD` (`git rev-parse "v$VERSION^{commit}"`). The script never creates tags.
2. `mkdir -p feed`; fetch the previous feed:
   `curl -fsSL -o feed/appcast.xml https://github.com/$REPO/releases/latest/download/appcast.xml || true`
   (the first release has none). If a feed exists, the newest `sparkle:version` in it must be lower
   than `VERSION` (`sort -V`).
3. `VERSION=$VERSION REPO=$REPO scripts/build-app.sh`; `cp dist/Tempo.zip feed/Tempo.zip`.
4. Release notes `feed/Tempo.md`: heading `Tempo $VERSION`, then `git log --format='- %s' <prev tag>..HEAD`
   (all commits when there is no previous tag). The same basename as the archive makes
   `generate_appcast` attach it to the item.
5. `GEN=$(find .build/artifacts -type f -name generate_appcast | head -1)`. Run
   `$GEN --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" --link "https://github.com/$REPO" --embed-release-notes feed`,
   preceded by `printf '%s' "$SPARKLE_PRIVATE_KEY" |` and `--ed-key-file -` when the variable is set.
   The tool reuses `feed/appcast.xml`, keeps the items whose archives are absent (their enclosures still
   point at their own tags), adds the new item, and keeps the three newest items by default.
6. Check the result: `feed/appcast.xml` contains `<sparkle:version>$VERSION</sparkle:version>` (an element,
   as `generate_appcast` writes it), and the new item's enclosure `releases/download/v$VERSION/Tempo.zip`
   carries `sparkle:edSignature`. `generate_appcast` exits 0 and leaves the item unsigned when the key does
   not match `SUPublicEDKey`, so this check is the one that catches a wrong key.
7. Unless `DRY_RUN`: `gh release create "v$VERSION" feed/Tempo.zip feed/appcast.xml --repo "$REPO" --title "Tempo $VERSION" --notes-file feed/Tempo.md --verify-tag`.
   A release that already exists makes this fail; the script does not overwrite releases.

### 7.2 `.github/workflows/release.yml`

```yaml
name: Release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
concurrency:
  group: release
  cancel-in-progress: false
jobs:
  release:
    runs-on: macos-26
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v7
        with: { fetch-depth: 0 }          # tags and history for the release notes
      - run: swift test
      - run: scripts/release.sh
        env:
          REPO: ${{ github.repository }}
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
          GH_TOKEN: ${{ github.token }}
```

`macos-26` ships Xcode 26.6 by default. `macos-14` is deprecated (brownouts from 2026-10-05, removed
2026-11-02) and is never used.

### 7.3 `.github/workflows/ci.yml`

On `push` to `main` and on pull requests: `macos-26`, `actions/checkout@v7`, `swift test`,
`VERSION=0.0.0 scripts/build-app.sh` (universal, the same configuration as a release). Public
repositories get these minutes free.

### 7.4 Keys and secrets (one-time, by the maintainer)

1. `swift build` once, so the Sparkle artifact exists.
2. `$(find .build/artifacts -name generate_keys)` → the private key goes into the login Keychain; the
   command prints the public key. Paste it into `SU_PUBLIC_ED_KEY` in `build-app.sh`.
3. `generate_keys -x "$TMPDIR/sparkle-private.key"` (the per-user temp folder, not the shared `/tmp`);
   `gh secret set SPARKLE_PRIVATE_KEY < "$TMPDIR/sparkle-private.key"`; copy the file's content into the
   password manager; then clear the clipboard (`pbcopy < /dev/null`) and `rm` the file.
4. Housekeeping: `security delete-identity -c "Tempo Local Signing"` removes the stale self-signed
   identity from the earlier approach (optional).

The private key never enters the repository. If the Keychain and the secret are lost, the password
manager copy restores both.

### 7.5 Release runbook (`docs/release.md`)

1. Commit on `main`. Make sure `ci.yml` is green.
2. `git tag v1.2.0 && git push origin main v1.2.0`.
3. Watch the Release workflow. The release appears at `github.com/<REPO>/releases/tag/v1.2.0` with
   `Tempo.zip` and `appcast.xml`.
4. Fallback when CI is unavailable: `VERSION=1.2.0 scripts/release.sh` on the maintainer's Mac after
   step 2. The key comes from the Keychain.

## 8. Install: `install.sh` and the README

`install.sh` is POSIX `sh` (`set -eu`), served from
`https://raw.githubusercontent.com/<REPO>/main/install.sh`. Steps:

1. `TMP=$(mktemp -d)`, removed on exit.
2. `curl -fsSL -o "$TMP/Tempo.zip" "https://github.com/$REPO/releases/latest/download/Tempo.zip"`.
3. `ditto -x -k "$TMP/Tempo.zip" "$TMP/x"`; require `"$TMP/x/Tempo.app/Contents/MacOS/Tempo"`;
   `codesign --verify --deep --strict "$TMP/x/Tempo.app"` (integrity of the ad hoc signature).
4. If Tempo runs (`pgrep -xq Tempo`): `osascript -e 'tell application id "app.tempo.menubar" to quit'`,
   wait up to 5 s, then `pkill -x Tempo` as a last resort. Never `tell application "Tempo"` without the
   check: AppleScript would launch the app first.
5. `mkdir -p ~/Applications`; `rm -rf ~/Applications/Tempo.app`; `ditto "$TMP/x/Tempo.app" ~/Applications/Tempo.app`.
6. `xattr -dr com.apple.quarantine ~/Applications/Tempo.app 2>/dev/null || true` (defence in depth;
   `curl` output carries no quarantine).
7. If `/Applications/Tempo.app` exists, print a warning: an older copy is there; delete it to avoid two
   copies.
8. `open ~/Applications/Tempo.app`; print `Installed Tempo <version> to ~/Applications`.

README changes:

- "Install (colleagues)" becomes: paste one command in Terminal; what the command does (downloads the
  latest release into `~/Applications`, no admin); the token steps stay as they are; a new paragraph
  "Updates: Tempo checks once a day. Click Install and Relaunch when asked, or use Settings › Check
  for updates." The out-of-date "right-click › Open" step disappears.
- The Developer ID paragraph disappears. A "Maintainer" section links to `docs/release.md`.

## 9. Versioning rules

- Tags are `vMAJOR.MINOR.PATCH`. The first Sparkle-enabled release is suggested as `v1.0.0`.
- `VERSION` must be greater than every published version (`release.sh` enforces it against the feed).
- No pre-release tags: `v1.3.0-beta` fails the validation in `release.sh` before anything is created.
- Never move or delete a published tag.

## 10. Error handling and edge cases

| Case | Behaviour |
|---|---|
| Private key lost everywhere | No key rotation without Developer ID. Coworkers rerun the install command; the new app carries the new public key. Three copies of the key (§4) make this unlikely. |
| Release created, assets not yet uploaded (seconds) | `latest/download/appcast.xml` returns 404. Sparkle treats it as a failed check and retries at the next interval. |
| CI toolchain differs from Xcode 27 locally | `ci.yml` builds the same universal configuration as a release, so it fails on the next push, not at release time. Fix the code or select another Xcode on the image. |
| Universal build fails | `build-app.sh` stops with the compiler output. No silent host-only release. |
| Tag does not point at HEAD, or version not greater than the feed | `release.sh` stops before building. |
| Release for this tag already exists | `gh release create` fails; nothing is overwritten. |
| Old manual copy in `/Applications` | `install.sh` warns. Two copies would confuse the login item. |
| Coworker on an early test build (another bundle id) | The organisation ID, the token and the other settings must be entered once more: the app reads the token only after it has an organisation ID. The README says so. |
| Offline queue in memory at update time | The automatic install waits while `TimeStore.hasPendingWork` is true (§5.7). A manual "Install and Relaunch" is the user's choice; pending offline actions are lost, as on any quit. |
| Sparkle alert hidden behind other windows | Gentle reminders: the footer hint stays until the user clicks it or the session ends. |
| Preview, idle-preview and click-test runs | `UpdateController.start()` is not called. No network, no alerts. |
| "The update is improperly signed" | Generic Sparkle text. The real cause is in Console (subsystem `org.sparkle-project.Sparkle`): usually a stale cached archive or a changed key. The runbook lists this. |

## 11. Later: the Developer ID layer

If a paid Apple Developer Program membership appears, add it without changing the architecture:

1. Keep the EdDSA key. Sparkle accepts the change of the Apple signing identity when the EdDSA key is
   unchanged (rotation of one factor only).
2. In `build-app.sh`, sign inside-out with `--options runtime --timestamp`: `Installer.xpc`,
   `Downloader.xpc` (with `--preserve-metadata=entitlements`), `Autoupdate`, `Updater.app`,
   `Sparkle.framework`, then the app. Never `--deep`.
3. Notarise the zip with `xcrun notarytool submit --wait`, `xcrun stapler staple` the app, zip again.
4. Secrets: the Developer ID `.p12` and an App Store Connect API key.
5. The install command stays valid; a browser download plus drag to Applications also works then.

## 12. Testing and acceptance

- `swift test` stays unchanged (ProductiveCore). Sparkle adds no test target.
- `build-app.sh` is self-verifying (§6 step 6). `ci.yml` runs it on every push to `main`.
- `release.sh` has `DRY_RUN=1`. The maintainer runs it once before the first real release and inspects
  `feed/appcast.xml` (one item, correct enclosure URL, `sparkle:edSignature` present).
- `install.sh` is run on the maintainer's Mac after the first release: the app appears in
  `~/Applications`, launches without a dialog, and Settings shows the version.
- Acceptance test, once, before the rollout:
  1. Release `v1.0.0`. Install it with the one-line command on the maintainer's Mac.
  2. Release `v1.0.1` (a trivial change). In Tempo, Settings › Check for updates… → Sparkle shows the
     release notes → Install and Relaunch → Settings shows 1.0.1. No Gatekeeper dialog at any point.
  3. Repeat step 1 on one coworker's Mac as a standard user.

## 13. Security notes

- Public repository; the build contains no secrets. Each user's Productive token stays in their own
  user-only file.
- The EdDSA private key exists only in the Keychain, the Actions secret and the password manager.
  Fork pull requests never receive Actions secrets.
- The install command runs a script from `main` over HTTPS. Anyone with push access to `main` can
  change it, so `main` is for the maintainer only. Coworkers run the command only from the README.
- Updates travel over HTTPS, and Sparkle verifies the EdDSA signature before it installs anything.

## 14. Files touched

- New: `Sources/Tempo/UpdateController.swift`, `scripts/release.sh`, `install.sh`,
  `.github/workflows/release.yml`, `.github/workflows/ci.yml`, `docs/release.md`, `Package.resolved`.
- Changed: `Package.swift`, `scripts/build-app.sh`, `Sources/Tempo/AppDelegate.swift`,
  `Sources/Tempo/StatusBarController.swift`, `Sources/Tempo/PreviewRenderer.swift`,
  `Sources/Tempo/Views/SettingsView.swift`, `Sources/Tempo/Views/MainView.swift`,
  `Sources/Tempo/Brand.swift`, `README.md`,
  `docs/superpowers/specs/2026-09-30-productive-menubar-design.md` (Distribution section points here).
- Manual, by the maintainer: create the public repository and push; generate the EdDSA keys; set the
  Actions secret; paste the public key; tag `v1.0.0`.

## 15. Sources

- Apple, Gatekeeper override moved to System Settings: https://developer.apple.com/news/?id=saqachfa
- Apple, open an app from an unknown developer (macOS 27): https://support.apple.com/guide/mac-help/mh40616/mac
- Eclectic Light, Gatekeeper and quarantine: https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/ and https://eclecticlight.co/2026/08/11/how-can-you-run-code-that-hasnt-been-notarised/
- Sparkle documentation: https://sparkle-project.org/documentation/ (publishing, programmatic-setup, customization, gentle-reminders)
- Sparkle update validation rules: https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m
- Sparkle quarantine removal: https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUPlainInstaller.m
- Sparkle 2.10.0 release: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0
- GitHub, linking to the latest release asset: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases
- GitHub Actions runner images and the macOS 14 retirement: https://github.com/actions/runner-images and https://github.com/actions/runner-images/issues/13518
- Homebrew 5.0 removed `--no-quarantine`: https://brew.sh/2025/11/12/homebrew-5.0.0/
