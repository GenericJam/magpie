# Magpie: design handoff (v1)

Magpie is a phone sampler: tall velocity pads, a simple step sequencer, recording, chopping and
a sample library. It is one app in a family built on Mob (Elixir on the phone), Android first:

- **FMutate**: FM-1 firmware emulator / instrument.
- **Humdinger**: voice → MIDI.
- **Magpie**: this app.
- (later) a Strudel scripting app.

**Each app stands alone.** Magpie must be fully useful with no other app installed and no
account. Pairing with siblings adds things; it never unlocks basics.

| File | What it is |
|---|---|
| `HANDOFF.md` | This spec. Read first. |
| `family_style.ex` | `FMutate.Style`: the shared family tokens (colours, type, spacing, motion). Copy as the base. |
| `magpie_style.ex` | `Magpie.Style`: Magpie additions (pad palette, pad geometry, sequencer). |
| `kit.schema.json` | JSON Schema for a kit (pads + patterns). `kits/dusty-breaks.kit.json` is an example. |
| `protocol.md` | How Magpie talks to sibling apps (pairing, messages, library sharing). |
| `creature.md` | The magpie mascot: geometry, moods, animation. |
| `boards/*.dc.html` | Design boards as HTML. Reference for measurements and colours only; not code to ship. |

---

## 1. Scope

In v1:
- **Pads**: 4 banks (A–D) × 16 pads. Landscape: 8 × 2 tall pads per bank. Portrait ("bus mode"): 4 × 4.
- **Velocity by where you hit**: top of the pad = 127, bottom ≈ 19 (same rule as FMutate).
- **Pad modes**: one-shot, gate, loop, toggle, keys (sample played chromatically from MIDI notes).
- **Choke groups** 1–3 (a pad cuts off others in its group: open/closed hat).
- **Step sequencer**: per-pad lanes, 16 or 32 steps, per-step velocity, swing, patterns per kit, live record.
- **Snap to grid** toggle (applies to loop launches and live recording).
- **Record a sample** from: microphone; FMutate's output (paired); what other apps are playing
  (Android playback capture, where the other app allows it); file import (wav, aiff, flac, mp3).
- **Sample editor**: trim, gain, fade in/out, pitch, reverse, loop; chop by hits / even / off;
  send slices to consecutive pads.
- **Library ("the stash")**: samples and kits, search, source filters, preview, import.
- **I/O**: audio out; MIDI in (notes trigger pads) and out (pads send notes); MIDI clock follow/send.
- **Pairing** with FMutate and Humdinger (QR / code), and sharing the stash with FMutate.

Not in v1:
- Song mode / pattern chaining beyond selecting a pattern per kit.
- Effects beyond per-pad gain/fade/pitch/reverse.
- Ableton Link (MIDI clock only for now; Link is a later option, check its licence).
- Cloud sync or sharing kits with other people. Kits are exportable files (zip), that's all.

## 2. Screens

| Screen | Board | Notes |
|---|---|---|
| Identity | `Main.dc.html`, `Bird.dc.html` | Wordmark on pad tiles, the magpie, moods, icon. |
| Pads (home, landscape) | `Pads.dc.html` | Top bar: menu (magpie), bank A–D, kit name, tempo, Snap, Play, Record pattern, Seq. |
| Sequencer | `Seq.dc.html` | Pattern tabs, length, swing, tempo, Snap, stop, live record; 6 lanes visible, scrolls vertically. |
| Record a sample | `Record.dc.html` | Source list, live waveform, input meter, start mode (now / when sound starts / count-in), Stop. |
| Sample editor | `Editor.dc.html` | Trim handles, numbered slice markers, pitch/gain/fade/reverse, "Send N slices to pads". |
| Pad settings | `PadSheet.dc.html` | Long-press a pad. Colour, play mode, choke group, velocity mode, pitch, MIDI note, edit/replace/clear. |
| Bus mode (portrait) | `Bus.dc.html` | 4 × 4 pads, a 16-step row for the selected pad, Sample, Rec pattern, tempo. |
| Library | `Library.dc.html` | Samples / Kits tabs, search, filters, rows with preview + mini waveform, Import. |
| Pair an app | `Connect.dc.html` | Scan / My code tabs, typed code, connected apps with what each can do, "Share the stash", MIDI in, clock. |

