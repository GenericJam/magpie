# The engine's streams and decoding through mob_audio_io

- Date: 2026-11-21
- Status: accepted (branch `audio-io`, MOB-531); the engine's DSP, the
  recorder and MIDI stay as `decisions/2026-11-12-audio-engine-design.md`,
  `decisions/2026-11-13-recording-other-apps.md` and
  `decisions/2026-11-13-midi-on-mob-midi.md` describe them.

## Context

`c_src/magpie_audio.c` carried its own device layer: AAudio loaded with
`dlopen` (the output stream, burst and buffer tuning, a reopen after a
disconnect), a second AAudio stream for the mic with its timestamp
mapping, a JNI permission check, the AMediaExtractor/AMediaCodec decoder
for sample loads and imports, and the engine clock from
`AAudioStream_getTimestamp` plus a `getFramesWritten` offset. Humdinger,
Choir Coach and FMutate carry copies of the same code, and none of it runs
on iOS. `mob_audio_io` (MOB-531) is the shared plugin for it: it owns the
streams (AAudio; RemoteIO and the `AVAudioSession`), calls an app's
registered processor from the audio thread with a `mai_time` (the stream
clock, the callback's host time, the block's presentation time), reopens
and retunes streams itself, and decodes files in chunks
(`decode_stream/3`, cancellable, bounded memory). Its spike rendered
Magpie's `sp_render` through it on a phone and an iPhone.
`AAudioStream_getTimestamp` can abort the process on Android 11 (the
plugin's verification found SIGABRTs from Magpie's clock refresh); the
plugin calls it only on API 31+.

## Decision

- The engine's two streams are the plugin's. `c_src/magpie_io.c` (plain C,
  in a host harness) registers `"magpie_out"` (render: `sp_render`) and
  `"magpie_mic"` (capture: the recorder); `Magpie.Audio.Native.Io` owns
  their streams, one at a time for the engine's owner. No platform audio
  API is left in `c_src/`.
- The renderer's role follows the output's stream events: `STARTED` (an
  open, or the plugin's reopen) applies `SP_CMD_RATE` and hands rendering
  to the stream; `STOPPED` hands it back to the control path, as the old
  open and close did. A second output stream renders silence rather than
  run `sp_render` twice.
- The engine clock comes from the render: every 20 ms it maps the engine
  frame it is about to render onto the block's `present_ns`. Everything
  that converts frames and times (frame_time, the count-in's downbeat,
  live record, MIDI out, latency stats) goes through it, on
  `mai_now_ns()`, which is the clock of `mob_midi_now_ns()` on both
  platforms (CLOCK_MONOTONIC on Android, mach_absolute_time on iOS, never
  Darwin's CLOCK_MONOTONIC).
- The mic is a plugin input stream; its `STOPPED` while it is the open
  input (a lost device, an iOS call) closes the input as `:disconnected`,
  as AAudio's error callback did. The NIF closes the input before `Io`
  closes the stream, so a close is never taken for a loss.
- Sample loads and imports decode with `decode_stream/3` in an Elixir
  process (the caller for imports, a task for `load_sample/2`), each chunk
  made into the library's form by the NIF (`import_chunk/2`); a file load
  claims its turn among the loads and unloads of its id first
  (`load_claim/1`), so the request order still decides which load wins.
- Other apps' audio stays Android's (`plugins/magpie_capture`); on iOS
  the NIF answers `{:error, :unsupported}`, `Engine.input_sources/0`
  says `[:mic]` and the Record screen shows the source disabled.
- `static_nifs` `archs: [:all]`; mob_midi `~> 0.4.0` (its C ABI on
  CoreMIDI).

## Consequences

- `Magpie.Engine`'s API and messages are unchanged. `:input_stuck` stays
  in the contract (the Fake still produces it) but `Native` no longer
  does: `MobAudioIo.close/1` returns once no callback can run. Likewise
  `:output_stuck` and `{:missing, lib}` are gone.
- `info/0` keeps its keys, filled from `MobAudioIo.status/1` where the
  stream's figures live (and the whole maps under `io`). `low_latency` is
  nil: the plugin asks for AAudio's low-latency mode and doesn't report
  what it got. On Android 8–11 `output_latency_ms` is now the frames
  written but not yet read (the plugin's guard against the
  `getTimestamp` abort), smaller than the old timestamp-based figure, and
  the clock's presentation times are estimates from the buffer there.
- Imported PCM keeps its float values (clipped to ±1) instead of passing
  through 16 bits; an import or a load stops within one codec buffer when
  its process exits.
- The plugin is a git dependency until 0.1.0 is on Hex (`mix.exs`, and
  `:acknowledge_unsafe_plugins` in `mob.exs` until it can be trusted).
- Not measured yet: everything above runs on the host only (device audio
  was paused). The PR lists the device checks: pad latency against master,
  underruns over a pattern, live recording timing, imports with cancel,
  MIDI in/out and clock, the stash, other apps' capture.
