defmodule Magpie.Import do
  @moduledoc """
  A file into the stash: `Magpie.Engine.decode/1` (MediaCodec on the
  phone: wav, mp3, m4a, flac, ogg…) and `Magpie.Library.put_pcm/2` with
  the engine's peaks, `source: :imported`.

  AIFF and AIFF-C, which the phone's decoder refuses, go through
  `Magpie.Aiff`: decoded here, written as a float WAV to a temporary file
  in the library's directory (the phone has no writable system temp
  directory) and decoded by the engine from there, so the peaks (and the
  two-channel limit) come from the one implementation.
  """

  alias Magpie.{Aiff, Engine, Library, Wav}
  alias Magpie.Library.Sample

  @doc """
  Import the audio file at `path` as `name` (default: the file name
  without its extension). Runs in the caller; a long file takes a while.
  """
  @spec import(Path.t(), String.t() | nil) :: {:ok, Sample.t()} | {:error, term()}
  def import(path, name \\ nil) do
    name = name || path |> Path.basename() |> Path.rootname()

    with {:ok, decoded} <- decode(path) do
      Library.put_pcm(decoded.pcm, %{
        name: name,
        rate: decoded.rate,
        channels: decoded.channels,
        source: :imported,
        peaks: decoded.peaks
      })
    end
  end

  defp decode(path) do
    case Engine.decode(path) do
      {:error, :unsupported} = error -> if aiff?(path), do: decode_aiff(path), else: error
      result -> result
    end
  end

  defp aiff?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 12)) do
      {:ok, head} when is_binary(head) -> Aiff.aiff?(head)
      _ -> false
    end
  end

  defp decode_aiff(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, info, pcm} <- Aiff.decode(bin) do
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
