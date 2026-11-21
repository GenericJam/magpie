defmodule Magpie.Import do
  @moduledoc """
  A file into the stash: `Magpie.Engine.decode/1` (the phone's decoder
  through mob_audio_io: AMediaCodec on Android, ExtAudioFile on iOS; wav,
  mp3, m4a, flac…) and `Magpie.Library.put_pcm/2` with the engine's peaks,
  `source: :imported` by default. The decode runs in the caller and stops
  with it (a screen's cancelled import task).

  AIFF, AIFF-C and WAV files the phone's decoder refuses go through
  `Magpie.Aiff` or `Magpie.Wav`: decoded here, written as a float WAV to
  a temporary file in the library's directory (the phone has no writable
  system temp directory) and decoded by the engine from there, so the
  peaks (and the two-channel limit) come from the one implementation.
  """

  alias Magpie.{Aiff, Engine, Library, Wav}
  alias Magpie.Library.Sample

  @doc """
  Import the audio file at `path` as `name` (default: the file name
  without its extension). Options: `source:` (`:imported`) and `tags:`
  (`[]`). Runs in the caller; a long file takes a while.
  """
  @spec import(Path.t(), String.t() | nil, keyword()) :: {:ok, Sample.t()} | {:error, term()}
  def import(path, name \\ nil, opts \\ [])
      when (is_binary(name) or is_nil(name)) and is_list(opts) do
    name = name || path |> Path.basename() |> Path.rootname()

    with {:ok, decoded} <- decode(path) do
      Library.put_pcm(decoded.pcm, %{
        name: name,
        rate: decoded.rate,
        channels: decoded.channels,
        source: Keyword.get(opts, :source, :imported),
        tags: Keyword.get(opts, :tags, []),
        peaks: decoded.peaks
      })
    end
  end

  defp decode(path) do
    case Engine.decode(path) do
      {:error, :unsupported} = error ->
        case fallback(path) do
          nil -> error
          decoder -> decode_with(path, decoder)
        end

      result ->
        result
    end
  end

  defp fallback(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 12)) do
      {:ok, head} when is_binary(head) ->
        cond do
          Aiff.aiff?(head) -> &Aiff.decode/1
          Wav.wav?(head) -> &Wav.decode/1
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp decode_with(path, decoder) do
    with {:ok, bin} <- File.read(path),
         {:ok, info, pcm} <- decoder.(bin) do
      dir = Library.dir()
      tmp = Path.join(dir, ".import-#{System.unique_integer([:positive])}.wav")

      try do
        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(tmp, Wav.encode_f32(pcm, info.rate, info.channels)),
             do: Engine.decode(tmp)
      after
        File.rm(tmp)
      end
    end
  end
end
