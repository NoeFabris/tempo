<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Tempo icon">
</p>

<h1 align="center">Tempo</h1>

<p align="center">A small, native macOS menu bar timer for <a href="https://productive.io">Productive</a>.</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/main-dark.png">
    <img src="docs/images/main-light.png" width="300" alt="The popup: the running timer, the week and the entries of the day">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/picker-dark.png">
    <img src="docs/images/picker-light.png" width="300" alt="The service picker: recent services, favourites and all clients">
  </picture>
</p>

<p align="center">
  <img src="docs/images/idle.png" width="340" alt="The idle question: remove the idle time and continue, remove it and stop, or keep it">
</p>

## Install

Paste this in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/NoeFabris/tempo/main/install.sh | sh
```

The script installs the latest release into `~/Applications` and opens Tempo. It needs no admin rights,
and macOS shows no security dialog. Run it again at any time to reinstall. Requires macOS 14 or later.

Then connect your account. In Productive, go to **Settings › API integrations** and generate a personal
access token with read/write access. Paste the token and your organisation ID into Tempo.

## Features

- **Menu bar timer.** `[▶ 0:45]`: click ▶ to start or stop, click the time to open the popup. ▶ continues
  your last task.
- **The week at a glance.** Day totals, your weekly target and the entries of the selected day. Edit the
  time, note, service or date, or add an entry.
- **Find a service fast.** Your two most recent services, your favourites, and a search in all services
  you can track: by client, code, budget or service.
- **Monthly budgets.** A favourite moves to the new month's budget after one confirmation. A small tag
  (`Sep`) marks a service from last month's budget.
- **Calendar meetings.** Meetings from the calendar connected in Productive show under the day. + logs one.
- **Idle detection.** Like Harvest: when you come back, remove the idle time and continue, or stop.
- **Automatic updates.** A new version installs in the background while the popup is closed. The timer
  keeps running.
- **Native.** Swift, no web runtime, light and dark mode.

The token is stored in `~/Library/Application Support/Tempo/token`, readable only by you. Tempo sends it
only to `api.productive.io`.

## Development

Build, test and project layout: [`docs/development.md`](docs/development.md).
Releases: [`docs/release.md`](docs/release.md).
