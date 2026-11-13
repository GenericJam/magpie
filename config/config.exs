import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Magpie.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :magpie, ecto_repos: [Magpie.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, Magpie.Repo

if config_env() == :test do
  # Host tests use a fresh in-memory database each time the Repo starts.
  config :magpie, Magpie.Repo, database: ":memory:", log: false
end
