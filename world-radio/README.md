# World Radio

Browse thousands of internet radio stations from around the world and play
them straight from a Noctalia panel - each country shows its flag, and while a
station plays, its logo appears in the media widget thanks to mpv's
`--cover-art-files`.

## Plugin

| Field   | Value                                        |
| ------- | -------------------------------------------- |
| ID      | `nilsonlinux/world-radio`                    |
| Entries | Bar widget: `radio`; Panel: `Panel`          |

## Features

- **Dashboard** - two stat cards (total stations and total countries) fetched
  from the radio-browser.info stats API, a searchable list of every country
  sorted by station count, and each country's flag in a small rounded square
  matching the plugin's cards.
- **Per-country stations** - tap a country to list its stations ordered by
  votes. A search box above the list filters them by name, and rows show the
  station's favicon (downloaded on demand), codec, bitrate and vote count,
  with a **Load more** button for the next page (100 stations per page).
- **Favorites** - star any station to save it; all favorites live in one
  place and are persisted to disk.
- **Local radios** - add your own stations by URL (name is optional and
  guessed from the host). Each one can be played, favorited, or removed;
  they persist across restarts in a separate file.
- **Playback via mpv** - stations are played through `mpv` at 85% volume
  (falls back to `ffplay` when mpv is missing). Starting a new station stops
  the previous one.
- **Station logo in the media widget** - the playing station's favicon is
  passed to mpv via `--cover-art-files`, which makes mpv-mpris publish it as
  `mpris:artUrl`; Noctalia's media tab then shows the station's own logo.
- **Now playing on the bar** - while a station plays, the bar widget shows its
  name next to the icon (configurable, see `show_now_playing`) and a tooltip
  with "Now playing: <station>".
- **Two languages** - English and `pt-BR` translations.

## How it works

- `panel.luau` is the only code entry. It fetches data from
  `radio-browser.info` (`de1.api.radio-browser.info`): `/json/countries`,
  `/json/stats`, and `/json/stations/search` per country (`hidebroken=true`,
  ordered by votes). Responses are cached as `countries.json` and `stats.json`
  for 4 hours.
- Playback runs `mpv --no-video --no-terminal --volume=85 <url>`; the PID is
  written to `player.pid` so the next play (or **Stop**) can kill it
  cleanly. If the station has a logo and it's already cached, it's added with
  `--cover-art-files`; otherwise the favicon downloads in the background so
  the next play shows it.
- While playing, the plugin publishes `{name, uuid, url}` on the `playing`
  state channel. `widget.luau` watches that channel to update the bar text,
  tooltip and widget icon (`glyph`).
- Favorites and local radios are persisted as `favorites.json` and
  `custom-stations.json`; station logos are stored under `thumbs/`. All files
  live in the plugin's data directory, so they survive plugin reloads.

Open the panel directly with:

```sh
noctalia msg panel-toggle nilsonlinux/world-radio:Panel
```

## Requirements

- `mpv` (the plugin's declared dependency). When only `ffplay` is available,
  playback falls back to it (`-nodisp -loglevel quiet -autoexit -volume 85`).
- The panel only works while a network connection is available to reach
  `radio-browser.info`.

## Usage

1. Click the radio widget in the bar (or open the panel via IPC).
2. **Dashboard** - search or scroll the country list; the stat cards show the
   total of stations and countries. Tap a country to open it.
3. **Country view** - type in the search box to filter stations by name, tap
   the play button on a station to start it (it becomes a stop button while
   playing), the star to favorite it, or **Load more** for the next page.
4. **Favorites** - the star button in the header lists every station you
   starred.
5. **Local radios** - the broadcast button in the header opens your saved
   stations; `+` lets you add one with a stream URL (and an optional name).
   Use the trash button to remove it.
6. While a station plays, check the media widget for the station's logo, and
   the bar for the now-playing name.

## Settings

### Bar Widget

| Setting            | Type    | Default  | Description                                             |
| ------------------ | ------- | -------- | ------------------------------------------------------- |
| `glyph`            | `glyph` | `radio`  | Icon shown in the bar for the widget.                   |
| `show_now_playing` | `bool`  | `true`   | Show the currently playing station name next to the icon (the tooltip always keeps it). |

## Notes

- The plugin has no background service: all fetching, caching and playback is
  driven from the panel, so nothing runs while the panel is closed.
- `countries.json`, `stats.json`, `thumbs/` and `player.pid` are runtime data
  and can be safely deleted to force a refresh.
- Station logos sometimes fail to download (some favicons return 403/404) -
  playback is never blocked by that; the station just plays without artwork.

## License

MIT