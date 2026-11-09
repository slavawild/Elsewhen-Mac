A native macOS port of **Elsewhen**, the world clock from [Omarchy](https://github.com/basecamp/omarchy): the time in several cities at once, each over its own day of daylight, with a spinnable globe behind it. It lives in the menu bar.

## Install

1. Download **Elsewhen-__VERSION__.zip** below, unzip it, and move `Elsewhen.app` to `/Applications`.
2. The app is ad-hoc signed but not notarized, so the first time, right-click it and choose **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Elsewhen.app
   ```

3. Click the globe in the menu bar. Right-click it for Settings, where you can turn on **Open at login** and a city's clock beside the icon.

Requires **macOS 14 Sonoma** or later. Universal build: Apple silicon and Intel.

## What's in it

- One row per city: weather, who is there, the date and time, and a daylight strip from that city's real sunrise to sunset, with the sun by day and tonight's moon by night.
- Drag along any strip, or press ← →, to move every clock together. Hovering a row shows the local greeting.
- Globe mode: click the little globe in the header. It grows into a spinnable globe with the day/night terminator and a city for every time zone, and you can jump to any town from it.
- Search every IANA zone plus the towns Open-Meteo's geocoder knows; reorder rows by dragging; add people by name or `@github` handle.
- A city's time in the menu bar, keyboard shortcuts for everything, and 50 languages.

The weather and place search use [Open-Meteo](https://open-meteo.com), which needs no API key. Elsewhen was made by Jason Fried for Omarchy (MIT); the coastlines are Natural Earth. The SHA-256 of the zip is in the `.sha256` file.
