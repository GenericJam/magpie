# Checks Magpie's MIDI on a connected Android phone through its own MIDI
# device "Magpie" (mob_midi's MobMidiDeviceService), from another process:
# scripts/midi_probe/MidiProbe.java runs on the phone as the shell user
# (app_process), sends notes and a 24 PPQN clock into the device and records
# what Magpie sends out, every message stamped with CLOCK_MONOTONIC; the app
# is driven over Erlang distribution.
#
#   mix mob.deploy --native --android --device <serial>
#   mix mob.connect --no-iex --android-only --device <serial>
#   SERIAL=<serial> mix run --no-start scripts/midi_check.exs
#
# Measures: the device's ports and service; notes in → the mapped pads
# (voice starts per pad), the channel filter, in → heard latency
# (`info().midi.in_latency_ms`: the probe's timestamp → the frame the voice
# is heard); notes out for touches (`Engine.trigger`) and sequencer steps,
# stamped with the frame heard; clock send (tick spacing of the stamps and
# of the arrivals, arrival − stamp, `out_late_us`, song position / Start /
# Stop, notes on the tick grid); an incoming clock with Start / Stop / song
# position / Continue ignored (Magpie doesn't follow a clock yet); a
# listener that stops reading (mob_midi refuses sends until its queue has
# drained: every note-on still gets its note-off).
#
# It puts short test tones on bank A pads 0..4 (notes 36, 38, 42, 46 and a
# keys pad rooted at 60) and its own pattern in the engine, then puts the
# pads, the kit's MIDI settings, the tempo and the pattern back and deletes
# only the sounds it added. Turn the volume down. Needs JDK 17+ and the
# Android SDK for the probe (see midi_probe.sh).

serial = System.fetch_env!("SERIAL")
app_dir = Path.expand("..", __DIR__)
probe_sh = Path.join(app_dir, "scripts/midi_probe/midi_probe.sh")

