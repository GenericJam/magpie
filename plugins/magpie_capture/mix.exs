defmodule MagpieCapture.MixProject do
  use Mix.Project

  # Recording what other apps play (Android AudioPlaybackCapture, API 29+),
  # carried as an in-repo Mob plugin because a plugin is the only way to ship
  # a Kotlin class and a manifest <service> through the Mob build: the
  # MediaProjection consent, the mediaProjection foreground service and the
  # AudioRecord read thread, which hands PCM to the magpie_audio NIF (it
  # finds the class and registers the natives itself, so the plugin has no
  # NIF of its own). Native only; the Elixir side is Magpie.Engine. Why not
  # mob_audio_capture: decisions/2026-11-13-recording-other-apps.md.
  def project do
    [
      app: :magpie_capture,
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
