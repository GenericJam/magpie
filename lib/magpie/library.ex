defmodule Magpie.Library do
  @moduledoc """
  The stash: every recorded, resampled or imported sound, stored once, and
  the saved kits that point at them (HANDOFF §6, protocol §2.2).

  A sample's id is the SHA-256 (lowercase hex) of its PCM in Magpie's
  canonical form, interleaved 32-bit float little-endian ("f32le"), so the
  same sound added twice is one sample. The audio lives in a float32 WAV file
  named by that id under `dir/0`; name, source, tags, format and the
  waveform peaks the decoder computed live in SQLite (`Magpie.Repo`).

  Pads are non-destructive (`Magpie.Kit.Region`): editing a pad never
  touches the sample. A sample a saved kit uses can't be deleted.
  """

  import Ecto.Query

  alias Magpie.{Kit, Repo, Wav}
  alias __MODULE__.{KitRecord, Sample}

  @sources ~w(recorded fmutate pack imported)a

  defmodule Sample do
    @moduledoc "A sample's library row. `seconds/1` gives its length."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "samples" do
      field(:name, :string)
      field(:source, Ecto.Enum, values: [:recorded, :fmutate, :pack, :imported])
      field(:tags, {:array, :string}, default: [])
      field(:rate, :integer)
      field(:channels, :integer)
      field(:frames, :integer)
      field(:peaks, :binary)
      timestamps(type: :utc_datetime_usec)
    end

    @doc "Length in seconds."
    def seconds(%__MODULE__{frames: f, rate: r}), do: f / r
  end

  defmodule KitRecord do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "kits" do
      field(:name, :string)
      field(:json, :string)
      field(:sample_ids, {:array, :string}, default: [])
      timestamps(type: :utc_datetime_usec)
    end
  end

  @type source :: :recorded | :fmutate | :pack | :imported

  # ── Samples ─────────────────────────────────────────────────────────────────

  @doc """
  Add a sound. `pcm` is f32le, interleaved; `meta` needs `:name`, `:rate`,
  `:channels`, `:source` (#{inspect(@sources)}), and may carry `:tags` and
  `:peaks` (the decoder's waveform, any binary). A sound already in the
  library comes back as it is (its name and tags are kept).
  """
  @spec put_pcm(binary(), map()) :: {:ok, Sample.t()} | {:error, term()}
  def put_pcm(pcm, %{name: name, rate: rate, channels: channels, source: source} = meta)
      when is_binary(pcm) and is_binary(name) and rate > 0 and channels > 0 and source in @sources do
    with {:ok, frames} <- frames(pcm, channels) do
      id = :sha256 |> :crypto.hash(pcm) |> Base.encode16(case: :lower)

      case Repo.get(Sample, id) do
        %Sample{} = existing -> {:ok, existing}
        nil -> insert(id, pcm, meta, frames)
      end
    end
  end

  def put_pcm(_pcm, _meta), do: {:error, :invalid_meta}

  defp frames("", _channels), do: {:error, :empty}

  defp frames(pcm, channels) do
    frame = 4 * channels

    if rem(byte_size(pcm), frame) == 0,
      do: {:ok, div(byte_size(pcm), frame)},
      else: {:error, :partial_frame}
  end

  defp insert(id, pcm, meta, frames) do
    path = path(id)
    File.mkdir_p!(dir())
    tmp = path <> ".part"

    with :ok <- File.write(tmp, Wav.encode_f32(pcm, meta.rate, meta.channels)),
         :ok <- File.rename(tmp, path) do
      %Sample{
        id: id,
        name: meta.name,
        source: meta.source,
        tags: Map.get(meta, :tags, []),
        rate: meta.rate,
        channels: meta.channels,
        frames: frames,
        peaks: Map.get(meta, :peaks)
      }
      |> Repo.insert()
      |> tap(fn
        {:ok, _} -> :ok
        {:error, _} -> File.rm(path)
      end)
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write, reason}}
    end
  end

  @doc "Add a WAV file's audio (decoded to f32le). `meta` as for `put_pcm/2`, without format fields."
  @spec put_wav(binary(), map()) :: {:ok, Sample.t()} | {:error, term()}
  def put_wav(wav, meta) do
    with {:ok, info, pcm} <- Wav.decode(wav) do
      put_pcm(pcm, Map.merge(meta, %{rate: info.rate, channels: info.channels}))
    end
  end

  @doc "A sample by id, or nil."
  @spec get(String.t()) :: Sample.t() | nil
  def get(id), do: Repo.get(Sample, id)

  @doc "The sample's audio file (float32 WAV)."
  @spec path(String.t()) :: Path.t()
  def path(id), do: Path.join(dir(), id <> ".wav")

  @doc "The sample's audio as f32le PCM."
  @spec pcm(String.t()) :: {:ok, binary()} | {:error, term()}
  def pcm(id) do
    with {:ok, wav} <- File.read(path(id)),
         {:ok, _info, pcm} <- Wav.decode(wav),
         do: {:ok, pcm}
  end

  @doc """
  Samples, newest first. `filter` (all optional): `source: :all | source()`,
  `q: text` (matches the name or a tag, ignoring case).
  """
  @spec list(map()) :: [Sample.t()]
  def list(filter \\ %{}) do
    Sample
    |> filter_source(Map.get(filter, :source, :all))
    |> order_by(desc: :inserted_at, desc: :id)
    |> Repo.all()
    |> filter_text(Map.get(filter, :q))
  end

  defp filter_source(query, :all), do: query
  defp filter_source(query, source) when source in @sources, do: where(query, source: ^source)

  defp filter_text(samples, q) when q in [nil, ""], do: samples

  defp filter_text(samples, q) do
    q = String.downcase(q)

    Enum.filter(samples, fn s ->
      Enum.any?([s.name | s.tags], &String.contains?(String.downcase(&1), q))
    end)
  end

  @doc "Rename a sample. A blank name is refused."
  @spec rename(String.t(), String.t()) :: {:ok, Sample.t()} | {:error, :not_found | :blank}
  def rename(id, name) do
    name = String.trim(name)

    cond do
      name == "" -> {:error, :blank}
      sample = get(id) -> sample |> Ecto.Changeset.change(name: name) |> Repo.update()
      true -> {:error, :not_found}
    end
  end

  @doc "Replace a sample's tags (trimmed, blanks and repeats dropped)."
  @spec set_tags(String.t(), [String.t()]) :: {:ok, Sample.t()} | {:error, :not_found}
  def set_tags(id, tags) do
    case get(id) do
      nil -> {:error, :not_found}
      sample -> sample |> Ecto.Changeset.change(tags: clean_tags(tags)) |> Repo.update()
    end
  end

  defp clean_tags(tags),
    do: tags |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  @doc "Delete a sample and its file, unless a saved kit uses it (`{:error, {:in_use, kit_ids}}`)."
  @spec delete(String.t()) :: :ok | {:error, :not_found | {:in_use, [String.t()]}}
  def delete(id) do
    with %Sample{} = sample <- get(id) || {:error, :not_found},
         [] <- kits_using(id) do
      {:ok, _} = Repo.delete(sample)
      File.rm(path(id))
      :ok
    else
      {:error, _} = error -> error
      kit_ids -> {:error, {:in_use, kit_ids}}
    end
  end

  defp kits_using(id) do
    KitRecord
    |> select([k], {k.id, k.sample_ids})
    |> Repo.all()
    |> Enum.filter(fn {_, ids} -> id in ids end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # ── Kits ────────────────────────────────────────────────────────────────────

  @doc "Save a kit (insert or replace by id)."
  @spec save_kit(Kit.t()) :: {:ok, Kit.t()} | {:error, term()}
  def save_kit(%Kit{} = kit) do
    record = %KitRecord{
      id: kit.id,
      name: kit.name,
      json: Kit.to_json(kit),
      sample_ids: sample_ids(kit)
    }

    record
    |> Repo.insert(
      on_conflict: {:replace, [:name, :json, :sample_ids, :updated_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, _} -> {:ok, kit}
      error -> error
    end
  end

  defp sample_ids(kit) do
    for {_bank, pads} <- kit.banks, {_slot, %{sample: %{id: id}}} <- pads, uniq: true, do: id
  end

  @doc "A saved kit."
  @spec load_kit(String.t()) :: {:ok, Kit.t()} | {:error, :not_found | [Kit.error()]}
  def load_kit(id) do
    case Repo.get(KitRecord, id) do
      nil -> {:error, :not_found}
      record -> Kit.decode(record.json)
    end
  end

  @doc "Saved kits as `%{id, name, updated_at}`, most recently saved first."
  @spec list_kits() :: [%{id: String.t(), name: String.t(), updated_at: DateTime.t()}]
  def list_kits do
    KitRecord
    |> order_by(desc: :updated_at)
    |> select([k], %{id: k.id, name: k.name, updated_at: k.updated_at})
    |> Repo.all()
  end

  @doc "Delete a saved kit (its samples stay in the library)."
  @spec delete_kit(String.t()) :: :ok | {:error, :not_found}
  def delete_kit(id) do
    case Repo.get(KitRecord, id) do
      nil -> {:error, :not_found}
      record -> with {:ok, _} <- Repo.delete(record), do: :ok
    end
  end

  # ── Storage ─────────────────────────────────────────────────────────────────

  @doc "Where sample files live: `config :magpie, :library_dir`, else `<data dir>/samples`."
  @spec dir() :: Path.t()
  def dir, do: Application.get_env(:magpie, :library_dir) || Path.join(Repo.data_dir(), "samples")
end
