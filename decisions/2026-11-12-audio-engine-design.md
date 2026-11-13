# The audio engine: sampler and sequencer in the AAudio callback

- Date: 2026-11-12
- Status: accepted (built on the `engine` branch; measured on the moto g power 2021)

## Context

Magpie needs pads that sound the moment they are hit and a step sequencer
with swing and off-grid ticks that keeps time while screens come and go.
The Android BEAM runs one scheduler, so BEAM timers can't keep audio time,
and a pad's trigger arrives from a screen or the MIDI handler, never from
the audio thread. Choir Coach (`c_src/choir_audio.c`) and Humdinger
(`c_src/hum_audio.c`) already solved AAudio via dlopen, MediaCodec
decoding, the output timestamp clock and the Native/Fake split. The kit
format (`design/kit.schema.json`) fixes the units: regions in seconds,
patterns as `step` + `tick` (−12..12 at 96 PPQN), swing as a fraction
0.5..0.75. The library (`Magpie.Library`) stores f32le PCM.

## Decision

- **Everything time-critical runs in the AAudio data callback**
  (`c_src/sampler.c`, plain C): draining a command queue, the sequencer,
  mixing. It never locks, allocates or frees. The BEAM only queues
  commands and receives events.
- **Commands go through a lock-free single-consumer ring** (1024). NIF
  callers serialise among themselves with a mutex the callback never
  takes. Live calls (`trigger`, `release`, `note_on/off`) are NIF calls
  from the caller's process (no GenServer hop); control calls are the
  owner's (`Magpie.Engine`) alone.
- **A 32-voice pool plus 16 slots for voices fading out.** Choke (4 ms
  ramp), steal (the quietest sounding voice, then the oldest; 4 ms ramp)
  and releases fade in a spare slot, so the new voice never waits and no
  voice is cut at full level. Only when all 48 slots are busy is the
  quietest fading voice cut.
- **The sequencer is sample-accurate by construction**: position in ticks
  is linear in frames from a base (rebased on tempo changes, so nothing
  accumulates), every event sounds on the first frame at or after its
  position, so step timing doesn't depend on buffer sizes. Swing warps
  time inside each 8th-note pair; swing changes wait for the next pair and
  pattern switches for the next bar, so nothing sounds twice or is
  skipped. Live hits are stamped where they were *heard* (the output
  timestamp maps the call's time to the frame then at the speaker) and
  reported as kit steps.
- **Samples are 16-bit in RAM at the engine's rate**, resampled once at
  load time (windowed sinc), played back with 4-point Hermite
  interpolation for pitch. Half the memory of float, 96 dB of range.
- **Events leave through a second ring** to an event thread (every 2 ms)
  that coalesces them (one playhead, at most a start and an end per pad
  per pass) and sends them; it also frees retired samples and patterns,
  refreshes the clock mapping and grows the buffer after an underrun.
- **Decoding stays off the BEAM**: one loader thread, async results.
  `load_pcm/4` takes library PCM without any decoder; `decode/1` turns an
  imported file into library PCM plus peaks.

## Consequences

- Trigger latency is the output pipeline: about 35 ms on the moto g power
  2021 (10 ms of AAudio buffer, the rest Android's mixer and the device).
  Nothing on the BEAM side can shave it; a lower-latency path would be
  exclusive (MMAP) mode where the device offers it.
- Playhead messages arrive about 30 ms *before* the step is heard: screens
  that want the playhead in sync with the sound delay drawing it to
  `Magpie.Audio.frame_time(clock, frame)`.
- Pad changes apply from the pad's next trigger (sounding voices keep their
  settings); a looping pad needs a retrigger to hear a gain change.
- A restarted `Magpie.Engine` resets the engine: whoever loads kits must
  load them again.
- The host harness (`c_src/test/sampler_host.c`) and the Fake keep both
  halves testable on the Mac; only the AAudio, MediaCodec and dlopen glue
  needs the phone.
