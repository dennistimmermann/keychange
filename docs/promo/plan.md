# Keychange — promo video plan

The landing page come alive, printed in the site's halftone look: cream stock, navy ink, coral and grape dot shadows, pastel blobs. Scene cuts are swoosh wipes; glides inside a scene stay glides.

**What it is:** a macOS menu bar app that switches the input source when you switch keyboards.
**For:** anyone with more than one keyboard and more than one layout (a German laptop and a U.S. mechanical, …).
**Sets it apart:** macOS switches input sources per app or by shortcut, never per keyboard. Keychange does it per keyboard.
**Hook:** German keys with the U.S. layout: typing "Grüße!" gives `Gr[-e!`. The Ü key prints `[` and the ß key prints `-`.
**The moment:** a key goes down on the other keyboard, and the menu bar mark switches on that same frame.
**Real UI shown:** the floating menu bar card and the real popover capture (`docs/assets/panel.png`), laid out as the old OG card was, the mark ported from `MenuBarMark.swift`, and the text field and keyboard names from `make-demo.py`.
**Tone:** polished story in a playful print.
**Share caption:** see `share-copy.txt`.

## Visual identity
- **Stock and ink.** Cream stock #FFF5E8 with a faint grape and sun dot screen. Navy ink #232B4A for type and the mark. White fields and cards.
- **Halftone engine.** The 45° engine prints every shadow as dots: coral #FF6F59 under the text fields, grape #8C6CF2 under the menu bar card, the popover and the keyboards.
- **Blobs.** Soft breathing pastel blobs (peach #FFE2C6, lilac #E6DEFF, aqua #D3F3E8) sit behind each subject.
- **Type.** Fraunces for display: the wordmark, headlines, captions and the typed text. SF Mono caps for labels. The secondary line (keychange.dev) is in coral.
- **Popover.** The popover capture is duotoned navy and white. Its rail is repainted in ink on whichever keyboard is live.
- **The mark.** In the moment scene's large card, the mark is screened as halftone plates, so its 40% back plate prints as open dots. In the small OG cards it stays solid ink.
- **Accent.** Coral is saved for the switch: the G key, the mark, and the dotted rings and dotted line that join them. After that, ü and ß print coral as they come out right. The hook's wrong characters, and the keys that printed them, punch out in navy ink.
- **Wipes.** Each is 0.9 s, centred on the cut: coral dots into solid coral, then sun #FFC247 dots. They run left to right, then right to left, then left to right.
- **Keyboards (the user's note).** They are supporting elements, not the hero:
  - They sit low and bleed off the bottom edge. The board top is at y=766 with 84 px keys, so the frame shows the number, top and home rows (every key the story presses) plus a sliver of the shift row. The space row is off-frame.
  - White case ruled in navy, cream caps, navy legends, grape dotted shadow.
  - A pressed cap fills navy with a white legend and drops 4 px. The switching G fills coral.
  - The inactive board is dimmed under a veil of paper rather than made transparent.
  - In the moment scene the boards rise up from under the frame edge.

## Storyboard (1920×1080, 30 fps, 96 BPM, 20.0 s = 8 bars; cuts on beats)
| # | Time | Scene |
|---|---|---|
| 1 Hook | 0.000–4.375 (7 beats) | **From frame 1:** a white text field with a navy rule and a coral dotted shadow, over a peach blob, with the German Apple keyboard cropped along the bottom edge.<br>**0.3125–1.09375:** keys go down on 16ths, G R Ü ß E ⇧1, and the field prints `Gr[-e!` in Fraunces.<br>**1.25:** `[` and `-` punch out as navy plates, and the Ü and ß caps punch out with them.<br>**1.5625** (settled 1.96): the caption "German keys. U.S. layout. Again." |
| wipe 1 | 3.925–4.825 | The swoosh runs left to right. |
| 2 Reveal | 4.375–8.125 (6 beats) | **OG layout, left:** the icon and the Keychange wordmark (4.455), then "Assign a layout / to each of your / keyboards." (4.625).<br>**Right:** the floating menu bar card (EN, "Thu 30 Jul 09:41", from 4.555) over the duotone popover (from 4.775), on a lilac blob with grape dotted shadows. The rows land at 5.3125, 5.46875 and 5.625 (German, U.S., 2-Set Korean), with the rail on Keychron K2. |
| wipe 2 | 7.675–8.575 | The swoosh runs right to left. |
| 3 The moment | 8.125–14.375 (10 beats) | **Layout:** the large menu bar card top right (800×160, halftone mark on EN, "U.S." in mono caps below it). A wide text field in the middle. Keychron K2 (U.S.) rises from the bottom edge, with Apple Internal (German) cropped at the right edge under a paper veil.<br>**8.75–9.6875:** "Hello! " types on the K2.<br>**10.005–10.505:** the view pans 1406 px to the German board, and the veils trade places.<br>**10.625 (downbeat), shown on frame 319:** G goes down in coral, and the mark turns coral. A dotted coral ring leaves the key and the mark together, joined by a dotted coral line. The mark runs its 0.3 s EN→DE swap, "U.S." crosses to "GERMAN", and G prints.<br>**10.9375–11.5625:** "rüße!" follows, with ü and ß flashing coral.<br>**11.5625** (settled 11.96): "It switches the moment / your hands do." top left. |
| wipe 3 | 13.925–14.825 | The swoosh runs left to right. |
| 4 End card (poster = 18.5 s) | 14.375–20.000 (9 beats) | **OG layout, right:** the card on DE (14.475) with the popover under it (14.795), rail on Apple Internal / German, on a lilac blob.<br>**Left:** the icon, Keychange and keychange.dev in coral (14.555), "One layout / per keyboard." (14.695), "FREE · MIT · MACOS 14+ · UNIVERSAL" (14.975) and the brew line (15.125). |

## Sound
The score: F major, 96 BPM, EP Dm9 → B♭maj7 under the hook with keycap clicks and a muted low bump on the typo. The pulse enters with the reveal, the popover rows plip in key, and a tuned tick (C6 over F5) lands on the keydown frame as bass and rim join. The end card cadences F → B♭ → C → F.

A soft band-passed breath under each wipe that travels across the stereo field with the band.

The mix is two-pass loudnorm to −16 LUFS integrated, with the true peak at −2.1 dBTP.
