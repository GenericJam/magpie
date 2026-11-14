# MIDI devices and ports through mob_midi, not an in-repo plugin

- Date: 2026-11-13
- Status: accepted (branch `midi-mob-midi`); supersedes the "Ports and
  devices: an in-repo Kotlin-only plugin" part of
  `decisions/2026-11-13-midi.md`. Clock follow stays deferred.

## Context

`decisions/2026-11-13-midi.md` put Magpie's MIDI ports and devices in
`plugins/magpie_midi` (Kotlin: the "Magpie" `MidiDeviceService`, the device
watcher, device open/close, Bluetooth-MIDI scan/connect) because mob_midi
then sent through the BEAM with the time of the call, had no timestamped
receive path, no hot-plug and no way to feed an audio thread. Humdinger
had its own copy of the same Kotlin (`plugins/humdinger_midi_port`).

mob_midi#6 (0.3, `consolidate-0.3`) makes mob_midi the one home for MIDI in
Mob apps: a C ABI (`priv/include/mob_midi.h`) for another static NIF of the
app (a sink called on the MIDI receive thread with source, generation,
bytes and the sender's timestamp; `mob_midi_send(handle, bytes, len, at)`
into a per-port queue sent at `at`; `mob_midi_discard`), `open_input(port:
:all, deliver: :native)`, `open_virtual(name, deliver: :native)`, output
handles, hot-plug, Bluetooth-MIDI, and `mix mob_midi.gen.virtual_device`
for the app's own device (Android reads its name and ports from the app's
`res/xml`, so a plugin can't ship it). Its queue never blocks a sender: a
listener that stops reading fills its port's queue, and the port refuses
every send until it has drained.

## Decision

- **Delete `plugins/magpie_midi`; depend on mob_midi** (`~> 0.3.0` from
  Hex: the same code as mob_midi#6's head). Magpie's device "Magpie" (one
  input, one output) is generated from `config :mob_midi, :virtual_device`
  and committed. `--check` stays out of the gate: the task puts its
  `<service>` block last in `<application>`, mob_dev's native build moves
  its own managed block after it, so the check fails after every native
  build (reported to mob_midi).
- **The engine keeps the timing**: the renderer stamps notes and clock
  with engine frames, the sending thread turns frames into
  CLOCK_MONOTONIC through the output timestamp, sleeps until then and calls
  `mob_midi_send(handle, ..., t)` per output instead of Kotlin. Sending at
  the time (not ahead with `at` in the future) keeps the clock map fresh
  and mob_midi's queue short, so a full queue means a stalled listener.
  The sampler mapping, clock send and frame → time conversion stay in
  Magpie.
- **Inputs go to the engine's C**: `mob_midi_set_sink` at NIF load; the
  sink parses per source (1..63) with Magpie's parser and ends what a
  source's previous port held when its generation changes. A source that
  closes without a successor (a device closed or unplugged, another app
  stopping sending into Magpie's device) is noticed through
  `midi_sources_changed/0`, which `Magpie.Midi` calls on those events and
  which checks every source with `mob_midi_source_info`.
- **Note-offs still always get out** (`c_src/midi_out.c`): per output, the
  notes it took a note-on for, the note-offs it took since it last
  refused, and the note-offs it is owed. At the first refusal Magpie
  discards the port's queue (what a stalled listener would get late, as
  Magpie drops late clock ticks) and owes the note-offs that were among it;
  refused note-offs are owed too; owed ones go first, in one send, once
  the port takes sends again (retried every 10 ms when nothing else is
  sent). A note held again since isn't sent its owed note-off (that would
  cut the new note; its own note-off ends it). Some owed note-offs are for
  notes long ended: harmless. The renderer's own out ring keeps its
  reserve for note-offs as before.
- **`Magpie.Midi` keeps the policy** (USB/Bluetooth open as they appear,
  other apps' ports only when the user turns them on, choices remembered by
  name) over `MobMidi`'s message protocol, and hands the engine the output
  handles. Host tests use `Magpie.Midi.Fake`, which answers with
  mob_midi's messages.
- `scripts/midi_probe/MidiProbe.java` stays Magpie's (moved from the
  plugin): mob_midi's probe has no channel, note-list or clock modes.

## Consequences

- One MIDI implementation for Magpie, Humdinger and FMutate; Magpie no
  longer carries Kotlin for MIDI or JNI glue for it.
- A stalled listener no longer blocks Magpie's sending thread (the old
  Kotlin `send` could): other outputs keep getting MIDI on time.
- `Magpie.Midi` is asynchronous throughout: device lists, opens and
  Bluetooth errors arrive as messages; the MIDI screen asks for the
  `:midi_bluetooth` permission before every scan and shows scan errors from
  the snapshot.
- mob_midi's native path is Android only; iOS (a later port) would need
  mob_midi's C ABI there first.
