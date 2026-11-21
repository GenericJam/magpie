defmodule Magpie.Audio.Native.Decode do
  @moduledoc """
  File decoding for `Magpie.Audio.Native`: `MobAudioIo.decode_stream/3`
  (AMediaCodec on Android, ExtAudioFile on iOS) in the calling process,
  chunk by chunk, each made into the library's form by the NIF
  (`Magpie.Audio.Nif.import_chunk/2`: the first two channels, clipped to
  ±1, with its peaks) before the next is asked for.

  The decode's own memory stays at a few chunks whatever the file's length
  (the plugin waits for each acknowledgement); what grows is the PCM being
  collected, which the caller asked for. Files over 5 minutes are refused
  (`:too_long`): at once when the file says so, else once 301 s have
  decoded, as the engine always did. The decode stops within one codec
  buffer when the calling process exits (a screen's import task that was
  cancelled, a screen that went away).
  """

  @nif Application.compile_env(:magpie, :audio_nif, Magpie.Audio.Nif)

  @max_seconds 300
  # Whole peak blocks (256 frames), so the chunks' peaks join into the file's.
  @chunk_frames 65_536
  @peak_frames 256

  @doc """
  Decode `path` in the caller: `{:ok, t:Magpie.Audio.decoded/0}` (f32le at
  the file's rate, up to two channels, peaks) or `{:error, reason}`
  (`:not_found`, `:unsupported`, `:no_audio`, `:too_long`, `:alloc`,
  `:decode_error`, `:busy` (four decodes run), `:cancelled`).
  """
  @spec decode(Path.t()) :: {:ok, Magpie.Audio.decoded()} | {:error, term()}
  def decode(path) do
    opts = [chunk_frames: @chunk_frames, max_ms: (@max_seconds + 1) * 1000]

    case MobAudioIo.decode_stream(IO.chardata_to_string(path), self(), opts) do
      {:ok, decode} -> collect(decode, nil, [], [])
      {:error, reason} -> {:error, reason(reason)}
    end
  end

  @doc """
  Finish the file load `ticket` (`Magpie.Audio.Nif.load_claim/1`) of
  sample `id` from `path`: the decoded PCM goes to the loader, or the
  failure to the owner, in the load's turn.
  """
  @spec load(term(), term(), Path.t()) :: :ok | {:error, term()}
  def load(id, ticket, path) do
    case decode(path) do
      {:ok, d} -> @nif.load_ticket(id, ticket, d.pcm, d.rate, d.channels)
      {:error, reason} -> @nif.load_ticket_failed(id, ticket, load_reason(reason))
    end
  end

  # The decode's messages, in order: its format, chunks (each acknowledged
  # once converted), one end.
  defp collect(decode, format, pcm, peaks) do
    receive do
      {:mob_audio_io, :decode_started, ^decode, %{rate: rate, channels: channels, frames: frames}} ->
        if is_integer(frames) and frames > @max_seconds * rate,
          do: abandon(decode, :too_long),
          else: collect(decode, %{rate: rate, channels: channels}, pcm, peaks)

      {:mob_audio_io, :decoded, ^decode, chunk} ->
        {chunk_pcm, chunk_peaks} = @nif.import_chunk(chunk, format.channels)
        _ = MobAudioIo.decode_ack(decode)
        collect(decode, format, [pcm | chunk_pcm], [peaks | chunk_peaks])

      {:mob_audio_io, :decode_done, ^decode, %{frames: 0}} ->
        {:error, :no_audio}

      {:mob_audio_io, :decode_done, ^decode, %{frames: frames, rate: rate, channels: channels}} ->
        {:ok,
         %{
           pcm: IO.iodata_to_binary(pcm),
           rate: rate,
           channels: min(channels, 2),
           frames: frames,
           peaks: IO.iodata_to_binary(peaks),
           peak_frames: @peak_frames
         }}

      {:mob_audio_io, :decode_cancelled, ^decode, _} ->
        {:error, :cancelled}

      {:mob_audio_io, :decode_error, ^decode, %{reason: reason}} ->
        {:error, reason(reason)}
    end
  end

  defp abandon(decode, reason) do
    _ = MobAudioIo.decode_cancel(decode)
    drain(decode)
    {:error, reason}
  end

  # What is left of the decode's messages, up to its end.
  defp drain(decode) do
    receive do
      {:mob_audio_io, kind, ^decode, _}
      when kind in [:decode_done, :decode_cancelled, :decode_error] ->
        :ok

      {:mob_audio_io, _kind, ^decode, _} ->
        drain(decode)
    after
      # decode_cancel/1 answered :ok (only :decode_cancelled follows) or
      # :not_running (the end is already here): never long.
      5_000 -> :ok
    end
  end

  defp reason(:no_memory), do: :alloc
  defp reason(reason), do: reason

  @load_reasons [
    :not_found,
    :unsupported,
    :no_audio,
    :decode_error,
    :too_long,
    :alloc,
    :busy,
    :cancelled
  ]
  defp load_reason(reason) when reason in @load_reasons, do: reason
  defp load_reason(_reason), do: :decode_error
end
