defmodule Magpie.Test.Aiff do
  @moduledoc """
  Builds small AIFF / AIFF-C files for tests: `encode(samples, rate,
  channels, opts)` from interleaved floats. Options: `bits:` (16),
  `compression:` (nil: plain AIFF; `"NONE"`, `"twos"`, `"sowt"`, `"fl32"`,
  `"fl64"` or anything else for AIFF-C), `extra:` (chunks `{id, body}`
  placed before COMM, to be skipped).
  """

  import Bitwise

  def encode(samples, rate, channels, opts \\ []) do
    bits = Keyword.get(opts, :bits, 16)
    comp = Keyword.get(opts, :compression)
    frames = div(length(samples), channels)

    comm =
      <<channels::big-16, frames::big-32, bits::big-16, extended(rate)::binary>> <>
        if(comp, do: comp <> pstring("test"), else: <<>>)

    data = for x <- samples, into: <<>>, do: sample(x, comp, bits)

    body =
      Enum.map_join(Keyword.get(opts, :extra, []), &chunk/1) <>
        chunk({"COMM", comm}) <> chunk({"SSND", <<0::32, 0::32, data::binary>>})

    kind = if comp, do: "AIFC", else: "AIFF"
    <<"FORM", byte_size(body) + 4::big-32, kind::binary, body::binary>>
  end

  defp chunk({id, body}) do
    pad = if rem(byte_size(body), 2) == 1, do: <<0>>, else: <<>>
    <<id::binary-size(4), byte_size(body)::big-32, body::binary, pad::binary>>
  end

  defp pstring(s) do
    bin = <<byte_size(s), s::binary>>
    if rem(byte_size(bin), 2) == 1, do: bin <> <<0>>, else: bin
  end

  defp sample(x, "fl32", _bits), do: <<x::float-32-big>>
  defp sample(x, "fl64", _bits), do: <<x::float-64-big>>
  defp sample(x, "sowt", bits), do: <<int(x, bits)::signed-little-size(bits)>>
  defp sample(x, _comp, bits), do: <<int(x, bits)::signed-big-size(bits)>>

  defp int(x, bits) do
    full = 1 <<< (bits - 1)
    (x * full) |> round() |> max(-full) |> min(full - 1)
  end

  # An integer rate as an 80-bit IEEE extended float.
  defp extended(rate) do
    e = trunc(:math.log2(rate))
    <<0::1, 16_383 + e::15, rate <<< (63 - e)::64>>
  end
end
