# Handoff: Locale — macOS menu bar applet

## Overview
**Locale** is a macOS menu bar utility that reproduces the functionality of [autokbisw](https://github.com/ohueter/autokbisw) with a GUI: it remembers which input source (keyboard locale) belongs to which physical keyboard, and switches the system input source automatically when the user starts typing on a different device.

The menu bar item shows the currently active input source. Clicking it opens a popover listing every detected keyboard, each with a dropdown of the enabled system input sources to switch to when that device is used. The keyboard currently being typed on is marked. An optional detail mode shows each device's USB VID / PID.

## About the Design Files
The file in this bundle (`Locale Menu Bar.dc.html`) is a **design reference created in HTML** — a prototype showing intended look and behavior, not production code to copy. The task is to **recreate this design natively in macOS (SwiftUI or AppKit)** using the platform's own controls, materials, and layout system. Where the prototype fakes a system control (the toggle switches, the popup buttons, the vibrant panel background), use the real platform equivalent instead of reimplementing it.

The HTML contains three side-by-side option cards per exploration round. **Only `3c` is the approved design** (top-left group, badge `3c`). `3a`, `3b` and the turn-2 / turn-1 sections below it are earlier iterations kept for history — `3b` is still relevant as the **empty state** reference. Everything else can be ignored.

## Fidelity
**High-fidelity.** Colors, type sizes, spacing and states are final and intended to be matched — but matched *through native controls*. Sizes below are given in points (1pt = 1px in the prototype).

## Screens / Views

### 1. Menu bar item (status item)
- Text-only status item showing the short code of the active input source (`ABC`, `DE`, `CH`, `あ`, `U+`).
- In the prototype it is drawn as a filled blue rounded rect for emphasis. **Natively: render as a plain monochrome template status item title** (system default styling), not a colored pill — a colored badge in the menu bar is off-platform. Optionally use a filled/dimmed appearance to indicate disabled state.
- When the app is globally disabled, the title is dimmed (see State Management).

### 2. Popover — main list (design `3c`)
Panel: width **344pt**, corner radius **10pt**, 0.5pt border `rgba(0,0,0,0.12)`, background = system popover material (`NSVisualEffectView` / `.regularMaterial`); prototype approximates it with `rgba(250,250,250,0.94)` + 30pt blur. Inner padding **6pt**.

**Header row** — padding `4pt 9pt 6pt`, space-between:
- Left: title `LOCALE` — 11pt, weight 600, letter-spacing 0.06em, uppercase, color `#8E8E93`.
- Right group, 8pt gap:
  - Device count — 11pt, `#8E8E93`, copy: `4 connected` / `None connected`.
  - **Master enable switch** — 30×18pt track, radius 9pt; knob 14×14pt white, shadow `0 1 2 rgba(0,0,0,0.28)`, inset 2pt. On = `#34C759`, off = `rgba(120,120,128,0.32)`. Native: `Toggle` with `.switch` style, control size small.

**Keyboard rows** — one per detected device, padding `6pt 9pt 6pt 0`, corner radius 6pt, hover background `rgba(0,0,0,0.05)`:
- **Active rail** (leading): 3pt wide, full row height, radius `0 2 2 0`, `margin-right: 6pt`. Active device = `#34C759`; all others = transparent (space reserved so labels stay aligned).
- **Label block** (flex 1, min-width 0, 1pt gap):
  - Device name — 13pt, line-height 1.25, single line, truncate with ellipsis. Active row weight **590** (SF `semibold`-ish); others regular 400.
  - Detail line (only when "Show device details" is on) — 10pt, monospace (SF Mono), `#9A9AA0`, format: `VID 0x05AC   PID 0x0342` (three spaces between the pairs).
- **Input-source dropdown** (trailing, intrinsic width): 12pt text `#1D1D1F`, white background, 0.5pt border `rgba(0,0,0,0.18)`, radius 5pt, padding `3pt 20pt 3pt 8pt`, shadow `0 1 1 rgba(0,0,0,0.06)`, chevron `▾` 10pt `#8E8E93` at right 7pt. Native: `NSPopUpButton` / SwiftUI `Picker` with `.menu` style.
- Whole row (excluding the dropdown) is a hover target; in the prototype clicking a row simulates typing on that device. **In the real app the row is not a click target** — the active device is driven by real keyboard events. Keep the hover highlight only if rows gain a real action (e.g. reveal in System Settings); otherwise drop it.

**Footer**
- A **cog button**, right-aligned, in its own row: padding `5pt 10pt 2pt`. Bare glyph, no background, no border: 14pt, `#8E8E93`, hover `#1D1D1F`. Native: `Image(systemName: "gearshape")` in a borderless button. Only the icon is clickable, not the row.
- Clicking the cog toggles the settings section open/closed (no separator line above it).

**Settings section** (revealed under the cog; hidden by default):
- `Show device details` — label 13pt, trailing 30×18pt switch (same spec as master enable).
- `Launch at login` — label 13pt, trailing switch.
- `Quit Locale` — label 13pt, plain row, hover `rgba(0,0,0,0.05)`.
- Row padding `5pt 9pt`, radius 6pt, 1pt gap between rows.

### 3. Popover — empty state (reference `3b`)
Shown when no keyboards are detected (typically because Input Monitoring permission has not been granted).
- Header identical, count reads `None connected`; status item title falls back to `—`.
- Centered block, padding `26pt 22pt 24pt`, 7pt gap, center-aligned:
  - Glyph: 34×22pt rounded rect, 1.5pt border `rgba(0,0,0,0.18)`, radius 4pt, with a 14×3pt bar near the bottom (a stylized keyboard). Native: use an SF Symbol (`keyboard`) at ~28pt in `tertiaryLabelColor`.
  - Title — 13pt, weight 600, `#1D1D1F`: `No keyboards detected`
  - Body — 12pt, line-height 1.4, `#8E8E93`: `Locale needs Input Monitoring access to see which keyboard you are typing on.`
  - Action — 12pt, accent color `#0A84FF`: `Open Privacy & Security…` → opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`.
- Cog + settings section still present below.

## Interactions & Behavior
- **Active-device detection**: tap into `CGEvent` / `IOHIDManager` keyboard events, identify the source device (vendor ID, product ID, and ideally the device's unique service/registry ID), and mark it as active. This requires **Input Monitoring** entitlement — same mechanism autokbisw uses.
- **On device change**: look up the stored input source for that device and call `TISSelectInputSource`. If the device has no stored mapping yet, adopt the currently selected input source as its mapping (autokbisw's behavior) and persist it.
- **Dropdown change**: writes the mapping for that device immediately; if the changed device is the active one, also switch the current input source right away.
- **Master enable off**: stop switching. The list dims to **opacity 0.4** (200ms transition) and the status item dims. Mappings and dropdowns remain visible and editable.
- **Switch animation**: track color 180ms, knob position 180ms.
- **Settings disclosure**: no animation needed; content appears/disappears and the popover resizes to fit.
- **Device connect/disconnect**: list updates live; a disconnected device's mapping is retained so it comes back with the same setting.
- **Hover**: rows and settings rows get `rgba(0,0,0,0.05)`; cog glyph darkens to `#1D1D1F`.
- **Dark mode**: not designed. Derive from system semantic colors — the prototype's grays map to `secondaryLabelColor` / `tertiaryLabelColor`, `#1D1D1F` → `labelColor`, `#0A84FF` → `controlAccentColor`, `#34C759` → `systemGreen`.

## State Management
| State | Type | Notes |
|---|---|---|
| `devices` | list of `{id, name, vendorID, productID}` | Live from HID enumeration. `id` should be a stable per-device key (autokbisw uses `name-vendorID-productID-serviceID`). |
| `activeDeviceID` | id? | Set by the keyboard event tap. Drives the green rail + semibold name. |
| `mapping` | `[deviceID: inputSourceID]` | Persisted in `UserDefaults`. Survives disconnects. |
| `inputSources` | list | Enabled, selectable keyboard input sources from `TISCreateInputSourceList`. Dropdown options; localized names shown. |
| `isEnabled` | bool, default true | Master switch. Persisted. |
| `showDeviceDetails` | bool, default false | Persisted. Shows the VID/PID line. |
| `launchAtLogin` | bool, default false | Persisted, backed by `SMAppService.mainApp`. |
| `settingsExpanded` | bool, default false | Transient (not persisted). |
| `hasInputMonitoringPermission` | bool | Drives the empty state. |

Input sources shown in the prototype (sample data): `ABC`, `German`, `Swiss German`, `Japanese – Romaji`, `Unicode Hex Input` — with menu bar short codes `ABC`, `DE`, `CH`, `あ`, `U+`. Real short codes should come from the input source's icon/abbreviation, not a hardcoded table.

Sample devices in the prototype: `Apple Internal Keyboard / Trackpad` (0x05AC/0x0342), `Keychron K2 Version 2` (0x3434/0x0121), `HHKB Professional HYBRID` (0x04FE/0x0007), `MX Keys for Mac` (0x046D/0xB35B).

## Design Tokens
**Colors**
| Token | Value | Use |
|---|---|---|
| label | `#1D1D1F` | Primary text |
| secondary label | `#8E8E93` | Header, count, cog, secondary copy |
| tertiary mono | `#9A9AA0` | VID/PID line |
| green | `#34C759` | Active rail, switch on |
| switch off | `rgba(120,120,128,0.32)` | Switch track off |
| accent | `#0A84FF` | Links |
| hover | `rgba(0,0,0,0.05)` | Row hover |
| hairline | `rgba(0,0,0,0.12)` | Panel border |
| control border | `rgba(0,0,0,0.18)` | Dropdown border |
| panel | popover material | `rgba(250,250,250,0.94)` + 30pt blur in prototype |

**Type** — SF Pro / system font: 13pt regular (rows, settings), 13pt weight 590 (active device), 12pt (dropdown, links, body), 11pt semibold + 0.06em tracking uppercase (title), 11pt (count), 10pt SF Mono (VID/PID).

**Spacing** — panel padding 6; row padding `6 / 9`; header padding `4 9 6`; label gap 1; row gap 8; footer padding `5 10 2`; settings row padding `5 9`.

**Radius** — panel 10; rows 6; dropdown 5; switch 9 (track) / full (knob); active rail `0 2 2 0`.

**Shadows** — panel `0 12 34 rgba(0,0,0,0.28)`; dropdown `0 1 1 rgba(0,0,0,0.06)`; switch knob `0 1 2 rgba(0,0,0,0.28)`.

**Sizes** — panel width 344; switch 30×18, knob 14; active rail 3 wide; cog glyph 14.

## Assets
None. All glyphs are text (`▾`, `⚙`) or CSS shapes in the prototype — replace with SF Symbols natively (`chevron.up.chevron.down` on the popup button, `gearshape`, `keyboard`). No custom icons, no images, no app icon designed yet.

## Screenshots
In `screenshots/`:
- `3c-approved-design.png` — approved main state, settings collapsed.
- `3c-settings-expanded.png` — same, cog pressed, settings revealed.
- `3b-empty-state.png` — no keyboards detected.

Note: the capture engine renders every dropdown showing its first option (`ABC`) regardless of the real selection — in the live prototype each device shows its own mapped input source. Treat the HTML file as the source of truth for dropdown values.

## Files
- `Locale Menu Bar.dc.html` — the design prototype. Open in a browser. Approved design is the card badged **`3c`**; **`3b`** is the empty state. Cards `3a`, `2a`, `2b`, `1a`, `1b`, `1c` are superseded iterations.

## Reference
autokbisw (`ohueter/autokbisw`) — the CLI whose behavior Locale wraps. Its device-identity keying and "adopt current input source on first sight" logic are worth reading before implementing the detection layer.
