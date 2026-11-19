defmodule Magpie.StarterPackTest do
  # Uses the shared Engine / Fake audio and app config (:library_dir, :audio): not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Magpie.{Import, KitSession, Library, StarterPack, Wav}
  alias Magpie.Library.Sample
  alias Magpie.Test.Kits

  defmodule FloatOnlyAudio do
    @moduledoc false
    alias Magpie.Audio.Fake

    # Simulates Android MediaCodec refusing 24-bit integer WAVs while decoding
    # float32 WAVs (the temporary file Magpie.Import writes).
    def decode(path) do
      case File.read(path) do
        {:ok, <<"RIFF", _::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, _::binary>>} ->
          {:error, :unsupported}

        _ ->
          Fake.decode(path)
      end
    end
  end

  @tmp_root Path.join(System.tmp_dir!(), "magpie_starter_pack_test")
  @credit "Samples from the Versilian Community Sample Library (VCSL), by Versilian Studios LLC and contributors. CC0 1.0 Universal."

  setup do
    Kits.setup_library()

    pack_dir = Path.join(@tmp_root, Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(pack_dir)

    on_exit(fn ->
      File.rm_rf!(pack_dir)
    end)

    %{pack_dir: pack_dir}
  end

  defp f32(values), do: for(v <- values, into: <<>>, do: <<v::float-32-little>>)

  # 24-bit integer PCM RIFF/WAVE binary.
  defp encode_s24(values, rate, channels) do
    align = channels * 3

    fmt =
      <<1::little-16, channels::little-16, rate::little-32, rate * align::little-32,
        align::little-16, 24::little-16>>

    data =
      for x <- values, into: <<>> do
        v = round(x * 8_388_608) |> max(-8_388_608) |> min(8_388_607)
        <<v::signed-24-little>>
      end

    pad = if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>

    body =
      <<"WAVE", "fmt ", byte_size(fmt)::little-32, fmt::binary, "data",
        byte_size(data)::little-32, data::binary, pad::binary>>

    <<"RIFF", byte_size(body)::little-32, body::binary>>
  end

  defp write_fixture_pack!(dir, opts \\ []) do
    include_third? = Keyword.get(opts, :include_third, true)

    kick_rel = "bass-drum/BDrum_v1.wav"
    snare_rel = "snare/Snare_v1.wav"
    clap_rel = "clap/SoloClap_vl1.wav"

    for rel <- [kick_rel, snare_rel, clap_rel] do
      File.mkdir_p!(Path.dirname(Path.join(dir, rel)))
    end

    # 512 frames each (2 peak blocks of 256 frames), distinct audio content.
    kick_vals = List.duplicate(0.75, 256) ++ List.duplicate(0.25, 256)
    snare_vals = List.duplicate(-0.5, 256) ++ List.duplicate(0.125, 256)
    clap_vals = List.duplicate(0.5, 256) ++ List.duplicate(-0.25, 256)

    File.write!(Path.join(dir, kick_rel), Wav.encode_s16(f32(kick_vals), 44_100, 1))
    File.write!(Path.join(dir, snare_rel), Wav.encode_s16(f32(snare_vals), 48_000, 1))

    if include_third? do
      File.write!(Path.join(dir, clap_rel), encode_s24(clap_vals, 44_100, 1))
    end

    manifest = %{
      "id" => "starter-drums",
      "name" => "Starter Drums",
      "version" => 1,
      "license" => "CC0-1.0",
      "credit" => @credit,
      "samples" => [
        %{"file" => kick_rel, "category" => "bass-drum"},
        %{"file" => snare_rel, "category" => "snare"},
        %{"file" => clap_rel, "category" => "clap"}
      ]
    }

    File.write!(Path.join(dir, "manifest.json"), JSON.encode!(manifest))
    %{kick: kick_rel, snare: snare_rel, clap: clap_rel, clap_vals: clap_vals}
  end

  describe "Magpie.Import options and WAV fallback" do
    test "defaults to source :imported and empty tags, and accepts source/tags options", %{
      pack_dir: dir
    } do
      path1 = Path.join(dir, "one.wav")
      path2 = Path.join(dir, "two.wav")
      File.write!(path1, Wav.encode_s16(f32(List.duplicate(0.4, 256)), 48_000, 1))
      File.write!(path2, Wav.encode_s16(f32(List.duplicate(0.6, 256)), 48_000, 1))

      assert {:ok, %Sample{name: "one", source: :imported, tags: [], peaks: peaks1}} =
               Import.import(path1)

      assert byte_size(peaks1) == 1

      assert {:ok, %Sample{name: "snare two", source: :pack, tags: ["snare"], peaks: peaks2}} =
               Import.import(path2, "snare two", source: :pack, tags: ["snare"])

      assert byte_size(peaks2) == 1
    end

    test "falls back to Magpie.Wav + temp float WAV when Engine.decode returns :unsupported", %{
      pack_dir: dir
    } do
      path = Path.join(dir, "SoloClap_24.wav")
      vals = List.duplicate(0.5, 256) ++ List.duplicate(-0.25, 256)
      File.write!(path, encode_s24(vals, 44_100, 1))

      previous = Application.get_env(:magpie, :audio)
      Application.put_env(:magpie, :audio, FloatOnlyAudio)
      on_exit(fn -> Application.put_env(:magpie, :audio, previous) end)

      assert {:error, :unsupported} = FloatOnlyAudio.decode(path)

      assert {:ok, sample} =
               Import.import(path, "clap SoloClap_24", source: :pack, tags: ["clap"])

      assert %Sample{
               name: "clap SoloClap_24",
               source: :pack,
               tags: ["clap"],
               rate: 44_100,
               channels: 1,
               frames: 512,
               peaks: peaks
             } = sample

      assert byte_size(peaks) == 2
      assert :binary.at(peaks, 0) > :binary.at(peaks, 1)
      assert Path.wildcard(Path.join(Library.dir(), ".import-*.wav")) == []
    end
  end

  describe "Magpie.StarterPack" do
    test "imports every fixture entry (including 24-bit WAV) with :pack source, category tag, and engine peaks",
         %{pack_dir: dir} do
      write_fixture_pack!(dir)

      existing_sample = Kits.sample!("Mic 17:22", 0.2)
      kit = Kits.kit([{"A", Kits.pad(0, existing_sample)}])
      Kits.start_session!(kit)

      start_supervised!({StarterPack, dir: dir})
      assert {%{total: 3}, @credit} = StarterPack.subscribe()

      assert %{state: :ready, done: 3, total: 3, failed: 0} = StarterPack.await()
      assert_receive {:starter_pack, %{state: :ready, done: 3, total: 3, failed: 0}}
      assert StarterPack.credit() == @credit
      assert File.read!(StarterPack.marker_path()) == "1"

      pack_samples = Library.list(%{source: :pack})
      assert [_, _, _] = pack_samples

      by_name = Map.new(pack_samples, &{&1.name, &1})

      assert %Sample{source: :pack, tags: ["bass-drum"], rate: 44_100, frames: 512, peaks: p1} =
               by_name["bass-drum BDrum_v1"]

      assert %Sample{source: :pack, tags: ["snare"], rate: 48_000, frames: 512, peaks: p2} =
               by_name["snare Snare_v1"]

      assert %Sample{source: :pack, tags: ["clap"], rate: 44_100, frames: 512, peaks: p3} =
               by_name["clap SoloClap_vl1"]

      for peaks <- [p1, p2, p3] do
        assert is_binary(peaks) and byte_size(peaks) == 2
        assert :binary.at(peaks, 0) > 0
      end

      # KitSession and existing user kit are completely untouched.
      assert KitSession.snapshot().kit.banks["A"][0].sample.id == existing_sample.id
    end

    test "second run is a no-op after marker and does not re-add a user-deleted pack sample", %{
      pack_dir: dir
    } do
      write_fixture_pack!(dir)

      start_supervised!({StarterPack, dir: dir})
      assert %{state: :ready, done: 3, total: 3, failed: 0} = StarterPack.await()
      stop_supervised!(StarterPack)

      # User deletes one pack sample, and the source WAVs on disk are removed to
      # prove the second run skips reading them once the marker exists.
      [to_delete | kept] = Library.list(%{source: :pack})
      assert :ok = Library.delete(to_delete.id)

      for wav <- Path.wildcard(Path.join(dir, "**/*.wav")), do: File.rm!(wav)

      start_supervised!({StarterPack, dir: dir})
      assert %{state: :ready, done: 3, total: 3, failed: 0} = StarterPack.await()

      remaining_ids = Library.list(%{source: :pack}) |> Enum.map(& &1.id) |> Enum.sort()
      assert remaining_ids == kept |> Enum.map(& &1.id) |> Enum.sort()
      assert Library.get(to_delete.id) == nil
    end

    test "a failing file leaves no marker and is reported; resuming later imports the rest without duplicates and preserves user renames",
         %{pack_dir: dir} do
      %{clap: clap_rel, clap_vals: clap_vals} = write_fixture_pack!(dir, include_third: false)

      log =
        capture_log(fn ->
          start_supervised!({StarterPack, dir: dir})
          assert %{state: :failed, done: 2, total: 3, failed: 1} = StarterPack.await()
          stop_supervised!(StarterPack)
        end)

      assert log =~ "couldn't import"
      refute File.exists?(StarterPack.marker_path())

      partial = Library.list(%{source: :pack})
      assert [_, _] = partial

      # User renames one of the already-imported pack samples before the next launch.
      kick = Enum.find(partial, &(&1.tags == ["bass-drum"]))
      assert {:ok, %{name: "My Custom Kick"}} = Library.rename(kick.id, "My Custom Kick")

      # Put the missing 24-bit WAV in place and resume on the next launch.
      File.write!(Path.join(dir, clap_rel), encode_s24(clap_vals, 44_100, 1))

      start_supervised!({StarterPack, dir: dir})
      assert %{state: :ready, done: 3, total: 3, failed: 0} = StarterPack.await()
      assert File.read!(StarterPack.marker_path()) == "1"

      final = Library.list(%{source: :pack})
      assert [_, _, _] = final
      assert Library.get(kick.id).name == "My Custom Kick"
      assert Enum.any?(final, &(&1.name == "clap SoloClap_vl1"))
    end
  end
end
