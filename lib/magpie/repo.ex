defmodule Magpie.Repo do
  use Ecto.Repo,
    otp_app: :magpie,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    # A configured `database:` wins (host tests use an in-memory database).
    database =
      Keyword.get_lazy(config, :database, fn ->
        Path.join(Magpie.Repo.data_dir(), "app.db")
      end)

    {:ok, Keyword.merge(config, database: database, pool_size: 1)}
  end

  @doc """
  The app's persistent data directory, created if missing. MOB_DATA_DIR is set
  by mob_beam.c (Android: `getFilesDir()`, app-private, survives updates);
  off the phone (`mix ecto.migrate` in dev) HOME, then priv/repo.
  """
  def data_dir do
    dir =
      System.get_env("MOB_DATA_DIR") || System.get_env("HOME") ||
        Path.join(File.cwd!(), "priv/repo")

    File.mkdir_p!(dir)
    dir
  end
end
