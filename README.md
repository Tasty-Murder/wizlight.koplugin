# wizlight.koplugin

Control [WiZ smart bulbs](https://www.wizconnected.com/en-us) directly from KOReader on Kindle. Adjust brightness,
color temperature, and lighting scenes without leaving your book.

## Features

- Toggle your light on or off from the menu or a custom gesture
- **Reading Mode** — toggle to warm white (3000 K, 70% brightness) and back;
  a checkmark shows when it's active, and turning it off restores exactly
  what the bulb was doing before you switched it on
- **Default Scene** — a one-tap preset you configure yourself: dial the
  bulb in however you like it with the other controls, then hold the
  button to save it; tap to recall it any time
- Brightness control (10–100%)
- Color temperature control (2200–6500 K)
- Effect speed control for animated scenes (10–200)
- 11 curated scenes, grouped into **Lighting Themes** (Warm White, Daylight,
  Cool White, Night Light, Focus, Relax, Wake Up, Bedtime) and **Animated
  Scenes** (Cozy, Candlelight, Golden White) — grouped by which scenes
  genuinely animate, per WiZ's own per-scene compatibility reference, not
  just a rough guess
- Per-scene customisation — save whichever parameters a given scene actually
  supports (brightness, colour temperature, and/or animation speed); scenes
  with saved settings are marked with *
- Named multi-bulb registry — save bulbs by room name and switch between them
- Blink-to-verify discovery — the wizard blinks each found bulb so you can
  confirm which physical light you are adding
- Automatic DHCP recovery — if a bulb's IP changes after a router restart,
  the plugin detects this and offers to re-discover the new address

## Platform

**Kindle only.** This plugin is designed for KOReader running on Kindle devices.
Talking to the bulbs requires `iptables` with root access, which Android's
security model does not permit. The spirit of this plugin is to let you control
your lights from your Kindle — without reaching for your phone.

## Prerequisites

- KOReader installed on a Kindle with Wi-Fi
- One or more WiZ smart bulbs on the same Wi-Fi network as your Kindle
- No account, cloud service, or app required — the plugin communicates with
  your bulbs directly over your local network
- The device must support `iptables` and KOReader must have permission to
  modify firewall rules. Bulbs answer over UDP, and on a locked-down device
  those answers can be dropped on the way back in — the command still
  reaches the bulb and takes effect, but the plugin never hears the reply.
  The plugin therefore adds two `ACCEPT` rules for UDP port 38899 (one for
  each direction the replies can take) the first time it contacts a bulb,
  and removes them again when KOReader closes. A session that never uses
  the plugin never touches `iptables`.

> **Note:** WiZ bulbs must be set up with the WiZ app at least once before
> the plugin can discover them.

## Installation

1. Download `wizlight.koplugin.zip` from the
   [latest release](https://github.com/Tasty-Murder/wizlight.koplugin/releases/latest).
2. Unzip the archive. You will get a folder named `wizlight.koplugin/`.
3. Copy that folder to the `koreader/plugins/` directory on your Kindle
   (connect via USB and paste alongside the other plugin folders).
4. Restart KOReader.

The plugin appears as **WiZ Light** under **Tools → More Tools**.

## Adding your first bulb

Before you can control a bulb you need to add it to the registry.

**Option A — automatic discovery (recommended):**

1. Open **Tools → More Tools** and tap **WiZ Light**.
2. Tap **Settings → Manage Lights → Discover new lights…**
3. The plugin scans your network for WiZ bulbs (this takes a few seconds).
4. For each bulb found, tap **Blink it** — the bulb will flash off and back on.
5. If it was your bulb, tap **Yes — name it**, enter a room name (e.g. *Bedroom*),
   and tap **Save**.
6. Repeat for any additional bulbs.

**Option B — add by IP address:**

If discovery does not find your bulb, you can add it manually:

1. Find the bulb's IP address in your router's DHCP client list or the WiZ app.
2. Tap **Settings → Manage Lights → Add light by IP…** and enter the address.
3. The plugin contacts the bulb directly, then runs the same blink-to-verify
   and naming flow as above.

The first bulb you add becomes the active bulb automatically. If you have more
than one, tap **Switch Bulb…** in the Controls panel to change which one
receives commands.

## Usage

All controls are under **Tools → More Tools → WiZ Light**:

| Entry | What it does |
|---|---|
| Toggle On / Off | Turns the active bulb on or off |
| Default Scene | Tap to activate your saved preset; hold to save the bulb's current settings as the new preset |
| Reading Mode - On / Reading Mode - Off | Toggles warm white (3000 K, 70%) and back; the label reflects the current state, and turning it off restores whatever the bulb was doing before |
| Brightness… | Opens a dial pre-filled with the bulb's real current brightness (10–100%) |
| Color Temperature… | Opens a dial pre-filled with the bulb's real current colour warmth (2200–6500 K) — some bulbs silently clamp a requested value below their own hardware minimum, so this always reflects what the bulb actually reports, not just the last value you asked for |
| Effect Speed… | Opens a dial to set animation speed for dynamic scenes (10–200) |
| Scenes | Opens the Lighting Themes / Animated Scenes chooser |
| Settings → Manage Lights → Discover new lights… | Scan the network for WiZ bulbs |
| Settings → Manage Lights → Add light by IP… | Add a bulb by entering its IP address directly |
| Settings → Manage Lights | Switch between or remove saved bulbs |
| Settings → Discovery Timeout… | Set how long a network scan runs (3–30s) |
| Settings → Default Scene… | Configure the Default Scene directly — brightness first, then colour temperature — without needing the bulb to already show it |

### Scenes

Scenes are split into two groups so you're never guessing which ones
animate:

- **Lighting Themes** — fixed lighting moods (Warm White, Daylight, Cool
  White, Night Light, Focus, Relax, Wake Up, Bedtime)
- **Animated Scenes** — genuinely dynamic effects (Cozy, Candlelight, Golden
  White)

Tap a scene name to activate it. Tap **Edit…** next to a scene to customise
whichever parameters that scene actually supports — most offer brightness,
the plain white-tone themes also offer colour temperature, and the animated
scenes also offer speed. (Night Light has neither adjustable brightness nor
speed on real WiZ hardware, so it has no **Edit…** button at all.)

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

**"No WiZ light configured"** — Go to **Tools → More Tools → WiZ Light → Settings → Manage Lights** and use
**Discover new lights…** or **Add light by IP…** to add at least one bulb.

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
