defmodule Magpie.Test.Repo do
  @moduledoc """
  The app's database for host tests: `start/0` starts `Magpie.Repo` under the
  test supervisor (a fresh in-memory SQLite database, see
  `config/config.exs`) and migrates it. The migration files are compiled
  once per test run, so tests that each start the Repo don't redefine them.
  (Same helper as Humdinger's.)
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Magpie.Repo

  @doc "Start and migrate the Repo for the calling test."
  def start do
    start_supervised!(Repo)
    Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false)
    :ok
  end

  defp migrations do
    key = {__MODULE__, :migrations}

    with nil <- :persistent_term.get(key, nil) do
      migrations =
        :magpie
        |> Application.app_dir("priv/repo/migrations/*.exs")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(fn file ->
          [version | _] = file |> Path.basename() |> String.split("_")
          [{module, _binary}] = Code.compile_file(file)
          {String.to_integer(version), module}
        end)

      :persistent_term.put(key, migrations)
      migrations
    end
  end
end
