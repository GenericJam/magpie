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
- Decisions go in `decisions/YYYY-MM-DD-<slug>.md` (Context / Decision /
  Consequences), as in mob.
