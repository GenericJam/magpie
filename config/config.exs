import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Magpie.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :magpie, ecto_repos: [Magpie.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, Magpie.Repo

# The audio engine: the magpie_audio NIF on the phone, a fake the tests drive
# on the host.
config :magpie,
  audio: if(config_env() == :test, do: Magpie.Audio.Fake, else: Magpie.Audio.Native)

if config_env() == :test do
  # Host tests use a fresh in-memory database each time the Repo starts.
  config :magpie, Magpie.Repo, database: ":memory:", log: false

  # Screens skip the phone's own calls (permission dialogs, the file picker,
  # orientation): tests drive their results as messages.
  config :magpie, device_calls: false
end
