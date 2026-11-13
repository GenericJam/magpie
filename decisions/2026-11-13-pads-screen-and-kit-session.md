# The pads screen and the kit session

- Date: 2026-11-13
- Status: accepted (MagpiePads; review in the `pads` PR)

## Context

The pads are the home screen (`design/boards/Pads.dc.html`, HANDOFF §3):
16 tall pads per bank, each finger its own pad, velocity from where it
lands, sound on touch-down, long-press for the pad settings sheet
(`PadSheet.dc.html`). Something has to own the kit while screens come and
go: load its samples into `Magpie.Engine`, apply its pads, save edits.
Mob (0.9.29) gives per-node multi-pointer `on_touch` (MOB-518), no window
size to a screen, and re-renders a screen's whole tree after every message.

## Decision

- **`Magpie.KitSession`**, one GenServer from `App.on_start` after the
  Engine, holds the current `%Magpie.Kit{}`. Samples load one at a time in
  a monitored loader process (`spawn_monitor`, the result as its exit
  reason), so the session answers while megabytes pass from
  `Library.pcm/1` to `Engine.load_pcm/4`; a pad goes to the engine as soon
  as its sample is in. Every change goes engine first (its error leaves
  the kit alone), then the kit, subscribers (`{:magpie_kit, snapshot}`)
  and a debounced autosave (1 s, `Library.save_kit/1`). The snapshot carries
  per pad its load status, a 12-bar wave from the engine's peaks over the
  pad's region and the region's length, so screens compute nothing.
- **Stopping a pad as it changes is the engine's job.** When a pad's
  sample or mode changes or it is cleared, the session sets it with
  `Engine.set_pad(index, pad, stop: true)`: one engine command that fades
  the pad's sounding voices and drops its waiting quantized launches in the
  same step as the new definition, with no stream too, and does nothing on
  an error. The session first stopped pads itself (a release, or a second
  trigger for a sounding toggle, from the engine's voice events), but a
  live call is dropped with no stream or a full queue while the control
  call still applies, and voice events lag the engine (a toggle fading
  out still "sounds", so the second trigger started it again).
- **Which kit:** the most recently saved one; with none, the board's
  `dusty-breaks.kit.json` (read at compile time) keeping only pads whose
  samples are in the library. A fresh install has none of them, so it
  starts as an empty kit named "Dusty Breaks": no invented first-run
  content until that is designed.
- **Pads are native layout, not a canvas.** Without the window size a
  canvas can't place a pad's bottom-anchored mode, wave or badge before the
  first touch reports the pad's size. Each pad is a weighted `Box` cell
  (the `on_touch` node, never moving) holding the face; Android's `Box`
  stacks its children, so the landing line, finger ring, badge and loop bar
  are offset children over the face. The 2 pt press offset is on the face,
  not the weighted cell (an offset wraps the node in another Box, which
  drops its `weight`).
- **The hot path:** the `:down` clause looks the pad up in a precomputed
  map (`{velocity, quantize, release?}`), calls `Engine.trigger/3`, then
  updates state; other `:down`s already queued are triggered in the same
  callback before the one render (fingers landing together otherwise wait
  ~5 ms each for the previous finger's render). A queued `:down` whose
  pointer id is still held stays queued behind that id's `:up`.
- **Long press on the BEAM:** `Process.send_after` 600 ms from the `:down`,
  a token per finger; `:up`, `:cancel` or a move outside the pad drops the
  token, and the first to fire drops every other one. Every loaded pad asks
  for moves (`moves: true`, 32 ms / 4 dp) all the time: Mob reads a node's
  move rule when the finger lands, so asking only once a long press is
  pending never reached that finger. A move runs `render/1` but repaints
  nothing unless the tree changed.
- **Orientation:** a screen locks the orientation it needs on mount and
  nobody unlocks: Mob has no "became active again" callback, so a pushed
  screen that unlocked on leave would leave the pads free to rotate.
- **Measuring with real input:** `scripts/pads_check.exs` registers a
  virtual multitouch screen with Android's `uinput` shell command (the
  shell user can't write the real touchscreen's evdev node, but may open
  `/dev/uinput`), so injected fingers go through the kernel, InputFlinger
  and Compose. It traces the screen and `Mob.Sender` on the BEAM and reads
  `dumpsys gfxinfo framestats`.

## Consequences

- Sound leads the picture: on the moto g power 5G 2024 a press is heard
  ~40 ms after the touch and on the display ~70 ms after it (AGENTS.md,
  "Pads"). Most of the visual time is Compose rebuilding the whole tree
  (~27 ms a frame with 16 pads, the same with 4) plus the display pipeline;
  a smaller tree barely moves it, so making it faster is Mob's job
  (recomposing only what changed), not this screen's.
- The kit on the phone changes under the user's hand only through the
  session; a second editor (the sequencer, the library) subscribes and
  calls the same API.
- `Magpie.RecordScreen`'s `{:recorded, pad, sample}` goes to the session
  (`reply_to: KitSession.whereis()`), so a recording lands on its pad even
  if the pads screen were gone.
