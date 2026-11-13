# Handoff from Choir Coach to the next app

Written 2026-11-12 at the end of the Choir Coach session, for a new session
building a similar app. Read this first, then `~/code/choir_coach/AGENTS.md`
(the main reference; this note points into it rather than repeating it).

## Where Choir Coach stands

- **App:** `~/code/choir_coach` (Elixir Mob app), private repo
  github.com/GenericJam/choir_coach, `master` at `9c5b8af`. Mob `~> 0.9.26`,
  mob_dev `~> 0.7.31`. 153 host tests, credo strict clean.
- **Releases:**
  - **Android:** APK 1.2 (versionCode 3), served at choir.genericjam.com/apps.
  - **iOS:** TestFlight version 1.0, build 3, approved. Public link
    https://testflight.apple.com/join/zNrehSSP.
- **Website:** `~/code/choir_web` (Phoenix LiveView; local git only, no
  remote), live at https://choir.genericjam.com behind the password
  `rockyview alliance`.
- **Running on:** moto g 2021, moto g 2024 (Kevin's), moto e 2020 (32-bit),
  iPhone SE 3rd gen (TestFlight), iPhone and iPad simulators.

## What a similar app can reuse

| Piece | Where | Notes |
|---|---|---|
| Audio engine, Android | `c_src/choir_audio.c` (≈1,900 lines) | AAudio output mixing up to 2 sources into lanes with per-lane L/R gain; mic input; NDK MediaCodec decode; timestamps mapping each mic reading to the song time the singer was hearing; one owner at a time. Static NIF registered as `ChoirCoach.Audio.Nif`. |
| Audio engine, iOS | `plugins/choir_audio_ios/` (local unsigned Mob plugin, ≈1,900 lines of Objective-C) | Port of the Android engine: RemoteIO, AudioQueue mic, ExtAudioFile. Same NIF module and events, so `Audio.Native` is shared. Also holds `screen_size/0` (see traps). |
| Pitch detector | `c_src/pitch_yin.c` | YIN. Shared by both engines; compiled to WebAssembly for the website. Host test harness in `c_src/test/pitch_host.c`. |
| Engine contract and test double | `lib/choir_coach/audio.ex`, `audio/native.ex`, `audio/fake.ex`, `audio/lease.ex` | `Audio.Fake` plus `FakeSinger` let screen tests run the real frame, trace and feedback paths on the host. |
| Pitch maths, feedback smoothing | `pitch.ex`, `feedback.ex` | Cents, octave folding, colour/glow/status smoothing ("On pitch", "A little low"). |
| Practice screen | `practice_screen.ex`, `practice_view.ex`, `controls_view.ex`, `style.ex` | Canvas staff + pitch roll at 30 fps; holding a note while paused; octave line; phone and tablet layouts (`window.ex`). Large: read its moduledoc first. |
| Song model | `song.ex`, `songs.ex`, `songs/*.ex`, `roles.ex` | Bar timeline, notes and lyrics per part; Melody/Part tags per note. |
| Mixer | `mix.ex`, `mix_view.ex` | Rows, presets, lane gains. |
| Headphone delay | `calibration.ex` | "Set by singing along": clicks, onset detection, median. |
| Settings | `settings.ex` | Per-device delays, part, mixes (Mob.State / DETS). |
| Device scripts | `scripts/controls_check.exs`, `device_check.exs`, `frame_rate.exs` | Real-touch control check over adb; trace-vs-score fit; frame timing. Copy and adapt early. |
| Audio prep | `scripts/align_track.exs`, `render_piano.exs`, `compress_audio.sh` | Align transcriptions to recordings, render piano guides, shrink tracks. |
| Website | `~/code/choir_web` | Password gate, Web Audio mixer, YIN in an AudioWorklet, canvas port of the practice view, /apps download page, /privacy. `scripts/export_web.exs` in choir_coach exports the songs as JSON. |

## Traps this build hit (avoid them from day one)

1. **Test a release build on a real iPhone early.** Development builds include
   Mob's test tools; release (TestFlight) builds don't. Choir Coach called
   `:mob_nif.screen_info/0` for the screen size. On iOS that function is part
   of the test tools, so every TestFlight build quit 0.4 s after launch until
   build 3 (MOB-517). iOS logs it as a voluntary exit, not a crash: the reason
   is in the app container's `Documents/beam_stdout.log` (`xcrun devicectl
   device copy from --domain-type appDataContainer --domain-identifier
   <bundle id>`). On iOS, never call `:mob_nif.*` test functions from app code.
2. **Every `on_tap` on a screen that redraws on a timer also needs
   `on_press_out={held()}`** (MOB-509). Without it most taps are lost during
   playback. Choir Coach's screen tests check every tap target.
3. **A drag's end can be lost on Android** (MOB-511, about 1 drag in 15).
   Choir Coach ends a drag that's been quiet for 1 s and lets Play/Pause close
   one. Don't run extra frame loops of your own during a drag.
4. **Frame timers need a token.** A tick already queued when you cancel its
   timer still arrives; Choir Coach sends `{:tick, token}` and ignores stale
   ones (a stale tick right after play paused the music).
5. **Expect about 1 in 100–200 real taps to be lost** on slower phones (moto e,
   moto g 2024) even with the fixes; the real-touch check shows it as a
   different single miss each run. Retry before calling it a regression.
6. **`Mob.Test.tap` skips the native tap path.** Only real touches (`adb shell
   input`) catch lost taps and drags. Coordinate taps don't work on a physical
   iPhone (MOB-515).
7. **iOS bundle id:** Apple forbids `_`. Use `ios_bundle_id` in `mob.exs`
   (Choir Coach: `com.genericjam.choircoach`, Android stays
   `com.example.choir_coach`).
8. **iOS flexible `Spacer`s keep a ~8 pt minimum,** so a row of them can
   overflow and shift the whole screen left. Use fixed gaps in tight rows.
   iOS also adds padding outside a node's fixed height.
9. **Canvas text width is a guess** (0.56 em per character) because Mob can't
   measure canvas text (MOB-513). Keep labels left of moving elements with a
   fit-or-shrink rule and a test at 360/390/411 pt.
10. **iOS release bundles carry `priv/` twice** (the recordings doubled the IPA
    to ~290 MB). Not fixed yet; mob_dev `release.ex` copies `priv/` into two
    places.
11. **App Store Connect API answers 403 "requires an in-effect agreement"**
    whenever Apple has a new developer agreement; only Kevin can accept it.
    The API can't create the app record: Kevin does that once on the website.
12. **Xcode 27 has no Simulator.app;** it's DeviceHub
    (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`).
