import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Magpie.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :magpie, ecto_repos: [Magpie.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, Magpie.Repo

# The audio engine: Magpie.Audio.Native (the magpie_audio NIF over
# mob_audio_io's streams) on the phone, a fake the tests drive on the host.
# MIDI devices likewise: mob_midi, or a fake of it.
config :magpie,
  audio: if(config_env() == :test, do: Magpie.Audio.Fake, else: Magpie.Audio.Native),
  midi: if(config_env() == :test, do: Magpie.Midi.Fake, else: MobMidi)

# The app's own MIDI device "Magpie" (other apps play into its input and
# listen to its output). `mix mob_midi.gen.virtual_device` writes its Android
# declaration from this (res/xml/mob_midi_device.xml + the manifest's
# <service>); then a native build, which reorders the manifest (AGENTS.md).
config :mob_midi, :virtual_device, name: "Magpie", inputs: 1, outputs: 1

if config_env() == :test do
  # Host tests use a fresh in-memory database each time the Repo starts.
  config :magpie, Magpie.Repo, database: ":memory:", log: false

  # Screens skip the phone's own calls (permission dialogs, the file picker,
  # orientation): tests drive their results as messages.
  config :magpie, device_calls: false

  # Magpie.Audio.Native's own tests run it on the host: the plugin's fake
  # streams and decodes, and a double of the magpie_audio NIF.
  config :mob_audio_io, backend: MobAudioIo.Fake
  config :magpie, audio_nif: Magpie.Test.FakeAudioNif
end
