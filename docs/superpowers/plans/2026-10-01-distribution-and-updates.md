# Distribution and Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Tempo from a public GitHub repository so coworkers install it with one Terminal command (no admin rights) and receive Sparkle updates signed with EdDSA.

**Architecture:** The app embeds Sparkle 2.10 through SwiftPM behind a small `UpdateController`. `scripts/build-app.sh` produces an ad hoc signed universal `Tempo.zip`; `scripts/release.sh` signs it with the EdDSA key, extends `appcast.xml` and creates a GitHub release; a tag-triggered workflow runs that script. `install.sh` downloads the latest release with `curl` into `~/Applications`, which carries no quarantine flag, so Gatekeeper shows no dialog.

**Tech Stack:** Swift 6 toolchain (Swift 5 language mode), SwiftPM, Sparkle 2.10.0, bash/POSIX sh, GitHub Actions (`macos-26`), `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-10-01-distribution-and-updates-design.md`

## Global Constraints

- Sparkle dependency: `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")`, product `Sparkle`, added to the `Tempo` target only. `ProductiveCore` never imports Sparkle.
- Platform: `platforms: [.macOS(.v14)]`, `LSMinimumSystemVersion` `14.0`, universal binary (`--arch arm64 --arch x86_64`) for releases.
- Signing: `codesign --force --sign - "$APP"` only. Never `--options runtime`, never `--deep`, no entitlements.
- Versions: `CFBundleVersion` = `CFBundleShortVersionString` = `VERSION`, matching `^[0-9]+\.[0-9]+\.[0-9]+$`. Tags are `v$VERSION`. No pre-release tags.
- Repo slug default `NoeFabris/tempo`, in one constant `REPO` per script; CI passes `GITHUB_REPOSITORY`.
- Feed URL: `https://github.com/$REPO/releases/latest/download/appcast.xml`. Release asset names are exactly `Tempo.zip` and `appcast.xml`.
- Install location: `~/Applications`. The installer never touches `/Applications`.
- Runner: `macos-26`. Never `macos-14`.
- The EdDSA private key never enters the repository. The public key is the constant `SU_PUBLIC_ED_KEY` in `scripts/build-app.sh`.
- Zip: `ditto -c -k --norsrc --keepParent` (changed from `--sequesterRsrc` during execution; see Execution notes). The zip contains only `Tempo.app/…` entries.
- Commit messages: `type: lowercase summary` (`feat`, `fix`, `chore`, `docs`, `ci`), ending with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Shell scripts: `scripts/*.sh` are bash (`#!/bin/bash`, `set -euo pipefail`, no empty-array expansion under `set -u` because macOS bash is 3.2). `install.sh` is POSIX `sh` (`set -eu`, no arrays, no `local`).

## Review Focus

1. **Installing over a running Tempo** (second run of `install.sh`): the running app must quit, the bundle in `~/Applications` must be replaced, and the new one must launch. Pinned in Task 7, Step 4.
2. **A release version that is not newer than the published one** (`release.sh` with `VERSION` ≤ newest `sparkle:version`): the script must stop before it builds anything. Pinned in Task 5, Step 5 (local previous appcast via `PREVIOUS_APPCAST_URL`).
3. **The placeholder public key** (`SU_PUBLIC_ED_KEY="REPLACE_ME"`): `build-app.sh` must refuse to build; an app without a key could never update. Pinned in Task 4, Step 3.
4. **Malformed versions** (`VERSION=1.0.0-beta`, `VERSION=v0.0.1`, empty): `release.sh` must reject the first and the empty value, and must accept a `v` prefix by stripping it. Pinned in Task 5, Step 5.
5. **A failed download** (`install.sh` with an unreachable URL): the script must stop before it quits or replaces anything; the existing install stays unchanged. Pinned in Task 7, Step 4.

## Execution notes (2026-10-01)

Rulings made while executing this plan. The task code blocks below are the original plan text; the
committed scripts differ where these notes say so.

- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (the harness changed the attribution).
- Task 4: `build-app.sh` zips with `--norsrc` (`--sequesterRsrc` stores metadata in `__MACOSX`); the
  `VERSION` default survives a repository without tags under `pipefail`; the rpath check uses
  `grep … >/dev/null` instead of `grep -q` (SIGPIPE under `pipefail`).
- Task 5: `release.sh` reads `<sparkle:version>` as an element and checks the new item's
  `sparkle:edSignature`; the test key is exported to `$TMPDIR`, not `/tmp`.
- Task 9: appcast checks use the element form `<sparkle:version>…</sparkle:version>`.

---

### Task 0: Commit the pending cleanup

