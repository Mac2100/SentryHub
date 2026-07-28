# SentryHub

An open-source, native **macOS** library and viewer for Tesla dashcam footage, built with SwiftUI.

SentryHub reads a TeslaCam drive entirely on your Mac: it organises Sentry, Saved, and Recent
clips into a browsable library, **keeps the ones that matter on your Mac after the drive is
unplugged**, groups related clips into named incidents, plays every camera angle locked to one
timeline, draws a fully customisable HUD over the picture, plots the drive on a map, and trims
and exports a range to MP4 with the HUD burned in.

![SentryHub icon](Resources/icon_1024.png)

> Not affiliated with, endorsed by, or sponsored by Tesla, Inc.

## Features

- **A library, not a window onto a USB stick** — the dashcam drive is a rolling buffer: the car
  overwrites it, and everything on it vanishes when you unplug it. Select clips and **Save to Mac**
  to copy them into a local library that's still there tomorrow. The drive and the local copies are
  merged into one gallery — one card per clip, labelled **On this Mac** or **Drive only** — with a
  **Storage** filter for *Everywhere / On This Mac / Drive Only*. With no drive connected, SentryHub
  opens straight into whatever you kept.
- **Incidents** — a second tab where clips are grouped into the thing that actually happened: every
  angle of one collision, under a name, with a claim or report number, notes, and an
  Open / Submitted / Closed status. An incident tells you at a glance how many of its clips are
  safely on your Mac, and offers to save the rest — because "the clips from the 3rd" is no use if
  they were left on a drive the car has since overwritten.
- **Multi-select** — a checkbox appears in a card's corner as you hover it, and once anything is
  ticked it shows on every card at once. Ticking one opens an action bar that floats at the bottom of
  the window and stays there while you scroll: save a batch to the Mac,
  file it
  into an incident, rename it in one go (one clip takes the name as typed; several get numbered),
  remove local copies, or clear clips off the drive. Both destructive actions state exactly what
  they'll destroy first — including the fact that dashcam drives have no Trash, so deleting off one
  is permanent.
- **Clip library** — the app opens straight into the gallery: clips loaded, what's on this Mac,
  events, incidents, recency, and total size at a glance. The filter row is a hierarchy, not a flat
  list: **All**, then **Sentry** with the reasons the car flags by itself (*Motion*, *Impact*), then
  **Saved** with the ways a driver asks for a clip to be kept (*Honk*, *Manual Save*), and an
  **Other** chip that appears only when a clip carries a `reason` SentryHub can't name. A folder
  says *where* a clip sits; a reason says *why* the car kept it, and they don't always agree — tap
  save during a Sentry event and the clip stays in `SentryClips`.

  Plus a date filter — Today, the last 7 or 30 days, or a custom range with a **time of day** on
  each end, so "that Tuesday between 9pm and midnight" is one query. Search over name, town, street, event,
  and incident, sorting by date/category/length/size/name, three card densities, and a
  **Grid / List / Map** switch — the grid for recognising footage by sight, the list for scanning
  hundreds of clips by their facts in aligned columns, the map for pinning every GPS-tagged clip on
  real tiles. The gallery is sectioned by day, event kind, or folder with sticky headers (chosen in
  Settings → Playback), because a real drive is hundreds of cards. Each card leads with what
  happened — and a Recent clip carries no badge at all, because nothing did: it's the car recording
  as it drives. Cards show date, time, place, size, and storage, and can be **renamed** by clicking
  the title — the label is stored in the app, so the timestamped files on the drive keep the names
  the car gave them.
- **Synchronised multi-camera playback** — up to six feeds (front, rear, both repeaters, both
  B-pillars) each backed by its own `AVPlayer`, started at a shared host time and drift-corrected
  every two seconds. A Sentry event's ~60-second segments are stitched into one continuous
  timeline, with gaps where a camera didn't record so the feeds stay aligned.
- **Layouts** — Single, Side by Side, Cinema, Quad, and the Six Up grid arranged the way the
  cameras sit on the car, plus a maximise toggle. Six positional buttons (↖ ↑ ↗ ↙ ↓ ↘) pick the
  focused camera; angles the vehicle never recorded stay as labelled placeholders.
