defmodule Magpie.EngineRecordTest do
  # The engine and its fake are one per VM: not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Magpie.Audio.Fake
  alias Magpie.Engine

  setup do
    :ok = Fake.fail_open(nil)
    :ok = Fake.fail_input(nil)
    :ok = Fake.refuse_input(nil)
    :ok = Fake.stick_input(0)
    start_supervised!({Engine, close_retry_ms: 50})
    :ok = Engine.subscribe()
    :ok
  end

  defp f32(values), do: for(v <- values, into: <<>>, do: <<v::float-32-little>>)
  defp level(frames, amp), do: f32(List.duplicate(amp, frames))

  defp open_mic! do
    {:ok, id} = Engine.open_input(:mic)
    assert_receive {:magpie_audio, :input, ^id, :started, %{source: :mic}}
    id
  end

  # Feed and wait for the meter it sends.
  defp feed!(pcm) do
    :ok = Fake.feed(pcm)
    assert_receive {:magpie_audio, :meter, _input, db, meter}
    Map.put(meter, :db, db)
  end

  # A message the native side sent late (still queued when the next input
  # or take began), straight into the Engine's mailbox.
  defp late(message) do
    send(Process.whereis(Engine), message)
    Engine.state()
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  describe "input" do
    test "opening reports the input and state/0 mirrors it until it closes" do
      assert Engine.state().input == nil
      {:ok, id} = Engine.open_input(:mic)

      assert_receive {:magpie_audio, :input, ^id, :started,
                      %{source: :mic, rate: 48_000, channels: 1} = info}

      assert Engine.state().input == Map.merge(info, %{id: id, status: :open})

      :ok = Engine.close_input()
      assert Engine.state().input == nil
      assert {:error, :no_input} = Fake.feed(level(10, 0.1))
    end

    test "every open is a new input" do
      first = open_mic!()
      second = open_mic!()
      assert second != first
      assert %{id: ^second, status: :open} = Engine.state().input
    end

    test "other apps open stereo; a refused consent and the system ending it close it" do
      :ok = Fake.fail_input(:denied)
      {:ok, refused} = Engine.open_input(:apps)
      assert_receive {:magpie_audio, :input, ^refused, :closed, :denied}
      assert Engine.state().input == nil

      {:ok, id} = Engine.open_input(:apps)
      assert_receive {:magpie_audio, :input, ^id, :started, %{source: :apps, channels: 2}}
      assert %{source: :apps, status: :open, channels: 2} = Engine.state().input

      :ok = Fake.end_input(:stopped)
      assert_receive {:magpie_audio, :input, ^id, :closed, :stopped}
      assert Engine.state().input == nil
    end

    test "only the engine controls the input and the recorder" do
      assert {:error, :not_owner} = Fake.input_open(:mic)
      open_mic!()

      opts = %{mode: :now, max_seconds: 1, threshold_db: -30, pre_roll_ms: 0}
      assert {:error, :not_owner} = Fake.record_start(opts)
      assert {:error, :not_owner} = Fake.record_stop()
      assert {:error, :not_owner} = Fake.input_close()
      assert {:error, {:invalid, :source}} = Engine.open_input(:radio)
    end

    test "the input closes when the process that opened it exits" do
      parent = self()

      opener =
        spawn(fn ->
          send(parent, {:opened, Engine.open_input(:mic)})
          Process.sleep(:infinity)
        end)

      assert_receive {:opened, {:ok, id}}
      assert_receive {:magpie_audio, :input, ^id, :started, _}
      Process.exit(opener, :kill)

      eventually(fn -> Engine.state().input == nil end)
      assert Fake.state().input == nil
    end
  end

  describe "late messages about an earlier input" do
    test "a :closed for it doesn't close the open one; its :started and meters are dropped" do
      old = open_mic!()
      new = open_mic!()

      late({:magpie_audio, :input, old, :closed, :stopped})
      late({:magpie_audio, :input, old, :started, %{source: :apps, rate: 44_100, channels: 2}})
      late({:magpie_audio, :meter, old, -3.0, %{take: nil, state: :idle, frames: 0, peaks: <<>>}})

      assert %{id: ^new, source: :mic, status: :open, rate: 48_000} = Engine.state().input
      refute_received {:magpie_audio, :input, ^old, _, _}
      refute_received {:magpie_audio, :meter, ^old, _, _}
      # Still open: the late :closed didn't release it.
      assert %{state: :idle} = feed!(level(10, 0.1))
    end
  end

  describe "a close that fails" do
    @tag :capture_log
    test "the system closing a stuck mic: closed to subscribers, closed again until released" do
      id = open_mic!()
      :ok = Fake.stick_input(2)
      :ok = Fake.end_input(:disconnected)

      assert_receive {:magpie_audio, :input, ^id, :closed, :disconnected}
      eventually(fn -> Fake.state().stuck == 0 end)
      eventually(fn -> Engine.state().input == nil end)
    end

    test "close_input/0 answers the error and the Engine keeps closing it" do
      open_mic!()
      :ok = Fake.stick_input(1)

      log =
        capture_log(fn ->
          assert {:error, :input_stuck} = Engine.close_input()
          assert %{status: :closing} = Engine.state().input
          eventually(fn -> Engine.state().input == nil end)
        end)

      assert log =~ "the input wouldn't close"
      assert Fake.state().stuck == 0
    end

    @tag :capture_log
    test "the opener exiting with the mic stuck: closed again until released" do
      parent = self()

      opener =
        spawn(fn ->
          send(parent, {:opened, Engine.open_input(:mic)})
          Process.sleep(:infinity)
        end)

      assert_receive {:opened, {:ok, _id}}
      :ok = Fake.stick_input(1)
      Process.exit(opener, :kill)

      eventually(fn -> Fake.state().stuck == 0 and Engine.state().input == nil end)
    end
  end

  describe "a source that fails to open" do
    test "the old input was closed first: no input on either side" do
      old = open_mic!()
      :ok = Fake.refuse_input(:unsupported)

      assert {:error, :unsupported} = Engine.open_input(:apps)
      assert Engine.state().input == nil
      assert Fake.state().input == nil
      assert {:error, :no_input} = Engine.record()

      # The old input's monitor went with it: a late :closed for it is dropped.
      late({:magpie_audio, :input, old, :closed, :stopped})
      refute_received {:magpie_audio, :input, _, _, _}
    end

    @tag :capture_log
    test "the old mic wouldn't stop: closing, then released" do
      old = open_mic!()
      :ok = Fake.stick_input(1)

      assert {:error, :input_stuck} = Engine.open_input(:apps)
      assert %{id: ^old, status: :closing} = Engine.state().input
      eventually(fn -> Engine.state().input == nil end)

      assert {:ok, _} = Engine.open_input(:apps)
    end
  end

  describe "meters" do
    test "each feed is one meter: the peak in dBFS, nothing recorded while idle" do
      id = open_mic!()

      :ok = Fake.feed(level(480, 0.5))
      assert_receive {:magpie_audio, :meter, ^id, db, %{take: nil, state: :idle, frames: 0}}
      assert_in_delta db, -6.02, 0.01
      assert %{db: -120.0} = feed!(level(480, 0.0))
    end
  end

  describe "record :now" do
    test "records from the next frame; peaks per 256 frames, the last part flushed on stop" do
      open_mic!()
      assert {:ok, take} = Engine.record()
      assert_receive {:magpie_audio, :record, ^take, :started, %{pre_roll_frames: 0}}

      pcm = level(1000, 0.5)
      assert %{take: ^take, state: :recording, frames: 1000, peaks: peaks} = feed!(pcm)
      assert peaks == <<128, 128, 128>>

      assert {:ok, rec} = Engine.stop_recording()
      assert %{pcm: ^pcm, rate: 48_000, channels: 1, frames: 1000, peak_frames: 256} = rec
      assert rec.peaks == <<128, 128, 128, 128>>
    end

    test "other apps record stereo frames" do
      {:ok, id} = Engine.open_input(:apps)
      assert_receive {:magpie_audio, :input, ^id, :started, _}
      {:ok, _take} = Engine.record()

      pcm = f32(List.duplicate([0.25, -0.5], 300) |> List.flatten())
      assert %{frames: 300} = feed!(pcm)
      assert {:ok, %{channels: 2, frames: 300, pcm: ^pcm}} = Engine.stop_recording()
    end
  end

  describe "late messages about an earlier take" do
    test "its :full, :started and count-in are dropped; the next take goes on" do
      open_mic!()
      {:ok, old} = Engine.record(max_seconds: 1)
      assert_receive {:magpie_audio, :record, ^old, :started, _}
      assert %{state: :full} = feed!(level(48_000, 0.2))
      assert_receive {:magpie_audio, :record, ^old, :full, 48_000}
      {:ok, _} = Engine.stop_recording()

      {:ok, new} = Engine.record(mode: :on_sound, threshold_db: -20)
      assert new != old

      late({:magpie_audio, :record, old, :full, 48_000})
      late({:magpie_audio, :record, old, :started, %{pre_roll_frames: 0, late_frames: 0}})
      late({:magpie_audio, :count_in, old, 0, 96_000})
      refute_received {:magpie_audio, :record, ^old, _, _}
      refute_received {:magpie_audio, :count_in, ^old, _, _}

      assert %{take: ^new, state: :recording} = feed!(level(100, 0.5))
      assert_received {:magpie_audio, :record, ^new, :started, _}
      assert {:ok, %{frames: 100}} = Engine.stop_recording()
    end

    test "once stopped or cancelled, its own late messages are dropped too" do
      open_mic!()
      {:ok, take} = Engine.record()
      assert_receive {:magpie_audio, :record, ^take, :started, _}
      :ok = Engine.cancel_recording()

      late({:magpie_audio, :record, take, :full, 10})
      refute_received {:magpie_audio, :record, ^take, :full, _}
    end
  end

  describe "record :on_sound" do
    test "starts at the first frame at the threshold, keeping the pre-roll before it" do
      open_mic!()
      # -20 dB is 0.1; 10 ms of pre-roll is 480 frames.
      {:ok, take} = Engine.record(mode: :on_sound, threshold_db: -20, pre_roll_ms: 10)

      assert %{state: :waiting, frames: 0} = feed!(level(1000, 0.099))
      refute_received {:magpie_audio, :record, _, :started, _}

      quiet = level(200, 0.05)
      loud = level(300, 0.1)
      assert %{state: :recording, frames: 780} = feed!(quiet <> loud)
      assert_received {:magpie_audio, :record, ^take, :started, %{pre_roll_frames: 480}}

      {:ok, rec} = Engine.stop_recording()
      assert rec.pcm == level(280, 0.099) <> quiet <> loud
    end

    test "the pre-roll holds only what was fed since arming" do
      open_mic!()
      feed!(level(5000, 0.01))
      {:ok, _} = Engine.record(mode: :on_sound, threshold_db: -20, pre_roll_ms: 150)

      feed!(level(100, 0.01) <> level(10, 0.5))
      assert_received {:magpie_audio, :record, _, :started, %{pre_roll_frames: 100}}
      assert {:ok, %{frames: 110}} = Engine.stop_recording()
    end

    test "stopping before any sound: not started, and disarmed" do
      open_mic!()
      {:ok, _} = Engine.record(mode: :on_sound)
      feed!(level(480, 0.001))

      assert {:error, :not_started} = Engine.stop_recording()
      assert {:error, :not_recording} = Engine.stop_recording()
    end
  end

  describe "record :count_in" do
    test "one bar of clicks from the current frame, recording from the downbeat" do
      open_mic!()
      {:ok, take} = Engine.record(mode: :count_in, pre_roll_ms: 500)

      # One bar of 4/4 at the fake's 120 bpm: 2 s at 48 kHz.
      assert_receive {:magpie_audio, :count_in, ^take, first, until}
      assert until - first == 96_000
      assert %{state: :counting, frames: 0} = feed!(level(2000, 0.5))

      :ok = Fake.downbeat()
      assert_receive {:magpie_audio, :record, ^take, :started, %{pre_roll_frames: 0}}
      assert %{state: :recording, frames: 500} = feed!(level(500, 0.5))
    end

    @tag :capture_log
    test "needs the output stream" do
      stop_supervised!(Engine)
      :ok = Fake.fail_open(:output_unavailable)
      start_supervised!(Engine)
      :ok = Engine.subscribe()
      open_mic!()

      assert {:error, :not_running} = Engine.record(mode: :count_in)
      assert {:ok, _} = Engine.record(mode: :now)
    end
  end

  describe "length and errors" do
    test "at max_seconds it is full: no more audio, stop returns exactly the limit" do
      open_mic!()
      {:ok, take} = Engine.record(max_seconds: 1)

      assert %{state: :full, frames: 48_000} = feed!(level(50_000, 0.2))
      assert_received {:magpie_audio, :record, ^take, :full, 48_000}
      assert %{state: :full, frames: 48_000, peaks: <<>>} = feed!(level(1000, 0.2))

      assert {:ok, rec} = Engine.stop_recording()
      assert rec.frames == 48_000
      assert byte_size(rec.pcm) == 48_000 * 4
      assert byte_size(rec.peaks) == div(48_000 + 255, 256)
    end

    test "recording needs an input, arms once, and cancel drops it" do
      assert {:error, :no_input} = Engine.record()
      assert {:error, :not_recording} = Engine.stop_recording()

      open_mic!()
      {:ok, _} = Engine.record()
      assert {:error, :recording} = Engine.record()
      feed!(level(100, 0.3))

      assert :ok = Engine.cancel_recording()
      assert {:error, :not_recording} = Engine.stop_recording()
    end

    test "closing the input drops the recording" do
      open_mic!()
      {:ok, _} = Engine.record()
      feed!(level(100, 0.3))
      :ok = Engine.close_input()

      assert {:error, :not_recording} = Engine.stop_recording()
    end

    test "bad options are refused before reaching the engine" do
      open_mic!()

      for {opts, field} <- [
            {[mode: :later], :mode},
            {[max_seconds: 0], :max_seconds},
            {[max_seconds: 301], :max_seconds},
            {[threshold_db: 1], :threshold_db},
            {[threshold_db: -91], :threshold_db},
            {[pre_roll_ms: -1], :pre_roll_ms},
            {[pre_roll_ms: 501], :pre_roll_ms},
            {[gain: 2], :gain}
          ] do
        assert Engine.record(opts) == {:error, {:invalid, field}}, inspect(opts)
      end

      assert Fake.state().rec == nil
      assert {:ok, _} = Engine.record(max_seconds: 300, threshold_db: -90, pre_roll_ms: 500)
    end
  end
end
