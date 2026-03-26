# wizlight.koplugin

Control WiZ smart bulbs directly from KOReader on Kindle. Adjust brightness,
color temperature, and lighting scenes without leaving your book.

## Features

- Toggle your light on or off from the menu or a custom gesture
- **Reading Mode** — one tap to warm white (3000 K, 70% brightness)
- Brightness control (10–100%)
- Color temperature control (2200–6500 K)
- Effect speed control for animated scenes (10–200)
- 11 curated scenes split into two types:
  - *Static* (solid colour): Warm White, Daylight, Cool White, Night Light, Focus
  - *Dynamic* (animated): Cozy, Relax, Candlelight, Fireplace, Wake Up, Bedtime
- Per-scene customisation — save preferred brightness, colour temperature, or speed
  per scene; scenes with saved settings are marked with *
- Named multi-bulb registry — save bulbs by room name and switch between them
- Blink-to-verify discovery — the wizard blinks each found bulb so you can
  confirm which physical light you are adding
- Automatic DHCP recovery — if a bulb's IP changes after a router restart,
  the plugin detects this and offers to re-discover the new address

## Prerequisites

- KOReader installed on a Kindle with Wi-Fi
- One or more WiZ smart bulbs on the same Wi-Fi network as your Kindle
- No account, cloud service, or app required — the plugin communicates with
  your bulbs directly over your local network

> **Note:** WiZ bulbs must be set up with the WiZ app at least once before
> the plugin can discover them.

## Installation

1. Download `wizlight.koplugin.zip` from the
   [latest release](https://github.com/Tasty-Murder/wizlight.koplugin/releases/latest).
2. Unzip the archive. You will get a folder named `wizlight.koplugin/`.
3. Copy that folder to the `koreader/plugins/` directory on your Kindle
   (connect via USB and paste alongside the other plugin folders).
4. Restart KOReader.

The plugin appears as **WiZ Light** under the Tools menu (the spanner icon in
the top bar).

## Adding your first bulb

Before you can control a bulb you need to add it to the registry.

1. Open the Tools menu and tap **WiZ Light**.
2. Tap **Settings → Manage Lights → Discover new lights…**
3. The plugin scans your network for WiZ bulbs (this takes a few seconds).
4. For each bulb found, tap **Blink it** — the bulb will flash off and back on.
5. If it was your bulb, tap **Yes — name it**, enter a room name (e.g. *Bedroom*),
   and tap **Save**.
6. Repeat for any additional bulbs.

The first bulb you add becomes the active bulb automatically. If you have more
than one, tap **Switch Bulb…** in the Controls panel to change which one
receives commands.

## Usage

All controls are under **Tools → WiZ Light**:

| Entry | What it does |
|---|---|
| Toggle On / Off | Turns the active bulb on or off |
| Reading Mode | Sets warm white (3000 K, 70%) |
| Brightness… | Opens a dial to set brightness (10–100%) |
| Color Temperature… | Opens a dial to set colour warmth (2200–6500 K) |
| Effect Speed… | Opens a dial to set animation speed for dynamic scenes (10–200) |
| Scenes | Opens the scenes panel |
| Settings → Manage Lights | Add, remove, or switch between bulbs |

### Scenes

Tap a scene name to activate it. Tap **Edit…** next to a scene to customise it:

- All scenes: brightness
- Static scenes (Warm White, Daylight, etc.): also colour temperature
- Dynamic scenes (Cozy, Candlelight, etc.): also animation speed

Saved customisations are applied every time you activate that scene. A `*`
appears next to scenes with saved customisations. Tap **Reset to defaults** in
the scene editor to clear them.

## Gesture setup (optional)

Bind a gesture for faster access:

1. Open the top menu and tap the **Cog** icon.
2. Go to **Taps and gestures → Gesture manager**.
3. Select the gesture you want to use.
4. Under **General**, find **WiZ Light: Toggle On/Off** or
   **WiZ Light: Open Controls** and enable it.

**Toggle On/Off** — flip the light state in one tap with no dialog.
**Open Controls** — opens the full Controls panel (all adjustments + scene selection).

## Troubleshooting

**"No WiZ light configured"** — Go to **Settings → Manage Lights** and run
the discovery wizard to add at least one bulb.

**"WiZ light unreachable"** — The bulb is off at the wall, out of range, or its
IP has changed. Tap **Re-discover** in the dialog that appears; the plugin will
find the new address automatically.

**Bulb not found during discovery** — Make sure your Kindle and your WiZ bulb
are on the same Wi-Fi network.

## Acknowledgements

The WiZ UDP protocol implementation was developed with reference to
[pywizlight](https://github.com/sbidy/pywizlight), an open-source Python
library for controlling WiZ bulbs. It was the primary source of inspiration
for understanding the protocol.

## License

[MIT](LICENSE) — Copyright (C) 2026 Tasty-Murder
