defmodule Magpie.StarterPack do
  @moduledoc """
  Background import of the bundled starter drum pack (`priv/samples/starter-drums`)
  into `Magpie.Library`.

  Started from `Magpie.App.on_start/0` after `Magpie.KitSession`. `init/1`
  returns at once and `manifest.json` is worked through one file per message
  so the single-scheduler BEAM on the phone stays responsive. Each sample goes
  through `Magpie.Import.import/3` with `source: :pack` and `tags: [category]`.

  Once every entry in the manifest succeeds, a version marker
  (`.starter-drums-v1`) is written in `Magpie.Library.dir()` so later launches
  skip the pack (and samples the user deleted stay deleted). If any file fails,
  no marker is written and the next launch tries again; `Magpie.Library.put_pcm/2`
  deduplicates what is already there without overwriting user renames or tags.
  """

  use GenServer

  require Logger

  alias Magpie.{Import, Library}

  @pack "starter-drums"
  @default_credit "Samples from the Versilian Community Sample Library (VCSL), by Versilian Studios LLC and contributors. CC0 1.0 Universal."

  @type state :: :importing | :ready | :failed
  @type status :: %{
          state: state(),
          done: non_neg_integer(),
          total: non_neg_integer(),
          failed: non_neg_integer()
        }

  defstruct dir: nil,
            id: @pack,
            version: 1,
            credit: @default_credit,
            state: :importing,
            done: 0,
            total: 0,
            failed: 0,
            queue: [],
            subscribers: %{},
            waiters: []

  # ── API ─────────────────────────────────────────────────────────────────────

  @doc "Options: `dir:` overrides `pack_dir/0` (for tests)."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current import progress: `%{state: :importing | :ready | :failed, done: n, total: n, failed: n}`."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Send `{:starter_pack, status}` to `pid` on progress and completion until
  it exits. Returns `{status, credit}` now: the current `status/0` and the
  manifest's attribution (`credit/0`), in one call so a screen mounting
  during the import waits for one file's import, not two.
  """
  @spec subscribe(pid()) :: {status(), String.t()}
  def subscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "The manifest's attribution string."
  @spec credit() :: String.t()
  def credit do
    case Process.whereis(__MODULE__) do
      nil -> read_credit(pack_dir())
      pid -> GenServer.call(pid, :credit)
    end
  end

  @doc "Wait until the import reaches `:ready` or `:failed` and return `status/0`."
  @spec await(timeout()) :: status()
  def await(timeout \\ 30_000), do: GenServer.call(__MODULE__, :await, timeout)

  @doc "Where the bundled starter pack lives on disk."
  @spec pack_dir() :: Path.t()
  def pack_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:magpie, Path.join("priv/samples", @pack))
      beams_dir -> Path.join([beams_dir, "priv", "samples", @pack])
    end
  end

  @doc "The stash name for a pack entry: `\"<category> <basename>\"`."
  @spec sample_name(String.t(), Path.t()) :: String.t()
  def sample_name(category, file) when is_binary(category) and is_binary(file) do
    "#{category} #{file |> Path.basename() |> Path.rootname()}"
  end

  @doc "Path of the completion marker in `Magpie.Library.dir()`."
  @spec marker_path(String.t(), pos_integer()) :: Path.t()
  def marker_path(id \\ @pack, version \\ 1),
    do: Path.join(Library.dir(), ".#{id}-v#{version}")

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &pack_dir/0)
    {:ok, %__MODULE__{dir: dir}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, s) do
    case read_manifest(s.dir) do
      {:ok, manifest} ->
        total = length(manifest.samples)

        s = %{
          s
          | id: manifest.id,
            version: manifest.version,
            credit: manifest.credit,
            total: total
        }

        cond do
          marked?(s) ->
            {:noreply, finish(%{s | state: :ready, done: total})}

          total == 0 ->
            _ = write_marker(s)
            {:noreply, finish(%{s | state: :ready})}

          true ->
            send(self(), :next)
            {:noreply, %{s | queue: manifest.samples}}
        end

      {:error, reason} ->
        if marked?(s) do
          {:noreply, finish(%{s | state: :ready})}
        else
          Logger.warning(
            "Magpie.StarterPack: couldn't read manifest in #{s.dir}: #{inspect(reason)}"
          )

          {:noreply, finish(%{s | state: :failed})}
        end
    end
  end

  @impl GenServer
  def handle_call(:status, _from, s), do: {:reply, view(s), s}

  def handle_call(:credit, _from, s), do: {:reply, s.credit, s}

  def handle_call({:subscribe, pid}, _from, s) do
    subscribers =
      if Map.has_key?(s.subscribers, pid),
        do: s.subscribers,
        else: Map.put(s.subscribers, pid, Process.monitor(pid))

    status = view(s)
    if s.state in [:ready, :failed], do: send(pid, {:starter_pack, status})
    {:reply, {status, s.credit}, %{s | subscribers: subscribers}}
  end

  def handle_call(:await, _from, %{state: state} = s) when state in [:ready, :failed],
    do: {:reply, view(s), s}

  def handle_call(:await, from, s),
    do: {:noreply, %{s | waiters: [from | s.waiters]}}

  @impl GenServer
  def handle_info(:next, %{queue: [entry | rest]} = s) do
    s =
      case import_entry(s.dir, entry) do
        {:ok, _sample} ->
          %{s | done: s.done + 1, queue: rest}

        {:error, reason} ->
          Logger.warning(
            "Magpie.StarterPack: couldn't import #{inspect(entry["file"])}: #{inspect(reason)}"
          )

          %{s | failed: s.failed + 1, queue: rest}
      end

    case rest do
      [_ | _] ->
        send(self(), :next)
        {:noreply, publish(s)}

      [] ->
        {:noreply, complete(s)}
    end
  end

  def handle_info(:next, %{queue: []} = s), do: {:noreply, s}

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # ── Importing ───────────────────────────────────────────────────────────────

  defp import_entry(dir, %{"file" => file, "category" => category})
       when is_binary(file) and is_binary(category) do
    path = Path.join(dir, file)
    name = sample_name(category, file)
    Import.import(path, name, source: :pack, tags: [category])
  end

  defp import_entry(_dir, entry), do: {:error, {:invalid_entry, entry}}

  defp complete(%{failed: 0} = s) do
    case write_marker(s) do
      :ok -> finish(%{s | state: :ready})
      {:error, _} -> finish(%{s | state: :failed})
    end
  end

  defp complete(s), do: finish(%{s | state: :failed})

  defp finish(s) do
    s = publish(s)
    status = view(s)
    Enum.each(s.waiters, &GenServer.reply(&1, status))
    %{s | waiters: []}
  end

  defp view(s), do: %{state: s.state, done: s.done, total: s.total, failed: s.failed}

  defp publish(s) do
    if map_size(s.subscribers) > 0 do
      message = {:starter_pack, view(s)}
      Enum.each(Map.keys(s.subscribers), &send(&1, message))
    end

    s
  end

  # ── Manifest & marker ───────────────────────────────────────────────────────

  defp read_manifest(dir) do
    path = Path.join(dir, "manifest.json")

    with {:ok, json} <- File.read(path),
         {:ok, %{"samples" => samples} = map} when is_list(samples) <- JSON.decode(json) do
      {:ok,
       %{
         id: Map.get(map, "id", @pack),
         version: Map.get(map, "version", 1),
         credit: Map.get(map, "credit", @default_credit),
         samples: samples
       }}
    else
      {:ok, _} -> {:error, :invalid_manifest}
      {:error, _} = error -> error
    end
  end

  defp read_credit(dir) do
    case read_manifest(dir) do
      {:ok, %{credit: credit}} when is_binary(credit) -> credit
      _ -> @default_credit
    end
  end

  defp marked?(s) do
    case File.read(marker_path(s.id, s.version)) do
      {:ok, content} -> String.trim(content) == Integer.to_string(s.version)
      {:error, _} -> false
    end
  end

  defp write_marker(s) do
    path = marker_path(s.id, s.version)

    with :ok <- File.mkdir_p(Library.dir()),
         :ok <- File.write(path, Integer.to_string(s.version)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Magpie.StarterPack: couldn't write marker #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
