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
or use **Settings › Check for updates…**. If you used an early build of Tempo, enter the
organisation ID and the token once more after the install.

## Build

Requires Xcode (Swift 6) on macOS 14 or later.

```sh
swift test
scripts/build-app.sh
ARCHS=host scripts/build-app.sh
open dist/Tempo.app
```

- `swift test` runs the unit tests.
- `scripts/build-app.sh` writes `dist/Tempo.app` and `dist/Tempo.zip` (universal).
- `ARCHS=host scripts/build-app.sh` is faster (this Mac's architecture only).

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
