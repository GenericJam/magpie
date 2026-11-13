defmodule Magpie.WavTest do
  use ExUnit.Case, async: true

  alias Magpie.Wav

  defp f32(values), do: for(v <- values, into: <<>>, do: <<v::float-32-little>>)
  defp floats(pcm), do: for(<<v::float-32-little <- pcm>>, do: v)

  # A WAV with an arbitrary fmt chunk and data, plus optional extra chunks before data.
  defp raw_wav(tag, channels, rate, bits, data, extra \\ <<>>, fmt_ext \\ <<>>) do
    align = channels * div(bits, 8)

    fmt =
      <<tag::little-16, channels::little-16, rate::little-32, rate * align::little-32,
        align::little-16, bits::little-16, fmt_ext::binary>>

    body =
      <<"WAVE", "fmt ", byte_size(fmt)::little-32, fmt::binary, extra::binary, "data",
        byte_size(data)::little-32, data::binary>>

    <<"RIFF", byte_size(body)::little-32, body::binary>>
  end

  test "float32 round-trips bit for bit" do
    pcm = f32([0.0, -1.0, 1.0, 0.123456789, -0.5, 0.25])

    assert {:ok, %{rate: 48_000, channels: 2, frames: 3}, ^pcm} =
             Wav.decode(Wav.encode_f32(pcm, 48_000, 2))
  end

  test "16-bit keeps every sample within one step, and clips past full scale" do
    values = [0.0, 0.5, -0.5, 0.999, -0.999, 1.7, -1.7]
    {:ok, %{channels: 1, frames: 7}, back} = Wav.decode(Wav.encode_s16(f32(values), 44_100, 1))

    for {v, b} <- Enum.zip(Enum.map(values, &max(min(&1, 1.0), -1.0)), floats(back)) do
      assert abs(v - b) <= 1 / 32_767 + 1.0e-6, "#{v} came back as #{b}"
    end
  end

  test "24-bit and 8-bit integer PCM decode to the right levels" do
    s24 = <<8_388_607::signed-24-little, -8_388_608::signed-24-little, 0::signed-24-little>>
    {:ok, %{frames: 3}, pcm} = Wav.decode(raw_wav(1, 1, 22_050, 24, s24))
    assert [hi, -1.0, +0.0] = floats(pcm)
    assert_in_delta hi, 1.0, 1.0e-6

    {:ok, _, pcm8} = Wav.decode(raw_wav(1, 1, 8_000, 8, <<0, 128, 255>>))
    assert [-1.0, +0.0, top] = floats(pcm8)
    assert_in_delta top, 127 / 128, 1.0e-6
  end

  test "skips unknown chunks, including an odd-sized one with its pad byte" do
    list = <<"LIST", 3::little-32, "abc", 0>>
    pcm = f32([0.25, -0.25])
    assert {:ok, %{frames: 2}, ^pcm} = Wav.decode(raw_wav(3, 1, 48_000, 32, pcm, list))
  end

  test "reads WAVE_FORMAT_EXTENSIBLE by its sub-format" do
    # cbSize 22, valid bits 16, channel mask, sub-format GUID starting with 1 (PCM)
    ext = <<22::little-16, 16::little-16, 3::little-32, 1::little-16, 0::size(14)-unit(8)>>
    data = <<16_384::signed-16-little, -16_384::signed-16-little>>

    assert {:ok, %{channels: 2, frames: 1}, pcm} =
             Wav.decode(raw_wav(0xFFFE, 2, 48_000, 16, data, <<>>, ext))

    assert floats(pcm) == [0.5, -0.5]
  end

  test "a trailing partial frame is dropped" do
    data = <<1::signed-16-little, 2::signed-16-little, 3::signed-16-little>>
    assert {:ok, %{channels: 2, frames: 1}, _} = Wav.decode(raw_wav(1, 2, 48_000, 16, data))
  end

  test "errors" do
    assert {:error, :not_wav} = Wav.decode("ID3...mp3")
    assert {:error, :no_data} = Wav.decode(raw_wav(1, 1, 48_000, 16, <<>>) |> binary_part(0, 36))
    assert {:error, {:unsupported, 1, 12}} = Wav.decode(raw_wav(1, 1, 48_000, 12, <<0, 0>>))
  end
end
