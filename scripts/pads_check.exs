# Measures the pads screen on a connected Android phone with real touches:
# a virtual multitouch touchscreen made with Android's `uinput` shell
# command (the CTS tool; the shell user may open /dev/uinput, not the real
# touchscreen's evdev node), so every finger goes through the kernel,
# InputFlinger and Compose like a real one. It measures touch-down → the
# screen's `Engine.trigger` call, the engine's call → first frame heard,
# and touch → the frame that paints the press, for one finger and for four
# fingers landing together.
#
#   mix mob.deploy --android --device <serial>
#   mix mob.connect --no-iex --android-only --device <serial>
#   SERIAL=<serial> mix run --no-start scripts/pads_check.exs
#
# It puts short test sounds ("CHECK 1".."CHECK 16") on bank A's pads (PADS,
# default 16: a full bank, the heaviest screen to draw) of the kit on the
# phone, then puts the pads back as they were and deletes only the sounds
# it added. Turn the volume down. The pads screen must be in front,
# landscape.
#
# Clocks: a touch's `ts` is the MotionEvent's uptimeMillis (CLOCK_MONOTONIC,
# ms); the BEAM's monotonic clock is CLOCK_MONOTONIC plus an offset read on
# the phone; `dumpsys gfxinfo framestats` is CLOCK_MONOTONIC ns. The touch
# stamp has 1 ms resolution, so touch → BEAM numbers carry ±1 ms. Injected
# events skip the touch controller's own scan latency.

