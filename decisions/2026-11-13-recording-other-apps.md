# Recording: the mic in the engine, other apps through an in-repo plugin

- Date: 2026-11-13
- Status: accepted (built on the `record` branch)

## Context

The Record screen (HANDOFF §5) records from the mic, from what other apps
play (Android `AudioPlaybackCapture`, API 29+) and from files, starting
now, when sound starts (with a pre-roll so the attack isn't cut) or after
a one-bar count-in whose clicks are heard. Playback must not suffer while
recording, the count-in has to line up with what the player heard, and
the result goes to the library as f32le PCM with peaks.

Prior art: Choir Coach and Humdinger open an AAudio input stream next to
their output in C. `mob_audio_capture` (Hex 0.2.0) has the MediaProjection
consent and the `mediaProjection` foreground service, but its AudioRecord
read thread only keeps an RMS/peak in Kotlin: `output_level/0` is all it
offers, and no PCM leaves it. AudioPlaybackCapture exists only as a Java
`AudioRecord` configuration; AAudio and the NDK can't open it.

## Decision

- **One recorder in C for every source** (`c_src/recorder.c`, plain C,
  host-tested with the sampler): a buffer of the maximum length allocated
  when recording is armed, a ring of the last ½ s while waiting, the
  meter and the peaks, and the three start modes. Its producer is whichever
  thread delivers input; it never locks or allocates. Stopping hands the
  buffer itself to the BEAM as a resource binary (shrunk with `realloc`),
  not a copy.
- **The mic is an AAudio input stream with its own callback**, mono at the
  output's rate, low latency, shared, `UNPROCESSED` (no AGC or noise
  suppression; `VOICE_RECOGNITION` if refused). The output callback isn't
  touched by recording; the only thing it gains is the count-in's clicks.
- **Every input frame carries its capture time** (the input timestamp,
  CLOCK_MONOTONIC), so the count-in starts the recording on the frame
  captured when its downbeat is *heard* (the output clock): output and
  input latency both drop out. The renderer schedules the clicks (from the
  sequencer's next bar while it plays, so the take lines up with the
  pattern) and reports the downbeat frame; the event thread converts it to
  a heard time for the recorder. A late time is covered by the ring.
- **Other apps: an in-repo Kotlin-only plugin, `plugins/magpie_capture`**,
  not `mob_audio_capture` as a dependency. Its consent and service code is
  the model (one pending consent, stale results dropped, the service
  foregrounded as `mediaProjection` before `getMediaProjection`), but
  delivering PCM means replacing its read loop and NIF, which is most of
  the plugin; activating both would also declare two capture services.
  The plugin is only Kotlin and a manifest `<service>` (the one way to
  ship either through the Mob build); it has no NIF. The `magpie_audio`
  NIF finds `MagpieCapture` through the activity's class loader (as
  Humdinger's `hum_audio.c` does), registers its natives and calls
  `start`/`stop`. The read thread hands 16-bit stereo blocks in a direct
  `ByteBuffer`, stamped from `AudioRecord.getTimestamp`, to the same
  recorder. Magpie's own UID is excluded, so pads and clicks aren't
  recorded with other apps.
- **Import stays in MediaCodec** (`Engine.decode/1`), which doesn't read
  AIFF on Android; `Magpie.Import` falls back to `Magpie.Aiff` (AIFF and
  AIFC: integer PCM, `sowt`, `fl32`, `fl64`) and decodes the result as a
  float WAV, so peaks still come from the engine.
- **Every input and every take has an id, and every message carries
  it.** `input_open` answers `{ok, Input}` (the same number Kotlin's calls
  carry as their session), `record_start` `{ok, Take}` (the recorder's
  arm generation); `:input`, `:meter`, `:record` and `:count_in`
  messages name theirs. A message can still be in a mailbox when the
  input closes or the next take starts (the event thread, the Kotlin
  callbacks and the Engine all run apart), so the Engine forwards only
  the current input's and take's, and the screen matches the ids it was
  given. The count-in's start time goes to the recorder tagged with its
  take too (`rc_start_at`), so a late one never starts the next take.
- **Producers write through the input's gate.** The mic callback and
  Kotlin's read thread call the recorder only between `rc_enter(id)` and
  `rc_leave`, which admits the open input alone; closing shuts the gate
  and waits out a producer inside before anything else. A mic stream that
  wouldn't stop, or a capture thread that outlived its one-second join,
  can then never write into the next input's recorder.
- **A close that fails is the Engine's to finish.** A mic stream that
  won't stop (`input_stuck`) is closed to everyone but still allocated;
  the Engine keeps it as `:closing` and closes it again on its own (1 s,
  doubling to 30 s), whichever path failed (a screen leaving, the
  system's `:closed`, the opener exiting, the next open). A failed open
  leaves no input: the old one was closed first, on both sides.

## Consequences

- The mic's buffer is committed as it fills (Linux maps it lazily): one
  minute of mono costs 11.5 MB at 48 kHz, of other apps 23 MB; up to 300 s
  can be asked for.
- The count-in is one bar of 4/4; a tempo change during it isn't followed.
- Count-in clicks reach the mic through the speaker (use headphones);
  they never reach an other-apps recording.
- Other-app capture needs the consent dialog each time and a visible
  foreground-service notification; apps that opt out of capture, voice
  calls and DRM-protected audio record silence (the meter says so).
- The event thread (started with the output) sends the meters: with no
  output stream there are no meters either.
- Which apps record (moto g power 2021, Android 11): an `AudioTrack`
  player on the normal mixer path (a throwaway app, `USAGE_MEDIA`, 997 Hz
  at amplitude 0.5) arrives exactly (997.0 Hz, −6.02 dBFS peak, all of
  the energy in the tone, whatever the speaker volume: the capture is
  pre-volume); Chrome arrives too once it is really playing (1499 Hz
  through its AAudio player on the deep-buffer mixer). Chrome looked like
  a failure at first: a URL sent to it by intent is held paused by its
  autoplay policy while its AAudio stream runs silent for ~10 s, and
  `dumpsys audio` lists that stream as `started`. The screen needs no
  notice for it: a silent source shows −∞ dB on the meter. Magpie's own
  output records as silence. Not tried: apps that opt out of capture,
  calls, DRM (silent by the platform's rules).
- Sound from other apps starts about 200–240 ms after `:started` (the
  remote submix comes up): a take started at once begins with that much
  silence.