The working tree holds six staged changes from the previous session (the self-signed "Tempo Local Signing" identity and its script are removed; the spec's token wording is updated). They belong to this topic and must not leak into later commits under the wrong message.

**Files:**
- Already staged: `README.md`, `Sources/ProductiveCore/TimeStore.swift`, `Sources/Tempo/AppDelegate.swift`, `docs/superpowers/specs/2026-09-30-productive-menubar-design.md`, `scripts/build-app.sh`, `scripts/make-signing-cert.sh` (deleted)

- [ ] **Step 1: Confirm what is staged**

Run: `git diff --cached --stat`
Expected: 6 files, `+5/-42`, including `scripts/make-signing-cert.sh | 32 ----`.

- [ ] **Step 2: Commit the index as it is**

```bash
git commit -q -m "$(cat <<'EOF'
chore: drop the local self-signed signing identity

Builds are signed ad hoc unless a Developer ID is given. The spec now says
the API token lives in a user-only file.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
git status --short
```
Expected: `git status --short` prints nothing.

---

### Task 1: Add the Sparkle dependency

**Files:**
- Modify: `Package.swift`
- Create (generated): `Package.resolved`

**Interfaces:**
- Produces: module `Sparkle` importable from the `Tempo` target; tools under `.build/artifacts/sparkle/Sparkle/bin/` (`generate_keys`, `generate_appcast`, `sign_update`).

- [ ] **Step 1: Replace `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tempo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tempo", targets: ["Tempo"]),
    ],
    dependencies: [
        // Updates. Binary target; the signing tools come with it (.build/artifacts/sparkle/Sparkle/bin).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "ProductiveCore"),
        .executableTarget(
            name: "Tempo",
            dependencies: ["ProductiveCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "ProductiveCoreTests",
            dependencies: ["ProductiveCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Resolve and build**

Run: `swift build 2>&1 | tail -3`
Expected: the last line is `Build complete!` (or `Compiling …` then `Build complete!`). `Package.resolved` appears at the repo root and pins Sparkle `2.10.0` or newer.

- [ ] **Step 3: Check the tools and that the framework is next to the binary**

Run:
```bash
ls .build/artifacts/sparkle/Sparkle/bin
ls "$(swift build --show-bin-path)/Sparkle.framework/Versions/B/Autoupdate"
grep -A8 '"sparkle"' Package.resolved | grep version
```
Expected: `BinaryDelta generate_appcast generate_keys sign_update`; the `Autoupdate` path exists; the resolved version is `2.10.x`.

- [ ] **Step 4: Run the existing tests**

Run: `swift test 2>&1 | tail -3`
Expected: `Executed N tests, with 0 failures` (live tests are skipped).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -q -m "$(cat <<'EOF'
feat: add Sparkle 2.10 as a dependency of the app target

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `UpdateController` and start-up wiring

**Files:**
- Create: `Sources/Tempo/UpdateController.swift`
- Modify: `Sources/Tempo/AppDelegate.swift:6-33`
- Modify: `Sources/Tempo/StatusBarController.swift:90-100`
- Modify: `Sources/Tempo/PreviewRenderer.swift:72`

**Interfaces:**
- Consumes: module `Sparkle` (Task 1).
- Produces, for Task 3: `@MainActor final class UpdateController: NSObject, ObservableObject` with `@Published private(set) var canCheckForUpdates: Bool`, `@Published private(set) var updateAvailable: Bool`, `let version: String`, `func start()`, `func checkForUpdates()`. It is injected with `.environmentObject(updates)` into `PopoverRootView`.
- Changes: `StatusBarController.init(store:updates:)` (was `init(store:)`).

- [ ] **Step 1: Create `Sources/Tempo/UpdateController.swift`**

```swift
import AppKit
import Combine
import os
import Sparkle

/// Wraps Sparkle for the menu bar app. One instance for the app's lifetime, created by `AppDelegate`.
/// `start()` runs only in a normal run: preview, idle-preview and click-test runs never touch the
/// network or show update alerts. Sparkle reads `SUFeedURL` and `SUPublicEDKey` from Info.plist.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    /// False before `start()` and while an update session runs.
    @Published private(set) var canCheckForUpdates = false
    /// True while a scheduled (not user-initiated) update waits for the user's attention. The footer
    /// shows a hint; a click runs `checkForUpdates()`, which brings Sparkle's alert to the front.
    @Published private(set) var updateAvailable = false
    /// `CFBundleShortVersionString`, or "dev" outside an app bundle.
    let version: String

    private var controller: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "app.tempo.menubar", category: "updates")

    override init() {
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        super.init()
        // startingUpdater: false has no side effects, so previews can create this freely.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] can in self?.canCheckForUpdates = can }
            .store(in: &cancellables)
    }

    /// Starts the scheduled checks (once a day, `SUScheduledCheckInterval`).
    func start() {
        do {
            try controller.updater.start()
        } catch {
            logger.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A user-initiated check. Sparkle shows the result in front of other apps.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate (called by Sparkle on the main thread)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Right after launch Sparkle may show the alert itself. Later the footer hint takes over.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let scheduled = !state.userInitiated
        MainActor.assumeIsolated { updateAvailable = scheduled }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { updateAvailable = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { updateAvailable = false }
    }
}
```

- [ ] **Step 2: Wire it in `AppDelegate.swift`**

Replace lines 6-8 (the properties) with:

```swift
    private var store: TimeStore!
    private var statusBar: StatusBarController!
    private var idleMonitor: IdleMonitor?
    private var updates: UpdateController!
```

Replace lines 16-19 with:

```swift
        installEditMenu()
        store = TimeStore()
        updates = UpdateController()
        statusBar = StatusBarController(store: store, updates: updates)
        idleMonitor = IdleMonitor(store: store) { [weak self] in self?.statusBar.itemScreenFrame }
```

Replace line 29 (`store.bootstrap()`) with:

```swift
        updates.start()   // Only a normal run gets here: the preview and test flags returned above.
        store.bootstrap()
```

- [ ] **Step 3: Inject it in `StatusBarController.swift`**

Change line 90 and line 99:

```swift
    init(store: TimeStore, updates: UpdateController) {
```
```swift
            rootView: PopoverRootView().environmentObject(store).environmentObject(nav).environmentObject(updates)
```

- [ ] **Step 4: Inject it in `PreviewRenderer.swift`**

Change line 72 to:

```swift
        let view = PopoverRootView().environmentObject(store).environmentObject(nav)
            .environmentObject(UpdateController()).environment(\.colorScheme, scheme)
```

- [ ] **Step 5: Build and run the preview smoke test**

The raw binary needs the framework path; inside the bundle (Task 4) the rpath does this.

Run:
```bash
swift build 2>&1 | grep -E "error|warning: .*UpdateController|Build complete" | head
BIN="$(swift build --show-bin-path)"
rm -rf /tmp/tempo-previews
DYLD_FRAMEWORK_PATH="$BIN" "$BIN/Tempo" --render-previews /tmp/tempo-previews
ls /tmp/tempo-previews | wc -l
```
Expected: `Build complete!`, no errors; the last line prints `14` (seven screens in dark and light).

- [ ] **Step 6: Commit**

```bash
git add Sources/Tempo/UpdateController.swift Sources/Tempo/AppDelegate.swift Sources/Tempo/StatusBarController.swift Sources/Tempo/PreviewRenderer.swift
git commit -q -m "$(cat <<'EOF'
feat: wrap Sparkle in an UpdateController started only in normal runs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Settings row and footer hint

**Files:**
- Modify: `Sources/Tempo/Views/SettingsView.swift:74-79,153-156,182`
- Modify: `Sources/Tempo/Views/MainView.swift:405-414`

**Interfaces:**
- Consumes: `UpdateController` (`version`, `canCheckForUpdates`, `updateAvailable`, `checkForUpdates()`) from the environment (Task 2). `Brand.font`, `Brand.violet`, `SecondaryButtonStyle`, `IconButton(systemName:help:tint:action:)` from `Brand.swift`.

- [ ] **Step 1: Settings: environment object, "About" group, login-item text**

Locate by content, not by line number: the insert below shifts the lines that follow.

In `SettingsView`, directly after `@EnvironmentObject var store: TimeStore` add:

```swift
    @EnvironmentObject var updates: UpdateController
```

Replace the two-line `Button("Sign out") { store.signOut() }` / `.buttonStyle(SecondaryButtonStyle())` block with:

```swift
                    group("About") {
                        HStack {
                            Text("Version \(updates.version)").font(Brand.font(13))
                            Spacer()
                            Button("Check for updates…") { updates.checkForUpdates() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(!updates.canCheckForUpdates)
                        }
                    }

                    Button("Sign out") { store.signOut() }
                        .buttonStyle(SecondaryButtonStyle())
```

In `setLaunchAtLogin`, replace the `loginError = "macOS did not allow this: …"` line with:

```swift
            loginError = "macOS did not allow this: \(error.localizedDescription). Move Tempo to your Applications folder (~/Applications) and try again."
```

- [ ] **Step 2: Footer: hint while a scheduled update waits**

In `FooterBar` (`MainView.swift`), directly after `@EnvironmentObject var nav: Navigator` add:

```swift
    @EnvironmentObject var updates: UpdateController
```

Directly after the refresh `IconButton` and its two modifiers (`.rotationEffect(…)`, `.animation(…)`) add:

```swift
            if updates.updateAvailable {
                IconButton(systemName: "arrow.down.circle", help: "Update available", tint: Brand.violet) {
                    updates.checkForUpdates()
                }
            }
```

- [ ] **Step 3: Build and render the settings screen**

Run:
```bash
swift build 2>&1 | grep -E "error|Build complete" | head
BIN="$(swift build --show-bin-path)"
rm -rf /tmp/tempo-previews
DYLD_FRAMEWORK_PATH="$BIN" "$BIN/Tempo" --render-previews /tmp/tempo-previews
ls /tmp/tempo-previews | wc -l
```
Expected: `Build complete!`; `14`. Then open `/tmp/tempo-previews/settings-dark.png` (Read tool) and check: an "About" card with "Version dev" and a disabled "Check for updates…" button sits above "Sign out".

- [ ] **Step 4: Commit**

```bash
git add Sources/Tempo/Views/SettingsView.swift Sources/Tempo/Views/MainView.swift
git commit -q -m "$(cat <<'EOF'
feat: version and Check for updates in Settings; footer hint for a waiting update

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `scripts/build-app.sh` with Sparkle embedded, plus the EdDSA key pair

**Files:**
- Modify (rewrite): `scripts/build-app.sh`

**Interfaces:**
- Consumes: `swift build` products and `Sparkle.framework` in the bin path (Task 1).
- Produces, for Tasks 5 and 7: `dist/Tempo.app` and `dist/Tempo.zip`; env interface `VERSION` (default newest tag without `v`, else `0.0.0`), `REPO` (default `NoeFabris/tempo`), `ARCHS` (`universal` | `host`); exits non-zero when any self-check fails.

- [ ] **Step 1: Rewrite `scripts/build-app.sh`**

```bash
#!/bin/bash
# Builds dist/Tempo.app and dist/Tempo.zip: a universal, ad hoc signed app with Sparkle embedded.
#   VERSION=1.2.0    marketing and bundle version (default: newest tag without "v", else 0.0.0)
#   REPO=owner/repo  GitHub repository for the Sparkle feed URL
#   ARCHS=host       build only for this Mac (default: universal)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-NoeFabris/tempo}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
ARCHS="${ARCHS:-universal}"
# Public half of the Sparkle EdDSA key. The private half lives in the maintainer's login Keychain,
# the GitHub secret SPARKLE_PRIVATE_KEY and the password manager. See docs/release.md.
SU_PUBLIC_ED_KEY="REPLACE_ME"
FEED_URL="https://github.com/${REPO}/releases/latest/download/appcast.xml"
APP="dist/Tempo.app"
ZIP="dist/Tempo.zip"

fail() { echo "build-app: $*" >&2; exit 1; }
[[ "$SU_PUBLIC_ED_KEY" != "REPLACE_ME" ]] || fail "SU_PUBLIC_ED_KEY is not set (see docs/release.md)"

ARCH_FLAGS="--arch arm64 --arch x86_64"
[[ "$ARCHS" != "host" ]] || ARCH_FLAGS=""
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Tempo" "$APP/Contents/MacOS/Tempo"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
# ditto keeps the symlinks and executable bits inside the framework; Sparkle's installer needs them.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# SwiftPM links @rpath/Sparkle.framework but adds no rpath for it. (The tool warns that this
# invalidates the linker's signature; codesign below replaces it.)
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Tempo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tempo</string>
  <key>CFBundleDisplayName</key><string>Tempo</string>
  <key>CFBundleIdentifier</key><string>app.tempo.menubar</string>
  <key>CFBundleExecutable</key><string>Tempo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Ad hoc. No hardened runtime: library validation would reject the ad hoc signed Sparkle.framework.
codesign --force --sign - "$APP"

# Self-checks. A broken bundle must never reach a release.
codesign --verify --deep --strict "$APP" || fail "code signature does not verify"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is not valid"
otool -l "$APP/Contents/MacOS/Tempo" | grep -q '@executable_path/../Frameworks' || fail "rpath missing"
[[ -x "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ]] || fail "Sparkle.framework is incomplete"
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/Tempo")"
if [[ "$ARCHS" != "host" ]]; then
  [[ "$ARCHS_BUILT" == *arm64* && "$ARCHS_BUILT" == *x86_64* ]] || fail "not universal: $ARCHS_BUILT"
fi

# --sequesterRsrc keeps the ._* AppleDouble entries out of the zip.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Built $APP $VERSION ($ARCHS_BUILT) and $ZIP"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/build-app.sh && git diff --stat`
Expected: `scripts/build-app.sh` listed; `ls -l scripts/build-app.sh` shows `-rwxr-xr-x`.

- [ ] **Step 3: Verify the placeholder guard (Review Focus 3)**

Run: `scripts/build-app.sh; echo "exit=$?"`
Expected: `build-app: SU_PUBLIC_ED_KEY is not set (see docs/release.md)` and `exit=1`. No `dist/` is created.

- [ ] **Step 4: Create the EdDSA key pair (once) and paste the public key**

`generate_keys` stores the private key in the login Keychain and prints the public key. If a key exists it reuses it. macOS may ask for Keychain access: click "Always Allow".

Run:
```bash
GK="$(find .build/artifacts -type f -name generate_keys | head -1)"
"$GK" >/dev/null
PUB="$("$GK" -p)"
echo "public key: $PUB"
sed -i '' "s|^SU_PUBLIC_ED_KEY=.*|SU_PUBLIC_ED_KEY=\"$PUB\"|" scripts/build-app.sh
grep '^SU_PUBLIC_ED_KEY=' scripts/build-app.sh
```
Expected: a 44-character base64 string (ends with `=`), now in the script.

- [ ] **Step 5: Build universal and check the bundle, the zip and the runtime**

Run:
```bash
scripts/build-app.sh
plutil -p dist/Tempo.app/Contents/Info.plist | grep -E 'SU|Version'
unzip -l dist/Tempo.zip | awk 'NR>3 && $4 != "" {print $4}' | grep -v '^Tempo.app/' | grep -c . || true
unzip -l dist/Tempo.zip | grep -c '/\._' || true
rm -rf /tmp/tempo-previews && dist/Tempo.app/Contents/MacOS/Tempo --render-previews /tmp/tempo-previews && ls /tmp/tempo-previews | wc -l
```
Expected: last line of the build `Built dist/Tempo.app 0.0.0 (x86_64 arm64) and dist/Tempo.zip`; the plist shows `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks => 1`, both version keys `0.0.0`; the two `grep -c` lines print `0` (only `Tempo.app/` entries, no `._*`); the preview run prints `14` (the embedded framework loads through the rpath).

- [ ] **Step 6: Quick host-only build**

Run: `ARCHS=host VERSION=0.0.0 scripts/build-app.sh | tail -1`
Expected: `Built dist/Tempo.app 0.0.0 (arm64) and dist/Tempo.zip`.

- [ ] **Step 7: Commit**

```bash
git add scripts/build-app.sh
git commit -q -m "$(cat <<'EOF'
feat: embed Sparkle in the app bundle and verify the build output

Ad hoc signature without hardened runtime, Sparkle feed and public key in
Info.plist, self-checks for the signature, rpath, framework and archs.
The Developer ID branch is gone; the spec records how to add it later.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `scripts/release.sh`

**Files:**
- Create: `scripts/release.sh`
- Modify: `.gitignore` (add `feed/`)

**Interfaces:**
- Consumes: `scripts/build-app.sh` (Task 4, env `VERSION`, `REPO`); `generate_appcast` under `.build/artifacts` (Task 1); `gh` CLI.
- Produces, for Task 6: env interface `VERSION` (or `GITHUB_REF_NAME`), `REPO`, `SPARKLE_PRIVATE_KEY`, `GH_TOKEN`, `DRY_RUN`, `PREVIOUS_APPCAST_URL`; a GitHub release `v$VERSION` with assets `Tempo.zip` and `appcast.xml`; `feed/` left on disk.

- [ ] **Step 1: Create `scripts/release.sh`**

```bash
#!/bin/bash
# Publishes one version: builds, signs the archive with the Sparkle EdDSA key, extends the appcast
# and creates the GitHub release. Same script on the maintainer's Mac and in the Release workflow.
#   VERSION=1.2.0            required (the workflow derives it from the tag v1.2.0)
#   REPO=owner/repo          GitHub repository
#   SPARKLE_PRIVATE_KEY=…    the private key; when unset, generate_appcast reads the login Keychain
#   DRY_RUN=1                everything except the GitHub release; leaves feed/ for inspection
#   PREVIOUS_APPCAST_URL=…   where the published feed is (tests point it at a local file)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-NoeFabris/tempo}"
VERSION="${VERSION:-${GITHUB_REF_NAME:-}}"
VERSION="${VERSION#v}"
PREVIOUS_APPCAST_URL="${PREVIOUS_APPCAST_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}"
fail() { echo "release: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.0, got '${VERSION:-<empty>}'"
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG does not exist; run: git tag $TAG"
[[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || fail "tag $TAG does not point at HEAD"

rm -rf feed && mkdir -p feed
# The published feed (none before the first release). generate_appcast appends the new item to it and
# keeps the older items, whose enclosures point at their own tags.
curl -fsSL -o feed/appcast.xml "$PREVIOUS_APPCAST_URL" 2>/dev/null || rm -f feed/appcast.xml
if [[ -f feed/appcast.xml ]]; then
  NEWEST="$(grep -o 'sparkle:version="[^"]*"' feed/appcast.xml | cut -d'"' -f2 | sort -V | tail -1)"
  HIGHEST="$(printf '%s\n%s\n' "$NEWEST" "$VERSION" | sort -V | tail -1)"
  [[ "$HIGHEST" == "$VERSION" && "$NEWEST" != "$VERSION" ]] || fail "$VERSION is not newer than the published $NEWEST"
fi

VERSION="$VERSION" REPO="$REPO" scripts/build-app.sh
cp dist/Tempo.zip feed/Tempo.zip

# Release notes: one line per commit since the previous tag. The same basename as the archive makes
# generate_appcast attach them to the item (markdown needs Sparkle 2.9+, which the app embeds).
PREV_TAG="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
{
  echo "## Tempo $VERSION"
  echo
  if [[ -n "$PREV_TAG" ]]; then git log --format='- %s' "$PREV_TAG..HEAD"; else git log --format='- %s'; fi
} > feed/Tempo.md

GEN="$(find .build/artifacts -type f -name generate_appcast | head -1)"
[[ -n "$GEN" ]] || fail "generate_appcast not found under .build/artifacts (run swift build)"
PREFIX="https://github.com/$REPO/releases/download/$TAG/"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GEN" --ed-key-file - --download-url-prefix "$PREFIX" \
    --link "https://github.com/$REPO" --embed-release-notes feed
else
  "$GEN" --download-url-prefix "$PREFIX" --link "https://github.com/$REPO" --embed-release-notes feed
fi

grep -q "sparkle:version=\"$VERSION\"" feed/appcast.xml || fail "appcast has no item for $VERSION"
grep -q "releases/download/$TAG/Tempo.zip" feed/appcast.xml || fail "appcast enclosure URL is wrong"
grep -q 'sparkle:edSignature="' feed/appcast.xml || fail "appcast item has no EdDSA signature"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "Dry run: feed/ is ready, no release created"
  exit 0
fi
gh release create "$TAG" feed/Tempo.zip feed/appcast.xml --repo "$REPO" --title "Tempo $VERSION" \
  --notes-file feed/Tempo.md --verify-tag
echo "Released https://github.com/$REPO/releases/tag/$TAG"
```

- [ ] **Step 2: Ignore the feed directory and make the script executable**

Append `feed/` to `.gitignore` (new line after `dist/`). Run: `chmod +x scripts/release.sh`.

- [ ] **Step 3: Dry run against a throw-away tag**

generate_appcast reads the private key from the Keychain; click "Allow" if macOS asks.

Run:
```bash
git tag v0.0.1
VERSION=0.0.1 DRY_RUN=1 scripts/release.sh | tail -2
grep -o 'sparkle:version="[^"]*"\|url="[^"]*"\|sparkle:edSignature="[^"]\{8\}' feed/appcast.xml
cat feed/Tempo.md | head -3
```
Expected: `Dry run: feed/ is ready, no release created`; `sparkle:version="0.0.1"`, `url="https://github.com/NoeFabris/tempo/releases/download/v0.0.1/Tempo.zip"`, an `edSignature`; `feed/Tempo.md` starts with `## Tempo 0.0.1` and lists the commits.

- [ ] **Step 4: Dry run with the key from the environment (the CI path)**

Run:
```bash
GK="$(find .build/artifacts -type f -name generate_keys | head -1)"
"$GK" -x /tmp/sparkle-test.key
KEY="$(cat /tmp/sparkle-test.key)"; rm -P /tmp/sparkle-test.key
SPARKLE_PRIVATE_KEY="$KEY" VERSION=0.0.1 DRY_RUN=1 scripts/release.sh | tail -1
unset KEY
```
Expected: `Dry run: feed/ is ready, no release created` (the key piped through `--ed-key-file -` works).

- [ ] **Step 5: Negative checks (Review Focus 2 and 4)**

Run:
```bash
VERSION=1.0.0-beta DRY_RUN=1 scripts/release.sh; echo "exit=$?"
VERSION= DRY_RUN=1 scripts/release.sh; echo "exit=$?"
VERSION=9.9.9 DRY_RUN=1 scripts/release.sh; echo "exit=$?"
printf '<rss><channel><item><sparkle:version="9.9.9"/></item></channel></rss>' > /tmp/old-appcast.xml
PREVIOUS_APPCAST_URL="file:///tmp/old-appcast.xml" VERSION=v0.0.1 DRY_RUN=1 scripts/release.sh; echo "exit=$?"
```
Expected, in order: `release: VERSION must look like 1.2.0, got '1.0.0-beta'` exit=1; `… got '<empty>'` exit=1; `release: tag v9.9.9 does not exist; run: git tag v9.9.9` exit=1; `release: 0.0.1 is not newer than the published 9.9.9` exit=1 (the `v` prefix was stripped and the version check ran before any build).

- [ ] **Step 6: Clean up the throw-away tag and artifacts**

Run: `git tag -d v0.0.1 && rm -rf feed /tmp/old-appcast.xml && git status --short`
Expected: `Deleted tag 'v0.0.1'`; status shows only `.gitignore` and `scripts/release.sh`.

- [ ] **Step 7: Commit**

```bash
git add .gitignore scripts/release.sh
git commit -q -m "$(cat <<'EOF'
feat: release script that signs the zip, extends the appcast and creates the GitHub release

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: GitHub Actions workflows

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/release.sh` env interface (Task 5); `scripts/build-app.sh` `ARCHS=host` (Task 4); repository secret `SPARKLE_PRIVATE_KEY` (set in Task 9).

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: macos-26
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v7
      - run: swift test
      - run: ARCHS=host VERSION=0.0.0 scripts/build-app.sh
```

- [ ] **Step 2: Create `.github/workflows/release.yml`**

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
        with:
          fetch-depth: 0   # tags and history for the release notes
      - run: swift test
      - run: scripts/release.sh
        env:
          REPO: ${{ github.repository }}
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
          GH_TOKEN: ${{ github.token }}
```

- [ ] **Step 3: Validate the YAML and the runner label**

Run:
```bash
for f in .github/workflows/*.yml; do ruby -ryaml -e 'YAML.load_file(ARGV[0]); puts "ok #{ARGV[0]}"' "$f"; done
grep -h 'runs-on' .github/workflows/*.yml | sort -u
grep -c 'macos-14' .github/workflows/*.yml || true
```
Expected: `ok .github/workflows/ci.yml`, `ok .github/workflows/release.yml`; one unique line `    runs-on: macos-26`; `0` for `macos-14`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml
git commit -q -m "$(cat <<'EOF'
ci: test on every push; build and publish a release on every v* tag

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `install.sh`

**Files:**
- Create: `install.sh` (repo root)

**Interfaces:**
- Consumes: the release asset `Tempo.zip` (Task 5) at `https://github.com/$REPO/releases/latest/download/Tempo.zip`.
- Produces: `~/Applications/Tempo.app`, running. Test overrides: `TEMPO_ZIP_URL` (any `curl` URL, including `file://`), `TEMPO_APP_DIR` (default `$HOME/Applications`).

- [ ] **Step 1: Create `install.sh`**

```sh
#!/bin/sh
# Installs or updates Tempo for the current user. No admin rights needed.
#   curl -fsSL https://raw.githubusercontent.com/NoeFabris/tempo/main/install.sh | sh
# curl downloads carry no quarantine flag, so macOS shows no Gatekeeper dialog for this app.
set -eu

REPO="NoeFabris/tempo"
ZIP_URL="${TEMPO_ZIP_URL:-https://github.com/$REPO/releases/latest/download/Tempo.zip}"
APP_DIR="${TEMPO_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Tempo.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "install: $*" >&2; exit 1; }

echo "Downloading the latest Tempo..."
curl -fsSL -o "$TMP/Tempo.zip" "$ZIP_URL" || fail "download failed ($ZIP_URL)"
ditto -x -k "$TMP/Tempo.zip" "$TMP/x" || fail "could not extract the archive"
[ -x "$TMP/x/Tempo.app/Contents/MacOS/Tempo" ] || fail "the archive does not contain Tempo.app"
codesign --verify --deep --strict "$TMP/x/Tempo.app" || fail "the app is damaged (signature check failed)"
NEW_VERSION="$(defaults read "$TMP/x/Tempo.app/Contents/Info.plist" CFBundleShortVersionString)"

if pgrep -xq Tempo; then
  echo "Quitting the running Tempo..."
  # The pgrep guard matters: without it, AppleScript would launch Tempo in order to quit it.
  osascript -e 'tell application id "app.tempo.menubar" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -xq Tempo && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
  if pgrep -xq Tempo; then pkill -x Tempo || true; sleep 1; fi
fi

mkdir -p "$APP_DIR"
rm -rf "$APP"
ditto "$TMP/x/Tempo.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [ -d "/Applications/Tempo.app" ] && [ "$APP" != "/Applications/Tempo.app" ]; then
  echo "Note: an older copy exists at /Applications/Tempo.app. Delete it to avoid two copies."
fi

open "$APP"
echo "Installed Tempo $NEW_VERSION to $APP_DIR"
```

- [ ] **Step 2: Syntax check and permissions**

Run: `sh -n install.sh && chmod +x install.sh && echo syntax-ok`
Expected: `syntax-ok`.

- [ ] **Step 3: Install the local build for real**

This replaces `~/Applications/Tempo.app` on this Mac with the Task 4 build and opens it. That is the intended use on the maintainer's Mac.

Run:
```bash
scripts/build-app.sh | tail -1
TEMPO_ZIP_URL="file://$PWD/dist/Tempo.zip" sh install.sh
defaults read ~/Applications/Tempo.app/Contents/Info.plist CFBundleShortVersionString
xattr -l ~/Applications/Tempo.app | grep -c quarantine || true
sleep 2; pgrep -x Tempo
```
Expected: `Downloading the latest Tempo...`, `Installed Tempo 0.0.0 to /Users/<you>/Applications`; version `0.0.0`; `0` quarantine attributes; a PID. The Tempo item appears in the menu bar with no dialog.

- [ ] **Step 4: Install over the running app, and a failed download (Review Focus 1 and 5)**

Run:
```bash
BEFORE="$(pgrep -x Tempo)"
TEMPO_ZIP_URL="file://$PWD/dist/Tempo.zip" sh install.sh
sleep 2; AFTER="$(pgrep -x Tempo)"; echo "before=$BEFORE after=$AFTER"
MTIME_BEFORE="$(stat -f %m ~/Applications/Tempo.app/Contents/Info.plist)"
TEMPO_ZIP_URL="file:///nonexistent/Tempo.zip" sh install.sh; echo "exit=$?"
MTIME_AFTER="$(stat -f %m ~/Applications/Tempo.app/Contents/Info.plist)"
[ "$MTIME_BEFORE" = "$MTIME_AFTER" ] && pgrep -xq Tempo && echo "install untouched, app still running"
```
Expected: the second install prints `Quitting the running Tempo...` and `Installed Tempo 0.0.0 …`; `before` and `after` are different PIDs; the failed download prints `install: download failed (file:///nonexistent/Tempo.zip)` with `exit=1`; the last line prints `install untouched, app still running`.

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -q -m "$(cat <<'EOF'
feat: one-line installer into ~/Applications with no admin rights

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: README, release runbook, old spec pointer

**Files:**
- Modify (rewrite): `README.md`
- Create: `docs/release.md`
- Modify: `docs/superpowers/specs/2026-09-30-productive-menubar-design.md:133-136`

**Interfaces:**
- Consumes: the install command (Task 7), `scripts/release.sh` and the key procedure (Tasks 4-5), the workflows (Task 6).

- [ ] **Step 1: Rewrite `README.md`**

```markdown
# Tempo

A small macOS menu bar timer for [Productive](https://productive.io), similar to the Harvest menu bar app.

```
[ ▶ | 0:45 ]    click ▶ to start or stop · click the time to open the popup
```

- Start and stop from the menu bar. ▶ continues your last service.
- The popup shows the running timer, the full week (Mon–Sun totals, weekly target), and the
  entries of the selected day. Edit the time and note, delete, or add a manual entry.
- Favourites for the services you use most, and a search in all services you can track.
- When a monthly budget closes, a favourite moves to the new budget after one confirmation.
- Meetings from the calendar connected in Productive show under the day; + logs one, with the
  service used last time for that meeting.
- Native Swift. No web runtime.

## Install (colleagues)

Paste this in Terminal (⌘ Space, type "Terminal"):

```sh
curl -fsSL https://raw.githubusercontent.com/NoeFabris/tempo/main/install.sh | sh
```

It downloads the latest release into `~/Applications` and opens Tempo. No admin rights are needed,
and macOS shows no security dialog: a `curl` download carries no quarantine flag. The same command
also updates an existing installation. Requires macOS 14 or later.

Then, in Productive, go to **Settings › API integrations** and generate a personal access token
with read/write access. Paste the token and your organisation ID into Tempo and click
**Test connection**.

The token is stored in `~/Library/Application Support/Tempo/token`, readable only by your user
(folder 0700, file 0600). The app sends it only to `api.productive.io`. Sign out deletes it.

**Updates.** Tempo checks for a new version once a day. Click **Install and Relaunch** when it asks,
or use **Settings › Check for updates…**. If you used an early build (bundle id
`com.example.tempo`), enter the organisation ID and the token once more after the install.

## Build

Requires Xcode (Swift 6) on macOS 14 or later.

```sh
swift test                              # unit tests
scripts/build-app.sh                    # dist/Tempo.app and dist/Tempo.zip (universal)
ARCHS=host scripts/build-app.sh         # faster: this Mac's architecture only
open dist/Tempo.app
```

Builds are signed ad hoc and embed Sparkle. Render all popup screens with sample data (no account
needed):

```sh
dist/Tempo.app/Contents/MacOS/Tempo --render-previews /tmp/tempo-previews
```

## Release (maintainer)

```sh
git tag v1.2.0 && git push origin main v1.2.0
```

The Release workflow builds, signs the archive with the Sparkle EdDSA key, extends `appcast.xml`
and publishes both as release assets. Installed copies update from there. Details, the one-time key
setup and the local fallback: [`docs/release.md`](docs/release.md).

## Check the Productive API

`scripts/live-check.sh` runs each API call that Tempo uses against your account. It creates one
0-minute entry, runs a timer on it for 65 seconds, and then deletes the entry.

```sh
PRODUCTIVE_TOKEN=… PRODUCTIVE_ORG_ID=… scripts/live-check.sh
```

## Layout

| Path | Job |
|---|---|
| `Sources/ProductiveCore` | API client (JSON:API), models, time format, favourites matcher, app state (`TimeStore`) |
| `Sources/Tempo` | Menu bar item, popup views, colour and type tokens, Sparkle wrapper (`UpdateController`) |
| `Tests/ProductiveCoreTests` | Unit tests with JSON fixtures and a mock API |
| `scripts/build-app.sh`, `scripts/release.sh` | Build the bundle; sign, appcast and GitHub release |
| `install.sh` | One-line installer for colleagues |
| `.github/workflows` | CI on push, release on tag |
| `docs/superpowers/specs` | Design specs |

Inter Tight is included under the SIL Open Font License (`Resources/Fonts/OFL.txt`).
```

- [ ] **Step 2: Create `docs/release.md`**

```markdown
# Releasing Tempo

Tempo ships from GitHub. Colleagues install with `install.sh`; installed copies update through
Sparkle. The design is in `docs/superpowers/specs/2026-10-01-distribution-and-updates-design.md`.

## One-time setup

1. Build once so the Sparkle tools exist: `swift build`.
2. Create the EdDSA key pair in your login Keychain and print the public key:

   ```sh
   GK="$(find .build/artifacts -type f -name generate_keys | head -1)"
   "$GK"        # creates the key when none exists
   "$GK" -p     # prints the public key
   ```

   The public key is the constant `SU_PUBLIC_ED_KEY` in `scripts/build-app.sh`.
3. Export the private key and keep it in two more places. Never commit it.

   ```sh
   "$GK" -x "$TMPDIR/sparkle-private.key"
   gh secret set SPARKLE_PRIVATE_KEY --repo NoeFabris/tempo < "$TMPDIR/sparkle-private.key"
   pbcopy < "$TMPDIR/sparkle-private.key"     # paste into the password manager, then:
   rm -P "$TMPDIR/sparkle-private.key"
   ```

   Without the private key no update can be signed. Key rotation needs a Developer ID, so a lost
   key means colleagues reinstall with the one-line command.
4. Optional housekeeping: `security delete-identity -c "Tempo Local Signing"` removes the stale
   self-signed identity from the earlier approach.

## Release a version

1. Everything is committed on `main` and the CI workflow is green.
2. `git tag v1.2.0 && git push origin main v1.2.0`
3. The Release workflow builds, signs and publishes: https://github.com/NoeFabris/tempo/releases
4. Installed copies see the update within a day. **Settings › Check for updates…** checks at once.

Versions are `MAJOR.MINOR.PATCH` and must increase. No pre-release tags. Never move or delete a
published tag.

## Fallback: release from this Mac

After step 2 above, when GitHub Actions is unavailable: `VERSION=1.2.0 scripts/release.sh`.
The key comes from the Keychain (allow access when asked). `DRY_RUN=1` does everything except the
GitHub release and leaves `feed/` for inspection.

## Troubleshooting

- "The update is improperly signed and could not be validated": generic Sparkle text. Open Console
  and filter for "Sparkle". Usual causes: a stale cached archive, or an item signed with another key.
- The Release workflow fails in `swift build`: the runner's Xcode differs from yours. The CI workflow
  shows this on the push before the tag. Select another Xcode on the image if needed.
- A colleague sees a Gatekeeper dialog: the zip came from a browser. Use the install command.
- Two copies of Tempo: delete `/Applications/Tempo.app`; the installer uses `~/Applications`.

## Later: Developer ID

See §11 of the design spec. Keep the EdDSA key; add inside-out signing with the hardened runtime,
notarisation and stapling to `scripts/build-app.sh`.
```

- [ ] **Step 3: Point the old spec at the new one**

Replace lines 133-136 of `docs/superpowers/specs/2026-09-30-productive-menubar-design.md` with:

```markdown
## Distribution

See `2026-10-01-distribution-and-updates-design.md`: public GitHub releases, a `curl`-based installer
into `~/Applications`, and Sparkle updates signed with EdDSA.
```

- [ ] **Step 4: Check links and commands in the docs**

Run:
```bash
grep -n 'right-click\|DEVELOPER_ID\|NOTARY_PROFILE' README.md docs/release.md || echo "no stale references"
grep -c 'install.sh | sh' README.md
test -f docs/release.md && echo "runbook present"
```
Expected: `no stale references`; `1`; `runbook present`.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/release.md docs/superpowers/specs/2026-09-30-productive-menubar-design.md
git commit -q -m "$(cat <<'EOF'
docs: one-line install, update notes and the release runbook

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Rollout (publishing steps; each push needs the maintainer's explicit go-ahead)

These steps publish the source and binaries. Stop and ask the maintainer before Step 1, Step 4 and
Step 6. Nothing here is code.

**Files:** none.

- [ ] **Step 1: Create the public repository and push (ASK FIRST)**

Run:
```bash
gh repo create NoeFabris/tempo --public --source=. --remote=origin --push \
  --description "Menu bar timer for Productive (macOS)"
git remote -v
```
Expected: `origin https://github.com/NoeFabris/tempo.git` for fetch and push; `main` pushed.

- [ ] **Step 2: Store the private key as the Actions secret and in the password manager**

Run:
```bash
GK="$(find .build/artifacts -type f -name generate_keys | head -1)"
"$GK" -x "$TMPDIR/sparkle-private.key"
gh secret set SPARKLE_PRIVATE_KEY --repo NoeFabris/tempo < "$TMPDIR/sparkle-private.key"
pbcopy < "$TMPDIR/sparkle-private.key"
echo "The private key is on the clipboard: paste it into the password manager now."
```
Then, after the maintainer confirms the paste: `rm -P "$TMPDIR/sparkle-private.key"`,
`pbcopy < /dev/null` (clears the clipboard) and `gh secret list --repo NoeFabris/tempo`.
Expected: `SPARKLE_PRIVATE_KEY` listed with today's date.

- [ ] **Step 3: Wait for the CI workflow**

Run: `gh run watch --repo NoeFabris/tempo --exit-status $(gh run list --repo NoeFabris/tempo --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: the run completes with `✓`. If `swift build` fails on the runner, fix the toolchain
difference before any tag (see `docs/release.md`, Troubleshooting).

- [ ] **Step 4: First release `v1.0.0` (ASK FIRST)**

Run:
```bash
git tag v1.0.0 && git push origin v1.0.0
gh run watch --repo NoeFabris/tempo --exit-status $(gh run list --repo NoeFabris/tempo --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId')
gh release view v1.0.0 --repo NoeFabris/tempo --json assets --jq '.assets[].name'
curl -fsSL https://github.com/NoeFabris/tempo/releases/latest/download/appcast.xml | grep -o 'sparkle:version="[^"]*"'
```
Expected: the run completes with `✓`; assets `Tempo.zip` and `appcast.xml`; `sparkle:version="1.0.0"`.

- [ ] **Step 5: Install with the real one-line command**

Run:
```bash
curl -fsSL https://raw.githubusercontent.com/NoeFabris/tempo/main/install.sh | sh
defaults read ~/Applications/Tempo.app/Contents/Info.plist CFBundleShortVersionString
```
Expected: `Installed Tempo 1.0.0 to …/Applications`; `1.0.0`; Tempo runs, no dialog. Settings shows
"Version 1.0.0" and an enabled "Check for updates…" button.

- [ ] **Step 6: Second release `v1.0.1` and the in-app update (ASK FIRST)**

Make one small commit first, so the release notes have a line (for example a wording fix in
`README.md`). Then:

```bash
git push origin main
git tag v1.0.1 && git push origin v1.0.1
gh run watch --repo NoeFabris/tempo --exit-status $(gh run list --repo NoeFabris/tempo --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId')
curl -fsSL https://github.com/NoeFabris/tempo/releases/latest/download/appcast.xml | grep -o 'sparkle:version="[^"]*"'
```
Expected: `sparkle:version="1.0.1"` and `sparkle:version="1.0.0"` (two items).

In Tempo: **Settings › Check for updates…** → Sparkle shows "Tempo 1.0.1" with the release notes →
**Install and Relaunch** → Tempo relaunches → Settings shows "Version 1.0.1". No Gatekeeper dialog at
any point.

- [ ] **Step 7: One colleague**

Send the install command from the README to one colleague who is a standard user. Expected: Tempo
installs and opens without a password or a dialog. Then roll out to the others.