node =
  String.to_atom(System.get_env("NODE", "magpie_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"midi_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

rpc = fn m, f, a ->
  case :rpc.call(node, m, f, a, 120_000) do
    {:badrpc, reason} -> raise "rpc #{inspect(m)}.#{f} failed: #{inspect(reason)}"
    value -> value
  end
end

pct = fn
  [], _ -> nil
  list, p -> list |> Enum.sort() |> Enum.at(min(length(list) - 1, floor(p * length(list))))
end

fmt = fn
  x when is_float(x) -> :erlang.float_to_binary(x, decimals: 2)
  x -> inspect(x)
end

stats = fn
  [] ->
    "none"

  list ->
    "p50 #{fmt.(pct.(list, 0.5) * 1.0)}, p95 #{fmt.(pct.(list, 0.95) * 1.0)}, " <>
      "min #{fmt.(Enum.min(list) * 1.0)}, max #{fmt.(Enum.max(list) * 1.0)} (n #{length(list)})"
end

rms = fn
  [] -> nil
  list -> :math.sqrt(Enum.sum(Enum.map(list, &(&1 * &1))) / length(list))
end

ring = fn
  nil -> "none"
  r -> "p50 #{fmt.(r.p50)}, p95 #{fmt.(r.p95)}, min #{fmt.(r.min)}, max #{fmt.(r.max)} (n #{r.count})"
end

ms = fn ns -> ns / 1.0e6 end

# ── The probe ────────────────────────────────────────────────────────────────

{out, status} =
  System.cmd(probe_sh, [serial], env: [{"PROBE_PUSH_ONLY", "1"}], stderr_to_stdout: true)

if status != 0, do: raise("midi_probe.sh failed:\n#{out}")

# One RECV may carry several messages (the sending thread batches messages
# within 0.1 ms): split them.
split = fn bytes ->
  bytes
  |> Enum.reduce([], fn
    b, acc when b >= 0x80 -> [[b] | acc]
    b, [msg | rest] -> [msg ++ [b] | rest]
    _b, [] -> []
  end)
  |> Enum.reverse()
end

parse = fn text ->
  text
  |> String.split("\n", trim: true)
  |> Enum.flat_map(fn line ->
    case String.split(String.trim(line), " ") do
      ["SENT", t | hex] ->
        [{:sent, String.to_integer(t), Enum.map(hex, &String.to_integer(&1, 16))}]

      ["RECV", arrival, stamp | hex] ->
        a = String.to_integer(arrival)
        s = String.to_integer(stamp)
        for msg <- split.(Enum.map(hex, &String.to_integer(&1, 16))), do: {:recv, a, s, msg}

      _ ->
        [{:line, line}]
    end
  end)
end

# Runs the probe (in the background); await with Task.await(task, :infinity).
probe = fn args ->
  Task.async(fn ->
    cmd = "CLASSPATH=/data/local/tmp/magpie_midi_probe.dex app_process /system/bin MidiProbe Magpie " <> Enum.join(args, " ")
    {out, _} = System.cmd("adb", ["-s", serial, "shell", cmd], stderr_to_stdout: true)
    events = parse.(out)

    for {:line, l} <- events, not String.starts_with?(l, ["DEVICE", "OPEN", "DONE"]),
        do: IO.puts("  probe: #{l}")

    events
  end)
end

# Until the probe has the port open (Magpie.Midi hears the port's status).
await_port = fn key ->
  Enum.reduce_while(1..100, nil, fn _, _ ->
    if rpc.(Magpie.Midi, :snapshot, []).port[key] > 0,
      do: {:halt, :ok},
      else: (Process.sleep(50) && {:cont, nil})
  end) || raise "the probe never opened the port"
end

# ── On the phone ─────────────────────────────────────────────────────────────

helper = """
defmodule MagpieMidiCheck do
  alias Magpie.{Engine, Kit, KitSession, Library}

  @pads [{0, 36, :one_shot}, {1, 38, :one_shot}, {2, 42, :one_shot}, {3, 46, :one_shot}, {4, 60, :keys}]

  # Short decaying tones on bank A pads 0..4 with their notes and modes.
  def setup do
    before = KitSession.snapshot().kit
    # A kit's `follow` couldn't be set back afterwards (Magpie refuses it
    # for now): leave such a kit alone.
    if before.midi.clock == :follow,
      do: raise("the open kit says clock follow, which this check couldn't put back: open another kit")

    originals = for {i, _, _} <- @pads, do: {i, get_in(before.banks, ["A", i])}

    new =
      for {i, note, mode} <- @pads do
        freq = 400 + 150 * i
        pcm =
          for f <- 0..5759, into: <<>> do
            v = 0.4 * :math.sin(2 * :math.pi() * freq * f / 48000) * :math.exp(-f / 1200)
            <<v::float-32-little>>
          end

        id = :sha256 |> :crypto.hash(pcm) |> Base.encode16(case: :lower)
        known = Library.get(id) != nil
        {:ok, s} = Library.put_pcm(pcm, %{name: "MIDI CHECK \#{i + 1}", rate: 48000, channels: 1, source: :imported})
        :ok = KitSession.put_sample(i, s.id)
        :ok = KitSession.update_pad(i, fn pad -> %{pad | midi_note: note, mode: mode} end)
        if known, do: nil, else: s.id
      end

    state = Engine.state()
    # Straight 16ths: sequenced notes land on clock ticks.
    :ok = Engine.set_swing(0.5)
    %{originals: originals, new: Enum.reject(new, &is_nil/1), midi: before.midi, pattern: state.pattern, swing: state.swing, tempo: state.tempo}
  end

  def ready? do
    pads = KitSession.snapshot().pads
    Enum.all?(@pads, fn {i, _, _} -> match?(%{status: :ready}, pads[i]) end)
  end

  def cleanup(%{originals: originals, new: new, midi: midi, pattern: pattern, swing: swing, tempo: tempo}) do
    Engine.stop()
    Engine.set_swing(swing)
    Engine.set_tempo(tempo)
    :ok = KitSession.set_midi(midi)
    for {i, pad} <- originals, do: :ok = KitSession.update_pad(i, fn _ -> pad end)
    :ok = KitSession.flush()
    # No pattern before (the engine can't be given none): an empty one.
    Engine.set_pattern(pattern || pattern([]), at: :now)
    Enum.map(new, &Library.delete/1)
  end

  # A 16-step bank A pattern: {slot, [steps]}.
  def pattern(lanes) do
    %Kit.Pattern{
      id: "MIDICHECK",
      bank: "A",
      length: 16,
      lanes: Map.new(lanes, fn {slot, steps} -> {slot, %{mute: false, steps: Enum.map(steps, &%Kit.Step{step: &1, vel: 100})}} end)
    }
  end

  # BEAM monotonic ns minus CLOCK_MONOTONIC ns.
  def offset do
    t0 = :erlang.monotonic_time(:nanosecond)
    os = Keyword.fetch!(:erlang.system_info(:os_monotonic_time_source), :time)
    t1 = :erlang.monotonic_time(:nanosecond)
    div(t0 + t1, 2) - :erlang.convert_time_unit(os, :native, :nanosecond)
  end

  # When engine frame `frame` is heard, CLOCK_MONOTONIC ns.
  def heard(frame), do: Magpie.Audio.frame_time(Engine.clock(), frame) - offset()

  # Touches: Engine.trigger on `pads` in turn, gap_ms apart. The call times, CLOCK_MONOTONIC ns.
  def touches(pads, n, gap_ms) do
    off = offset()
    for k <- 0..(n - 1) do
      pad = Enum.at(pads, rem(k, length(pads)))
      t = :erlang.monotonic_time(:nanosecond) - off
      :ok = Engine.trigger(pad, 100)
      Process.sleep(gap_ms)
      {pad, t}
    end
  end

  def collector do
    parent = self()
    pid = spawn(fn -> Engine.subscribe(); send(parent, :subscribed); loop([]) end)
    receive do
      :subscribed -> pid
    end
  end

  defp loop(acc) do
    receive do
      {:report, from} -> send(from, {:report, Enum.reverse(acc)}); loop(acc)
      :clear -> loop([])
      :exit -> :ok
      msg -> loop([{:erlang.monotonic_time(:nanosecond), msg} | acc])
    end
  end

  # The messages since the last clear: {CLOCK_MONOTONIC ns, msg}, frames turned into heard times.
  def report(pid) do
    send(pid, {:report, self()})
    off = offset()
    receive do
      {:report, msgs} ->
        for {t, msg} <- msgs do
          msg =
            case msg do
              {:magpie_audio, :playhead, step, frame} -> {:playhead, step, heard(frame)}
              {:magpie_audio, :voice, pad, what} -> {:voice, pad, what}
              other -> other
            end
          {t - off, msg}
        end
    end
  end
end
"""

_ = rpc.(Code, :compile_string, [helper])
reset = fn -> rpc.(Magpie.Audio.Native, :reset_stats, []) end
info = fn -> rpc.(Magpie.Engine, :info, []).midi end

IO.puts("== Magpie's MIDI device")

dumpsys = System.cmd("adb", ["-s", serial, "shell", "dumpsys midi"], stderr_to_stdout: true) |> elem(0)

for d <- String.split(dumpsys, "\n"), String.contains?(d, "name=Magpie") do
  [_, i, o] = Regex.run(~r/mInputPortCount=(\d+),\s*mOutputPortCount=(\d+)/, d)
  service = Regex.run(~r/io\.mob\.midi\.\w+|com\.genericjam\.\S+Service/, d)
  IO.puts("  dumpsys midi: \"Magpie\", #{i} input, #{o} output, service #{inspect(service && hd(service))}")
end

i0 = rpc.(Magpie.Engine, :info, [])
IO.puts("  sink registered #{i0.midi.bound}; stream #{i0.rate} Hz, burst #{i0.burst}, buffer #{i0.buffer_frames}, output latency #{fmt.(i0.output_latency_ms)} ms")
IO.puts("  outputs the engine sends to: #{i0.midi.outputs}")

saved = rpc.(MagpieMidiCheck, :setup, [])

Enum.reduce_while(1..200, nil, fn _, _ ->
  if rpc.(MagpieMidiCheck, :ready?, []), do: {:halt, :ok}, else: (Process.sleep(100) && {:cont, nil})
end) || raise "the test pads never loaded"

c = rpc.(MagpieMidiCheck, :collector, [])
report = fn -> rpc.(MagpieMidiCheck, :report, [c]) end
clear = fn -> send(c, :clear) end

try do
  # ── Notes in ───────────────────────────────────────────────────────────────

  IO.puts("\n== Notes in (probe → the Magpie port → pads)")
  :ok = rpc.(Magpie.KitSession, :set_midi, [%{in_channel: :all, clock: :internal}])
  Process.sleep(300)
  reset.()
  before = info.()
  clear.()
  notes = [36, 38, 42, 46, 60, 64]
  count = 36
  events = Task.await(probe.(["notes", "8", "#{count}", "150", "1", Enum.join(notes, ",")]), :infinity)
  Process.sleep(300)
  after_ = info.()
  starts = for {_, {:voice, pad, :start}} <- report.(), do: pad
  sent_on = Enum.count(for {:sent, _, [s, _, v]} <- events, s == 0x90 and v > 0, do: 1)
  sent_msgs = Enum.count(for {:sent, _, _} <- events, do: 1)

  IO.puts("  sent #{sent_on} note-ons + #{sent_msgs - sent_on} note-offs (#{Enum.join(notes, ", ")} in turn, 150 ms apart)")
  IO.puts("  received #{after_.received} messages, applied #{after_.applied - before.applied}")

  IO.puts(
    "  voice starts per pad: " <>
      (starts |> Enum.frequencies() |> Enum.sort() |> Enum.map_join(", ", fn {p, n} -> "pad #{p}: #{n}" end)) <>
      " (expected pads 0..3: #{div(count, 6)} each, keys pad 4: #{div(count, 3)})"
  )

  IO.puts("  in → heard (probe timestamp → first frame heard): #{ring.(after_.in_latency_ms)}")

  :ok = rpc.(Magpie.KitSession, :set_midi, [%{in_channel: 1}])
  Process.sleep(300)
  clear.()
  _ = Task.await(probe.(["notes", "3", "8", "100", "2", "36"]), :infinity)
  Process.sleep(200)
  wrong = Enum.count(for {_, {:voice, _, :start}} <- report.(), do: 1)
  IO.puts("  in_channel 1, 8 notes on channel 2: #{wrong} voices")
  :ok = rpc.(Magpie.KitSession, :set_midi, [%{in_channel: :all}])

  # ── Notes out: touches ─────────────────────────────────────────────────────

  IO.puts("\n== Notes out: touches (Engine.trigger, pads 0 and 4)")
  Process.sleep(300)
  reset.()
  task = probe.(["listen", "7"])
  await_port.(:outputs)
  touches = rpc.(MagpieMidiCheck, :touches, [[0, 4], 20, 200])
  events = Task.await(task, :infinity)
  ons = for {:recv, a, s, [st, n, v]} <- events, Bitwise.band(st, 0xF0) == 0x90 and v > 0, do: {a, s, n}
  offs = for {:recv, _, _, [st, n, v]} <- events, Bitwise.band(st, 0xF0) == 0x80 or (Bitwise.band(st, 0xF0) == 0x90 and v == 0), do: n

  IO.puts(
    "  20 touches → #{length(ons)} note-ons (#{ons |> Enum.map(&elem(&1, 2)) |> Enum.frequencies() |> inspect}), #{length(offs)} note-offs"
  )

  pairs = Enum.zip(touches, ons)
  IO.puts("  touch call → note stamp (= heard): #{stats.(for {{_, t}, {_, s, _}} <- pairs, do: ms.(s - t))} ms")
  IO.puts("  note stamp → arrival at the probe: #{stats.(for {a, s, _} <- ons, do: ms.(a - s))} ms")
  IO.puts("  out_late_us (send call − stamp): #{ring.(info.().out_late_us)}")
  IO.puts("  for comparison, the engine's trigger latency (NIF call → heard): #{ring.(rpc.(Magpie.Engine, :info, []).trigger_latency_ms)}")

  # ── Clock send + sequenced notes ───────────────────────────────────────────

  IO.puts("\n== Clock send at 120 bpm, pattern: pad 0 on steps 0/4/8/12, pad 1 on 2/6/10/14")
  :ok = rpc.(Magpie.KitSession, :set_midi, [%{clock: :send}])
  :ok = rpc.(Magpie.Engine, :set_tempo, [120])
  :ok = rpc.(Magpie.Engine, :set_pattern, [rpc.(MagpieMidiCheck, :pattern, [[{0, [0, 4, 8, 12]}, {1, [2, 6, 10, 14]}]]), [at: :now]])
  Process.sleep(300)
  reset.()
  task = probe.(["listen", "14"])
  await_port.(:outputs)
  Process.sleep(2000)
  :ok = rpc.(Magpie.Engine, :play, [])
  Process.sleep(8000)
  :ok = rpc.(Magpie.Engine, :stop, [])
  events = Task.await(task, :infinity)
  stats_send = info.()

  ticks = for {:recv, a, s, [0xF8]} <- events, do: {a, s}
  period = 60.0e9 / 120 / 24
  stamps = Enum.map(ticks, &elem(&1, 1))
  seq = for {:recv, _, s, msg} <- events, msg != [0xF8], do: {s, msg}
  {start_t, _} = Enum.find(seq, fn {_, m} -> m == [0xFA] end)
  spp = Enum.find(seq, fn {_, m} -> match?([0xF2 | _], m) end)
  {stop_t, _} = Enum.find(seq, {nil, nil}, fn {_, m} -> m == [0xFC] end)
  stop_t = stop_t || :infinity
  # Spacing while playing: Start restarts the clock on the play frame.
  playing = for {a, s} <- ticks, s >= start_t, s <= stop_t, do: {a, s}
  gaps = fn list -> list |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [x, y] -> y - x end) end
  stamp_gaps = for g <- gaps.(Enum.map(playing, &elem(&1, 1))), do: (g - period) / 1000
  arrival_gaps = for g <- gaps.(Enum.map(playing, &elem(&1, 0))), do: ms.(g - period)

  IO.puts("  #{length(ticks)} ticks over ~12 s, #{length(playing)} while playing (period #{fmt.(period / 1.0e6)} ms)")
  IO.puts("  stamp spacing − period (playing): #{stats.(stamp_gaps)} µs")
  IO.puts("  arrival spacing − period (playing): #{stats.(arrival_gaps)} ms (rms #{fmt.(rms.(arrival_gaps))})")
  IO.puts("  arrival − stamp: #{stats.(for {a, s} <- ticks, do: ms.(a - s))} ms")
  IO.puts("  out_late_us (send call − stamp): #{ring.(stats_send.out_late_us)}; late ticks dropped #{stats_send.late_ticks_dropped}, out dropped #{stats_send.out_dropped}")

  tick_at_start = Enum.find(stamps, &(&1 >= start_t))
  IO.puts("  song position #{inspect(spp && elem(spp, 1))} at the Start stamp: #{spp != nil and elem(spp, 0) == start_t}; first tick at Start: #{tick_at_start == start_t}; Stop: #{stop_t != :infinity}")
  IO.puts("  ticks before Start (free-running while stopped): #{Enum.count(stamps, &(&1 < start_t))}, after Stop: #{Enum.count(stamps, &(&1 > stop_t))}")

  seq_ons = for {s, [st, n, v]} <- seq, Bitwise.band(st, 0xF0) == 0x90 and v > 0, do: {s, n}
  seq_offs = for {_, [st, _, v]} <- seq, Bitwise.band(st, 0xF0) == 0x80 or (Bitwise.band(st, 0xF0) == 0x90 and v == 0), do: 1
  step_ns = period * 6
  expected = for {s, _} <- seq_ons, do: round((s - start_t) / step_ns)
  grid_err = for {s, _} <- seq_ons, do: (s - Enum.min_by(stamps, &abs(&1 - s))) / 1000

  IO.puts(
    "  sequenced notes: #{length(seq_ons)} note-ons (#{seq_ons |> Enum.map(&elem(&1, 1)) |> Enum.frequencies() |> inspect}), #{length(seq_offs)} note-offs; " <>
      "steps #{expected |> Enum.take(8) |> inspect}…"
  )

  IO.puts("  note stamp − nearest tick stamp: #{stats.(grid_err)} µs")

  # ── Clock in: ignored ──────────────────────────────────────────────────────

  IO.puts("\n== Clock in (probe → the Magpie port): not followed, ignored")
  :ok = rpc.(Magpie.KitSession, :set_midi, [%{clock: :internal}])
  :ok = rpc.(Magpie.Engine, :set_pattern, [rpc.(MagpieMidiCheck, :pattern, [[{0, Enum.to_list(0..15)}]]), [at: :now]])
  Process.sleep(300)
  before = info.()
  clear.()
  events = Task.await(probe.(["clock", "6", "120", "8"]), :infinity)
  Process.sleep(200)
  after_ = info.()
  beam = report.()
  sent = for {:sent, _, [b | _]} <- events, do: b
  heads = Enum.count(for {_, {:playhead, _, _}} <- beam, do: 1)
  voices = Enum.count(for {_, {:voice, _, :start}} <- beam, do: 1)
  outs = Enum.count(for {:recv, _, _, _} <- events, do: 1)

  IO.puts(
    "  sent #{Enum.count(sent, &(&1 == 0xF8))} ticks at 120 bpm with Start, Stop, song position 8 + Continue, Stop " <>
      "(#{length(sent)} messages); applied #{after_.applied - before.applied}"
  )

  IO.puts(
    "  Magpie: playing #{rpc.(Magpie.Engine, :state, []).playing}, #{heads} playhead steps, #{voices} voice starts, " <>
      "#{outs} messages out"
  )

  # ── A listener that stops reading ──────────────────────────────────────────

  IO.puts("\n== A listener that stops reading (probe stall 18 s, reads again at 15 s; 240 bpm clock send, pads 0 and 1 on every step)")
  :ok = rpc.(Magpie.KitSession, :set_midi, [%{clock: :send}])
  :ok = rpc.(Magpie.Engine, :set_tempo, [240])
  :ok = rpc.(Magpie.Engine, :set_pattern, [rpc.(MagpieMidiCheck, :pattern, [[{0, Enum.to_list(0..15)}, {1, Enum.to_list(0..15)}]]), [at: :now]])
  Process.sleep(300)
  reset.()
  task = probe.(["stall", "18"])
  await_port.(:outputs)
  :ok = rpc.(Magpie.Engine, :play, [])
  Process.sleep(16_500)
  :ok = rpc.(Magpie.Engine, :stop, [])
  events = Task.await(task, :infinity)
  stalled = info.()
  times = fn tag -> for {:line, l} <- events, [^tag, t] <- [String.split(l, " ")], do: String.to_integer(t) end
  resume = List.first(times.("RESUME"))
  recv = for {:recv, a, _s, msg} <- events, do: {a, msg}

  sounding =
    Enum.reduce(recv, MapSet.new(), fn
      {_, [st, n, v]}, acc when Bitwise.band(st, 0xF0) == 0x90 and v > 0 -> MapSet.put(acc, {Bitwise.band(st, 15), n})
      {_, [st, n, _]}, acc when Bitwise.band(st, 0xF0) in [0x80, 0x90] -> MapSet.delete(acc, {Bitwise.band(st, 15), n})
      _, acc -> acc
    end)

  after_resume = for {a, msg} <- recv, resume && a >= resume, do: msg
  ons = Enum.count(recv, fn {_, m} -> match?([st, _, v] when Bitwise.band(st, 0xF0) == 0x90 and v > 0, m) end)
  offs = Enum.count(recv, fn {_, m} -> match?([st, _, _] when Bitwise.band(st, 0xF0) == 0x80, m) end)

  IO.puts(
    "  refused #{stalled.refused} messages, #{stalled.discards} queue discard(s), #{stalled.offs_owed} owed note-offs sent after; " <>
      "still refusing at the end: #{stalled.refusing}"
  )

  IO.puts("  at the probe: #{length(recv)} messages (#{length(after_resume)} after it read again), #{ons} note-ons, #{offs} note-offs; left sounding: #{inspect(MapSet.to_list(sounding))}")

  IO.puts(
    "\n== Totals: #{inspect(Map.take(info.(), [:received, :applied, :sent, :out_dropped, :late_ticks_dropped, :refused, :discards, :offs_owed]))}"
  )
after
  send(c, :exit)
  rpc.(MagpieMidiCheck, :cleanup, [saved])
  IO.puts("\n(pads, MIDI settings and pattern restored)")
end
