defmodule Magpie.Wav do
  @moduledoc """
  RIFF/WAVE in pure Elixir: enough to store the library's samples, import WAV
  files without a platform decoder, and hand siblings `:wav16` (protocol §2.2).

  Magpie's canonical PCM is interleaved 32-bit float, little-endian
  ("f32le"): what the engine mixes, what a sample's id is hashed from, and
  what the library stores (as a WAVE_FORMAT_IEEE_FLOAT file).

  `decode/1` reads 8/16/24/32-bit integer PCM and 32/64-bit float, mono or
  more channels, and returns f32le. It skips chunks it doesn't know (LIST,
  fact, cue…) and accepts WAVE_FORMAT_EXTENSIBLE.
  """

  @pcm 1
  @float 3
  @extensible 0xFFFE

  @type info :: %{rate: pos_integer(), channels: pos_integer(), frames: non_neg_integer()}

  @doc "A float32 WAV file holding `pcm` (interleaved f32le)."
  @spec encode_f32(binary(), pos_integer(), pos_integer()) :: binary()
  def encode_f32(pcm, rate, channels), do: wav(@float, 32, pcm, rate, channels)

  @doc "A 16-bit integer WAV file from f32le `pcm`, clipped to ±1 and rounded."
  @spec encode_s16(binary(), pos_integer(), pos_integer()) :: binary()
  def encode_s16(pcm, rate, channels) do
    data = for <<x::float-32-little <- pcm>>, into: <<>>, do: <<to_s16(x)::signed-16-little>>
    wav(@pcm, 16, data, rate, channels)
  end

  @doc """
  Read a WAV file into f32le. Returns `{:ok, info, pcm}` or `{:error,
  reason}` (`:not_wav`, `:no_format`, `:no_data`, `{:unsupported, format,
  bits}`).
  """
  @spec decode(binary()) :: {:ok, info(), binary()} | {:error, term()}
  def decode(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>), do: chunks(chunks, nil)
  def decode(_), do: {:error, :not_wav}

  @doc "True when `head` (a file's first 12 bytes or more) starts a RIFF/WAVE file."
  @spec wav?(binary()) :: boolean()
  def wav?(<<"RIFF", _size::little-32, "WAVE", _::binary>>), do: true
  def wav?(_head), do: false

  defp chunks(<<"fmt ", size::little-32, body::binary-size(size), rest::binary>>, _fmt) do
    chunks(skip_pad(rest, size), parse_fmt(body))
  end

  defp chunks(<<"data", _size::little-32, _::binary>>, nil), do: {:error, :no_format}

  defp chunks(<<"data", size::little-32, rest::binary>>, fmt) do
    # Streaming writers leave the size at 0 or 0xFFFFFFFF; take what's there.
    data = binary_part(rest, 0, min(size, byte_size(rest)))
    to_f32(fmt, data)
  end

  defp chunks(<<_id::binary-size(4), size::little-32, rest::binary>>, fmt)
       when byte_size(rest) >= size do
    <<_::binary-size(^size), rest::binary>> = rest
    chunks(skip_pad(rest, size), fmt)
  end

  defp chunks(_, _), do: {:error, :no_data}

  # Chunks are word-aligned: an odd size is followed by one pad byte.
  defp skip_pad(<<_, rest::binary>>, size) when rem(size, 2) == 1, do: rest
  defp skip_pad(rest, _size), do: rest

  defp parse_fmt(
         <<tag::little-16, channels::little-16, rate::little-32, _bps::little-32,
           _align::little-16, bits::little-16, ext::binary>>
       ) do
    tag =
      case {tag, ext} do
        {@extensible,
         <<_cb::little-16, _valid::little-16, _mask::little-32, sub::little-16, _::binary>>} ->
          sub

        _ ->
          tag
      end

    %{tag: tag, channels: channels, rate: rate, bits: bits}
  end

  defp parse_fmt(_), do: %{tag: :invalid, channels: 0, rate: 0, bits: 0}

  defp to_f32(%{channels: c, rate: r}, _data) when c < 1 or r < 1, do: {:error, :no_format}

  defp to_f32(%{tag: tag, bits: bits} = fmt, data) do
    frame = div(bits, 8) * fmt.channels
    usable = byte_size(data) - rem(byte_size(data), max(frame, 1))

    case convert(tag, bits, binary_part(data, 0, usable)) do
      :unsupported ->
        {:error, {:unsupported, tag, bits}}

      pcm ->
        frames = div(byte_size(pcm), 4 * fmt.channels)
        {:ok, %{rate: fmt.rate, channels: fmt.channels, frames: frames}, pcm}
    end
  end

  defp convert(@float, 32, data), do: data

  defp convert(@float, 64, data),
    do: for(<<x::float-64-little <- data>>, into: <<>>, do: <<x::float-32-little>>)

  defp convert(@pcm, 8, data),
    do: for(<<x::8 <- data>>, into: <<>>, do: <<(x - 128) / 128::float-32-little>>)

  defp convert(@pcm, 16, data),
    do: for(<<x::signed-16-little <- data>>, into: <<>>, do: <<x / 32_768::float-32-little>>)

  defp convert(@pcm, 24, data),
    do: for(<<x::signed-24-little <- data>>, into: <<>>, do: <<x / 8_388_608::float-32-little>>)

  defp convert(@pcm, 32, data),
    do:
      for(<<x::signed-32-little <- data>>, into: <<>>, do: <<x / 2_147_483_648::float-32-little>>)

  defp convert(_tag, _bits, _data), do: :unsupported

  defp wav(tag, bits, data, rate, channels) do
    align = channels * div(bits, 8)

    fmt =
      <<tag::little-16, channels::little-16, rate::little-32, rate * align::little-32,
        align::little-16, bits::little-16>>

    pad = if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>

    body =
      <<"WAVE", "fmt ", byte_size(fmt)::little-32, fmt::binary, "data",
        byte_size(data)::little-32, data::binary, pad::binary>>

    <<"RIFF", byte_size(body)::little-32, body::binary>>
  end

  # Same scale as decoding (÷ 32768), so a round trip keeps the level.
  defp to_s16(x) do
    v = round(x * 32_768)
    v |> max(-32_768) |> min(32_767)
  end
end
