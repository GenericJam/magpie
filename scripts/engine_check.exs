# Checks the magpie_audio engine on a connected Android phone over Erlang
# distribution: the stream, loading (file formats through MediaCodec, library
# PCM, decode for import), memory per loaded second, the sequencer's step
# timing against the engine clock, how playhead events reach the BEAM,
# trigger latency (NIF call → the frame that sounded, from the output
# timestamp), callback timing, underruns and CPU, idle and under load.
#
#   mix mob.deploy --native --android --device <serial>
#   mix mob.connect --no-iex --android-only --device <serial>
#   SERIAL=<serial> mix run --no-start scripts/engine_check.exs
#
# Needs ffmpeg on the Mac (test sounds). Turn the phone's volume down: it
# plays clicks, loops and a 32-voice wall for about a minute.

serial = System.fetch_env!("SERIAL")
app = "com.genericjam.magpie"
files = "/data/data/#{app}/files/engine_check"

node =
  String.to_atom(System.get_env("NODE", "magpie_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"engine_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

rpc = fn m, f, a ->
  case :rpc.call(node, m, f, a, 180_000) do
    {:badrpc, reason} -> raise "rpc #{inspect(m)}.#{f} failed: #{inspect(reason)}"
    value -> value
  end
end

adb = fn args ->
  {out, 0} = System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true)
  out
end

pct = fn
  [], _ -> nil
  list, p -> list |> Enum.sort() |> Enum.at(min(length(list) - 1, floor(p * length(list))))
end

fmt = fn
  x when is_float(x) -> :erlang.float_to_binary(x, decimals: 2)
  x -> inspect(x)
end

stats = fn list ->
  "p50 #{fmt.(pct.(list, 0.5))}, p95 #{fmt.(pct.(list, 0.95))}, max #{fmt.(Enum.max(list, fn -> nil end))}"
end

# ── Test sounds, made on the Mac and pushed into the app's files ──────────────

tmp = Path.join(System.tmp_dir!(), "magpie_engine_check")
File.mkdir_p!(tmp)

ffmpeg = fn args ->
  {_, 0} = System.cmd("ffmpeg", ["-v", "error", "-y" | args], stderr_to_stdout: true)
end

# A click (2 ms of 1 kHz, then silence): the sequencer's metronome.
ffmpeg.(~w(-f lavfi -i sine=frequency=1000:duration=0.05:sample_rate=48000 -af afade=t=out:st=0.002:d=0.001 -ac 1 #{tmp}/click.wav))
# Two seconds of a stereo chord at 44.1 kHz, in every format MediaCodec should read.
ffmpeg.(~w(-f lavfi -i sine=frequency=220:duration=2:sample_rate=44100 -f lavfi -i sine=frequency=331:duration=2:sample_rate=44100 -filter_complex [0][1]amerge=inputs=2,volume=0.4 #{tmp}/chord.wav))

formats = [
  {"wav16", "chord.wav", []},
  {"wav_f32", "chord_f32.wav", ~w(-c:a pcm_f32le)},
  {"wav24", "chord24.wav", ~w(-c:a pcm_s24le)},
  {"mp3", "chord.mp3", ~w(-c:a libmp3lame -b:a 192k)},
  {"m4a", "chord.m4a", ~w(-c:a aac -b:a 160k)},
  {"flac", "chord.flac", ~w(-c:a flac)},
  {"ogg", "chord.ogg", ~w(-c:a libopus -b:a 128k)}
]

for {_, name, codec} <- formats, name != "chord.wav",
    do: ffmpeg.(["-i", "#{tmp}/chord.wav"] ++ codec ++ ["#{tmp}/#{name}"])

adb.(["shell", "run-as", app, "mkdir", "-p", files])

for name <- ["click.wav" | Enum.map(formats, &elem(&1, 1))] do
  adb.(["push", "#{tmp}/#{name}", "/data/local/tmp/#{name}"])
  adb.(["shell", "run-as", app, "cp", "/data/local/tmp/#{name}", "#{files}/#{name}"])
  adb.(["shell", "rm", "/data/local/tmp/#{name}"])
end

# ── On the phone: a subscriber that stamps arrivals ───────────────────────────

collector = """
defmodule MagpieEngineCheck.Collector do
  def start do
    parent = self()
    pid = spawn(fn -> Magpie.Engine.subscribe(); send(parent, :subscribed); loop([]) end)
    receive do
      :subscribed -> pid
    end
  end

  defp loop(acc) do
    receive do
      {:report, from} -> send(from, {:report, Enum.reverse(acc)}); loop(acc)
      :clear -> loop([])
      :exit -> :ok
      msg -> loop([{System.monotonic_time(:nanosecond), msg} | acc])
    end
  end

  def report(pid) do
    send(pid, {:report, self()})
    receive do
      {:report, msgs} -> msgs
    end
  end

  # NIF cost of a live call, and a burst of triggers spread like a drummer's.
  def trigger_cost(pad, n) do
    t0 = System.monotonic_time(:nanosecond)
    for _ <- 1..n, do: Magpie.Engine.trigger(pad, 100)
    (System.monotonic_time(:nanosecond) - t0) / n / 1000
  end

  def drum(pad, n, gap_ms) do
    for _ <- 1..n do
      Magpie.Engine.trigger(pad, 100)
      Process.sleep(gap_ms + :rand.uniform(gap_ms))
    end
    :ok
  end

  # utime + stime (fields 14 and 15 of /proc/self/stat), in clock ticks.
  def cpu_ticks do
    fields = File.read!("/proc/self/stat") |> String.split(") ") |> List.last() |> String.split(" ")
    String.to_integer(Enum.at(fields, 11)) + String.to_integer(Enum.at(fields, 12))
  end

  def rss_kb do
    "/proc/self/status" |> File.read!() |> String.split("\\n") |> Enum.find(&String.starts_with?(&1, "VmRSS"))
    |> String.split() |> Enum.at(1) |> String.to_integer()
  end
end
"""

_ = rpc.(Code, :compile_string, [collector])
c = rpc.(MagpieEngineCheck.Collector, :start, [])
report = fn -> rpc.(MagpieEngineCheck.Collector, :report, [c]) end
clear = fn -> send(c, :clear) end

info = rpc.(Magpie.Engine, :info, [])

IO.puts("""
== Stream
  #{info.rate} Hz, burst #{info.burst}, buffer #{info.buffer_frames} of #{info.buffer_capacity} frames, low latency #{info.low_latency}, exclusive #{info.exclusive}
  output latency #{fmt.(info.output_latency_ms)} ms (frames written but not yet heard, from the timestamp)
""")

rate = info.rate

# ── Loading ──────────────────────────────────────────────────────────────────

IO.puts("== Loading (file → MediaCodec → 16-bit at #{rate} Hz)")

for {label, name, _} <- formats do
  t0 = System.monotonic_time(:millisecond)
  result = rpc.(Magpie.Engine, :load_sample, [label, "#{files}/#{name}"])
  ms = System.monotonic_time(:millisecond) - t0

  case result do
    {:ok, s} ->
      IO.puts(
        "  #{String.pad_trailing(label, 8)} #{s.frames} frames × #{s.channels} ch from #{s.source_rate} Hz, " <>
          "#{byte_size(s.peaks)} peak bytes, decode+resample #{fmt.(s.load_ms)} ms (call #{ms} ms)"
      )

    {:error, reason} ->
      IO.puts("  #{String.pad_trailing(label, 8)} #{inspect(reason)}")
  end
end

{:ok, click} = rpc.(Magpie.Engine, :load_sample, ["click", "#{files}/click.wav"])
IO.puts("  click    #{click.frames} frames")

{:ok, dec} = rpc.(Magpie.Engine, :decode, ["#{files}/chord.mp3"])
IO.puts("  decode(mp3) for import: #{byte_size(dec.pcm)} bytes f32le, #{dec.rate} Hz × #{dec.channels}, #{byte_size(dec.peaks)} peak bytes")

{:error, missing} = rpc.(Magpie.Engine, :load_sample, ["nope", "#{files}/missing.wav"])
IO.puts("  a missing file: #{inspect(missing)}")

# ── Memory: 60 s of library PCM (stereo, 48 kHz) ─────────────────────────────

IO.puts("\n== Memory")
:erlang.garbage_collect()
rss0 = rpc.(MagpieEngineCheck.Collector, :rss_kb, [])
bytes0 = rpc.(Magpie.Engine, :memory, [])
ten_s = for i <- 0..(48_000 * 10 - 1), into: <<>>, do: <<:math.sin(i / 7) * 0.3::float-32-little, :math.sin(i / 5) * 0.3::float-32-little>>

pcm_ms =
  for n <- 1..6 do
    t0 = System.monotonic_time(:millisecond)
    {:ok, _} = rpc.(Magpie.Engine, :load_pcm, ["pcm#{n}", ten_s, 48_000, 2])
    System.monotonic_time(:millisecond) - t0
  end

:rpc.call(node, :erlang, :garbage_collect, [])
rss1 = rpc.(MagpieEngineCheck.Collector, :rss_kb, [])
bytes1 = rpc.(Magpie.Engine, :memory, [])
per_s = (bytes1 - bytes0) / 60

IO.puts("""
  6 × 10 s stereo PCM loaded in #{Enum.join(pcm_ms, "/")} ms each (call, incl. 3.84 MB over dist)
  engine samples +#{div(bytes1 - bytes0, 1024)} KB = #{round(per_s / 1024)} KB per stereo second; process RSS +#{rss1 - rss0} KB (#{round((rss1 - rss0) / 60)} KB/s)
""")

for n <- 1..6, do: :ok = rpc.(Magpie.Engine, :unload_sample, ["pcm#{n}"])
Process.sleep(200)
rss2 = rpc.(MagpieEngineCheck.Collector, :rss_kb, [])
IO.puts("  after unloading them: engine samples #{div(rpc.(Magpie.Engine, :memory, []), 1024)} KB, RSS #{rss2 - rss0} KB over the start")

# ── Pads ─────────────────────────────────────────────────────────────────────

pad = fn id, opts ->
  {region, rest} = Keyword.split(opts, [:start, :stop, :gain_db, :pitch_st, :fade_out_ms, :reverse])
  struct(%Magpie.Kit.Pad{slot: 0, sample: struct(%Magpie.Kit.Region{id: id}, region)}, rest)
end

:ok = rpc.(Magpie.Engine, :set_pad, [0, pad.("click", [])])

for {id, i} <- Enum.with_index(~w(wav16 wav_f32 mp3 m4a flac ogg wav24)) do
  :ok = rpc.(Magpie.Engine, :set_pad, [1 + i, pad.(id, mode: :loop, gain_db: -12, pitch_st: i - 3)])
end

:ok = rpc.(Magpie.Engine, :set_pad, [8, pad.("wav16", mode: :keys, midi_note: 60, gain_db: -12)])

# ── Sequencer timing ─────────────────────────────────────────────────────────

steps16 = for s <- 0..15, do: %Magpie.Kit.Step{step: s, vel: 100}

pattern = %Magpie.Kit.Pattern{id: "chk", bank: "A", length: 16, lanes: %{0 => %{mute: false, steps: steps16}}}

# Frames from play to straight position `t` ticks at `bpm`, swing `s` (the
# engine's warp), exact up to float rounding.
expected = fn t, bpm, s ->
  pair = div(t, 48)
  r = rem(t, 48)
  x = if r < 24, do: pair * 48 + r * 2 * s, else: pair * 48 + 48 * s + (r - 24) * 2 * (1 - s)
  Float.ceil(x * 60 * rate / (bpm * 96) - 1.0e-6) |> trunc()
end

seq_run = fn bpm, swing, secs ->
  :ok = rpc.(Magpie.Engine, :set_tempo, [bpm])
  :ok = rpc.(Magpie.Engine, :set_swing, [swing])
  :ok = rpc.(Magpie.Engine, :set_pattern, [pattern])
  Process.sleep(100)
  clear.()
  :ok = rpc.(Magpie.Engine, :play, [])
  Process.sleep(secs * 1000)
  :ok = rpc.(Magpie.Engine, :stop, [])
  clock = rpc.(Magpie.Engine, :clock, [])
  heads = for {t, {:magpie_audio, :playhead, step, frame}} <- report.(), do: {t, step, frame}
  {heads, clock}
end

IO.puts("== Sequencer: step frames against the exact step positions; playhead delivery")

for {bpm, swing} <- [{120, 0.5}, {173, 0.62}, {240, 0.75}] do
  {heads, clock} = seq_run.(bpm, swing, 6)
  [{_, 0, f0} | _] = heads

  errors =
    heads
    |> Enum.with_index()
    |> Enum.map(fn {{_, _, f}, k} -> f - f0 - expected.(k * 24, bpm, swing) end)

  # When each step is heard (engine clock) vs when its message arrived.
  delivery = for {t, _, f} <- heads, do: (t - Magpie.Audio.frame_time(clock, f)) / 1.0e6

  heard = for {_, _, f} <- heads, do: Magpie.Audio.frame_time(clock, f)

  heard_err =
    heard
    |> Enum.with_index()
    |> Enum.map(fn {h, k} -> abs(h - hd(heard) - expected.(k * 24, bpm, swing) * 1.0e9 / rate) / 1000 end)

  arrivals = for {t, _, _} <- heads, do: t
  gaps = arrivals |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> (b - a) / 1.0e6 end)
  ideal = Enum.zip(arrivals, heard) |> Enum.map(fn {a, h} -> (a - h) / 1.0e6 end)
  mean = Enum.sum(ideal) / length(ideal)
  jitter = Enum.map(ideal, &abs(&1 - mean))

  IO.puts("""
    #{bpm} bpm swing #{swing}: #{length(heads)} steps, frame error vs exact: max #{Enum.max(Enum.map(errors, &abs/1))} frames; heard-time error (clock) max #{fmt.(Enum.max(heard_err))} µs
      message arrival − heard time (ms): #{stats.(delivery)} (negative: before the speaker plays it)
      arrival jitter around that (ms): #{stats.(jitter)}; arrival gaps #{fmt.(Enum.min(gaps))}..#{fmt.(Enum.max(gaps))} ms
  """)
end

# ── Trigger latency and the cost of a live call ──────────────────────────────

IO.puts("== Live triggers")
:ok = rpc.(Magpie.Audio.Native, :reset_stats, [])
:ok = rpc.(MagpieEngineCheck.Collector, :drum, [0, 200, 15])
lat = rpc.(Magpie.Engine, :info, []).trigger_latency_ms
cost = rpc.(MagpieEngineCheck.Collector, :trigger_cost, [0, 1000])

IO.puts("""
  NIF call → first frame heard (#{lat.count} triggers): p50 #{fmt.(lat.p50)} ms, p95 #{fmt.(lat.p95)} ms, min #{fmt.(lat.min)}, max #{fmt.(lat.max)}
  a trigger call costs #{fmt.(cost)} µs on the BEAM (1000 in a row)
""")

# ── Load: idle, then the sequencer plus 30 looping voices ────────────────────

hz = 100

measure = fn label, secs, fun ->
  Process.sleep(500)
  :ok = rpc.(Magpie.Audio.Native, :reset_stats, [])
  u0 = rpc.(Magpie.Engine, :info, []).underruns
  cpu0 = rpc.(MagpieEngineCheck.Collector, :cpu_ticks, [])
  fun.()
  Process.sleep(secs * 1000)
  cpu1 = rpc.(MagpieEngineCheck.Collector, :cpu_ticks, [])
  i = rpc.(Magpie.Engine, :info, [])

  IO.puts(
    "  #{String.pad_trailing(label, 22)} callback mean #{fmt.(i.callback_mean_us)} µs, max #{fmt.(i.callback_max_us)} µs, " <>
      "gap max #{fmt.(i.callback_gap_max_us / 1000)} ms, load #{fmt.(i.cpu_load * 100)} % of real time, " <>
      "underruns +#{i.underruns - u0}, voices peak #{i.voices_peak} (steals #{i.steals}, hard cuts #{i.hard_cuts}), " <>
      "app CPU #{fmt.((cpu1 - cpu0) / hz / secs * 100)} % of a core, buffer #{i.buffer_frames}"
  )
end

IO.puts("== Load (#{rate} Hz)")
measure.("idle stream", 5, fn -> :ok end)

measure.("sequencer 140 bpm", 5, fn ->
  :ok = rpc.(Magpie.Engine, :set_tempo, [140])
  :ok = rpc.(Magpie.Engine, :play, [])
end)

measure.("+ 30 looping voices", 10, fn ->
  for p <- 1..7, _ <- 1..4, do: :ok = rpc.(Magpie.Engine, :trigger, [p, 90])
  for n <- [48, 55], do: :ok = rpc.(Magpie.Engine, :note_on, [8, n, 90])
end)

measure.("+ steals (40 more)", 5, fn ->
  for _ <- 1..40, do: :ok = rpc.(Magpie.Engine, :trigger, [1 + :rand.uniform(6), 80])
end)

:ok = rpc.(Magpie.Engine, :stop, [])
for p <- 1..8, do: :ok = rpc.(Magpie.Engine, :release, [p])
Process.sleep(300)

final = rpc.(Magpie.Engine, :info, [])
IO.puts("\n== After\n  #{inspect(Map.drop(final, [:trigger_latency_ms]), limit: :infinity)}")

for id <- ~w(wav16 wav_f32 wav24 mp3 m4a flac ogg click), do: rpc.(Magpie.Engine, :unload_sample, [id])
for p <- 0..8, do: rpc.(Magpie.Engine, :clear_pad, [p])
adb.(["shell", "run-as", app, "rm", "-rf", files])
send(c, :exit)
