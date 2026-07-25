# SentryHub

An open-source, native **macOS** viewer for Tesla dashcam footage, built with SwiftUI.

SentryHub reads a TeslaCam drive entirely on your Mac: it organises Sentry, Saved, and Recent
clips into a browsable library, plays every camera angle locked to one timeline, draws a fully
customisable HUD over the picture, plots the drive on a map, and trims and exports a range to
MP4 with the HUD burned in.

![SentryHub icon](Resources/icon_1024.png)

> Not affiliated with, endorsed by, or sponsored by Tesla, Inc.

## Features

- **Clip library** — the app opens straight into the gallery: clips loaded, GPS-tagged, camera
  streams, and total storage at a glance, with filter chips for **All / Sentry / Saved / Recent**,
  search by date, city, coordinates or event reason, sorting by date/length/size/name, three card
  densities, and a **Grid / Map** switch that pins every GPS-tagged clip on a real map.
- **Synchronised multi-camera playback** — up to six feeds (front, rear, both repeaters, both
  B-pillars) each backed by its own `AVPlayer`, started at a shared host time and drift-corrected
  every two seconds. A Sentry event's ~60-second segments are stitched into one continuous
  timeline, with gaps where a camera didn't record so the feeds stay aligned.
- **Layouts** — Single, Side by Side, Cinema, Quad, and the Six Up grid arranged the way the
  cameras sit on the car, plus a maximise toggle. Six positional buttons (↖ ↑ ↗ ↙ ↓ ↘) pick the
  focused camera; angles the vehicle never recorded stay as labelled placeholders.
- **Customisable HUD** — speedometer, pedals, steering wheel, gear selector, Autopilot/FSD state,
  g-force indicator, date, time, location, turn signals, and compass & coordinates, each toggled
  individually. Choose KM/H, MPH and M/S (any combination), 0–2 speed decimals, an AUTO/US/EU/ISO
  date format, and interface opacity and size.
- **Maps** — a vector mini map baked into the HUD (style, corner, size, zoom, route mode, endpoint
  markers, heading rotation, opacity) plus a tile-backed interactive route map behind the transport
  bar's **Map** button, whose marker follows the play head.
- **Trim & export** — set IN and OUT points on the timeline, then export the current grid to MP4.
  The HUD is rendered by the *same* SwiftUI view the player uses, so exports are WYSIWYG. Also
  exports the current frame as a PNG.
- **Sample library** — one click generates synthetic clips with demo telemetry so the player, HUD,
  map, and exporter can be tried without a dashcam drive.
- **Themes & appearance** — six accent themes and a System/Light/Dark override.
- **One-click updates** — an optional launch check against GitHub Releases; installing downloads
  the DMG, swaps the app in place, and relaunches.
- **Local only** — footage never leaves your Mac. The single network request the app can make is
  the (off-switchable) update check.

## Installation

### Download

