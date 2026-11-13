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
- **Design companion files are coming from Kevin:** `family_style.ex`,
  `magpie_style.ex`, `kit.schema.json` (+ `kits/dusty-breaks.kit.json`),
  `protocol.md`, `creature.md`. Don't invent `Magpie.Style`, the kit format
  or the pairing protocol before they arrive.

### Design references (read before building a screen)

`design/HANDOFF.md` is the spec. `design/boards/*.dc.html` are the boards
(unpacked from the designer's bundled `Magpie.html`; they render with
JavaScript, so open them in a browser): measurements and colours only, not
code to ship. "Not designed yet (ask before inventing)": kit save/load
sheet, first run (mic permission, empty kit), the library's Kits tab, kit
export/share, error states. `design/choir-coach-handoff.md` is the lessons
note from the previous app.

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
| Pair an app | (`Connect`, not in the bundle) | later |

### App icon

`assets/icon/magpie-icon-1024.png` is the Identity board's app icon
("Magpie over its nest", tile colour `#1C1925`), rendered from
`design/boards/icon-tile.html`. `magpie-icon-foreground-1024.png` is the same
art at 60 % of the canvas for the Android adaptive foreground, so round
launcher masks keep the whole nest. Regenerate every launcher icon with
`mise exec -- mix run --no-start scripts/render_icon.exs`.

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
