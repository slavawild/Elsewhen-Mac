# Elsewhen for macOS

A native macOS port of **Elsewhen**, the world clock from [Omarchy](https://github.com/basecamp/omarchy)'s shell: the time in several cities at once, each over its own day of daylight, with a spinnable globe behind it. It lives in the menu bar, and clicking the globe icon opens the panel.

It is written in Swift and SwiftUI with no dependencies. The behaviour follows the original plugin (`shell/plugins/panels/elsewhen`, by Jason Fried) closely. Its model, solar and globe maths are ported line by line, and its data and translations are shared with it.

## What it does

- **One row per city**: the name, the weather, who is there, the date (or *Tomorrow*, *Yesterday*), and the time with its zone and offset.
- **A daylight strip** under each row covers that city's 24 hours, lit from its real sunrise to sunset. The marker is the sun by day and tonight's moon, in its actual phase, by night. Hover a row to see the sunrise and sunset arrows; click one for the time.
- **Scrub time**: drag along any strip, or press ← and →, and every clock moves together.
- **Hover greetings**: hovering a row shows what people say to each other at that hour there (*Buongiorno*, *Dobryi den*, *boker tov*…).
- **Globe mode**: click the little globe in the header and it grows into a spinnable globe that knocks the rows aside. It shows coastlines, the day/night terminator, and a city for every time zone. Drag to spin it, click a city to read its time, or jump to any town. Shift-click runs the transition in slow motion.
- **Where you are**: the header reads *It's 10:28 AM here in Kyiv*. Click it to say which city you are actually in.
- **People**: add names or `@github` handles to a city to see their faces on its row.
- **Reorder** rows by dragging them. Add places by name: the search knows every IANA zone plus the towns Open-Meteo's geocoder knows (Portland, Oregon is not Portland, Maine).
- First run seeds your city plus four others spread around the clock.
- 50 languages, taken from Omarchy's catalog.

### Keys (while the panel is open)

| Key | |
|---|---|
| Space | open or close the globe |
| ↑ ↓ | pick a city (the globe turns to it) |
| ← → | move every clock an hour |
| `+` / `a` | add a city; on the globe, `+` / `j` jumps to one |
| `w` | where are you? |
| `p` | who's in the picked city |
| `t` / ⌥`t` | 12/24-hour, °C/°F |
| ⌫ | remove the picked city |
| `r` | refresh weather |
| Esc | back out one layer: search, shifted time, globe, panel |
| ⌘, / ⌘Q | settings / quit |

Right-click the menu bar icon for Refresh, Settings, About and Quit.

## Install

Every CI run attaches a universal, ad-hoc signed `Elsewhen.zip` (macOS 13 Ventura or later). Unzip it and move `Elsewhen.app` to `/Applications`. The app is not notarized, so the first time, right-click it and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Elsewhen.app
```

Turn on **Open at login** in Settings.

## Build

You need Xcode 15 or later (or the Swift 5.9+ command line tools) on macOS.

```bash
swift test
```

```bash
scripts/build-app.sh        # build/Elsewhen.app and build/Elsewhen.zip
```

```bash
open build/Elsewhen.app
```

`swift run Elsewhen` also works for a quick try. Open at login only works from the bundled app.

### Layout

- `Sources/ElsewhenCore`: everything that is arithmetic or text, with no AppKit, so it is unit-tested on its own. Ported from `Model.js`, `Sun.js`, `GlobeModel.js`, `Arc.js` and `Greetings.js`.
- `Sources/Elsewhen`: the app. `PanelModel` is `Panel.qml`'s state and behaviour; the views mirror the QML components; `AppDelegate` is the menu bar item and popover.
- `scripts/make-icon.py` draws `Support/AppIcon.png`, the app icon: the app's own globe (same projection and coastlines) with a day side, a night side and a gold terminator, on a night-blue tile. `build-app.sh` turns it into `AppIcon.icns`.
- `scripts/sync-omarchy.mjs` regenerates `world.json`, `cities.json`, `greetings.json` and every `.lproj` from an Omarchy checkout. The macOS-only strings live in `scripts/mac-strings.json`.

```bash
node scripts/sync-omarchy.mjs ~/src/omarchy
```

## How it differs from the Omarchy plugin

- **Time zones come from the system.** QML has no `Intl`, so the plugin probes `date` for each zone's offset. Here Foundation's tz database answers directly, and stays correct while scrubbing across a DST change.
- **Moving the clock.** On Omarchy, picking a *here* in another zone runs `timedatectl set-timezone`. macOS keeps the time zone in System Settings, so Elsewhen offers to open *Date & Time*, remembers the city, and makes it *here* once the Mac is on that zone.
- **Settings** live in the app's user defaults instead of `shell.json`, in the same `{ name, zone, lat, lon, region, people }` shape. The ones Omarchy keeps on the widget entry are in a Settings window.
- Weather icons are SF Symbols; colours follow the system's light/dark appearance and accent colour, not the Omarchy theme.
- There is no IPC surface.

## Network

Only three things touch the network: [Open-Meteo](https://open-meteo.com) geocoding and forecasts (no API key), and the public GitHub profile and avatar of anyone you add by handle, cached in `~/Library/Caches` for a week.

## Credits

Elsewhen was designed and written by Jason Fried for Omarchy (MIT, © David Heinemeier Hansson). The coastlines are [Natural Earth](https://www.naturalearthdata.com) 110m (public domain). The translations come from Omarchy's contributors. This port is MIT licensed too; see [LICENSE](LICENSE).
