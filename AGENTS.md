# AGENTS.md: magpie

Magpie is a [Mob](https://hexdocs.pm/mob) app: Elixir on the BEAM,
running on the phone, rendering native SwiftUI / Jetpack Compose views. Screens
live in `lib/magpie/`; `lib/magpie/app.ex` starts the app.

## Where Mob's docs are

Read the docs for the mob version this app actually uses, in this order:

1. **`deps/mob/guides/*.md` and `deps/mob/usage-rules.md`**, after `mix deps.get`.
   These match the installed version exactly. (With a `path:` dependency on
   mob, read that checkout's `guides/` instead.)
2. **https://hexdocs.pm/mob/llms.txt**, the index of every page. Each page is
   also served as Markdown at `https://hexdocs.pm/mob/<page>.md`, e.g.
   https://hexdocs.pm/mob/screen_lifecycle.md. Hexdocs shows the latest
   release; check `mix.lock` if behaviour differs.
3. **`mix hex.docs fetch mob`** for offline docs, written to
   `~/.hex/docs/hexpm/mob/<version>/`.
4. **IEx**: `iex -S mix`, then `h Mob.Socket.start_async` (any module or
   function).

Guides to start with: `getting_started`, `screen_lifecycle` (including async
loading with `start_async/3` / `handle_async/3`), `components`, `events`,
`navigation`, `testing` (`Mob.ScreenCase`), `coming_from_liveview`.

## Rules for this app

- Load data asynchronously with `Mob.Socket.start_async/3` and handle the result
  in `handle_async/3` (LiveView's `start_async`; `assign_async` is a `:loading`
  assign plus `start_async`). Never a bare `Task.async` in a screen.
- Long or paginated lists use `<LazyList>` with `on_end_reached`. Mob has no
  `stream`.
- Write UI with the `~MOB` sigil.
- Test screens with `Mob.ScreenCase` (`mount_screen`, `render_event`,
  `render_info`, `render_async`).

If you use [usage_rules](https://hexdocs.pm/usage_rules), `mix usage_rules.sync`
picks up `deps/mob/usage-rules.md`.

## What this app is

**Magpie: collect sounds, play them back.** A phone sampler: tall velocity
pads (4 banks × 16), a step sequencer, recording and chopping samples, and a
sample library ("the stash"). Its mascot is a scruffy magpie that steals
sounds; its nest is the pad grid. One app in a family built on Mob:
**FMutate** (FM-1 emulator / synth; only a design handoff exists so far),
**Humdinger** (voice → MIDI, `~/code/humdinger`), Magpie, and later a Strudel
app. Each app stands alone: Magpie must be fully useful with no sibling
installed and no account; pairing only adds.

**Scope decisions (Kevin, 2026-11-12):**

- **Android only for now.** iOS is a later port (Choir Coach's
  `plugins/choir_audio_ios` shows how). Keep Elixir platform-neutral where
  it costs nothing; the generated `ios/` tree stays.
- **Standalone first.** No pairing in the first milestones: FMutate doesn't
  exist yet, its protocol v1 has no record call or library sharing, and
  Humdinger has no pairing server. The Connect screen and a family protocol
  extension come later.
- **Pads use Mob's per-node multi-pointer `on_touch` (MOB-518)**, built
  into Mob first rather than a pad view of the app's own.

### Design references (read before building a screen)

`design/HANDOFF.md` is the spec; read it first. Beside it:

- `family_style.ex` (the family tokens, = FMutate's `style.ex`) and
  `magpie_style.ex`: the designer's token files, ported in `Magpie.Style`.
- `kit.schema.json` and `kits/dusty-breaks.kit.json`: the kit format,
  implemented by `Magpie.Kit`.
- `creature.md`: the magpie's geometry, moods and animation.
- `protocol.md`: Magpie's part of the family protocol (later milestone).
- `boards/*.dc.html`: the designer's source boards; `Magpie.html` is the
  same boards bundled to render (open it in a browser). Measurements and
  colours only, not code to ship. `boards/icon-tile.html` is the app icon
  tile, extracted from the rendered Identity board.

"Not designed yet (ask before inventing)": kit save/load sheet, first run
(mic permission, empty kit), the library's Kits tab, kit export/share, error
states. `design/choir-coach-handoff.md` is the lessons note from the
previous app.

| Screen | Board | Module (planned) |
|---|---|---|
| Identity, the magpie, moods, icon | `Main`, `Bird` | `Magpie.Bird`, app icon |
| Pads (home, landscape 8 × 2) | `Pads` | `Magpie.PadsScreen` |
| Sequencer | `Seq` | `Magpie.SeqScreen` |
| Record a sample | `Record` | `Magpie.RecordScreen` |
| Sample editor + chop | `Editor` | `Magpie.EditorScreen` |
| Pad settings (long-press) | `PadSheet` | sheet in `PadsScreen` |
| Bus mode (portrait 4 × 4) | `Bus` | `Magpie.BusScreen` |
| Library (the stash) | `Library` | `Magpie.LibraryScreen` |
| Pair an app | `Connect` | later |

### App icon

`assets/icon/magpie-icon-1024.png` is the Identity board's app icon
("Magpie over its nest", tile colour `#1C1925`), rendered from
`design/boards/icon-tile.html`. `magpie-icon-foreground-1024.png` is the same
art at 60 % of the canvas for the Android adaptive foreground, so round
launcher masks keep the whole nest. Regenerate every launcher icon with
`mise exec -- mix run --no-start scripts/render_icon.exs`.

## Shared modules (in place; extend, don't fork)

- **`Magpie.Style`**: the token maps of `design/family_style.ex` and
  `design/magpie_style.ex`, copied verbatim (hex strings) and converted to
  ARGB at compile time; a test fails if either drifts from the design file.
  `color(token)`, `pad_color(name)`, `pad_palette/0`, `pad_fill(name, :idle
  | :loop | :playing)` (opaque, over `raised`), `bird(:awake | :asleep)`,
  `space/1`, `edge_gutter/0` (28), `radius/1` (family; pads use
  `pad().radius`, 14), `type/1`, `motion/0`, `pad/0`, `sequencer/0`,
  `grid_for/2`, `velocity(y, height)` (127 at the top … 19 at the bottom),
  `fixed_velocity/0`, `pitch_color/2` (ARGB; the family file returns
  `{h, s, l}`), `hsl/3`, `alpha/2`, `blend/3`, `theme/0` (set in
  `App.on_start`; fonts in `priv/fonts`: `:default` Inter, `:medium`,
  `:semibold`, `:bold`, `:mono` JetBrains Mono, `:mono_semibold`,
  `:mono_bold`, `:display` Bricolage Grotesque 800).
- **`Magpie.Kit`**: `magpie.kit/1`. `load/1`, `decode(json | map) :: {:ok,
  Kit} | {:error, [{path, message}]}` (every problem, as JSON paths),
  `encode/1`, `to_json/1`, `pad_index(bank, slot)` (0..63) and
  `bank_slot/1`. Structs `Kit` (banks `%{"A".."D" => %{slot => Pad}}`),
  `Pad`, `Region` (seconds; `stop: nil` = to the end; the JSON key is
  `end`), `Pattern` (lanes `%{slot => %{mute, steps}}`), `Step` (`step`,
  `vel`, `tick` −12..12 at 96 PPQN, `note`). Tests validate encoded kits
  against `design/kit.schema.json` with JSV, and check that every invalid
  case the decoder rejects the schema rejects too. One rule beyond the
  schema: `step < length`.
- **`Magpie.Library`** (the stash): a sample's id is the SHA-256 (lowercase
  hex) of its PCM in canonical form, interleaved f32le, so a sound is stored
  once (protocol §2.2). Audio in `<dir>/<id>.wav` (float32 WAV; `dir/0` =
  `config :magpie, :library_dir` or `<MOB_DATA_DIR>/samples`), rows in
  SQLite (`samples`, `kits`). `put_pcm(pcm, %{name, rate, channels, source,
  tags?, peaks?})` (a known sound comes back unchanged; `:empty`,
  `:partial_frame`, `:invalid_meta`), `put_wav/2`, `get/1`, `path/1`,
  `pcm/1`, `list(%{source: :all | :recorded | :fmutate | :pack | :imported,
  q: text})` (newest first; `q` matches name or tag, any case), `rename/2`,
  `set_tags/2`, `delete/1` (`{:error, {:in_use, kit_ids}}` while a saved kit
  uses it), `save_kit/1` (replace by id), `load_kit/1`, `list_kits/0`,
  `delete_kit/1`. `peaks` is whatever the decoder computed (the engine);
  the library doesn't compute waveforms. Tests: `Magpie.Test.Repo.start/0`
  (in-memory SQLite, migrations compiled once).
- **`Magpie.Wav`**: `encode_f32/3`, `encode_s16/3` (for protocol `:wav16`),
  `decode/1` → `{:ok, %{rate, channels, frames}, f32le}` from 8/16/24/32-bit
  integer or 32/64-bit float, mono or more, WAVE_FORMAT_EXTENSIBLE, unknown
  chunks skipped. Integer scale is ÷ 32768 both ways.
- **`Magpie.Bird`**: the magpie (`design/creature.md`) as `Mob.Canvas` ops:
  `ops(mood, x:, y:, size:, trinket:)`, moods `:idle | :listen | :grab |
  :play | :proud | :sleep | :nomic` (`moods/0`); size 1 = 64 × 56 pt. No
  rotation or gradients.
- **`Magpie.Import`**: `import(path, name \\ nil)` → `Engine.decode/1` →
  `Library.put_pcm(source: :imported)`. AIFF/AIFC (MediaCodec answers
  `:unsupported` on Android) goes through **`Magpie.Aiff`** (`decode/1`
  like `Magpie.Wav.decode/1`: big-endian integer, `sowt`, `fl32`, `fl64`),
  then a float WAV under the library dir so the engine still makes the
  peaks.
- **`Magpie.RecordScreen`**: the Record board. Params `%{pad: 0..63,
  reply_to: pid}` record into a pad: the title names it and each saved
  sample goes to `reply_to` as `{:recorded, pad, %Magpie.Library.Sample{}}`.

## Architecture (planned)

```
pad on_touch (MOB-518: pointer id, y in pad) ─► velocity ─► Engine.trigger ─┐
MIDI in (mob_midi) ─────────────────────────────────────────────────────────┤
                                                                            ▼
             audio engine (C NIF, AAudio): voice pool, choke groups, sequencer clock (96 PPQN, swing)
                                                                            │
                         events (step played, playhead, voice ended) ◄──────┘ ─► screens
```

- **Timing lives in the audio thread.** The Android BEAM runs one
  scheduler, so sequencer steps, swing and MIDI clock are scheduled in the
  engine's AAudio callback, not by BEAM timers. The BEAM edits patterns and
  receives playhead/step events for display.
- **Engine base:** Choir Coach's `c_src/choir_audio.c` (AAudio via dlopen,
  low-latency shared float stream, NDK MediaCodec decode, `getTimestamp`
  clock mapping, mic input), reworked into a sampler. Behind a behaviour
  with `Native` and `Fake` implementations so screens test on the host
  (the Choir Coach / Humdinger pattern).
- **Library:** sample audio as files under `Mob.Storage.dir(:app_support)`,
  metadata and kits in SQLite (`Magpie.Repo`). Pads are non-destructive:
  sample id + start/end/fades/pitch/gain/reverse.
- Real-time processes start from `App.on_start`, never from a screen.

## The audio engine

`c_src/magpie_audio.c` is a static NIF (`mob.exs` `:static_nifs`, Android
only), `ERL_NIF_INIT(Elixir.Magpie.Audio.Nif, …)`. It includes
`c_src/sampler.c`, plain C (no Android, no erl_nif) that builds on the Mac:
voices, choke, the sequencer, the queues, the resampler. Elixir side:
`Magpie.Audio` (the behaviour; `Native` on the phone, `Fake` in host tests,
`config :magpie, :audio`) owned by **`Magpie.Engine`**, one GenServer
started in `App.on_start`. Why it is built this way:
`decisions/2026-11-12-audio-engine-design.md`.

### `Magpie.Engine` API

- **Subscribe** (`subscribe/1`, monitored) for
  `{:magpie_audio, :playhead, step, frame}`,
  `{:magpie_audio, :voice, pad, :start | :end}` (a voice of the pad started;
  its last voice ended), `{:magpie_audio, :hit, pad, %Magpie.Kit.Step{}}`
  and `{:magpie_audio, :pattern, %Magpie.Kit.Pattern{}, frame}` (it took
  over). Frames are engine frames; `Magpie.Audio.frame_time(clock(), frame)`
  is when one is heard, in `System.monotonic_time(:nanosecond)`.
- **Samples:** `load_sample(id, path)` (MediaCodec: wav 16/24/float, mp3,
  m4a, flac, ogg checked), `load_pcm(id, f32le, rate, channels)` (the
  library's PCM, no decoder: use this for kits), both blocking the caller
  until the sample is in RAM and returning `%{frames, channels, rate, peaks,
  peak_frames, bytes, source_rate, load_ms}`; `decode(path)` (import: f32le
  at the file's rate, up to 2 channels, plus peaks, for
  `Magpie.Library.put_pcm/2`); `unload_sample/1` (clears pads using it);
  `samples/0`, `memory/0`. Ids are library ids. Up to 256 samples, 5
  minutes each.
- **Peaks:** one byte per 256 frames, the largest |sample| over the
  channels, linear, 255 = full scale.
- **Pads:** `set_pad(index, %Magpie.Kit.Pad{} | nil)` (regions in seconds,
  converted to frames of the loaded sample; `{:error, :unknown_sample |
  {:invalid, field}}`), `clear_pad/1`, `pads/0`. Index =
  `Magpie.Kit.pad_index(bank, slot)`. Changes apply from the pad's next
  trigger.
- **Live:** `trigger(index, velocity, quantize: ticks)`, `release/1`,
  `note_on/3`, `note_off/2`. They run in the caller (no GenServer hop) and
  only queue a command; `{:error, :not_running}` without a stream. The
  caller applies the pad's velocity mode (`Magpie.Style.velocity/2`).
  `quantize:` (24 a 16th, 96 a beat, 384 a bar) waits for the grid while
  playing: Snap for loop launches.
- **Sequencer:** `set_pattern(%Magpie.Kit.Pattern{}, at: :bar | :now)`
  (`:bar` while playing: takes over at the next bar from its step 0, for
  switching; `:now`: at once, same position, for edits; muted lanes are
  left out), `set_tempo/1` (40..240), `set_swing/1` (0.5..0.75), `play/0`,
  `stop/0` (a waiting pattern takes over), `state/0`.
- **Live record:** while playing, each live trigger also arrives as a hit
  `%Magpie.Kit.Step{step, vel, tick, note}`: the nearest step of the
  playing pattern and `tick` (−12..12) from that step's swung start, at the
  frame being *heard* when the call was made (the output timestamp), so
  the output latency doesn't drag the recording late. Snap on: store it
  with `tick: 0`.
- `clock/0`, `info/0` (stream, underruns, callback timing, voices, steals,
  trigger latency, sample bytes, dropped events); `Native.reset_stats/0`.
  A restarted Engine resets the engine: load the kit again.

### Inside

- **Output:** AAudio low-latency, shared, stereo float at the device's
  rate. Buffer 2 bursts; the event thread adds a burst after an underrun
  and reopens the stream after a disconnect (headphones, Bluetooth).
- **Commands:** a lock-free ring (1024) the callback drains at the start
  of each buffer: a live call sounds from the next callback's first frame.
  While no stream renders, control calls apply themselves and live calls
  are dropped.
- **Voices:** 32 sound at once, 16 more slots hold voices fading out.
  Gain = (velocity/127)² (the DLS curve) × pad gain. Pitch by 4-point
  Hermite resampling (pitch_st, keys notes from `midi_note`, and the
  sample/engine rate ratio). Fades in sample time: fade-in at the start of
  what is heard, fade-out before the region's end (in reverse too); at
  least 0.5 ms in and 1 ms out against clicks. Modes: one_shot (release
  ignored), gate (until release), loop (loops until release), toggle (a
  trigger starts a loop, the next stops it), keys (note_on/off chromatic
  from `midi_note`; trigger plays the root). A release fades over
  max(fade_out_ms, 5 ms). Choke groups 1–3: a start fades the group's other
  pads in 4 ms. Full: the quietest sounding voice (then the oldest) fades
  in 4 ms in a spare slot; only with all 48 slots busy is the quietest
  fading voice cut. Output soft-clips above 0.8 (tanh knee) into ±1.
- **Sequencer:** position in ticks is linear in frames from a base
  (rebased on tempo changes); an event sounds on the first frame at or
  after its position, so steps are exact to the frame at any buffer size.
  A step is `step × 24 + tick` (wrapped: step 0, tick −12 is the pattern's
  end); swing warps each 8th-note pair (first half to `48 × swing` ticks).
  Swing changes wait for the next pair, pattern switches for the next bar.
  Sequenced gate, loop and keys pads sound for one step.
- **Samples:** 16-bit at the engine's rate, resampled once on load
  (Blackman-windowed sinc, 16 zero crossings), mono or stereo (more
  channels: the first two). 96 KB per second mono, 192 KB stereo at 48 kHz.
- **Events:** an event thread every 2 ms sends one playhead, at most a
  start and an end per pad, every hit and pattern change; it also frees
  retired samples and patterns and refreshes the clock mapping (20 ms).
- **Locks:** `lock` (stream lifecycle; only dirty NIFs and the event
  thread's trylock) → `ctl` (owner, sample table) → `push` / `jobs_lock`
  → `stats_lock`. The callback takes none.

### Measured

On the moto g power 2021 (Android 11), `scripts/engine_check.exs`:

- **Stream:** 48 kHz, 240-frame bursts (5 ms), buffer 480 frames, low
  latency, shared (no exclusive mode on this phone). Output latency (frames
  written but not yet heard) 32–36 ms. The callback is the legacy
  `AudioTrack` thread (SCHED_FIFO 2) on a little core (A53, 1.8 GHz).
- **Trigger latency**, NIF call → first frame heard (200 triggers):
  p50 34.3 ms, p95 36.8 ms (29–37). That is the output path; the call
  itself costs 4–12 µs on the BEAM.
- **Step timing:** every step on its exact frame (0 frames off over 49–97
  steps at 120 bpm straight, 173 bpm swing 0.62, 240 bpm swing 0.75).
  Playhead messages arrive 27–33 ms *before* the step is heard (jitter
  around that p95 1.4–3.4 ms, max 5 ms): draw the playhead at
  `frame_time/2`, not on arrival.
- **Load:** idle stream 28 µs per callback (0.6 % of real time, the app 5 %
  of a core); sequencer at 140 bpm 56 µs; 31 looping voices plus the
  sequencer 1.44 ms mean, 2.3 ms max per 5 ms callback (32 % of real time,
  app 38 % of a core), 33 voices with steals 1.57 ms / 2.6 ms; no
  underruns. The host bench (`sampler_host bench`) on the phone: 32 voices
  cost 86 ns per voice-frame back to back on a little core and 259 ns paced
  every 5 ms like the callback (the core wakes slowly): the paced number is
  the one the app sees.
- **Loading** (2 s stereo 44.1 kHz → 48 kHz): wav 130–165 ms, flac
  170 ms, mp3 220 ms, m4a 275 ms, ogg/opus 165 ms; 10 s of library PCM
  (`load_pcm`) 160–180 ms. Missing file `:not_found`.
- **Memory:** 188 KB per stereo second in the engine (exactly 2 bytes ×
  channels × 48000). The process grows more while PCM passes through the
  BEAM (`Library.pcm/1` reads it into a binary; +18 MB RSS for 11 MB of
  samples), and the BEAM's allocators don't hand that back at once.
- **Budget per phone** (handoff open question 1): on a 4 GB phone like this
  one, keep loaded samples under about 64 MB (≈ 5.5 min stereo, 11 min
  mono): with the BEAM's own copy while loading that stays well clear of
  Android's low-memory killer. A drum kit is far below (64 one-shots of
  0.5 s stereo ≈ 6 MB); chopped breaks share one sample. Phones with 6 GB+
  can take 128 MB. `Engine.memory/0` is the number to check against.

### Checking it

- Host, the C core: `cc -O2 -Wall -Wextra -o /tmp/sampler_host
  c_src/test/sampler_host.c -lm && /tmp/sampler_host` (step timing to the
  frame at 5 tempos × 4 swings with random block sizes, off-grid and
  negative ticks, block-size independence, tempo change, pattern swap at
  the bar and edits now, choke and steal with a bounded sample-to-sample
  step, pitch to 0.5 ¢, reverse, loop, gate/one-shot/toggle/keys, fades and
  velocity, hit stamping with swing, quantized launch, unload while
  playing, queue overflow, the limiter, resampler SNR and aliasing, peaks;
  the count-in's clicks and downbeat stopped and on the sequencer's bar,
  the recorder's threshold, pre-roll, start time (ahead, late from the
  ring, past it), length limit and peaks, and the whole count-in chain
  through a latency loopback: the take starts on the downbeat's frame;
  arm generations (an earlier arm's start time never starts a later one)
  and the input's gate; then the recorder on threads for 1.5 s
  (`STRESS_MS`, `STRESS_SEED`): producer, a straggler from closed inputs,
  count-in starts in arm order, a reader under the lock, and control
  arming, stopping, cancelling and reopening the input at random, every
  take checked frame by frame against the input). Also with
  `-fsanitize=address,undefined` and `-fsanitize=thread`.
  `/tmp/sampler_host bench` (built with `-Os`, as the app is) for render
  cost.
- The NIF for Android: `$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang
  --target=aarch64-linux-android28 --sysroot=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot
  -I ~/.mob/cache/otp-android-*/erts-*/include
  -DSTATIC_ERLANG_NIF_LIBNAME=magpie_audio -Wall -Wextra -c c_src/magpie_audio.c`
  (also `armv7a-linux-androideabi28`, `x86_64-linux-android28`).
- Host, Elixir: `mix test test/magpie/engine_test.exs` (the Fake: ownership,
  loading and errors, pads in seconds, pattern compile, swap at the bar,
  edits now, hits as kit steps), `engine_record_test.exs`,
  `record_screen_test.exs`, `aiff_test.exs`, `bird_test.exs`.
- Device: `mix mob.deploy --native --android --device <serial>`, `mix
  mob.connect --no-iex --android-only --device <serial>`, then
  `SERIAL=<serial> mix run --no-start scripts/engine_check.exs` (needs
  ffmpeg; turn the volume down); recording: `scripts/record_check.exs`
  (grant RECORD_AUDIO first; `OTHER_APPS=1` also records Chrome).

## Recording

Why it is built this way: `decisions/2026-11-13-recording-other-apps.md`.
`c_src/recorder.c` (plain C, in the host harness) is the recorder for every
source: a buffer of the maximum length allocated when armed, a ring of the
last ½ s while waiting, the meter, the peaks, and the start modes. The mic
is an AAudio input stream of its own (mono, the output's rate, low latency
requested, `UNPROCESSED`); other apps come from
`plugins/magpie_capture` (Kotlin only: MediaProjection consent, a
`mediaProjection` foreground service, `AudioRecord` on the playback
capture, 16-bit stereo, Magpie's own UID excluded), whose read thread hands
blocks to the NIF. Every block carries its capture time, so a count-in
starts the take on the frame captured when its downbeat is heard.

### `Magpie.Engine` recording API

- `open_input(:mic | :apps)` → `{:ok, input}`: closes any input, then opens
  this one (monitors the caller: the input closes when it exits); after a
  failed open nothing is open. `close_input/0`; `{:magpie_audio, :input,
  input, :started, %{source, rate, channels}}` / `{:magpie_audio, :input,
  input, :closed, :denied | :stopped | :disconnected | :error}`.
  `state/0`'s `input` (`%{id, source, status, rate, channels}`; status
  `:closing` while a mic stream that wouldn't stop is closed again, every
  second and slower, by the Engine on its own; `close_input/0` answers
  `{:error, :input_stuck}` then).
- `{:magpie_audio, :meter, input, level_db, %{take, state, frames,
  peaks}}` every 40 ms while an input is open: peak dBFS since the last
  one, the armed take (nil none), the recorder's state (`:idle | :waiting
  | :counting | :recording | :full`), frames so far and the new peak bytes
  (append them).
- `record(mode: :now | :on_sound | :count_in, max_seconds: 60,
  threshold_db: -30, pre_roll_ms: 150)` → `{:ok, take}`; `{:magpie_audio,
  :record, take, :started, %{pre_roll_frames, late_frames}}`,
  `{:magpie_audio, :record, take, :full, frames}`, `{:magpie_audio,
  :count_in, take, first_frame, downbeat_frame}` (4 clicks, one bar at the
  tempo; while the sequencer plays, from its next bar). `:count_in` needs
  the output stream.
- Ids are positive integers, never reused. A message about an input or a
  take that is over can still be queued when the next one starts: the
  Engine drops them, and a subscriber matches the ids it was given.
- `stop_recording/0` → `{:ok, %{pcm, rate, channels, frames, peaks,
  peak_frames}}` (the recorder's own buffer as a resource binary, no copy)
  or `{:error, :not_recording | :not_started}`; `cancel_recording/0`.
- Inside: the input's producer (the mic callback, Kotlin's read thread)
  writes through a gate (`rc_enter`/`rc_leave`) open only for the input's
  id; closing shuts it and waits out a producer inside, so a stream that
  wouldn't stop or a capture thread that outlived its join never writes
  into the next input. The count-in's start time is tagged with its take
  (`rc_start_at`).
- Changing `lib/magpie/audio/nif.ex` and hot-pushing (`mix mob.deploy`
  without `--native`) reloads the module and drops the static NIF
  (`:nif_not_loaded`): restart the app (`mix mob.connect`).

### Measured (moto g power 2021, Android 11, `scripts/record_check.exs`)

- **Mic:** 48 kHz mono, `UNPROCESSED` (preset 9), burst 960 frames (20 ms):
  AAudio gives it the normal path, not low latency. `VOICE_RECOGNITION`
  gets low latency (burst 192) but its input timestamp never succeeds and
  its processing swallows the clicks, so it is only the fallback. Newest
  frame 5–10 ms old when it reaches the recorder; no overruns.
- **Playback while recording:** sequencer at 120 bpm, 5 s without and 5 s
  with the mic recording: 0 underruns both, output callback mean 33.6 →
  37.1 µs, max 206 → 330 µs (of 5 ms), CPU 0.74 → 0.82 %, nothing
  dropped. The take: 240 000 frames for 5.00 s, the clicks 24 000 frames
  apart within ±110 frames (acoustic onset detection through the speaker).
- **Meters:** 25 a second, 39–43 ms apart.
- **Count-in (playing, 120 bpm, speaker → mic):** the click on the downbeat
  lands 2040–2050 frames (42.5–42.7 ms) into the take in every run, the
  next ones 24 000 apart. The engine is exact to its clocks (the host
  loopback test puts the downbeat on frame 0); the 42.5 ms is latency the
  phone's output and input timestamps don't report. A per-phone offset
  (measured by loopback) would remove it; not built yet. Stopped, the 4
  clicks span exactly 2.00 s and none reach the take.
- **When sound starts:** room −40 dBFS, threshold −28 dBFS, a pad click
  1.5 s after arming: `pre_roll_frames` 7200, its onset at 149.9 ms into the
  take (the full 150 ms pre-roll, attack intact).
- **Length limit:** `max_seconds: 2` → `:full` at exactly 96 000 frames.
- **Playback through a pad:** 5 s take → `load_pcm` 10–13 ms, `set_pad`,
  `trigger`: the voice starts.
- **Import:** wav and mp3 through MediaCodec; AIFF → `:unsupported` from
  MediaCodec, imported through `Magpie.Aiff` (88 200 frames × 2, 44.1 kHz).
- **Other apps:** the consent dialog ("Start now", tapped over adb), the
  `mediaProjection` service and the playback-capture `AudioRecord` all
  start (`:started`, 48 kHz stereo; the system registers the
  remote-submix mix), and PCM arrives at the real rate (480 000 frames in
  10 s). But Chrome playing a tone (its own AAudio player, usage MEDIA,
  capture policy unset) came through as digital silence in three tries,
  playing in front and behind. Not yet explained; a player on the plain
  AudioTrack/mixer path (a music app, YouTube) is the next thing to try.

## Rules for Mob screens here (from Choir Coach and Humdinger)

- **Every `on_tap` on a screen that re-renders on a timer** (pads while
  playing, sequencer, record) **also declares `on_press_out={held()}`**
  (MOB-509). Screen tests check every tap target has it.
- Frame timers carry a token (`{:tick, token}`) and stale ticks are ignored.
- Never call `:mob_nif.*` test functions (e.g. `screen_info/0`) from app
  code: release builds compile them out (MOB-517).
- Canvas: no gradients, rotation or hard offset shadows; waveforms are bars
  (rects). Text width is a guess (≈0.56 em per character, MOB-513). A long
  sample's waveform is rendered once (to a PNG for `<Image src>`, or a
  native view), not as thousands of shapes; the canvas `image` op does
  nothing on Android.
- A drag's end can be lost on Android (MOB-511): end a drag quiet for 1 s.
- Mob's root already insets the safe area; don't pad it again. Landscape
  screens keep 28 pt side gutters for the back gesture.
- `Mob.Test.tap/2` skips the native tap path: only real touches (`adb shell
  input`) catch lost taps.

## Working on it

- Run mix through mise (`mise exec -- mix …`): `.tool-versions` pins the
  toolchain (zig 0.17.0; the nightly in `~/.local/bin` fails the native
  build).
- Gate before every commit: `mix format`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix test`.
- Devices are shared with other agents: lease first (`agent-lease acquire
  <name> --serial <serial>`), release when done (see `~/AGENTS.md`).
- Android: `mix mob.deploy --native --android --device <serial>` after
  native changes (`c_src/`, plugins, manifest, icons), else `mix mob.deploy
  --android --device <serial>`; restart with `mix mob.connect --no-iex
  --android-only --device <serial>`. Scripts over dist need
  `Node.set_cookie(MobDev.DistCookie.for_project!())`.
- `priv/generated/driver_tab_{android,ios}.zig` are committed (the rest of
  `priv/generated/` is ignored): mob_dev only creates a driver table for
  plugin NIFs, so without these files `magpie_audio` links but never
  registers (`:nif_not_loaded` on the phone, MOB-519). Regenerate with `mix
  mob.regen_driver_tab` after changing `:static_nifs`; they can go
  untracked once mob_dev creates them for `:static_nifs` itself.
- Decisions go in `decisions/YYYY-MM-DD-<slug>.md` (Context / Decision /
  Consequences), as in mob.