Not designed yet (ask before inventing): kit save/load sheet, first run (mic permission,
empty kit), the Kits tab of the library, export/share of a kit, error states (file won't
import, recording too long, storage full).

## 3. Pads

- Layout: landscape 8 × 2 per bank inside the standard instrument area (28 pt side gutters for
  the back gesture, 8 pt gaps); on 844 × 390 a pad is ≈ 91 × 155 pt. Portrait 4 × 4.
- **Visual states**
  - Empty: dashed-feel 2 pt outline (`line`), "+ record or load". Tap = Record screen for that pad.
  - Loaded, idle: `raised` base with the pad colour at 26 % opacity; name top-left, mode
    bottom-left, a 12-bar mini waveform in the pad colour.
  - Playing: pad colour at 100 %, text and waveform turn `ink`; the pad moves down 2 pt.
    A thin `ink` line marks where the finger landed, a ring marks the finger, and a small badge
    shows the velocity (`v103`).
  - Looping: 55 % tint plus a progress bar along the bottom edge.
- **Velocity**: `v = round(127 × (1 − 0.85 × y / pad_height))`, y from the pad's top.
  Setting per pad: "Where you hit" (default) or "Fixed 100".
- **Gestures**: tap = play; long-press (600 ms) = pad settings; every finger plays its own pad
  (multitouch); a finger that slides onto another pad does **not** trigger it.
- Visual press feedback paints on touch-down, before audio.

## 4. Sequencer

- One lane per loaded pad in the current bank; lane label = colour chip + name (tap to audition).
- 16 or 32 steps; step width fills the row (≈ 44 pt on 844 pt), lanes ≥ 48 pt tall, more lanes
  scroll vertically. Steps are a deliberate dense grid (exception to the 48 dp rule).
- Step on = pad colour, fill height = velocity (min 25 %). Tap toggles; drag up/down on a step
  changes its velocity; long-press for probability later (not v1).
- Alternate 4-step groups use `raised` / `surface` so beats read at a glance.
- Playhead: 2 pt ring on the current column plus a bar above the grid.
- Live record: pressing pads while recording writes steps; with Snap on they quantize to the
  grid, with Snap off they keep their timing (store ticks, not just steps: 96 PPQN).
- Swing applies to even 16ths. Tempo 40–240 bpm.

## 5. Recording and editing

- Sources: mic; FMutate (via `protocol.md` record call); other apps (Android
  `AudioPlaybackCapture`, API 29+; only apps that allow capture); file import.
- Start: now / when sound starts (threshold from the input meter) / count-in 1 bar.
- Record into the chosen pad; default max length 60 s (setting).
- Chop: by hits (transient detection), even (N slices), off. Markers are draggable; tap the
  waveform to add one. "Send N slices to pads" fills consecutive empty pads in the bank,
  starting at the next free one.
- Non-destructive: a pad stores sample id + start/end/fades/pitch/gain/reverse; the source file
  stays untouched in the library.

## 6. Library

- Every recorded, resampled or imported sound is stored once and referenced by id.
- Filters: All, Recorded, From FMutate, Firmware packs, Imported. Search by name and tags.
- **Shared with FMutate** when "Share the stash" is on: paired FMutate sampler firmwares list and
  fetch samples through `protocol.md`.
- Kits: a kit file references samples by id; exporting a kit zips the kit JSON plus its samples.

## 7. Tokens and look

- Same flat family look as FMutate and Humdinger: `family_style.ex`.
- Pad palette (user-chosen per pad): coral, amber, lime, teal, sky, violet, pink, cream
  (`magpie_style.ex`). Lime keeps its family meaning for "live/primary" in chrome.
- The magpie is the menu button (44 pt) and appears in empty states, the library header,
  recording and the pairing screen. Never over pads.

## 8. Platform notes

- Low-latency audio: Oboe/AAudio on Android. Pads and sequencer must trigger from the audio
  thread's clock, not the UI thread.
- Mob canvas: no gradients, no rotation, no hard offset shadows. Waveforms are bars (rects).
  A long sample's waveform should be rendered once to a bitmap/native view, not as thousands of shapes.
- Multitouch: needs per-pointer events with IDs (same requirement as FMutate).

## 9. Open questions

1. Max kit size / sample memory budget per phone.
2. Should "keys" mode pads also respond to pitch bend (from Humdinger's open mode)?
3. Ableton Link later? (licence)
4. Name check: "Magpie" in the stores.
