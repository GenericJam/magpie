defmodule Magpie.AiffTest do
  use ExUnit.Case, async: true

  alias Magpie.Aiff
  alias Magpie.Test.Aiff, as: Build

  # Values every format here stores exactly.
  @samples [0.0, 0.5, -0.5, 0.25, -1.0, 0.125]

  defp f32(values), do: for(v <- values, into: <<>>, do: <<v::float-32-little>>)

  test "16-bit stereo AIFF reads as f32le at its rate" do
    file = Build.encode(@samples, 44_100, 2)
    assert {:ok, %{rate: 44_100, channels: 2, frames: 3}, pcm} = Aiff.decode(file)
    assert pcm == f32(@samples)
  end

  test "24-bit AIFF-C (NONE) at 48 kHz" do
    file = Build.encode(@samples, 48_000, 1, bits: 24, compression: "NONE")
    assert {:ok, %{rate: 48_000, channels: 1, frames: 6}, pcm} = Aiff.decode(file)
    assert pcm == f32(@samples)
  end

  test "sowt: little-endian 16-bit" do
    file = Build.encode(@samples, 22_050, 1, compression: "sowt")
    assert {:ok, %{rate: 22_050, frames: 6}, pcm} = Aiff.decode(file)
    assert pcm == f32(@samples)
  end

  test "fl32 and fl64 floats" do
    samples = [0.1, -0.7, 0.999]
    expected = f32(samples)

    assert {:ok, %{frames: 3}, ^expected} =
             Aiff.decode(Build.encode(samples, 96_000, 1, bits: 32, compression: "fl32"))

    assert {:ok, %{rate: 96_000}, ^expected} =
             Aiff.decode(Build.encode(samples, 96_000, 1, bits: 64, compression: "fl64"))
  end

  test "unknown chunks before COMM, odd-sized too, are skipped" do
    extra = [{"COMT", <<1, 2, 3>>}, {"MARK", <<0, 0>>}]
    file = Build.encode(@samples, 8000, 1, extra: extra)
    assert {:ok, %{rate: 8000, frames: 6}, pcm} = Aiff.decode(file)
    assert pcm == f32(@samples)
  end

  test "frames beyond the data are not invented" do
    file = Build.encode(@samples, 8000, 1)
    head = binary_part(file, 0, byte_size(file) - 4)

    assert {:ok, %{frames: 4}, pcm} = Aiff.decode(head)
    assert pcm == f32(Enum.take(@samples, 4))
  end

  test "what it can't read" do
    assert {:error, :not_aiff} = Aiff.decode("RIFF....WAVE")
    assert {:error, :not_aiff} = Aiff.decode(<<"FORM", 4::32, "8SVX">>)
    assert {:error, :no_format} = Aiff.decode(<<"FORM", 4::32, "AIFF">>)

    assert {:error, {:unsupported, "ulaw", 16}} =
             Aiff.decode(Build.encode(@samples, 8000, 1, compression: "ulaw"))

    <<"FORM", _::32, "AIFF", comm_only::binary>> = Build.encode(@samples, 8000, 1)
    <<"COMM", size::big-32, comm::binary-size(size), _::binary>> = comm_only
    no_data = <<"COMM", size::big-32, comm::binary>>

    assert {:error, :no_data} =
             Aiff.decode(<<"FORM", byte_size(no_data) + 4::big-32, "AIFF", no_data::binary>>)
  end
end
