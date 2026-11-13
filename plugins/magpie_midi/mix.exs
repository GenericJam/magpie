defmodule MagpieMidi.MixProject do
  use Mix.Project

  # Magpie's Android MIDI, carried as an in-repo Mob plugin because a plugin
  # is the only way to ship a Kotlin class, a manifest <service> and a res
  # file through the Mob build: the virtual "Magpie" port (a
  # MidiDeviceService, in and out), the device watcher, opening USB /
  # Bluetooth devices, the Bluetooth-MIDI scan and connect, and the send to
  # every destination. Kotlin only: the magpie_audio NIF finds the class,
  # registers its natives (bytes in, device events) and calls it (bytes
  # out, device calls). The Elixir side is Magpie.Midi and Magpie.Engine.
  # Why: decisions/2026-11-13-midi.md.
  def project do
    [
      app: :magpie_midi,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [],
      # As a path dependency it compiles in every mix run of the app; pruning
      # would drop OTP libraries mob_dev's tooling needs (as in Humdinger).
      prune_code_paths: false
    ]
  end

  def application, do: []
end
