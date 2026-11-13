# V1 scope: Android only, standalone, pad touch built into Mob

- Date: 2026-11-12
- Status: accepted (Kevin)

## Context

The handoff (`design/HANDOFF.md`) describes Magpie as Android first, with
pairing to FMutate and Humdinger in v1 and pads that need per-finger touch
with the landing position (velocity by height). At the start:

- FMutate exists only as a design handoff. Its protocol v1 has no "record
  FMutate's output" call and no library sharing, which Magpie's spec relies
  on; Humdinger is only a pairing client and has no server Magpie could
  pair with.
- Mob has no per-node, per-pointer touch event with a position. `on_press_in`
  carries no position or pointer id; the `mob_touch` plugin is window-wide.

## Decision

- **Android only** for the first stretch. Keep Elixir platform-neutral
  where it costs nothing; the generated `ios/` tree stays for the later port.
- **Standalone first.** Pads, sequencer, recording, editor, library and USB
  MIDI come before any pairing. The Connect screen and a family protocol
  extension wait until FMutate exists.
- **Per-node multi-pointer touch goes into Mob first** (MOB-518), rather
  than a native pad view inside Magpie or window-wide `mob_touch` with
  app-side hit-testing. FMutate needs the same thing.

## Consequences

- Pads can't be built until MOB-518 ships in a mob release. Work that
  doesn't need them (engine, library, kit model, sequencer model) goes first.
- Touch events still cross to the BEAM before a pad sounds. The engine's
  trigger path from the BEAM must stay short; the latency from touch to sound
  is measured on the phone once pads exist, and revisited if it's audible.
- The design's pairing items (Record from FMutate, "Share the stash", the
  Connect screen) are out of the first milestones.
