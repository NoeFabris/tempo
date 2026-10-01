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
- Native Swift. About 5 MB on disk. No web runtime.

## Install (colleagues)

1. Unzip `Tempo.zip` and move `Tempo.app` to **Applications**.
2. The build is not notarised: right-click `Tempo.app` › **Open** › **Open** the first time.
3. In Productive, go to **Settings › API integrations** and generate a personal access token
   with read/write access.
4. Paste the token and your organisation ID into Tempo, then click **Test connection**.

The token is stored in `~/Library/Application Support/Tempo/token`, readable only by your user
(folder 0700, file 0600). The app sends it only to `api.productive.io`. Sign out deletes it.

## Build

Requires Xcode (Swift 6) on macOS 14 or later.

```sh
swift test                     # unit tests
scripts/build-app.sh           # dist/Tempo.app and dist/Tempo.zip (universal)
open dist/Tempo.app
```

Without a Developer ID, builds are signed ad hoc.

To sign and notarise for the whole team:

```sh
DEVELOPER_ID="Developer ID Application: Your Company (TEAMID)" \
NOTARY_PROFILE=tempo-notary scripts/build-app.sh
```

Render all popup screens with sample data (no account needed):

```sh
dist/Tempo.app/Contents/MacOS/Tempo --render-previews /tmp/tempo-previews
```

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
| `Sources/Tempo` | Menu bar item, popup views, colour and type tokens |
| `Tests/ProductiveCoreTests` | Unit tests with JSON fixtures and a mock API |
| `docs/superpowers/specs` | Design spec |

Inter Tight is included under the SIL Open Font License (`Resources/Fonts/OFL.txt`).
