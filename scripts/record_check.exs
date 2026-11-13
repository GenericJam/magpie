# Checks recording on a connected Android phone over Erlang distribution:
# the mic stream, the meters, a recording made while the sequencer plays
# (callback timing and underruns with and without the mic, the clicks'
# spacing in what was recorded), the count-in's downbeat against what the
# mic heard, "when sound starts" with its pre-roll, the length limit,
# playing a take back through a pad, other apps (with OTHER_APPS=1) and
# importing (wav, mp3, aiff).
#
#   mix mob.deploy --native --android --device <serial>
#   mix mob.connect --no-iex --android-only --device <serial>
#   adb -s <serial> shell pm grant com.genericjam.magpie android.permission.RECORD_AUDIO
#   SERIAL=<serial> mix run --no-start scripts/record_check.exs
#
# The phone's speaker plays clicks the mic records (volume about half, no
# headphones, a quiet room). Needs ffmpeg on the Mac. With OTHER_APPS=1 it
# also serves a tone over `adb reverse`, opens it in Chrome, answers the
# capture consent dialog with a tap, and records what Chrome plays.

serial = System.fetch_env!("SERIAL")
app = "com.genericjam.magpie"
files = "/data/data/#{app}/files/record_check"

node =
  String.to_atom(System.get_env("NODE", "magpie_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"record_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

rpc = fn m, f, a ->
  case :rpc.call(node, m, f, a, 300_000) do
    {:badrpc, reason} -> raise "rpc #{inspect(m)}.#{f} failed: #{inspect(reason)}"
    value -> value
  end
end

adb = fn args ->
  {out, _} = System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true)
  out
end

fmt = fn
  x when is_float(x) -> :erlang.float_to_binary(x, decimals: 2)
  x -> inspect(x)
end

# ── Test sounds ──────────────────────────────────────────────────────────────

tmp = Path.join(System.tmp_dir!(), "magpie_record_check")
File.mkdir_p!(tmp)

ffmpeg = fn args ->
  {_, 0} = System.cmd("ffmpeg", ["-v", "error", "-y" | args], stderr_to_stdout: true)
end

# A click: 20 ms of 2 kHz, fading out.
ffmpeg.(~w(-f lavfi -i sine=frequency=2000:duration=0.02:sample_rate=48000 -af afade=t=out:st=0.005:d=0.015,volume=0.9 -ac 1 #{tmp}/click.wav))
# Two seconds of a stereo chord to import, as wav, mp3 and aiff.
ffmpeg.(~w(-f lavfi -i sine=frequency=220:duration=2:sample_rate=44100 -f lavfi -i sine=frequency=331:duration=2:sample_rate=44100 -filter_complex [0][1]amerge=inputs=2,volume=0.4 #{tmp}/chord.wav))
ffmpeg.(~w(-i #{tmp}/chord.wav -c:a libmp3lame -b:a 192k #{tmp}/chord.mp3))
ffmpeg.(~w(-i #{tmp}/chord.wav -c:a pcm_s16be #{tmp}/chord.aiff))

adb.(["shell", "run-as", app, "mkdir", "-p", files])

for name <- ~w(click.wav chord.wav chord.mp3 chord.aiff) do
  adb.(["push", "#{tmp}/#{name}", "/data/local/tmp/#{name}"])
  adb.(["shell", "run-as", app, "cp", "/data/local/tmp/#{name}", "#{files}/#{name}"])
  adb.(["shell", "rm", "/data/local/tmp/#{name}"])
end

# ── On the phone: one process per scenario owns the input ─────────────────────

phone = """
defmodule MagpieRecordCheck do
  alias Magpie.Engine
  alias Magpie.Kit.{Pad, Pattern, Region, Step}

  def setup(click) do
    {:ok, _} = Engine.load_sample("rc_click", click)
    :ok = Engine.set_pad(0, %Pad{slot: 0, sample: %Region{id: "rc_click"}})
    lanes = %{0 => %{mute: false, steps: for(s <- [0, 4, 8, 12], do: %Step{step: s, vel: 110})}}
    :ok = Engine.set_pattern(%Pattern{id: "rc", bank: "A", length: 16, lanes: lanes}, at: :now)
    :ok = Engine.set_tempo(120)
  end

  defp open(source) do
    :ok = Engine.subscribe()
    :ok = Engine.open_input(source)
    receive do
      {:magpie_audio, :input, :started, info} -> info
      {:magpie_audio, :input, :closed, reason} -> raise "input closed: \#{inspect(reason)}"
    after
      60_000 -> raise "no input"
    end
  end

  defp close do
    Engine.close_input()
    Engine.unsubscribe()
    flush()
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  # The meters (and anything else) for `ms`.
  defp collect(ms, acc \\\\ []) do
    deadline = System.monotonic_time(:millisecond) + ms
    collect_until(deadline, acc)
  end

  defp collect_until(deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)
    receive do
      msg -> collect_until(deadline, [{System.monotonic_time(:millisecond), msg} | acc])
    after
      max(left, 0) -> Enum.reverse(acc)
    end
  end

  defp await(pattern_fun, ms) do
    receive do
      msg -> if pattern_fun.(msg), do: msg, else: await(pattern_fun, ms)
    after
      ms -> :timeout
    end
  end

  defp window(ms) do
    Magpie.Audio.Native.reset_stats()
    before = Engine.info()
    Process.sleep(ms)
    after_ = Engine.info()
    %{
      underruns: after_.underruns - before.underruns,
      callback_mean_us: after_.callback_mean_us,
      callback_max_us: after_.callback_max_us,
      callback_gap_max_us: after_.callback_gap_max_us,
      cpu_load: after_.cpu_load,
      dropped: after_.dropped
    }
  end

  # The sequencer plays a click on every beat; 5 s without the mic, 5 s
  # with it recording; the take comes back with its meters.
  def mic_while_playing do
    :ok = Engine.play()
    Process.sleep(1000)
    quiet = window(5000)
    info = open(:mic)
    meters = collect(1000)
    :ok = Engine.record(mode: :now, max_seconds: 30)
    recording = window(5000)
    input = Engine.info().input
    {:ok, rec} = Engine.stop_recording()
    :ok = Engine.stop()
    close()
    %{info: info, quiet: quiet, recording: recording, input: input, rec: rec, idle_meters: meters}
  end

  # Count-in while playing: the take should start on the downbeat.
  def count_in(play?) do
    if play?, do: :ok = Engine.play()
    if play?, do: Process.sleep(700)
    open(:mic)
    t0 = System.monotonic_time(:millisecond)
    :ok = Engine.record(mode: :count_in, max_seconds: 30)
    {:magpie_audio, :count_in, first, until} = await(&match?({:magpie_audio, :count_in, _, _}, &1), 5000)
    clock = Engine.clock()
    started = await(&match?({:magpie_audio, :record, :started, _}, &1), 10_000)
    t_started = System.monotonic_time(:millisecond) - t0
    Process.sleep(2500)
    {:ok, rec} = Engine.stop_recording()
    if play?, do: :ok = Engine.stop()
    close()
    heard = Magpie.Audio.frame_time(clock, until)
    %{first: first, until: until, started: started, started_after_ms: t_started,
      downbeat_from_now_ms: (heard - System.monotonic_time(:nanosecond)) / 1.0e6, rec: rec}
  end

  # When sound starts: a click 1.5 s after arming.
  def on_sound(threshold_db) do
    open(:mic)
    ambient = collect(1000) |> Enum.flat_map(fn {_, {:magpie_audio, :meter, db, _}} -> [db]; _ -> [] end)
    threshold = (Enum.max(ambient, fn -> -60.0 end) + 12) |> max(-48.0) |> min(-12.0)
    threshold = threshold_db || threshold
    :ok = Engine.record(mode: :on_sound, threshold_db: threshold, pre_roll_ms: 150)
    Process.sleep(1500)
    waiting = Engine.info().input.recorder
    Engine.trigger(0, 127)
    started = await(&match?({:magpie_audio, :record, :started, _}, &1), 5000)
    Process.sleep(1000)
    {:ok, rec} = Engine.stop_recording()
    close()
    %{ambient_max: Enum.max(ambient, fn -> nil end), threshold: threshold, waiting: waiting, started: started, rec: rec}
  end

  def full do
    open(:mic)
    :ok = Engine.record(mode: :now, max_seconds: 2)
    full = await(&match?({:magpie_audio, :record, :full, _}, &1), 5000)
    {:ok, rec} = Engine.stop_recording()
    close()
    %{full: full, frames: rec.frames, rate: rec.rate}
  end

  def play_back(rec) do
    :ok = Engine.subscribe()
    {:ok, loaded} = Engine.load_pcm("rc_take", rec.pcm, rec.rate, rec.channels)
    :ok = Engine.set_pad(1, %Pad{slot: 1, sample: %Region{id: "rc_take"}})
    :ok = Engine.trigger(1, 120)
    voice = await(&match?({:magpie_audio, :voice, 1, :start}, &1), 2000)
    Engine.unsubscribe()
    flush()
    %{loaded: Map.drop(loaded, [:peaks]), voice: voice}
  end

  def apps(seconds) do
    info = open(:apps)
    meters = collect(1000)
    :ok = Engine.record(mode: :now, max_seconds: 30)
    Process.sleep(seconds * 1000)
    {:ok, rec} = Engine.stop_recording()
    close()
    %{info: info, meters: meters, rec: rec}
  end

  def import(path, name) do
    decode = Engine.decode(path)
    result = Magpie.Import.import(path, name)
    with {:ok, sample} <- result, do: Magpie.Library.delete(sample.id)
    %{decode: (case decode do {:ok, d} -> {:ok, Map.drop(d, [:pcm, :peaks])}; e -> e end),
      import: (case result do {:ok, s} -> {:ok, Map.take(s, [:source, :rate, :channels, :frames, :name])}; e -> e end)}
  end
end
"""

_ = rpc.(Code, :compile_string, [phone])
# Ecto's debug queries would bury the report.
:ok = rpc.(Logger, :configure, [[level: :info]])

# ── Analysis on the Mac ──────────────────────────────────────────────────────

# |x| per frame (largest over the channels).
levels = fn rec ->
  ch = rec.channels
  samples = for <<x::float-32-little <- rec.pcm>>, do: abs(x)
  samples |> Enum.chunk_every(ch) |> Enum.map(&Enum.max/1) |> List.to_tuple()
end

# Where sound starts after at least `quiet` frames under the threshold
# (a third of the take's peak).
onsets = fn lv, quiet ->
  n = tuple_size(lv)
  peak = Enum.max(Tuple.to_list(lv), fn -> 0.0 end)
  thr = peak / 3

  {list, _} =
    Enum.reduce(0..(n - 1)//1, {[], quiet}, fn i, {acc, q} ->
      if elem(lv, i) >= thr,
        do: {if(q >= quiet, do: [i | acc], else: acc), 0},
        else: {acc, q + 1}
    end)

  {Enum.reverse(list), peak}
end

db = fn x -> if x > 0, do: 20 * :math.log10(x), else: -120.0 end

IO.puts("== Setup")
:ok = rpc.(MagpieRecordCheck, :setup, ["#{files}/click.wav"])
info = rpc.(Magpie.Engine, :info, [])
rate = info.rate
IO.puts("  output #{rate} Hz, burst #{info.burst}, buffer #{info.buffer_frames}")

IO.puts("\n== The mic, recording while the sequencer plays a click on every beat (120 bpm)")
m = rpc.(MagpieRecordCheck, :mic_while_playing, [])
IO.puts("  input #{inspect(m.info)}, #{inspect(m.input)}")

meter_times = for {t, {:magpie_audio, :meter, _, _}} <- m.idle_meters, do: t
gaps = meter_times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
IO.puts("  meters: #{length(meter_times)} in 1 s, gaps #{inspect(Enum.min_max(gaps, fn -> nil end))} ms")

for {label, w} <- [{"playing, no mic", m.quiet}, {"playing + mic recording", m.recording}] do
  IO.puts(
    "  #{label}: underruns #{w.underruns}, callback mean #{fmt.(w.callback_mean_us)} µs, max #{fmt.(w.callback_max_us)} µs, " <>
      "gap max #{fmt.(w.callback_gap_max_us)} µs, cpu #{fmt.(w.cpu_load * 100)} %, dropped #{inspect(w.dropped)}"
  )
end

rec = m.rec
lv = levels.(rec)
{at, peak} = onsets.(lv, div(rate, 4))
spacing = at |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
beat = div(rate * 60, 120)

IO.puts(
  "  take: #{rec.frames} frames (#{fmt.(rec.frames / rec.rate)} s) × #{rec.channels} at #{rec.rate} Hz, peak #{fmt.(db.(peak))} dBFS, " <>
    "#{byte_size(rec.peaks)} peak bytes; #{length(at)} clicks heard, spacing − #{beat}: #{inspect(Enum.map(spacing, &(&1 - beat)))} frames"
)

IO.puts("\n== Playing the take through a pad (load_pcm, set_pad, trigger)")
IO.puts("  #{inspect(rpc.(MagpieRecordCheck, :play_back, [rec]))}")

IO.puts("\n== Count-in while playing (120 bpm): the take starts on the downbeat")

for run <- 1..3 do
  c = rpc.(MagpieRecordCheck, :count_in, [true])
  lv = levels.(c.rec)
  {at, peak} = onsets.(lv, div(rate, 4))
  first = List.first(at)

  IO.puts(
    "  run #{run}: clicks from #{c.first}, downbeat #{c.until} (#{fmt.((c.until - c.first) / rate)} s later), started #{inspect(c.started)} " <>
      "#{c.started_after_ms} ms after record/1; first click in the take at frame #{inspect(first)} " <>
      "(#{if first, do: fmt.(first * 1000 / rate), else: "-"} ms), then #{inspect(at |> Enum.take(4))}, peak #{fmt.(db.(peak))} dBFS"
  )
end

IO.puts("\n== Count-in stopped (the clicks alone)")
c = rpc.(MagpieRecordCheck, :count_in, [false])
lv = levels.(c.rec)
{at, peak} = onsets.(lv, div(rate, 10))

IO.puts(
  "  clicks from #{c.first} to the downbeat #{c.until} (#{fmt.((c.until - c.first) / rate)} s = 4 beats at 120), started #{inspect(c.started)}; " <>
    "sounds in the take: #{inspect(Enum.take(at, 4))}, peak #{fmt.(db.(peak))} dBFS"
)

IO.puts("\n== When sound starts (a click 1.5 s after arming, 150 ms pre-roll)")
s = rpc.(MagpieRecordCheck, :on_sound, [nil])
lv = levels.(s.rec)
{at, peak} = onsets.(lv, div(rate, 20))

IO.puts(
  "  ambient max #{fmt.(s.ambient_max)} dBFS, threshold #{fmt.(s.threshold)} dBFS, recorder #{s.waiting} while quiet; started #{inspect(s.started)}; " <>
    "the click's onset in the take at frame #{inspect(List.first(at))} (#{if at != [], do: fmt.(hd(at) * 1000 / rate), else: "-"} ms), peak #{fmt.(db.(peak))} dBFS"
)

IO.puts("\n== The length limit (2 s)")
f = rpc.(MagpieRecordCheck, :full, [])
IO.puts("  #{inspect(f.full)}, the take #{f.frames} frames = #{fmt.(f.frames / f.rate)} s")

IO.puts("\n== Import")

for name <- ~w(chord.wav chord.mp3 chord.aiff) do
  IO.puts("  #{name}: #{inspect(rpc.(MagpieRecordCheck, :import, ["#{files}/#{name}", name]))}")
end

if System.get_env("OTHER_APPS") == "1" do
  IO.puts("\n== Other apps (Chrome playing a 440 Hz tone)")
  ffmpeg.(~w(-f lavfi -i sine=frequency=440:duration=30:sample_rate=48000 -af volume=0.5 -c:a libmp3lame -b:a 128k #{tmp}/tone.mp3))
  port = 8765
  server = Port.open({:spawn_executable, System.find_executable("python3")}, [:binary, args: ["-m", "http.server", "#{port}", "--directory", tmp]])
  adb.(["reverse", "tcp:#{port}", "tcp:#{port}"])
  Process.sleep(500)
  adb.(["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "http://127.0.0.1:#{port}/tone.mp3", "com.android.chrome"])
  Process.sleep(4000)
  adb.(["shell", "am", "start", "-n", "#{app}/.MainActivity"])
  Process.sleep(1500)
  task = Task.async(fn -> rpc.(MagpieRecordCheck, :apps, [3]) end)

  # The consent dialog: tap "Start now".
  tap =
    Enum.find_value(1..20, fn _ ->
      Process.sleep(500)
      adb.(["shell", "uiautomator", "dump", "/sdcard/rc_ui.xml"])
      xml = adb.(["shell", "cat", "/sdcard/rc_ui.xml"])

      case Regex.run(~r/text="Start now"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/i, xml) do
        [_, x1, y1, x2, y2] ->
          [x1, y1, x2, y2] = Enum.map([x1, y1, x2, y2], &String.to_integer/1)
          adb.(["shell", "input", "tap", "#{div(x1 + x2, 2)}", "#{div(y1 + y2, 2)}"])
          {div(x1 + x2, 2), div(y1 + y2, 2)}

        _ ->
          nil
      end
    end)

  IO.puts("  consent: #{if tap, do: "tapped Start now at #{inspect(tap)}", else: "dialog not found"}")
  a = Task.await(task, 120_000)
  lv = levels.(a.rec)
  peak = Enum.max(Tuple.to_list(lv), fn -> 0.0 end)
  left = for <<x::float-32-little, _::float-32-little <- a.rec.pcm>>, do: x
  crossings = left |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [x, y] -> x < 0 and y >= 0 end)
  hz = crossings * a.rec.rate / max(a.rec.frames, 1)
  levels_db = for {_, {:magpie_audio, :meter, d, _}} <- a.meters, do: Float.round(d, 1)

  IO.puts(
    "  #{inspect(a.info)}; meters #{inspect(Enum.take(levels_db, 8))}; take #{a.rec.frames} frames × #{a.rec.channels}, " <>
      "peak #{fmt.(db.(peak))} dBFS, ≈ #{fmt.(hz * 1.0)} Hz"
  )

  adb.(["reverse", "--remove", "tcp:#{port}"])
  Port.close(server)
end
