defmodule Magpie.Audio.NativeTest do
  # Magpie.Audio.Native on the host: mob_audio_io's fake streams and
  # decodes (MobAudioIo.Fake) and a double of the NIF (FakeAudioNif). Both
  # are global: not async.
  use ExUnit.Case, async: false

  # mob_audio_io logs every open, close and decode.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Magpie.Audio.Native
  alias Magpie.Audio.Native.Io
  alias Magpie.Test.FakeAudioNif
  alias Magpie.Wav
  alias MobAudioIo.Fake

  @tmp_root Path.join(System.tmp_dir!(), "magpie_native_test")

  setup do
    :ok = Io.stop()
    :ok = Fake.reset()
    :ok = Fake.register_processor("magpie_out")
    :ok = Fake.register_processor("magpie_mic")
    :ok = FakeAudioNif.start(self())

    dir = Path.join(@tmp_root, Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(dir)

    on_exit(fn ->
      Io.stop()
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp streams, do: MobAudioIo.status().streams

  defp stream(processor), do: Enum.find(streams(), &(&1.processor == processor))

  # An owner that lives until told, as the Engine does.
  defp owner do
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp wav!(dir, name, frames, rate, channels, fun) do
    pcm =
      for f <- 0..(frames - 1)//1,
          c <- 0..(channels - 1)//1,
          into: <<>>,
          do: <<fun.(f, c)::float-32-little>>

    path = Path.join(dir, name)
    File.write!(path, Wav.encode_f32(pcm, rate, channels))
    path
  end

  defp floats(bin), do: for(<<x::float-32-native <- bin>>, do: x)

  describe "the output" do
    test "open: the engine's owner, then the output on magpie_out, stereo at the device's rate" do
      owner = owner()

      assert {:ok, %{rate: 48_000, burst: 192, buffer_frames: 384, low_latency: nil}} =
               Native.open(owner)

      assert_received {:fake_nif, :open, [^owner]}

      assert [%{processor: "magpie_out", direction: :output, channels: 2, rate: 48_000}] =
               streams()
    end

    test "a new owner's open replaces the streams of the one before: never two outputs" do
      assert {:ok, _} = Native.open(owner())
      assert {:ok, _} = Native.input_open(:mic)
      assert {:ok, _} = Native.open(owner())
      assert [%{processor: "magpie_out"}] = streams()
    end

    test "the streams close when the owner exits" do
      owner = owner()
      assert {:ok, _} = Native.open(owner)
      assert {:ok, _} = Native.input_open(:mic)
      ref = Process.monitor(Process.whereis(Io))
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, _, :normal}
      assert streams() == []
    end

    test "a refused output is :output_unavailable, logged; the NIF stays the owner's" do
      Fake.fail_next_open({:unavailable, "open: AAUDIO_ERROR_UNAVAILABLE (-889)"})

      log =
        capture_log(fn -> assert {:error, :output_unavailable} = Native.open(owner()) end)

      assert log =~ "[magpie_audio] no output: open: AAUDIO_ERROR_UNAVAILABLE"
      assert_received {:fake_nif, :open, [_]}
      assert streams() == []
    end

    test "a NIF that can't open (no processors) opens no stream" do
      FakeAudioNif.answer(:open, {:error, :processors})
      assert {:error, :processors} = Native.open(owner())
      assert streams() == []
    end

    test "close: the NIF's threads (owner only), then the stream; the mic stays" do
      assert {:ok, _} = Native.open(owner())
      assert {:ok, _} = Native.input_open(:mic)
      FakeAudioNif.answer(:close, {:error, :not_owner})
      assert {:error, :not_owner} = Native.close()
      assert [_, _] = streams()
      FakeAudioNif.answer(:close, :ok)
      assert :ok = Native.close()
      assert [%{processor: "magpie_mic"}] = streams()
    end
  end

  describe "the microphone" do
    setup do
      {:ok, _} = Native.open(owner())
      :ok
    end

    test "opens mono at the engine's rate, unprocessed, after the NIF made it the input" do
      FakeAudioNif.answer(:input_open, {:ok, 7, 44_100})
      assert {:ok, 7} = Native.input_open(:mic)
      assert_received {:fake_nif, :input_open, [:mic]}

      assert %{direction: :input, rate: 44_100, input_channels: 1, preset: :unprocessed} =
               stream("magpie_mic")
    end

    test "a device that refuses unprocessed input: its default preset, on a fresh input id" do
      Fake.fail_next_open({:unavailable, "open: AAUDIO_ERROR_ILLEGAL_ARGUMENT"})

      log = capture_log(fn -> assert {:ok, 2} = Native.input_open(:mic) end)

      # The refused start left input 1 closed (as lost): input 2 gets the stream.
      assert_received {:fake_nif, :input_open, [:mic]}
      assert_received {:fake_nif, :input_open, [:mic]}
      assert log =~ "unprocessed input refused"
      assert %{preset: :default} = stream("magpie_mic")
    end

    test "replacing the mic: the old input and its stream are gone before the new input opens" do
      assert {:ok, _} = Native.input_open(:mic)
      test = self()

      FakeAudioNif.answer(:input_open, fn :mic ->
        send(test, {:mic_at_open, stream("magpie_mic")})
        {:ok, 42, 48_000}
      end)

      assert {:ok, 42} = Native.input_open(:mic)
      assert_received {:fake_nif, :input_close, []}
      assert_received {:mic_at_open, nil}
      assert %{processor: "magpie_mic"} = stream("magpie_mic")
    end

    test "no permission: :no_permission and no input left" do
      Fake.deny_permission()
      assert {:error, :no_permission} = Native.input_open(:mic)
      assert_received {:fake_nif, :input_close, []}
      assert stream("magpie_mic") == nil
    end

    test "a mic that can't open: its error, and no input left" do
      :ok = Fake.reset()
      :ok = Fake.register_processor("magpie_out")
      assert {:error, :unknown_processor} = Native.input_open(:mic)
      assert_received {:fake_nif, :input_close, []}
      assert stream("magpie_mic") == nil
    end

    test "closing: the NIF shuts the input before its stream goes (so its STOPPED is no lost device)" do
      assert {:ok, _} = Native.input_open(:mic)
      test = self()

      FakeAudioNif.answer(:input_close, fn ->
        send(test, {:mic_at_close, stream("magpie_mic")}) && :ok
      end)

      assert :ok = Native.input_close()
      assert_received {:mic_at_close, %{processor: "magpie_mic"}}
      assert stream("magpie_mic") == nil
    end

    test "other apps: the mic stream before is closed" do
      assert {:ok, _} = Native.input_open(:mic)
      FakeAudioNif.answer(:input_open, {:ok, 9})
      assert {:ok, 9} = Native.input_open(:apps)
      assert stream("magpie_mic") == nil
    end

    test "other apps where they don't exist (iOS): :unsupported, and the mic before is gone" do
      assert {:ok, _} = Native.input_open(:mic)
      FakeAudioNif.answer(:input_open, {:error, :unsupported})
      assert {:error, :unsupported} = Native.input_open(:apps)
      assert stream("magpie_mic") == nil
    end

    test "not the owner: nothing changes" do
      assert {:ok, _} = Native.input_open(:mic)
      FakeAudioNif.answer(:input_close, {:error, :not_owner})
      assert {:error, :not_owner} = Native.input_open(:mic)
      assert %{processor: "magpie_mic"} = stream("magpie_mic")
      FakeAudioNif.answer(:input_close, :ok)
    end

    test "a lost microphone is logged; the NIF tells the owner, who closes it" do
      assert {:ok, _} = Native.input_open(:mic)
      mic = stream("magpie_mic").id

      log =
        capture_log(fn ->
          :ok = Fake.inject(mic, :device_lost, %{})
          _ = Io.status()
        end)

      assert log =~ "[magpie_audio] the microphone went (device_lost)"
      assert :ok = Native.input_close()
      assert stream("magpie_mic") == nil
    end
  end

  describe "info/0 and reset_stats/0" do
    test "the engine's figures with the streams' under the keys they always had" do
      {:ok, _} = Native.open(owner())

      FakeAudioNif.answer(:info, %{
        running: true,
        rate: 48_000,
        input: %{source: :mic, status: :open, rate: 48_000, channels: 1, callbacks: 3}
      })

      {:ok, _} = Native.input_open(:mic)

      assert %{
               running: true,
               burst: 192,
               buffer_frames: 384,
               buffer_capacity: 4096,
               exclusive: false,
               output_latency_ms: 8.0,
               underruns: 0,
               reopens: 0,
               low_latency: nil,
               input: %{source: :mic, callbacks: 3, burst: 192, overruns: 0},
               io: %{output: %{processor: "magpie_out"}, mic: %{processor: "magpie_mic"}}
             } = Native.info()
    end

    test "without a stream: zeros, no input" do
      assert %{burst: 0, underruns: 0, output_latency_ms: -1.0, input: nil, io: %{output: nil}} =
               Native.info()
    end

    test "other apps' input has no stream figures" do
      {:ok, _} = Native.open(owner())
      FakeAudioNif.answer(:info, %{input: %{source: :apps, status: :open}})
      assert %{input: %{source: :apps, preset: 0, burst: 0, overruns: 0}} = Native.info()
    end

    test "reset_stats: the engine's and the streams' counters" do
      {:ok, _} = Native.open(owner())
      assert :ok = Native.reset_stats()
      assert_received {:fake_nif, :reset_stats, []}
    end
  end

  describe "decode/1" do
    test "the file at its rate, two channels at most, clipped, with its peaks", %{dir: dir} do
      frames = 1000

      path =
        wav!(dir, "three.wav", frames, 44_100, 3, fn f, c ->
          if f == 10, do: 1.5, else: c * 0.1
        end)

      assert {:ok, d} = Native.decode(path)
      assert %{rate: 44_100, channels: 2, frames: ^frames, peak_frames: 256} = d
      samples = floats(d.pcm)
      assert length(samples) == 2 * frames
      assert Enum.slice(samples, 20, 2) == [1.0, 1.0]
      assert_in_delta Enum.at(samples, 1), 0.1, 1.0e-6
      # 1000 frames: 4 peak bytes; the first block holds the clipped 1.0.
      assert <<255, p, p, p>> = d.peaks
      assert p == div(round(0.1 * 32_768) * 255 + 16_384, 32_768)
    end

    test "chunks join: a file longer than one chunk", %{dir: dir} do
      frames = 65_536 + 300

      path =
        wav!(dir, "long.wav", frames, 48_000, 1, fn f, _ ->
          if f == frames - 1, do: 0.5, else: 0.0
        end)

      assert {:ok, %{frames: ^frames, channels: 1, peaks: peaks, pcm: pcm}} = Native.decode(path)
      assert byte_size(pcm) == 4 * frames
      assert byte_size(peaks) == div(frames + 255, 256)
      assert :binary.last(peaks) == div(round(0.5 * 32_768) * 255 + 16_384, 32_768)
      assert :binary.first(peaks) == 0
    end

    test "errors: a missing file, a file that says it is over 5 minutes", %{dir: dir} do
      assert {:error, :not_found} = Native.decode(Path.join(dir, "missing.wav"))
      # 300.5 s mono at 8 kHz: refused from its stated length.
      path = Path.join(dir, "long.wav")

      File.write!(
        path,
        Wav.encode_s16(:binary.copy(<<0.0::float-32-little>>, 2_404_000), 8_000, 1)
      )

      assert {:error, :too_long} = Native.decode(path)
      refute_received {:mob_audio_io, _, _, _}
    end

    test "an empty file: :no_audio", %{dir: dir} do
      path = Path.join(dir, "empty.wav")
      File.write!(path, Wav.encode_f32(<<>>, 48_000, 1))
      assert {:error, :no_audio} = Native.decode(path)
    end
  end

  describe "load_sample/2" do
    setup do
      {:ok, _} = Native.open(owner())
      :ok
    end

    test "queues its turn before returning, decodes off the caller, hands the PCM over", %{
      dir: dir
    } do
      path = wav!(dir, "a.wav", 500, 22_050, 2, fn _, c -> c * 0.25 end)
      assert :ok = Native.load_sample("a", path)
      # Claimed (queued in order, in C) before load_sample/2 returned.
      assert_received {:fake_nif, :load_claim, ["a"]}
      assert_receive {:fake_nif, :load_ticket, [1, pcm, 22_050, 2]}
      assert byte_size(pcm) == 500 * 2 * 4
    end

    test "a file that won't decode finishes its load with the reason", %{dir: dir} do
      assert :ok = Native.load_sample("b", Path.join(dir, "nope.wav"))
      assert_receive {:fake_nif, :load_ticket_failed, [1, :not_found]}
    end

    test "a decode that crashes still finishes its load, so the loader doesn't wait for it",
         %{dir: dir} do
      path = wav!(dir, "c.wav", 300, 48_000, 1, fn _, _ -> 0.1 end)
      FakeAudioNif.answer(:load_ticket, fn _ticket, _pcm, _rate, _ch -> raise "boom" end)
      assert :ok = Native.load_sample("c", path)
      assert_receive {:fake_nif, :load_ticket_failed, [1, :decode_error]}, 2_000
    end

    test "not the owner (or no slot): answered at once, nothing decodes", %{dir: dir} do
      FakeAudioNif.answer(:load_claim, {:error, :too_many_samples})
      assert {:error, :too_many_samples} = Native.load_sample("c", Path.join(dir, "x.wav"))
      refute_receive {:fake_nif, :load_ticket_failed, _}, 100
    end
  end
end