# uinput's JSON commands, keys in the order its parser insists on (keyword
# lists here, written in order). Event codes: EV_SYN 0, EV_KEY 1, EV_ABS 3,
# BTN_TOUCH 330, ABS_MT_SLOT 47, ABS_MT_POSITION_X 53, _Y 54,
# ABS_MT_TRACKING_ID 57; INPUT_PROP_DIRECT 1.
defmodule PadsCheck.Json do
  def encode([{k, _} | _] = pairs) when is_atom(k),
    do: "{" <> Enum.map_join(pairs, ",", fn {k, v} -> ~s("#{k}":) <> encode(v) end) <> "}"

  def encode(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  def encode(v), do: JSON.encode!(v)
end

serial = System.fetch_env!("SERIAL")
app = "com.genericjam.magpie"
rounds = String.to_integer(System.get_env("ROUNDS", "40"))
loaded = String.to_integer(System.get_env("PADS", "16"))
batch = 8

node =
  String.to_atom(System.get_env("NODE", "magpie_android_#{String.downcase(serial)}@127.0.0.1"))

{:ok, _} = Node.start(:"pads_check_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
true = Node.connect(node)

rpc = fn m, f, a ->
  case :rpc.call(node, m, f, a, 120_000) do
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
  x when is_float(x) -> :erlang.float_to_binary(x, decimals: 1)
  x -> inspect(x)
end

stats = fn
  [] ->
    "none"

  list ->
    "p50 #{fmt.(pct.(list, 0.5))}, p95 #{fmt.(pct.(list, 0.95))}, min #{fmt.(Enum.min(list))}, max #{fmt.(Enum.max(list))} ms (n #{length(list)})"
end

# ── On the phone: test sounds and a tracer on the screen and the sender ──────

probe = """
defmodule MagpiePadsCheck.Probe do
  alias Magpie.{KitSession, Library}

  # n short decaying tones on bank A's pads 0..n-1, one-shot. Returns what
  # cleanup/1 needs: the pads there before, and the sounds new to the library.
  def setup(n) do
    before = KitSession.snapshot().kit
    originals = for i <- 0..(n - 1), do: {i, get_in(before.banks, ["A", i])}

    new =
      for i <- 0..(n - 1) do
        freq = 500 + 170 * i
        pcm =
          for f <- 0..5759, into: <<>> do
            v = 0.5 * :math.sin(2 * :math.pi() * freq * f / 48000) * :math.exp(-f / 1200)
            <<v::float-32-little>>
          end

        id = :sha256 |> :crypto.hash(pcm) |> Base.encode16(case: :lower)
        known = Library.get(id) != nil
        {:ok, s} = Library.put_pcm(pcm, %{name: "CHECK \#{i + 1}", rate: 48000, channels: 1, source: :imported})
        :ok = KitSession.put_sample(i, s.id)
        if known, do: nil, else: s.id
      end

    {originals, Enum.reject(new, &is_nil/1)}
  end

  def ready?(n) do
    pads = KitSession.snapshot().pads
    Enum.all?(0..(n - 1), &match?(%{status: :ready}, pads[&1]))
  end

  # The pads as they were, and only the sounds this check added deleted.
  def cleanup({originals, new_ids}) do
    for {i, pad} <- originals, do: :ok = KitSession.update_pad(i, fn _ -> pad end)
    :ok = KitSession.flush()
    Enum.map(new_ids, &Library.delete/1)
  end

  # BEAM monotonic ns minus CLOCK_MONOTONIC ns.
  def offset do
    t0 = :erlang.monotonic_time(:nanosecond)
    os = Keyword.fetch!(:erlang.system_info(:os_monotonic_time_source), :time)
    t1 = :erlang.monotonic_time(:nanosecond)
    div(t0 + t1, 2) - :erlang.convert_time_unit(os, :native, :nanosecond)
  end

  def start_trace do
    parent = self()
    tracer = spawn(fn -> collect([], parent) end)
    screen = Mob.Screen.get_screen_pid(:mob_screen)
    sender = Process.whereis(Mob.Sender)
    flags = [:monotonic_timestamp, {:tracer, tracer}]
    :erlang.trace(screen, true, [:receive, :call | flags])
    :erlang.trace(sender, true, [:call | flags])
    :erlang.trace_pattern({Magpie.Engine, :trigger, 3}, true, [:global])
    :erlang.trace_pattern({:mob_nif, :set_root, 1}, [{:_, [], [{:return_trace}]}], [:global])
    {tracer, screen, sender}
  end

  def stop_trace({tracer, screen, sender}) do
    :erlang.trace(screen, false, [:all])
    :erlang.trace(sender, false, [:all])
    :erlang.trace_pattern({Magpie.Engine, :trigger, 3}, false, [:global])
    :erlang.trace_pattern({:mob_nif, :set_root, 1}, false, [:global])
    send(tracer, {:report, self()})

    receive do
      {:report, events} -> events
    after
      10_000 -> :timeout
    end
  end

  defp collect(acc, parent) do
    receive do
      {:report, from} ->
        send(from, {:report, Enum.reverse(acc)})

      {:trace_ts, _pid, :receive, {:touch, {:pad, pad}, %{phase: phase} = t}, ts} when phase in [:down, :up] ->
        collect([{:touch, ns(ts), pad, phase, t.pointer_id, t.ts} | acc], parent)

      {:trace_ts, _pid, :call, {Magpie.Engine, :trigger, [pad | _]}, ts} ->
        collect([{:trigger, ns(ts), pad} | acc], parent)

      {:trace_ts, _pid, :return_from, {:mob_nif, :set_root, 1}, _, ts} ->
        collect([{:set_root, ns(ts)} | acc], parent)

      _other ->
        collect(acc, parent)
    end
  end

  defp ns(ts), do: :erlang.convert_time_unit(ts, :native, :nanosecond)
end
"""

_ = rpc.(Code, :compile_string, [probe])
probe = MagpiePadsCheck.Probe

# ── Pads, fingers and the touchscreen ────────────────────────────────────────

state = rpc.(probe, :setup, [loaded])
# Put the kit back however the script ends.
System.at_exit(fn _ -> rpc.(probe, :cleanup, [state]) end)

Enum.reduce_while(1..200, nil, fn _, _ ->
  if rpc.(probe, :ready?, [loaded]), do: {:halt, :ok}, else: {:cont, Process.sleep(50)}
end)

frames = Mob.Test.element_frames(node)
density = adb.(["shell", "wm", "density"]) |> String.split() |> List.last() |> String.to_integer() |> Kernel./(160)
[rotation] = Regex.run(~r/ROTATION_\d+/, adb.(["shell", "dumpsys", "window", "displays"]))
if rotation not in ["ROTATION_90", "ROTATION_270"], do: raise("the pads aren't landscape (#{rotation})")

# The virtual touchscreen is an external device: InputReader gives it the
# display's natural (portrait) frame, so its axes are the natural size and
# a landscape point is rotated into it.
[nat_w, nat_h] =
  adb.(["shell", "wm", "size"])
  |> String.split()
  |> List.last()
  |> String.split("x")
  |> Enum.map(&String.to_integer/1)

IO.puts("display #{nat_w}×#{nat_h} px natural, density #{density}, #{rotation}")

# Landscape dp to the natural frame's pixels.
natural = fn x, y ->
  {dx, dy} = {round(x * density), round(y * density)}
  if rotation == "ROTATION_90", do: {nat_w - dy, dx}, else: {dy, nat_h - dx}
end

# A pad's centre, y at 30 % of its height.
at = fn pad ->
  {x, y, w, h} = Map.fetch!(frames, "pad_#{pad}")
  natural.(x + w / 2, y + h * 0.3)
end

# The top bar's empty middle, between the kit name and the tempo: nothing
# there reacts.
{px, py, _, ph} = Map.fetch!(frames, "play")
inert = natural.(px - 200, py + ph / 2)

abs = fn code, max ->
  [code: code, info: [value: 0, minimum: 0, maximum: max, fuzz: 0, flat: 0, resolution: 0]]
end

register = [
  id: 1,
  command: "register",
  name: "Magpie pads check",
  vid: 6353,
  pid: 43981,
  bus: "usb",
  configuration: [
    [type: "UI_SET_EVBIT", data: [1, 3]],
    [type: "UI_SET_KEYBIT", data: [330]],
    [type: "UI_SET_ABSBIT", data: [47, 53, 54, 57]],
    [type: "UI_SET_PROPBIT", data: [1]]
  ],
  abs_info: [abs.(47, 9), abs.(53, nat_w - 1), abs.(54, nat_h - 1), abs.(57, 65_535)]
]

inject = fn events -> [id: 1, command: "inject", events: List.flatten(events)] end
delay = fn ms -> [id: 1, command: "delay", duration: ms] end

down = fn fingers ->
  inject.([
    for({slot, {x, y}} <- fingers, do: [3, 47, slot, 3, 57, 100 + slot, 3, 53, x, 3, 54, y]),
    [1, 330, 1, 0, 0, 0]
  ])
end

up = fn fingers ->
  inject.([for({slot, _} <- fingers, do: [3, 47, slot, 3, 57, -1]), [1, 330, 0, 0, 0, 0]])
end

tmp = Path.join(System.tmp_dir!(), "magpie_pads_check")
File.mkdir_p!(tmp)

# A batch: register, settle, a warm-up tap on nothing (the uinput tool
# stamps the first event after registering ~800 ms early), then n rounds of
# all fingers down, 150 ms held, up, 350 ms apart.
push_batch = fn name, fingers, n ->
  commands =
    [register, delay.(800), down.([{0, inert}]), delay.(50), up.([{0, inert}]), delay.(300)] ++
      Enum.flat_map(1..n, fn _ -> [down.(fingers), delay.(150), up.(fingers), delay.(350)] end)

  File.write!(Path.join(tmp, name), Enum.map_join(commands, "\n", &PadsCheck.Json.encode/1))
  adb.(["push", Path.join(tmp, name), "/data/local/tmp/#{name}"])
end

one = [{0, at.(0)}]
four = Enum.map(0..3, &{&1, at.(&1)})

for {prefix, fingers} <- [one: one, four: four], n <- 1..batch,
    do: push_batch.("pads_check_#{prefix}_#{n}.json", fingers, n)

# ── A run: N rounds of down / hold / up, traced, frames per batch ────────────

parse_frames = fn text ->
  lines = String.split(text, "\n")
  header = Enum.find(lines, &String.starts_with?(&1, "Flags,"))
  cols = header |> String.split(",") |> Enum.with_index() |> Map.new()

  lines
  |> Enum.drop_while(&(&1 != header))
  |> Enum.drop(1)
  |> Enum.take_while(&(&1 =~ ~r/^\d/))
  |> Enum.map(fn line ->
    v = line |> String.split(",") |> Enum.map(&(Integer.parse(&1) |> then(fn {n, _} -> n; :error -> 0 end)))
    # Older Androids (10 on the moto e) have no DisplayPresentTime: it reads nil.
    get = fn name -> cols[name] && Enum.at(v, cols[name]) end
    completed = get.("FrameCompleted")
    present = get.("DisplayPresentTime")

    # The frame's Choreographer callbacks start at AnimationStart (Compose
    # recomposes there). Read by name: on this Android the FrameStartTime and
    # FrameInterval headers are swapped against their values. A present
    # time not after completion is stale (its fence hadn't signalled).
    %{
      flags: get.("Flags"),
      start: get.("AnimationStart"),
      completed: completed,
      present: if(present && present > completed, do: present)
    }
  end)
  |> Enum.filter(&(&1.flags == 0))
end

run = fn label, prefix ->
  :ok = rpc.(Magpie.Audio.Native, :reset_stats, [])
  offset = rpc.(probe, :offset, [])
  trace = rpc.(probe, :start_trace, [])

  frames =
    for b <- 0..(div(rounds + batch - 1, batch) - 1), reduce: [] do
      acc ->
        adb.(["shell", "dumpsys", "gfxinfo", app, "reset"])
        n = min(batch, rounds - b * batch)
        adb.(["shell", "uinput", "/data/local/tmp/pads_check_#{prefix}_#{n}.json"])
        Process.sleep(300)
        acc ++ parse_frames.(adb.(["shell", "dumpsys", "gfxinfo", app, "framestats"]))
    end

  events = rpc.(probe, :stop_trace, [trace])
  info = rpc.(Magpie.Engine, :info, [])

  downs = for {:touch, t, pad, :down, id, ts} <- events, do: {t, pad, ts * 1_000_000 + offset, id}
  frames = Enum.sort_by(frames, & &1.start)
  ms = fn t, from -> t && (t - from) / 1.0e6 end

  # Per down: the BEAM receiving it, the trigger call after it, the next
  # set_root returning, the first frame whose callbacks start after that.
  rows =
    Enum.map(downs, fn {t_recv, pad, t_touch, id} ->
      after_recv = Enum.drop_while(events, &(elem(&1, 1) < t_recv))
      t_trig = Enum.find_value(after_recv, fn {:trigger, t, ^pad} -> t; _ -> nil end)
      t_root = Enum.find_value(after_recv, fn {:set_root, t} -> t; _ -> nil end)
      touch_mono = t_touch - offset

      frame =
        t_root &&
          Enum.find(frames, &(&1.start >= t_root - offset and &1.start < t_root - offset + 200_000_000))

      %{
        pad: pad,
        pointer: id,
        recv: ms.(t_recv, t_touch),
        trig: ms.(t_trig, t_touch),
        root: ms.(t_root, t_touch),
        start: frame && ms.(frame.start, touch_mono),
        drawn: frame && ms.(frame.completed, touch_mono),
        shown: frame && ms.(frame.present, touch_mono)
      }
    end)

  if System.get_env("DEBUG") do
    for row <- rows, do: IO.inspect(row)
  end

  col = fn key -> rows |> Enum.map(& &1[key]) |> Enum.reject(&is_nil/1) end
  lat = info.trigger_latency_ms

  IO.puts("""

  == #{label}: #{length(downs)} touch-downs, #{lat && lat.count} triggers in the engine
    touch → screen receives the :down   #{stats.(col.(:recv))}
    touch → Engine.trigger call         #{stats.(col.(:trig))}
    Engine.trigger → first frame heard  p50 #{fmt.(lat && lat.p50)}, p95 #{fmt.(lat && lat.p95)}, min #{fmt.(lat && lat.min)}, max #{fmt.(lat && lat.max)} ms (engine, output timestamp)
    touch → tree committed (set_root)   #{stats.(col.(:root))}
    touch → press frame starts          #{stats.(col.(:start))} (its Choreographer callbacks)
    touch → press frame drawn           #{stats.(col.(:drawn))}
    touch → press frame on the display  #{stats.(col.(:shown))}
    underruns #{info.underruns}, output latency #{fmt.(info.output_latency_ms)} ms
  """)
end

run.("One finger (pad A1)", "one")
run.("Four fingers landing together (pads A1–A4)", "four")
