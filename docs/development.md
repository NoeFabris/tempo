# Developing Tempo

## Build

Requires Xcode (Swift 6) on macOS 14 or later.

```sh
swift test
scripts/build-app.sh
open dist/Tempo.app
```

- `swift test` runs the unit tests.
- `scripts/build-app.sh` writes `dist/Tempo.app` and `dist/Tempo.zip` (universal).
- For a faster build for this Mac's architecture only, run `ARCHS=host scripts/build-app.sh` instead.

Builds are signed ad hoc and embed Sparkle. Releases: [`release.md`](release.md).

## Previews and screenshots

Render all popup screens with sample data (no account needed):

```sh
dist/Tempo.app/Contents/MacOS/Tempo --render-previews /tmp/tempo-previews
```

The README screenshots are `main-running-*.png` and `picker-*.png` from that folder, copied to
`docs/images/` as `main-*.png` and `picker-*.png`.

The app icon is drawn in code. After a change to `scripts/make-icon.swift`, run it in the repository root;
it writes `Resources/AppIcon.icns` and `docs/images/icon.png`:

```sh
swift scripts/make-icon.swift
```

## Test data

The repository is public. Sample data, fixtures, screenshots and commit messages use fictional clients
only (Northwind Retail, Fabrikam Finance, Wingtip Online, Acme Agency, Tailspin Sports) and the
`example.atlassian.net` Jira site. Never commit real client names, client codes, budgets or Jira keys.
The app learns client codes at runtime, from Jira keys and `[NWR]`-style budget prefixes.

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
| `scripts/make-icon.swift` | Draw the app icon |
| `install.sh` | One-line installer |
| `.github/workflows` | CI on push, release on tag |
| `docs/superpowers/specs` | Design specs |

Inter Tight is included under the SIL Open Font License (`Resources/Fonts/OFL.txt`).