13. **Mic tests from the Mac's speaker** only reach a phone right next to it,
    and low notes (≈130 Hz) barely carry. Check acoustics before blaming code.
14. **32-bit Android phones (moto e):** the APK's 32-bit build works, but first
    launch takes ~33 s to unpack. The trace only shows the last ~2 s, so a
    screenshot in a rest shows no trace: that's not a mic failure.

## Accounts, keys and infrastructure

- **Apple:** team Q89CW299G8; Apple Distribution certificate in the keychain
  (expires 2027-05-02); App Store Connect API key
  `~/.appstoreconnect/AuthKey_9GQ2L259B6.p8`, issuer
  `38bd5c33-223a-44fb-9a94-5237205e3cd3` (see `mob.exs`). New app: register its
  bundle id and create its App Store profile through the API, as Choir Coach's
  AGENTS.md "iOS (TestFlight)" describes, then Kevin creates the app record.
  TestFlight: an internal group (Kevin) plus an external group with a public
  link; the first build of a version needs Apple's beta review (Choir Coach:
  submitted Nov 7 morning, approved by Nov 9 evening; exact time unknown),
  later builds of that version passed within minutes.
- **Android signing:** Choir Coach's upload key is `android/upload_jks.keystore`
  + `keystore.properties` (gitignored; passphrase in Keychain
  `choir-coach-android-upload-keystore`). A new app should get its own key
  (`mix mob.setup.google_play` writes one).
- **Hosting:** Cloudflare tunnels from this Mac, one per site: config
  `~/.cloudflared/<name>.yml`, launchd `com.cloudflare.cloudflared.<name>`,
  DNS with `TUNNEL_ORIGIN_CERT=~/.cloudflared/cert-genericjam.com.pem
  cloudflared tunnel route dns <tunnel> <host>`. The Phoenix server runs under
  launchd `local.phoenix.<app>` with secrets in `~/.config/<app>/env` (0600).
  Choir Coach uses port 8031; pick a free one. Cloudflare caches `/assets/*`:
  version static URLs by content hash (choir_web's `ChoirWeb.static_url/1`).
- **Licensed audio:** never commit it. Choir Coach keeps originals in
  `audio_src/`, shipped copies in `priv/audio/` (gitignored), and the website
  serves them only behind the password.

## Devices

- moto g power 2021 `ZY22DP6HFL`, moto g 2024 `ZY22K6BSJM` (Kevin's), moto e
  2020 `ZY22CRLMWK` (32-bit, 1.8 GB), iPhone SE 3rd gen
  `00008110-001E1C3A34F8401E` (mob_ci sometimes holds it; Kevin approved
  stopping that daemon once).
- Simulators: iPhone 18 Pro `A7363AC9-BC45-4604-8E61-E6061AD11C3C`, iPad Pro
  11-inch (M5) `1AE10236-F7B3-483E-94AA-B9385F844B27`.
- Always lease first (`agent-lease acquire <name> --serial|--udid …`), release
  when done (`~/AGENTS.md`).

## Open Mob issues that may affect the new app

| Issue | What |
|---|---|
| MOB-509 | Plain taps dropped on a screen that re-renders (workaround: `held()`) |
| MOB-510 | Android release never set MOB_RELEASE (fixed in the app's MainActivity) |
| MOB-511 | Android drag `ended` lost when a render lands as the finger lifts |
| MOB-512 | Count and report events the native bridge drops |
| MOB-513 | Layout diagnostics: frames for all nodes, overflow warnings, canvas text measurement |
| MOB-514 | Opt-in diagnostics for release builds |
| MOB-515 | `tap_xy` does nothing on a physical iPhone |
| MOB-516 | Spike: GPUI views embedded in Mob screens (a plugin) |
| MOB-517 | iOS release builds compile out `screen_info/0` |

## Suggested first steps for the new app

1. Generate with `mob.new`, add AGENTS.md + CLAUDE.md pointer, copy Choir
   Coach's "Rules for this app" and "Working on it" sections.
2. If it uses audio and pitch: copy `c_src/`, `plugins/choir_audio_ios/`,
   `lib/choir_coach/audio*`, `pitch.ex`, `feedback.ex`, and rename the NIF
   module. Keep the engine contract and `Audio.Fake` so screens are testable on
   the host.
3. Put `screen_size/0` (or Mob's fix for MOB-517) in from the start, and add
   `held()` to every tap target.
4. Copy and adapt `scripts/controls_check.exs` as soon as there's a screen.
5. Make one release build per platform in the first days: an APK on a moto,
   and a TestFlight build on the iPhone.
