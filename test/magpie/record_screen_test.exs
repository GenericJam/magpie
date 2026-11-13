defmodule Magpie.RecordScreenTest do
  # The engine, its fake and the sample directory are one per VM: not async.
  use Mob.ScreenCase, async: false

  import ExUnit.CaptureLog
  import Magpie.Test.Screens

  alias Magpie.Audio.Fake
  alias Magpie.{Bird, Engine, Library, RecordScreen, Style, Wav}
  alias Magpie.Test.Aiff
  alias Magpie.Test.Repo, as: TestRepo

  @tmp_root Path.join(System.tmp_dir!(), "magpie_record_screen_test")

  setup do
    :ok = Fake.fail_open(nil)
    :ok = Fake.fail_input(nil)
    :ok = Fake.refuse_input(nil)
    :ok = Fake.stick_input(0)
    start_supervised!({Engine, close_retry_ms: 50})
    TestRepo.start()

    dir = Path.join(@tmp_root, Integer.to_string(System.unique_integer([:positive])))
    Application.put_env(:magpie, :library_dir, Path.join(dir, "samples"))
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.delete_env(:magpie, :library_dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp level(frames, amp), do: for(_ <- 1..frames, into: <<>>, do: <<amp::float-32-little>>)

  defp mounted, do: RecordScreen |> mount_screen() |> pump()

  defp feed(view, pcm) do
    :ok = Fake.feed(pcm)
    pump(view)
  end

  defp press(view, tag), do: render_info(view, {:tap, tag})

  defp chip(view), do: view |> canvas_texts("wave") |> hd()

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  # The magpie on the card in `mood` (top-right, size 0.75).
  defp bird?(view, mood) do
    ops = canvas_ops(view, "wave")
    Enum.all?(Bird.ops(mood, x: 496 - 60, y: 8, size: 0.75, trinket: :coral), &(&1 in ops))
  end

  defp coral_bars(view) do
    coral = Style.color(:pad_coral)
    # Bars are the coral rects with rounded corners (the playhead has none).
    for %{op: :rect, color: ^coral, radius: 1} = op <- canvas_ops(view, "wave"), do: op
  end

  defp lit_segments(view) do
    off = Style.color(:line_soft)
    for %{op: :rect, h: 10, color: c} <- canvas_ops(view, "meter"), c != off, do: c
  end

  describe "the screen" do
    test "renders; every tap target is held" do
      view = mounted()
      assert_renderable(view)
      assert assert_every_tap_held(view) >= 7
      assert "Record a sample" in texts(view)
      assert "pairing comes later" in texts(view)
    end

    test "the mic granted: the input opens, the magpie listens, READY" do
      view = mounted()
      assert %{source: :mic, status: :open} = Engine.state().input
      assert chip(view) == "READY"
      assert bird?(view, :listen)
      assert "● Record" in texts(view)
    end

    test "the mic denied: no input, the greyed magpie and Try again" do
      view = mounted() |> render_info({:permission, :microphone, :denied})

      assert Engine.state().input == nil
      assert "Magpie needs the microphone to record." in texts(view)
      assert bird?(view, :nomic)
      assert_every_tap_held(view)

      view = view |> press(:try_again) |> pump()
      assert %{source: :mic, status: :open} = Engine.state().input
      assert chip(view) == "READY"
    end

    test "back cancels and closes the input" do
      view = mounted() |> press(:record)
      view = feed(view, level(480, 0.3)) |> press(:back)

      assert Engine.state().input == nil
      assert {:error, :not_recording} = Engine.stop_recording()
      assert navigated_to(view) == {:pop}
    end
  end

  describe "meters" do
    test "the level moves the meter; recording grows the bars and the clock" do
      view = mounted() |> feed(level(480, 0.5))
      assert "−6 dB" in texts(view)
      # -6 dB lights segments 0..26 (lit when level >= -60 + 2i).
      assert Enum.count(lit_segments(view)) == 27
      assert coral_bars(view) == []

      view = feed(view, level(480, 0.0))
      assert "−∞ dB" in texts(view)
      assert lit_segments(view) == []

      view = view |> press(:record) |> pump() |> feed(level(24_000, 0.5))
      assert chip(view) == "● REC 0:00.5"
      # 0.5 s of a 6 s window: 94 peaks of 1125, about 10 of 120 bars.
      assert length(coral_bars(view)) in 9..11
      assert "■ Stop" in texts(view)
      assert bird?(view, :listen)
    end

    test "When sound starts: the threshold sits 12 dB over the room" do
      # The room at -40 dB: the threshold is -28 dB.
      view = mounted() |> feed(level(480, 0.01)) |> press({:mode, :on_sound})
      view = view |> press(:record) |> pump()
      assert chip(view) == "WAITING FOR SOUND"

      # -30 dB stays under it; -20 dB starts the recording.
      view = feed(view, level(480, 0.0316))
      assert chip(view) == "WAITING FOR SOUND"
      view = feed(view, level(480, 0.1))
      assert "● REC" <> _ = chip(view)
    end

    test "the threshold is clamped to -48..-12 dB" do
      assert RecordScreen.threshold([]) == -30
      assert RecordScreen.threshold([-70.0, -90.0]) == -48
      assert RecordScreen.threshold([-3.0]) == -12
      assert RecordScreen.threshold([-50.0, -38.4, -60.0]) == -26
    end

    test "Count in shows the beat and records from the downbeat" do
      view = mounted() |> press({:mode, :count_in}) |> press(:record) |> pump()
      assert chip(view) == "COUNT-IN 1"

      :ok = Fake.downbeat()
      view = feed(view, level(4800, 0.3))
      assert chip(view) == "● REC 0:00.1"
    end

    test "stopping before any sound goes back to monitoring" do
      view = mounted() |> press({:mode, :on_sound}) |> press(:record) |> pump()
      view = view |> press(:record) |> render_async()

      assert chip(view) == "READY"
      assert Library.list() == []
    end
  end

  describe "saving" do
    test "Stop saves the take as a recorded sample, and the magpie grabs it" do
      view = mounted() |> press(:record) |> pump() |> feed(level(48_000, 0.25))
      view = view |> press(:record) |> render_async()

      assert [sample] = Library.list()
      assert sample.name =~ ~r/^Mic \d\d:\d\d$/
      assert %{source: :recorded, frames: 48_000, rate: 48_000, channels: 1} = sample
      assert byte_size(sample.peaks) == div(48_000 + 255, 256)
      assert chip(view) == "SAVED 1.0 s"
      assert bird?(view, :grab)
      # The whole sample fills the card.
      assert Enum.count(coral_bars(view)) == 120
    end

    test "recording into a pad names it and hands the saved sample back" do
      view = RecordScreen |> mount_screen(%{pad: 14, reply_to: self()}) |> pump()
      assert "Record into pad A15" in texts(view)

      view = view |> press(:record) |> pump() |> feed(level(4800, 0.25))
      _view = view |> press(:record) |> render_async()

      assert [sample] = Library.list()
      assert_received {:recorded, 14, ^sample}
    end

    test "reaching the length limit saves on its own, with a notice" do
      view = mounted() |> press(:record) |> pump() |> feed(level(4800, 0.25))
      take = Fake.state().rec.take
      view = view |> render_info({:magpie_audio, :record, take, :full, 4800}) |> render_async()

      assert [%{frames: 4800, source: :recorded}] = Library.list()
      assert "Stopped at the 60 s limit" in texts(view)
      assert chip(view) == "SAVED 0.1 s"
    end

    test "other apps: a refused consent goes back to the mic with a notice" do
      view = mounted()
      :ok = Fake.fail_input(:denied)
      view = view |> press({:source, :apps}) |> pump()

      assert %{source: :mic, status: :open} = Engine.state().input
      assert "Other apps weren't shared; back to the microphone." in texts(view)
      assert chip(view) == "READY"
    end

    test "other apps record under their own name" do
      view = mounted() |> press({:source, :apps}) |> pump()
      assert %{source: :apps, channels: 2} = Engine.state().input

      view = view |> press(:record) |> pump() |> feed(level(960, 0.2))
      view |> press(:record) |> render_async()
      assert [%{name: "Other apps " <> _, channels: 2, frames: 480}] = Library.list()
    end
  end

  describe "late messages and failed inputs" do
    test "a :full from an earlier take doesn't stop the next one" do
      view = mounted() |> press(:record) |> pump() |> feed(level(4800, 0.25))
      old = Fake.state().rec.take
      view = view |> press(:record) |> render_async()
      assert chip(view) == "SAVED 0.1 s"

      view = view |> press(:record) |> pump() |> feed(level(4800, 0.25))
      view = render_info(view, {:magpie_audio, :record, old, :full, 4800})

      assert chip(view) == "● REC 0:00.1"
      assert "■ Stop" in texts(view)
      assert [_first] = Library.list()
    end

    test "an earlier take's meter doesn't draw into the next" do
      view = mounted() |> press(:record) |> pump() |> feed(level(4800, 0.25))
      old = Fake.state().rec.take
      view = view |> press(:record) |> render_async() |> press(:record) |> pump()

      meter = %{take: old, state: :recording, frames: 96_000, peaks: :binary.copy(<<255>>, 375)}
      view = render_info(view, {:magpie_audio, :meter, Engine.state().input.id, -6.0, meter})

      assert coral_bars(view) == []
      assert chip(view) == "● REC 0:00.0"
    end

    test "a late :closed for the mic doesn't close other apps opened after it" do
      view = mounted()
      mic = Engine.state().input.id
      view = view |> press({:source, :apps}) |> pump()

      view = render_info(view, {:magpie_audio, :input, mic, :closed, :disconnected})
      assert chip(view) == "READY"
      assert %{source: :apps, status: :open} = Engine.state().input

      view = view |> press(:record) |> pump() |> feed(level(960, 0.2))
      view |> press(:record) |> render_async()
      assert [%{channels: 2}] = Library.list()
    end

    test "other apps failing to open: the mic was closed for it, so back to the mic" do
      view = mounted()
      :ok = Fake.refuse_input(:unsupported)
      view = view |> press({:source, :apps}) |> pump()

      assert %{source: :mic, status: :open} = Engine.state().input
      assert "Couldn't open other apps (unsupported); back to the microphone." in texts(view)
      assert chip(view) == "READY"
    end

    test "the mic failing to open after other apps: no input on either side" do
      view = mounted() |> press({:source, :apps}) |> pump()
      :ok = Fake.refuse_input(:input_unavailable)
      view = view |> press({:source, :mic}) |> pump()

      assert Engine.state().input == nil
      assert chip(view) == "NO INPUT"
      assert "Couldn't open the microphone (input_unavailable)." in texts(view)
    end

    test "leaving with a mic that won't close: logged, and the Engine closes it later" do
      view = mounted()
      :ok = Fake.stick_input(1)

      log = capture_log(fn -> assert navigated_to(press(view, :back)) == {:pop} end)
      assert log =~ "the input didn't close (:input_stuck)"
      assert %{status: :closing} = Engine.state().input

      eventually(fn -> Engine.state().input == nil end)
      assert Fake.state().stuck == 0
    end
  end

  describe "import" do
    defp pick(view, path, name),
      do:
        view
        |> press({:source, :file})
        |> render_info({:files, :picked, [%{path: path, name: name, mime: "audio/x-wav"}]})
        |> render_async()

    test "a WAV lands in the library as imported", %{dir: dir} do
      path = Path.join(dir, "Snare.wav")
      File.write!(path, Wav.encode_s16(level(2400, 0.5), 48_000, 1))

      view = pick(mounted(), path, "Snare.wav")
      assert [%{name: "Snare", source: :imported, frames: 2400}] = Library.list()
      assert chip(view) == "SAVED 0.1 s"
      assert bird?(view, :grab)
    end

    test "an AIFF goes through Magpie.Aiff", %{dir: dir} do
      path = Path.join(dir, "Clap.aiff")
      File.write!(path, Aiff.encode(List.duplicate(0.25, 2 * 4410), 44_100, 2))

      pick(mounted(), path, "Clap.aiff")

      assert [%{name: "Clap", source: :imported, rate: 44_100, channels: 2, frames: 4410}] =
               Library.list()

      assert Path.wildcard(Path.join(System.tmp_dir!(), "magpie-import-*")) == []
    end

    test "a file it can't read shows why", %{dir: dir} do
      path = Path.join(dir, "notes.wav")
      File.write!(path, "not audio")

      view = pick(mounted(), path, "notes.wav")
      assert Library.list() == []
      assert "Couldn't import notes.wav: unsupported" in texts(view)
      assert chip(view) == "READY"
    end
  end
end
