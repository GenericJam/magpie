# mob.exs — Mob project configuration: plugin activation, plugin trust,
# styles, and build settings. Commit it — a clone without it activates no
# plugins, so their NIFs are left out of the native build.
#
# Machine-specific overrides (e.g. a local `mob_dir` checkout) go in
# mob.local.exs, which is gitignored and imported at the end of this file.
#
# OTP runtimes for Android and iOS are downloaded automatically by `mix mob.install`.

import Config

config :mob_dev,
  # One id on both platforms (Apple forbids "_"; this has none).
  bundle_id: "com.genericjam.magpie",

  # Path to the mob library repo (native source files for iOS/Android builds).
  mob_dir: Path.join(File.cwd!(), "deps/mob"),

  # Path to your Elixir lib dir (e.g. ~/.local/share/mise/installs/elixir/1.18.4-otp-28/lib).
  elixir_lib: System.get_env("MOB_ELIXIR_LIB", :code.lib_dir(:elixir) |> to_string() |> Path.dirname()),

  # iOS devices and orientations, stamped into the built app's Info.plist
  # (they override ios/Info.plist). ios_target_devices: [:iphone, :ipad] runs
  # full-screen on iPad, resizes and joins Split View; [:iphone] runs iPad in
  # iPhone compatibility mode. An App Store app that has shipped iPad support
  # can't drop it in an update. ios_orientations (:all, :portrait or
  # :landscape) applies to iPhone; iPad always declares all four, since
  # iPadOS 26 rotates resizable apps freely.
  ios_target_devices: [:iphone, :ipad],
  ios_orientations: :all,

  # Open the app from <scheme>://... links: each arrives in Elixir as
  # {:link, %{url: url, source: :launch | :running}} (see Mob.Link). Takes a
  # native rebuild (mix mob.deploy --native). Schemes can't contain "_".
  # Also set android:launchMode="singleTask" on MainActivity in
  # android/app/src/main/AndroidManifest.xml (mob_dev refuses to build without it).
  # url_schemes: ["magpie"],

  # Several windows of the app on iPad (Split View, Stage Manager, the app
  # switcher), each with its own navigation, in one BEAM. Stamped into the
  # built app's Info.plist as UIApplicationSupportsMultipleScenes. iOS only;
  # Android ignores it. The per-window navigation needs a mob release with
  # Mob.Scene (not released yet, mob#184): keep false until then.
  multi_window: false,

  # The audio engine (c_src/magpie_audio.c, which includes c_src/magpie_io.c,
  # c_src/sampler.c and c_src/recorder.c): the sampler, sequencer and
  # recorder as mob_audio_io processors, MIDI through mob_midi's C ABI. Plain
  # C over both plugins' C ABIs (they own the streams and the MIDI ports), so
  # it builds for both platforms; only the other-apps input is Android's.
  static_nifs: [%{module: :magpie_audio, archs: [:all]}]

# Activated capability plugins (the packages added in mix.exs). Each contributes
# its native code, permissions, and any demo screens at build time. Drop a name
# here to deactivate a plugin without removing the dep; remove both to drop it
# entirely (the native build shrinks and a clean rebuild prunes its artifacts).
#
# magpie_capture: the "Other apps" recording source (plugins/magpie_capture,
# Kotlin only: the MediaProjection consent, its foreground service and the
# AudioRecord read thread feeding the magpie_audio NIF), part of this repo.
# Android only: on iOS the NIF answers {:error, :unsupported} for it.
# mob_midi: MIDI devices (USB, Bluetooth, other apps' ports), the app's own
# "Magpie" device (its declaration is generated from `config :mob_midi,
# :virtual_device` by `mix mob_midi.gen.virtual_device`) and the C ABI the
# magpie_audio NIF receives and sends MIDI through
# (deps/mob_midi/priv/include/mob_midi.h). A signed Hex release (trusted below).
# mob_audio_io: the audio streams (the output, the microphone) under
# c_src/magpie_io.c's processors, and file decoding
# (deps/mob_audio_io/priv/include/mob_audio_io.h).
config :mob, :plugins, [:magpie_capture, :mob_midi, :mob_audio_io]

# magpie_capture is this app's own code, reviewed with it, so it builds
# unsigned instead of carrying a signing key (mob_dev prints a banner).
# mob_audio_io isn't released yet, so its checkout carries no signature for
# the trust gate below: a git dependency pinned to a commit (mix.lock) of a
# first-party repo. Once it is on Hex, drop it from this list and add it to
# :trusted_plugins with the shared release key like the others.
config :mob, :acknowledge_unsafe_plugins, [:magpie_capture, :mob_audio_io]

# Trust gate for the first-party plugins. Each is signed in CI with the shared
# mob release key; this is that key's public fingerprint. The build refuses an
# ACTIVATED plugin whose signature doesn't verify against a trusted fingerprint
# (tamper protection) — entries for plugins you haven't activated are simply
# unused, so every official plugin is pre-trusted and "just works" the moment
# you add it to deps + :plugins above. For your own/third-party plugins, run
# `mix mob.plugin.trust <name>`, or `config :mob, :acknowledge_unsafe_plugins,
# [...]` for an unsigned prototype.
config :mob, :trusted_plugins, %{
  mob_audio_capture: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_camera: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_location: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_biometric: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_scanner: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_bluetooth: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_screencast: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_midi: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_photos: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_notify: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_mishka: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_ash: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}



if File.exists?(Path.join(__DIR__, "mob.local.exs")), do: import_config("mob.local.exs")
