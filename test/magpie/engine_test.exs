defmodule Magpie.EngineTest do
  # The engine and its fake are one per VM: not async.
  use ExUnit.Case, async: false

  alias Magpie.Audio.Fake
  alias Magpie.Engine
  alias Magpie.Kit.{Pad, Pattern, Region, Step}
  alias Magpie.Wav

  @tmp_root Path.join(System.tmp_dir!(), "magpie_engine_test")

  setup do
    :ok = Fake.fail_open(nil)
    start_supervised!(Engine)
    :ok = Engine.subscribe()

    dir = Path.join(@tmp_root, Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A WAV file of `seconds` of a 0.5 full-scale square-ish wave.
  defp wav!(dir, name, seconds, rate \\ 48_000, channels \\ 1) do
    frames = round(seconds * rate)

    pcm =
      for i <- 0..(frames * channels - 1)//1,
          into: <<>>,
          do: <<if(rem(i, 64) < 32, do: 0.5, else: -0.5)::float-32-little>>

    path = Path.join(dir, name)
    File.write!(path, Wav.encode_s16(pcm, rate, channels))
    path
  end

  defp loaded!(dir, id, seconds \\ 1.0) do
    {:ok, info} = Engine.load_sample(id, wav!(dir, "#{id}.wav", seconds))
    info
  end

  defp pad(id, opts \\ []) do
    {region, opts} =
      Keyword.split(opts, [:start, :stop, :gain_db, :pitch_st, :fade_out_ms, :reverse])

    struct(%Pad{slot: 0, sample: struct(%Region{id: id}, region)}, opts)
  end

  defp pattern(id, lanes, opts \\ []),
    do: %Pattern{
      id: id,
      bank: Keyword.get(opts, :bank, "A"),
      length: Keyword.get(opts, :length, 16),
      lanes: lanes
    }

  defp lane(steps, mute \\ false), do: %{mute: mute, steps: Enum.map(steps, &struct(Step, &1))}

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  describe "ownership" do
    test "only the engine changes what is loaded; any process can play", %{dir: dir} do
      loaded!(dir, "kick")
      assert :ok = Engine.set_pad(0, pad("kick"))

      assert {:error, :not_owner} = Fake.set_pad(1, nil)
      assert {:error, :not_owner} = Fake.play()
      assert {:error, :not_owner} = Fake.load_sample("other", "/nowhere.wav")

      assert :ok = Task.await(Task.async(fn -> Engine.trigger(0, 100) end))
      assert_receive {:magpie_audio, :voice, 0, :start}
    end

    test "a restarted engine takes the audio over and starts clean", %{dir: dir} do
      loaded!(dir, "kick")
      :ok = Engine.set_pad(0, pad("kick"))
      stop_supervised!(Engine)

      pid = start_supervised!(Engine)
      assert Engine.samples() == %{}
      assert Engine.pads() == %{}
      assert %{owner: ^pid, samples: samples, pads: pads} = Fake.state()
      assert samples == %{} and pads == %{}
    end

    @tag :capture_log
    test "with no output stream, live calls say so" do
      stop_supervised!(Engine)
      :ok = Fake.fail_open(:output_unavailable)
      start_supervised!(Engine)

      assert %{stream: {:error, :output_unavailable}} = Engine.state()
      assert {:error, :not_running} = Engine.trigger(0, 100)
    end
  end

  describe "samples" do
    test "a file loads resampled to the engine's rate, with peaks and its size", %{dir: dir} do
      path = wav!(dir, "loop.wav", 1.5, 44_100, 2)

      assert {:ok, info} = Engine.load_sample("loop", path)

      assert %{rate: 48_000, source_rate: 44_100, channels: 2, frames: 72_000, peak_frames: 256} =
               info

      assert byte_size(info.peaks) == div(72_000 + 255, 256)
      assert info.peaks |> :binary.bin_to_list() |> Enum.all?(&(&1 == 128))
      assert info.bytes == 72_000 * 2 * 2
      assert Engine.samples() == %{"loop" => info}
      assert Engine.memory() == info.bytes
    end

    test "load errors come back to the caller", %{dir: dir} do
      assert {:error, :not_found} = Engine.load_sample("x", Path.join(dir, "missing.wav"))

      text = Path.join(dir, "notes.txt")
      File.write!(text, "not audio")
      assert {:error, :unsupported} = Engine.load_sample("x", text)
      assert Engine.samples() == %{}
    end

    test "library PCM loads without a decoder; more than two channels keep the first two" do
      pcm = for i <- 1..(3 * 4800), into: <<>>, do: <<rem(i, 3) * 0.25::float-32-little>>

      assert {:ok, %{channels: 2, frames: 4800, rate: 48_000}} =
               Engine.load_pcm("lib", pcm, 48_000, 3)

      assert {:error, :no_audio} = Engine.load_pcm("empty", <<>>, 48_000, 1)
    end

    test "an imported file decodes to f32le PCM and peaks for the library", %{dir: dir} do
      path = wav!(dir, "import.wav", 0.5, 22_050)

      assert {:ok, %{pcm: pcm, rate: 22_050, channels: 1, frames: 11_025, peaks: peaks}} =
               Engine.decode(path)

      assert byte_size(pcm) == 11_025 * 4
      assert byte_size(peaks) == div(11_025 + 255, 256)
      assert {:ok, %{frames: 24_000}} = Engine.load_pcm("imported", pcm, 22_050, 1)
    end

    test "unloading clears the pads that use the sample", %{dir: dir} do
      loaded!(dir, "kick")
      loaded!(dir, "snare")
      :ok = Engine.set_pad(0, pad("kick"))
      :ok = Engine.set_pad(1, pad("snare"))

      assert :ok = Engine.unload_sample("kick")
      assert Map.keys(Engine.pads()) == [1]
      assert Map.keys(Fake.state().pads) == [1]
      assert {:error, :unknown_sample} = Engine.unload_sample("kick")
    end
  end

  describe "pads" do
    test "regions in seconds become frames of the loaded sample", %{dir: dir} do
      loaded!(dir, "break", 2.0)

      :ok =
        Engine.set_pad(
          3,
          pad("break", start: 0.25, stop: 0.5, gain_db: -6, mode: :keys, midi_note: 48)
        )

      :ok = Engine.set_pad(4, pad("break", start: 1.0, choke: 2, mode: :loop))

      assert %{3 => three, 4 => four} = Fake.state().pads

      assert %{sample: "break", start: 12_000, end: 24_000, gain_db: -6, mode: :keys, root: 48} =
               three

      assert %{start: 48_000, end: 0, choke: 2, mode: :loop, root: 60} = four
    end

    test "a pad that can't play is refused", %{dir: dir} do
      loaded!(dir, "kick", 0.5)

      assert {:error, :unknown_sample} = Engine.set_pad(0, pad("nope"))
      assert {:error, {:invalid, :start}} = Engine.set_pad(0, pad("kick", start: 0.5))
      assert {:error, {:invalid, :stop}} = Engine.set_pad(0, pad("kick", start: 0.2, stop: 0.1))
      assert {:error, {:invalid, :gain_db}} = Engine.set_pad(0, pad("kick", gain_db: 13))
      assert {:error, {:invalid, :pitch_st}} = Engine.set_pad(0, pad("kick", pitch_st: -25))
      assert {:error, {:invalid, :mode}} = Engine.set_pad(0, pad("kick", mode: :drone))
      assert {:error, {:invalid, :choke}} = Engine.set_pad(0, pad("kick", choke: 4))
      # A region shorter than a frame once rounded would never sound.
      assert {:error, {:invalid, :stop}} =
               Engine.set_pad(0, pad("kick", start: 0.1, stop: 0.10001))

      assert Engine.pads() == %{}
    end

    test "a pad without a sample is silent", %{dir: dir} do
      loaded!(dir, "kick")
      :ok = Engine.set_pad(0, pad("kick"))
      :ok = Engine.set_pad(0, %Pad{slot: 0, name: "EMPTY"})

      assert Fake.state().pads == %{}
      :ok = Engine.trigger(0, 100)
      refute_receive {:magpie_audio, :voice, 0, _}
    end
  end

  describe "sequencer" do
    setup %{dir: dir} do
      loaded!(dir, "kick")
      :ok = Engine.set_pad(0, pad("kick"))
      :ok = Engine.set_pad(1, pad("kick"))
      :ok
    end

    test "a pattern switched while playing takes over at the next bar, from its step 0" do
      a = pattern("A1", %{0 => lane([%{step: 0, vel: 100}])})
      b = pattern("A2", %{1 => lane([%{step: 0, vel: 100}])})
      :ok = Engine.set_pattern(a)
      assert_receive {:magpie_audio, :pattern, ^a, 0}
      :ok = Engine.play()
      assert_receive {:magpie_audio, :playhead, 0, 0}

      Fake.advance(5)
      :ok = Engine.set_pattern(b)
      assert %{pattern: ^a, pending: ^b} = Engine.state()

      Fake.advance(10)
      # The engine forwards in order: by step 15, no pattern change came.
      assert_receive {:magpie_audio, :playhead, 15, _}
      refute_received {:magpie_audio, :pattern, _, _}

      Fake.advance(1)
      # 120 bpm: a bar is 2 s, 96 000 frames.
      assert_receive {:magpie_audio, :pattern, ^b, 96_000}
      assert_receive {:magpie_audio, :playhead, 0, 96_000}
      assert_receive {:magpie_audio, :voice, 1, :start}
      assert %{pattern: ^b, pending: nil, step: 0} = Engine.state()
    end

    test "an edit applies at once and keeps the position" do
      :ok = Engine.set_pattern(pattern("A1", %{0 => lane([%{step: 0, vel: 100}])}))
      :ok = Engine.play()
      Fake.advance(6)

      edited = pattern("A1", %{0 => lane([%{step: 0, vel: 100}, %{step: 7, vel: 90}])})
      :ok = Engine.set_pattern(edited, at: :now)
      assert %{pattern: ^edited, pending: nil} = Engine.state()

      flush()
      Fake.advance(1)
      assert_receive {:magpie_audio, :playhead, 7, _}
      assert_receive {:magpie_audio, :voice, 0, :start}
    end

    test "stopping lets a waiting pattern take over" do
      :ok = Engine.set_pattern(pattern("A1", %{}))
      :ok = Engine.play()
      b = pattern("A2", %{})
      :ok = Engine.set_pattern(b)

      :ok = Engine.stop()
      assert_receive {:magpie_audio, :pattern, ^b, _}
      assert %{playing: false, pattern: ^b, pending: nil} = Engine.state()
    end

    test "kit steps become engine ticks: muted lanes out, negative ticks wrap, pads by bank" do
      lanes = %{
        0 => lane([%{step: 0, vel: 100, tick: -12}, %{step: 3, vel: 60, tick: 5}]),
        2 => lane([%{step: 1, vel: 90, note: 64}]),
        5 => lane([%{step: 4, vel: 127}], true)
      }

      :ok = Engine.set_pattern(pattern("B1", lanes, bank: "B", length: 32))

      assert %{length: 32, events: events} = Fake.state().pattern
      assert Enum.sort(events) == [{24, 18, 90, 64}, {77, 16, 60, nil}, {756, 16, 100, nil}]
    end

    test "patterns, tempo and swing out of range are refused" do
      assert {:error, {:invalid, {:step, 0}}} =
               Engine.set_pattern(pattern("A1", %{0 => lane([%{step: 16, vel: 100}])}))

      assert {:error, {:invalid, {:step, 0}}} =
               Engine.set_pattern(pattern("A1", %{0 => lane([%{step: 1, vel: 0}])}))

      assert {:error, {:invalid, :bank}} = Engine.set_pattern(pattern("E1", %{}, bank: "E"))
      assert {:error, {:invalid, :length}} = Engine.set_pattern(pattern("A1", %{}, length: 24))
      assert {:error, {:invalid, :at}} = Engine.set_pattern(pattern("A1", %{}), at: :soon)
      assert {:error, {:invalid, :tempo}} = Engine.set_tempo(241)
      assert {:error, {:invalid, :swing}} = Engine.set_swing(0.4)

      crowded = lane(for i <- 0..4096, do: %{step: rem(i, 16), vel: 100})
      assert {:error, {:invalid, :steps}} = Engine.set_pattern(pattern("A1", %{0 => crowded}))

      assert :ok = Engine.set_tempo(96)
      assert :ok = Engine.set_swing(0.54)
      assert %{tempo: 96, swing: 0.54} = Engine.state()
      assert %{tempo: 96, swing: 0.54} = Fake.state()
    end
  end

  describe "voices" do
    setup %{dir: dir} do
      loaded!(dir, "kick")
      :ok
    end

    test "a keys pad sounds until its last note is released" do
      :ok = Engine.set_pad(2, pad("kick", mode: :keys, midi_note: 60))
      :ok = Engine.note_on(2, 60, 100)
      :ok = Engine.note_on(2, 64, 100)
      :ok = Engine.note_off(2, 60)
      assert_receive {:magpie_audio, :voice, 2, :start}
      refute_receive {:magpie_audio, :voice, 2, :end}

      :ok = Engine.note_off(2, 64)
      assert_receive {:magpie_audio, :voice, 2, :end}
    end

    test "sequenced gate and loop pads sound for one step; stopping ends them" do
      :ok = Engine.set_pad(0, pad("kick", mode: :gate))
      :ok = Engine.set_pad(1, pad("kick", mode: :loop))
      :ok = Engine.set_pad(2, pad("kick"))

      lanes = %{
        0 => lane([%{step: 0, vel: 100}]),
        1 => lane([%{step: 4, vel: 100}]),
        2 => lane([%{step: 0, vel: 100}])
      }

      :ok = Engine.set_pattern(pattern("A1", lanes))
      :ok = Engine.play()
      assert_receive {:magpie_audio, :voice, 0, :start}
      Fake.advance(1)
      assert_receive {:magpie_audio, :voice, 0, :end}

      Fake.advance(3)
      assert_receive {:magpie_audio, :voice, 1, :start}
      :ok = Engine.stop()
      assert_receive {:magpie_audio, :voice, 1, :end}
      # The one-shot rings on.
      refute_received {:magpie_audio, :voice, 2, :end}
    end
  end

  describe "live record" do
    setup %{dir: dir} do
      loaded!(dir, "kick")
      :ok = Engine.set_pad(1, pad("kick"))
      :ok = Engine.set_pad(18, pad("kick", mode: :keys, midi_note: 60))
      :ok = Engine.set_pattern(pattern("A1", %{}))
      :ok
    end

    test "a hit while playing arrives as the kit step where it was heard" do
      :ok = Engine.play()
      Fake.advance_ticks(3 * 24 + 5)
      :ok = Engine.trigger(1, 90)
      assert_receive {:magpie_audio, :hit, 1, %Step{step: 3, tick: 5, vel: 90, note: nil}}

      # Just before the loop point: step 0 of the next pass, a little early.
      Fake.advance_ticks(15 * 24 + 20 - (3 * 24 + 5))
      :ok = Engine.trigger(1, 70)
      assert_receive {:magpie_audio, :hit, 1, %Step{step: 0, tick: -4, vel: 70}}
    end

    test "keys pads report the note" do
      :ok = Engine.play()
      :ok = Engine.note_on(18, 64, 80)
      assert_receive {:magpie_audio, :hit, 18, %Step{step: 0, tick: 0, vel: 80, note: 64}}
    end

    test "nothing is recorded while stopped" do
      :ok = Engine.trigger(1, 90)
      assert_receive {:magpie_audio, :voice, 1, :start}
      refute_received {:magpie_audio, :hit, _, _}
    end
  end
end