- **Customisable HUD** — speedometer, pedals, steering wheel, gear selector, Autopilot/FSD state,
  g-force indicator, date, time, location, turn signals, and compass & coordinates, each toggled
  individually. Readouts a clip has no data for are hidden by default rather than drawn as `—`. Choose KM/H, MPH and M/S (any combination), 0–2 speed decimals, an AUTO/US/EU/ISO
  date format, and interface opacity and size.
- **Maps** — a vector mini map baked into the HUD, with a **Map Settings** popover for Visible,
  Theme (Dark / Light / Satellite), Rotation (Heading / North Up), Zoom level, Size (S / M / L), and
  Route Overview; corner, route line, endpoint markers, label, export inclusion, and opacity live in
  Settings → HUD. Real map tiles are snapshotted once per clip and sit under the route, so a clip
  whose only fix is the one in `event.json` still shows where it happened — as a **single pin**,
  said plainly, rather than a route line and a pair of start/finish flags stacked on one address.
  Tesla records one position per clip and nothing per second, so most clips have no route to follow;
  drop in a [sidecar](#sidecar-schema) and the map moves. Behind the same button
  sits a fully interactive route map whose camera follows the play head — or frames the whole drive
  when Route Overview is on.
- **Trim & export** — set IN and OUT points on the timeline, then export the current grid to MP4.
  The HUD is rendered by the *same* SwiftUI view the player uses, so exports are WYSIWYG. Also
  exports the current frame as a PNG.
- **Event focus** — Tesla wraps roughly ten minutes of buffer around a Sentry trigger, so the moment
  you opened the clip for is usually nine minutes in. A clip with a flagged moment therefore **opens
  a minute before it** rather than at 0:00, and the marker is reachable with one click or the `E`
  key, landing **10 seconds early** so the lead-in is visible. Both distances are adjustable in
  Settings → Playback, and clips with no event still open at the start. A clip starts playing as
  soon as it's ready, which can be turned off in the same place. The camera that
  saw it is traced with a pulsing highlight that lights up **eight seconds before** the moment and
  fades once it has passed — but only for a **Sentry motion or impact**. A horn press or a
  manual save is the driver already knowing what happened, and a highlight shown on every clip is
  one nobody reads.
- **First-run walkthrough** — the first time the library opens, the window dims and each part is
  ringed in turn with a sentence explaining it: the two tabs, the stat row, the folder-and-reason
  chips, the storage filter, the Grid/List/Map switch, and the gallery. Click anywhere to move on,
  Skip to leave, and **Settings → General → Walkthrough → Show Again** to see it later. The
  highlights are anchored to the real controls, so they follow them as the window resizes and as
  chips appear and disappear with the library's contents.
- **Themes & appearance** — six accent themes and a System/Light/Dark override.
- **One-click updates** — an optional launch check against GitHub Releases; installing downloads
  the DMG, swaps the app in place, and relaunches.
- **Local only** — footage never leaves your Mac. The single network request the app can make is
  the (off-switchable) update check.

### Where saved clips go

Clips you keep are copied into Application Support, in exactly the layout Tesla uses:

```
~/Library/Application Support/SentryHub/Library/
  SentryClips/2026-07-24_11-27-41/{*.mp4, event.json, thumb.png}
  SavedClips/…
  RecentClips/2026-07-24_11-27-41-front.mp4, …
```

That's deliberate: the same scanner reads the drive and the local library, and what you keep stays
a plain folder of MP4s that outlives SentryHub. **Settings → General → On This Mac** shows the size,
reveals the folder in Finder, and can empty it. Incidents live beside it in `incidents.json`.

Clip names and incident membership are keyed on the category and the timestamp the car wrote —
never on a file path — so a clip you renamed keeps its name when it's copied to the Mac, and when
the drive is remounted somewhere else.

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

**Plug the drive in and SentryHub opens it.** Mounted volumes are watched, and a drive holding a
`TeslaCam` folder is loaded straight into the library — at launch or the moment it appears. If a
different folder is already open the library is left alone and you're told the drive is there
instead. Pull the drive out and its clips leave with it, while anything saved to this Mac stays.

You can still pick a folder by hand with **Choose Your TeslaCam Folder** (⌘O). SentryHub accepts
the drive root, the `TeslaCam` folder itself, or any folder of clips you copied off it:

```
<drive>/
  TeslaCam/
    SentryClips/2025-12-21_20-59-54/{*.mp4, event.json, thumb.png}
    SavedClips/2025-12-21_20-59-54/{*.mp4, event.json, thumb.png}
    RecentClips/2025-12-21_20-59-54-front.mp4, …
```

The chosen folder is remembered between launches. Click any card to open the player.

Before you unplug the drive, hit **Select**, pick what's worth keeping, and choose **Save to Mac**.
Those clips stay in the library — playable, searchable, and exportable — with nothing connected.

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `←` `→` | Step one frame |
| `⇧←` `⇧→` | Jump five seconds |
| `[` `]` | Set the trim in / out point |
| `C` | Cycle the focused camera |
| `F` | Full screen — hides everything but the picture |
| `E` | Jump to just before the event |
| `Esc` | Leave full screen, or the clip if you're not in it |
| `⌘O` | Choose the TeslaCam folder |
| `⌘R` | Rescan |
| `⌘1` `⌘2` | Clips / Incidents tab |

## Telemetry

This is worth being precise about, because it shapes what the HUD can show.

**Tesla's dashcam files carry almost no telemetry.** The car writes video plus a small `event.json`
next to Sentry and Saved clips, holding one approximate fix:

```json
{
  "timestamp": "2026-07-25T14:57:38",
  "city": "Fair Lawn",
  "street": "River Rd",
  "est_lat": "40.93",
  "est_lon": "-74.1316",
  "reason": "sentry_aware_object_detection",
  "camera": "6"
}
```

`street` arrived in newer firmware; `reason` comes in two families, `sentry_aware_*` for what the
car noticed by itself and `user_interaction_*` for what the driver asked it to keep. Tesla publishes
none of this and has changed the strings across firmware, so a reason SentryHub doesn't recognise is
shown as-is and offered under the **Other** chip rather than guessed into the nearest bucket.

SentryHub tries three sources, richest first, and draws `—` for any field none of them supplied —
it never invents numbers:

1. **A sidecar file** next to the clip — `telemetry.json`, `telemetry.csv`,
   `<clip-name>.telemetry.json`, or `<clip-name>.csv`.
2. **Metadata embedded in the MP4** — a timed metadata track or an ISO-6709 location atom, both
   read when the firmware wrote them.
3. **`event.json`** — one static fix, enough to place the map pin.

The `camera` index in `event.json` is the car's own camera enumeration, not the order TeslaCam
writes files in: `0`–`2` all look forward, `3`/`4` are the B-pillars, `5`/`6` the repeaters, `7` the
rear. Index 6 is confirmed against a real event whose subject appears first on the right repeater.
An index SentryHub doesn't know simply singles out no tile.

The clock in the HUD always works: it comes from the clip's own start time plus the play head, not
from telemetry.

**On time zones:** Tesla writes none — not in a file name, not in `event.json`. Every timestamp is
therefore read in *this Mac's* time zone, which is what the date-and-time filter matches against.
Footage shot in another zone will sit at the wrong hour.

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
the layout, **Resolution** (720p/1080p), **Frame Rate** (30/60), **Quality** (4/8 Mbps), **Format**
(H.264/HEVC), and whether the HUD is burned in.

An `AVAssetReaderVideoCompositionOutput` composes the camera grid, the HUD is drawn onto each
decoded frame, and an `AVAssetWriter` encodes at the chosen resolution, frame rate, and bitrate —
so the result doesn't depend on playback keeping up or on the window staying in front.

The HUD is rasterised from the same `HUDCanvas` view the player draws, at the export resolution.
Refresh defaults to 5 Hz because telemetry itself samples at 1–4 Hz; raising it costs render time
without adding information. Frames are held PNG-compressed in memory so a long export doesn't
balloon.

## CI / Releases

Every push and pull request builds the app and uploads a DMG artifact via GitHub Actions.

**Releases publish themselves.** When a pull request lands on `main`, the workflow tags the merge
commit `v<AppVersion.marketing>` and creates a GitHub Release with the DMG attached — which is what
the in-app update checker looks at. It skips publishing when that tag already exists, so bumping
`AppVersion.marketing` in `Sources/SentryHub/Support/AppVersion.swift` is what decides a new version
ships; merging docs or fixes without a bump just refreshes the build artifact.

Pushing a `v*` tag by hand, or dispatching **Build** manually with *release* checked, publishes too.

## Privacy

- Footage is read directly from the folder you pick and never leaves your Mac.
- There is no analytics, no account, and no license check.
- The only outbound request is the optional update check against the public GitHub Releases API,
  switchable off in **Settings → Updates**.

## License

[MIT](LICENSE)
