defmodule Magpie.MixProject do
  use Mix.Project

  def project do
    [
      app: :magpie,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info],
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # 0.9.29: per-node multi-pointer on_touch (MOB-518), which the pads use;
      # 0.9.30: the 32-bit Android fixes (MOB-523), for the moto e (armv7);
      # 0.9.31: what mob_audio_io needs.
      {:mob, "~> 0.9.31"},
      {:mob_dev, "~> 0.7.31", only: :dev, runtime: false},
      # mix mob.icon renders the launcher icons with it.
      {:image, "~> 0.54", only: :dev, runtime: false},
      {:ecto_sqlite3, "~> 0.18"},
      # The "Other apps" recording source (Kotlin; see mob.exs).
      {:magpie_capture, path: "plugins/magpie_capture"},
      # MIDI: devices, the "Magpie" virtual device, Bluetooth MIDI and the C
      # ABI magpie_audio.c sends and receives through (see mob.exs); 0.4.0
      # has that C ABI on iOS too (CoreMIDI, MOB-543).
      {:mob_midi, "~> 0.4.0"},
      # The audio streams under the engine (c_src/magpie_io.c's processors):
      # the output, the microphone and file decoding, on Android and iOS.
      # Temporary: main's commit until 0.1.0 is on Hex, then
      # {:mob_audio_io, "~> 0.1"} (see mob.exs for its trust entry).
      {:mob_audio_io,
       github: "GenericJam/mob_audio_io", ref: "faf1de89b969f5d43a0bf43ff2740008cd35039b"},
      # Tests check kit files against design/kit.schema.json itself.
      {:jsv, "~> 0.28.0", only: :test},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      connect: ["mob.connect"],
      deploy: ["mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      ios: ["mob.deploy --ios"],
      "ios.native": ["mob.deploy --native --ios"],
      android: ["mob.deploy --android"],
      "android.native": ["mob.deploy --native --android"]
    ]
  end
end