Grab the latest `SentryHub-x.y.z.dmg` from [Releases](https://github.com/Mac2100/SentryHub/releases),
open it, and drag **SentryHub** into **Applications**.

> **Note on Gatekeeper:** releases are ad-hoc signed (no paid Apple Developer certificate), so the
> first launch requires right-clicking the app → **Open**, or:
> ```bash
> xattr -d com.apple.quarantine /Applications/SentryHub.app
> ```

### Build from source

Requires Xcode 15+ / Swift 5.9+ on macOS 14 or later.

```bash
git clone https://github.com/Mac2100/SentryHub.git
cd SentryHub
./scripts/make_app.sh          # produces dist/SentryHub.app and dist/SentryHub-<version>.dmg
```

For development, `swift run` works directly, or open `Package.swift` in Xcode.

## Using it

Plug in the dashcam drive and choose it with **Choose Your TeslaCam Folder** (⌘O). SentryHub
accepts the drive root, the `TeslaCam` folder itself, or any folder of clips you copied off it:

```
<drive>/
  TeslaCam/
    SentryClips/2025-12-21_20-59-54/{*.mp4, event.json, thumb.png}
    SavedClips/2025-12-21_20-59-54/{*.mp4, event.json, thumb.png}
    RecentClips/2025-12-21_20-59-54-front.mp4, …
```

The chosen folder is remembered between launches. Click any card to open the player.

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `←` `→` | Step one frame |
| `⇧←` `⇧→` | Jump five seconds |
| `[` `]` | Set the trim in / out point |
| `C` | Cycle the focused camera |
| `F` | Maximise the picture |
| `Esc` | Back to the library |
| `⌘O` | Choose the TeslaCam folder |
| `⌘R` | Rescan |

## Telemetry

This is worth being precise about, because it shapes what the HUD can show.

**Tesla's dashcam files carry almost no telemetry.** The car writes video plus a small `event.json`
next to Sentry and Saved clips, holding one approximate fix:

```json
{
  "timestamp": "2025-12-21T20:59:54",
  "city": "…",
  "est_lat": "48.0610",
  "est_lon": "3.2910",
  "reason": "sentry_aware_object_detection",
  "camera": "0"
}
```

SentryHub tries three sources, richest first, and draws `—` for any field none of them supplied —
it never invents numbers:

1. **A sidecar file** next to the clip — `telemetry.json`, `telemetry.csv`,
   `<clip-name>.telemetry.json`, or `<clip-name>.csv`.
2. **Metadata embedded in the MP4** — a timed metadata track or an ISO-6709 location atom, both
   read when the firmware wrote them.
3. **`event.json`** — one static fix, enough to place the map pin.

The clock in the HUD always works: it comes from the clip's own start time plus the play head, not
from telemetry.

### Sidecar schema

Drop this next to a clip to give the HUD a full instrument feed. Exports from TeslaMate, TeslaFi,
or any GPS logger can be reshaped into it. Every field except the time reference is optional.

```json
{
  "samples": [
    {
      "t": 0.0,
      "speed_kph": 96.4,
      "lat": 48.0610,
      "lon": 3.2910,
      "heading": 182.4,
      "elevation": 214,
      "gear": "D",
      "autopilot": "autosteer",
      "accel_lon": 0.01,
      "accel_lat": 0.15,
      "steering": -3.2,
      "turn_left": false,
      "turn_right": false,
      "brake": 0.0,
      "accelerator": 0.32
    }
  ]
}
```

- Time: `t` (seconds from the clip start), `time`, or an absolute `timestamp`.
- Speed: `speed_mps`, `speed_kph`, or `speed_mph` — whichever you have.
- `autopilot` accepts `true`/`false` or `"off"`, `"available"`, `"autosteer"`, `"fsd"`.
- `gear` is `"P"`, `"R"`, `"N"`, or `"D"`.
- Pedals (`brake`, `accelerator`) are 0…1; accelerations are in g.

A bare JSON array of the same rows works too, as does a CSV whose header uses these column names.

## Export

**Export** on the transport bar opens the sheet: pick the range (the trim range or the whole clip),
the layout, a quality preset, and whether the HUD is burned in.

The HUD is rasterised from the same `HUDCanvas` view the player draws, at the export resolution,
and attached as a Core Animation overlay. HUD refresh defaults to 5 Hz because telemetry itself
samples at 1–4 Hz; raising it costs render time without adding information. Frames are held
PNG-compressed in memory so a long export doesn't balloon.

## CI / Releases

Every push and pull request builds the app and uploads a DMG artifact via GitHub Actions. Pushing a
tag like `v1.2.0` additionally creates a GitHub Release with the DMG attached — which is what the
in-app update checker looks at.

To cut a release: bump `AppVersion.marketing` in `Sources/SentryHub/Support/AppVersion.swift`, then
tag the commit `v<version>` and push the tag. The **Build** workflow can also be dispatched manually
with *release* checked.

## Privacy

- Footage is read directly from the folder you pick and never leaves your Mac.
- There is no analytics, no account, and no license check.
- The only outbound request is the optional update check against the public GitHub Releases API,
  switchable off in **Settings → Updates**.

## License

[MIT](LICENSE)
