defmodule Magpie.Aiff do
  @moduledoc """
  AIFF and AIFF-C in pure Elixir, for importing files the phone's decoder
  (MediaCodec) doesn't read. Same result as `Magpie.Wav.decode/1`:
  interleaved f32le.

  Reads big-endian integer PCM of 8, 16, 24 or 32 bits (AIFF, and AIFC
  `NONE` / `twos`), little-endian integers (AIFC `sowt`) and 32/64-bit
  float (AIFC `fl32` / `fl64`). Sample sizes that aren't a whole number of
  bytes are stored left-justified in the next one and read as that. The
  sample rate is the COMM chunk's 80-bit extended float. Chunks it doesn't
  know (MARK, INST, COMT, ANNO…) are skipped, in any order. Integer scale
  is ÷ 2^(bits − 1), as `Magpie.Wav`.
  """

  @type info :: Magpie.Wav.info()

  @doc """
  Read an AIFF or AIFF-C file into f32le: `{:ok, %{rate, channels,
  frames}, pcm}` or `{:error, reason}` (`:not_aiff`, `:no_format`,
  `:no_data`, `{:unsupported, compression, bits}`).
  """
  @spec decode(binary()) :: {:ok, info(), binary()} | {:error, term()}
  def decode(<<"FORM", _size::big-32, kind::binary-size(4), chunks::binary>>)
      when kind in ["AIFF", "AIFC"] do
    found = chunks(chunks, %{})

    with {:ok, comm} <- Map.fetch(found, "COMM") |> or_error(:no_format),
         {:ok, fmt} <- parse_comm(comm, kind),
         {:ok, ssnd} <- Map.fetch(found, "SSND") |> or_error(:no_data) do
      to_f32(fmt, sound_data(ssnd))
    end
  end

  def decode(_), do: {:error, :not_aiff}

  @doc "True when `head` (a file's first 12 bytes or more) starts an AIFF or AIFF-C file."
  @spec aiff?(binary()) :: boolean()
  def aiff?(<<"FORM", _size::big-32, kind::binary-size(4), _::binary>>),
    do: kind in ["AIFF", "AIFC"]

  def aiff?(_head), do: false

  # Every chunk by id (the first of each); chunks are padded to even sizes.
  # A truncated last chunk keeps what is there (SSND sizes are sometimes wrong).
  defp chunks(<<id::binary-size(4), size::big-32, rest::binary>>, found) do
    take = min(size, byte_size(rest))
    <<body::binary-size(^take), rest::binary>> = rest

    rest =
      if rem(size, 2) == 1 and rest != <<>>,
        do: binary_part(rest, 1, byte_size(rest) - 1),
        else: rest

    chunks(rest, Map.put_new(found, id, body))
  end

  defp chunks(_rest, found), do: found

  defp or_error({:ok, value}, _reason), do: {:ok, value}
  defp or_error(:error, reason), do: {:error, reason}

  defp parse_comm(
         <<channels::big-16, frames::big-32, bits::big-signed-16, rate::binary-size(10),
           rest::binary>>,
         kind
       )
       when channels > 0 and bits > 0 do
    compression =
      case {kind, rest} do
        {"AIFC", <<type::binary-size(4), _::binary>>} -> type
        _ -> "NONE"
      end

    case extended(rate) do
      rate when rate >= 1 ->
        {:ok, %{channels: channels, frames: frames, bits: bits, rate: rate, comp: compression}}

      _ ->
        {:error, :no_format}
    end
  end

  defp parse_comm(_comm, _kind), do: {:error, :no_format}

  # IEEE 754 80-bit extended: sign, 15-bit exponent (bias 16383), 64-bit
  # mantissa with an explicit integer bit.
  defp extended(<<_sign::1, 0::15, _mantissa::64>>), do: 0

  defp extended(<<_sign::1, exponent::15, mantissa::64>>) do
    shift = exponent - 16_383 - 63

    value =
      if shift >= 0,
        do: Bitwise.bsl(mantissa, shift),
        else: mantissa / :math.pow(2, -shift)

    round(value)
  end

  defp sound_data(<<offset::big-32, _block::big-32, rest::binary>>)
       when offset <= byte_size(rest),
       do: binary_part(rest, offset, byte_size(rest) - offset)

  defp sound_data(_ssnd), do: <<>>

  defp to_f32(%{comp: comp, bits: bits, channels: channels} = fmt, data) do
    case layout(comp, bits) do
      :unsupported ->
        {:error, {:unsupported, comp, bits}}

      {kind, width} ->
        frame = div(width, 8) * channels
        frames = min(fmt.frames, div(byte_size(data), frame))
        pcm = convert(kind, width, binary_part(data, 0, frames * frame))
        {:ok, %{rate: fmt.rate, channels: channels, frames: frames}, pcm}
    end
  end

  # {how samples are stored, container bits}.
  defp layout(comp, bits) when comp in ["NONE", "twos"] and bits in 1..32,
    do: {:big, container(bits)}

  defp layout("sowt", bits) when bits in 1..32, do: {:little, container(bits)}
  defp layout(comp, _bits) when comp in ["fl32", "FL32"], do: {:float, 32}
  defp layout(comp, _bits) when comp in ["fl64", "FL64"], do: {:float, 64}
  defp layout(_comp, _bits), do: :unsupported

  defp container(bits), do: div(bits + 7, 8) * 8

  defp convert(:float, 32, data),
    do: for(<<x::float-32-big <- data>>, into: <<>>, do: <<x::float-32-little>>)

  defp convert(:float, 64, data),
    do: for(<<x::float-64-big <- data>>, into: <<>>, do: <<x::float-32-little>>)

  defp convert(:big, width, data) do
    scale = Bitwise.bsl(1, width - 1)
    for <<x::signed-big-size(^width) <- data>>, into: <<>>, do: <<x / scale::float-32-little>>
  end

  defp convert(:little, width, data) do
    scale = Bitwise.bsl(1, width - 1)
    for <<x::signed-little-size(^width) <- data>>, into: <<>>, do: <<x / scale::float-32-little>>
  end
end
