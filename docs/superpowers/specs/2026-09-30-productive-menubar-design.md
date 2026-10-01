# Tempo — a Productive menu bar timer (design)

Date: 2026-09-30
Status: approved in conversation

## Purpose

The team moves from Harvest to Productive. The Productive app is heavy on resources and slow
for basic time tracking. Tempo is a small native macOS menu bar app, similar to the Harvest
menu bar app, that uses the Productive API.

Success criteria:

- Start and stop a timer from the menu bar without opening a window.
- See the time tracked so far on the current service in the menu bar.
- Open a small popup that shows the full week and the entries of a selected day.
- Low memory use (target below 50 MB), native UI, no web runtime.
- Shareable: each user adds their own token; the build contains no secrets.

## Productive API facts used

- Base URL `https://api.productive.io/api/v2/`, JSON:API (`application/vnd.api+json`).
- Headers: `X-Auth-Token` (personal access token, Settings > API integrations) and
  `X-Organization-Id`.
- Rate limits: 100 requests / 10 s, 4,000 requests / 30 min. `429` on excess.
- Hierarchy: Client (company) → Project → Budget (deal) → Section → **Service**.
  A time entry needs a person, a service and a date. A task is optional and not used.
- `GET /organization_memberships?include=person` → the token owner's person ID and name.
- `GET /services?filter[trackable_by_person_id]=…&filter[time_tracking_enabled]=true`.
- `GET /time_entries?filter[person_id]=…&filter[after]=…&filter[before]=…`.
- `POST /time_entries`, `PATCH /time_entries/{id}`, `DELETE /time_entries/{id}`.
- `GET /timers?filter[person_id]=…&sort=-started_at`, `POST /timers` (relationship
  `time_entry`), `PATCH /timers/{id}/stop`.

Items not confirmed by the docs, checked with `scripts/live-check.sh`:

1. The exact body of `POST /timers`.
2. That `organization_memberships` returns the person relationship.
3. Whether `time_entries.time` includes the minutes of a running timer.

## Behaviour

### Menu bar

Two click zones in one status item: `[ ▶ | 0:45 ]`.

- Click the icon zone: start or stop. With no timer, ▶ starts the last used service.
  If today has an unlocked entry on that service, the timer continues that entry;
  otherwise the app creates an entry (0 minutes) and starts a timer on it.
  With no last service, the popup opens on the picker.
- Click the time zone (or right-click anywhere): open the popup.
- Time format is `h:mm` only. Running: today's total for the running entry. Stopped:
  today's total for the last used service. A violet tint marks a running timer.
  A grey `⚠` marks offline or error state.

### Popup (about 340 × 520 pt)

1. Timer header: service name, client · project, elapsed `h:mm:ss`, stop button.
   When stopped: favourite quick-start chips and a "Start…" button.
2. Week header: **This week** *21:45 / 37:30*, previous / next week.
3. Day strip Mon–Sun with day totals; today is marked; one day is selected.
4. Entries of the selected day: continue (▶), edit note and time, delete. Approved or
   invoiced entries show a lock and cannot change. "+ Add entry" adds a manual entry.
5. Footer bar: settings, refresh, status, quit.

### Picker

Favourites first, then a search over all trackable services, grouped by client.
A star adds or removes a favourite.

### Favourites and monthly budgets

A favourite stores the service ID and its label (client, project, budget, service).
If the ID is no longer in the trackable list, the matcher looks for a service with the
same client + project + service name (then client + service name), and takes the
newest (highest ID). The app asks once to confirm the replacement, then stores the new ID.

### Settings

API token (user-only file), organisation ID, "Test connection" (shows the person's name),
weekly target (default 37:30), week start day (default Monday), start at login,
manage favourites (order, remove).
The first launch shows the same connection fields as a setup screen.

## Architecture

Swift Package, macOS 14+, two targets and one test target.

| Unit | Job |
|---|---|
| `ProductiveCore/JSONAPI` | Generic JSON:API document decoding. |
| `ProductiveCore/Models`, `Mapping` | Domain models and resource → model mapping. |
| `ProductiveCore/ProductiveClient` | `ProductiveAPI` protocol and the HTTP implementation. Auth headers, pagination, `429` retry, error mapping. |
| `ProductiveCore/TimeFormat`, `Week` | `h:mm` format and parse, days of a week, totals. |
| `ProductiveCore/FavouriteMatcher` | Favourite resolution after budget changes. |
| `ProductiveCore/SettingsStore` | Token in a user-only file (`FileTokenStore`); other settings in UserDefaults. |
| `ProductiveCore/TimeStore` | Main-actor app state; the only caller of `ProductiveAPI`. |
| `Tempo/StatusBarController` | Status item, two click zones, popover. |
| `Tempo/Views/*` | SwiftUI popup screens. |
| `Tempo/Brand` | Colour tokens and Inter Tight fonts. |

Data flow: refresh at launch, every 60 s, and when the popup opens. The menu bar time
ticks locally. Start and stop update the UI at once, then call the API; on failure the
UI reverts and shows the error. Network failures queue the start or stop action with its
time and send it at the next successful refresh (a queued stop corrects the entry time
to the click time).

## Visual style

- Dark: black background, white text. Light: off-white `#F1EFE9` background, black text.
- Vibrant Violet `#7546FF` only for the running dot, stop button, selected day, links.
- Mellow Yellow `#F2FA7A` only on black: today marker in dark mode.
- Inter Tight (bundled, OFL) with bold anchor + italic qualifier headings.
- The menu bar uses system font and template symbols.

## Errors

| Case | Behaviour |
|---|---|
| No network | Show last known data with `⚠`; retry every 60 s; queue start/stop. |
| `401` / `403` | Stop polling; open setup with "Token not valid". |
| `429` | Wait `Retry-After` (default 10 s) and retry, at most twice. |
| Timer started elsewhere | The next refresh shows it. |
| Favourite budget closed | Matcher + one confirmation. |
| Locked entry | Edit and delete disabled. |

## Testing

- XCTest for JSON:API decoding (fixtures), mapping, `h:mm` format/parse, week totals,
  favourite matcher, and `TimeStore` start/stop/offline logic with a mock API.
- `scripts/live-check.sh` against the real API with the user's token.

## Distribution

`scripts/build-app.sh` builds a release `.app`, signs ad hoc (or with
`DEVELOPER_ID` when set) and zips it. Unsigned builds need right-click > Open once.
