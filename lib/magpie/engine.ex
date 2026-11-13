defmodule Magpie.Engine do
  @moduledoc """
  The sampler: owns the audio engine (`Magpie.Audio`), keeps a mirror of
  what is loaded, and tells subscribed screens what plays. One per app,
  started from `Magpie.App.on_start/0` (never from a screen), so sound and
  the sequencer outlive screens.

  It speaks the kit's language (`Magpie.Kit`): `set_pad/2` takes a
  `%Magpie.Kit.Pad{}` (regions in seconds), `set_pattern/2` a
  `%Magpie.Kit.Pattern{}`, and live-record hits arrive as
  `%Magpie.Kit.Step{}` ready to drop into a lane. Pads are addressed by
  index, `Magpie.Kit.pad_index(bank, slot)`.

  ## Live play

  `trigger/3`, `release/1`, `note_on/3` and `note_off/2` don't go through
  this process: they call the engine directly from the caller (a screen,
  the MIDI handler), which only queues a command for the audio thread. A
  sample loading or a busy mailbox here never delays a pad.

  ## Subscribers

  `subscribe/1` (monitored) forwards the engine's messages:

      {:magpie_audio, :playhead, step, frame}         # step (0..length-1) started sounding at engine frame `frame`
      {:magpie_audio, :voice, pad, :start | :end}     # a voice of `pad` started; its last voice ended
      {:magpie_audio, :hit, pad, %Magpie.Kit.Step{}}  # a live trigger while playing (see below)
      {:magpie_audio, :pattern, %Magpie.Kit.Pattern{}, frame}  # this pattern took over at `frame`

  `frame` is an engine frame; `Magpie.Audio.frame_time(clock(), frame)`
  says when it is heard, for drawing the playhead in time with the sound.

  ## Live record

  While the sequencer plays, every live trigger also arrives as a hit:
  `%Magpie.Kit.Step{step, vel, tick, note}` stamped where the player heard
  it (the frame being heard at the call, from the output timestamp): the
  nearest step of the playing pattern and `tick` (-12..12 at 96 PPQN) from
  that step's swung start; `note` for keys pads. With Snap on, store it
  with `tick: 0`; off, as it is.

  ## Samples

  `load_sample/2` decodes a file (MediaCodec on the phone), `load_pcm/4`
  takes the library's f32le PCM (`Magpie.Library.pcm/1`). Both block the
  caller until the sample is in RAM, resampled to the engine's rate, and
  return its info (`t:Magpie.Audio.sample_info/0`); this process stays
  free meanwhile. `decode/1` decodes a file for importing into the
  library. A restarted engine starts clean: load the kit again.
  """

  use GenServer

  require Logger

  alias Magpie.{Audio, Kit}
  alias Magpie.Kit.{Pad, Pattern, Region, Step}

  @load_timeout 120_000
  @modes [:one_shot, :gate, :loop, :toggle, :keys]
  @banks ~w(A B C D)
  # The most events the engine takes in one pattern (c_src/sampler.c SP_MAX_STEPS).
  @max_events 4096

  defstruct stream: nil,
            samples: %{},
            loading: %{},
            pads: %{},
            pattern: nil,
            pattern_number: nil,
            pending: nil,
            tempo: 120,
            swing: 0.5,
            playing: false,
            step: nil,
            subscribers: %{}

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Forward the engine's messages to `pid` until it exits or unsubscribes."
  def subscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def unsubscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

  @doc """
  Decode the file at `path` into the engine as sample `id`. `{:ok,
  info}` or `{:error, reason}` (see `c:Magpie.Audio.load_sample/2`).
  Loading an id again replaces it (pads using it play the new sound).
  """
  @spec load_sample(term(), Path.t()) :: {:ok, Audio.sample_info()} | {:error, term()}
  def load_sample(id, path),
    do: GenServer.call(__MODULE__, {:load, id, {:file, path}}, @load_timeout)

  @doc "Load interleaved f32le PCM (`Magpie.Library.pcm/1`) as sample `id`. As `load_sample/2`."
  @spec load_pcm(term(), binary(), pos_integer(), pos_integer()) ::
          {:ok, Audio.sample_info()} | {:error, term()}
  def load_pcm(id, pcm, rate, channels)
      when is_binary(pcm) and is_integer(rate) and rate > 0 and is_integer(channels) and
             channels > 0,
      do: GenServer.call(__MODULE__, {:load, id, {:pcm, pcm, rate, channels}}, @load_timeout)

  @doc """
  Decode a file for importing into the library, in the caller: f32le PCM
  at the file's rate plus peaks, ready for `Magpie.Library.put_pcm/2`.
  """
  @spec decode(Path.t()) :: {:ok, Audio.decoded()} | {:error, term()}
  def decode(path), do: Audio.impl().decode(path)

  @doc "Unload sample `id`; pads using it are cleared. `:ok` or `{:error, :unknown_sample}`."
  def unload_sample(id), do: GenServer.call(__MODULE__, {:unload, id})

  @doc "Loaded samples: `%{id => info}`."
  def samples, do: GenServer.call(__MODULE__, :samples)

  @doc "Bytes of RAM the loaded samples take."
  def memory, do: GenServer.call(__MODULE__, :memory)

  @doc """
  Set pad `index` (0..63) from a kit pad. Its sample must be loaded. A pad
  without a sample is silent. Takes effect on the pad's next trigger.
  `{:error, :unknown_sample}` or `{:error, {:invalid, field}}` otherwise.
  """
  @spec set_pad(Audio.pad(), Pad.t() | nil) :: :ok | {:error, term()}
  def set_pad(index, pad) when index in 0..63 and (is_nil(pad) or is_struct(pad, Pad)),
    do: GenServer.call(__MODULE__, {:set_pad, index, pad})

  def clear_pad(index) when index in 0..63, do: set_pad(index, nil)

  @doc "Pads set: `%{index => %Magpie.Kit.Pad{}}`."
  def pads, do: GenServer.call(__MODULE__, :pads)

  @doc """
  Set the pattern the sequencer plays. `at: :bar` (default): while
  playing, it takes over at the next bar, from its step 0 (switching
  patterns); `at: :now`: at once, keeping the position (editing the playing
  pattern). Stopped, it applies at once either way. Muted lanes are left
  out.
  """
  @spec set_pattern(Pattern.t(), keyword()) :: :ok | {:error, term()}
  def set_pattern(%Pattern{} = pattern, opts \\ []) do
    at = Keyword.get(opts, :at, :bar)

    if at in [:bar, :now],
      do: GenServer.call(__MODULE__, {:set_pattern, pattern, at}),
      else: {:error, {:invalid, :at}}
  end

  @doc "Tempo, 40..240 bpm."
  def set_tempo(bpm) when is_number(bpm) and bpm >= 40 and bpm <= 240,
    do: GenServer.call(__MODULE__, {:tempo, bpm})

  def set_tempo(_bpm), do: {:error, {:invalid, :tempo}}

  @doc "Swing as the kit has it: 0.5 straight … 0.75 (the first 16th of each pair's share)."
  def set_swing(swing) when is_number(swing) and swing >= 0.5 and swing <= 0.75,
    do: GenServer.call(__MODULE__, {:swing, swing})

  def set_swing(_swing), do: {:error, {:invalid, :swing}}

  @doc "Start the sequencer from step 0."
  def play, do: GenServer.call(__MODULE__, :play)

  @doc "Stop the sequencer; sounding voices ring on."
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "`%{playing, step, tempo, swing, pattern, pending, stream}`."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc """
  Play pad `index` at `velocity` (the caller applies the pad's velocity
  mode, `Magpie.Style.velocity/2`). `quantize: ticks` waits, while the
  sequencer plays, for the next point of that grid (24 a 16th, 96 a beat,
  384 a bar): Snap for loop launches. `{:error, :not_running}` with no
  output stream.
  """
  def trigger(index, velocity, opts \\ []) when index in 0..63 and velocity in 1..127 do
    quantize = Keyword.get(opts, :quantize, 0)
    Audio.impl().trigger(index, velocity, quantize)
  end

  @doc "Let go of pad `index`: gate, loop and keys voices fade out (its fade-out, at least 5 ms)."
  def release(index) when index in 0..63, do: Audio.impl().release(index)

  @doc "A keys pad plays `note`, chromatic from its `midi_note`; any other pad just triggers."
  def note_on(index, note, velocity)
      when index in 0..63 and note in 0..127 and velocity in 1..127,
      do: Audio.impl().note_on(index, note, velocity)

  def note_off(index, note) when index in 0..63 and note in 0..127,
    do: Audio.impl().note_off(index, note)

  @doc "The engine clock (`t:Magpie.Audio.clock/0`), or nil before the stream has a timestamp."
  def clock, do: Audio.impl().clock()

  @doc "Engine diagnostics (see `c:Magpie.Audio.info/0`)."
  def info, do: Audio.impl().info()

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    impl = Audio.impl()

    stream =
      case impl.open(self()) do
        {:ok, stream} ->
          stream

        {:error, reason} = error ->
          Logger.warning("Magpie.Engine: no audio output (#{inspect(reason)})")
          error
      end

    case impl.reset() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Magpie.Engine: reset refused (#{inspect(reason)})")
    end

    {:ok, %__MODULE__{stream: stream}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, s) do
    subscribers =
      if Map.has_key?(s.subscribers, pid),
        do: s.subscribers,
        else: Map.put(s.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{s | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, s) do
    {ref, subscribers} = Map.pop(s.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{s | subscribers: subscribers}}
  end

  def handle_call({:load, id, source}, from, s) do
    result =
      case source do
        {:file, path} -> Audio.impl().load_sample(id, path)
        {:pcm, pcm, rate, channels} -> Audio.impl().load_pcm(id, pcm, rate, channels)
      end

    s =
      case result do
        :ok ->
          %{s | loading: Map.update(s.loading, id, [from], &(&1 ++ [from]))}

        {:error, _} = error ->
          GenServer.reply(from, error)
          s
      end

    # A PCM load passed megabytes through this process: hibernating collects
    # now, so the binary is freed as soon as the loader has converted it
    # rather than whenever this mostly idle process next collects.
    case source do
      {:pcm, _, _, _} -> {:noreply, s, :hibernate}
      {:file, _} -> {:noreply, s}
    end
  end

  def handle_call({:unload, id}, _from, s) do
    case Audio.impl().unload_sample(id) do
      :ok ->
        pads = Map.reject(s.pads, fn {_, pad} -> uses?(pad, id) end)
        {:reply, :ok, %{s | samples: Map.delete(s.samples, id), pads: pads}}

      {:error, _} = error ->
        {:reply, error, s}
    end
  end

  def handle_call(:samples, _from, s), do: {:reply, s.samples, s}

  def handle_call(:memory, _from, s),
    do: {:reply, s.samples |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum(), s}

  def handle_call({:set_pad, index, pad}, _from, s) do
    case apply_pad(index, pad, s.samples) do
      :ok -> {:reply, :ok, %{s | pads: put_pad(s.pads, index, pad)}}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call(:pads, _from, s), do: {:reply, s.pads, s}

  def handle_call({:set_pattern, pattern, at}, _from, s) do
    with {:ok, compiled} <- compile(pattern),
         {:ok, number} <- Audio.impl().set_pattern(compiled, at) do
      s =
        if s.playing and at == :bar,
          do: %{s | pending: {number, pattern}},
          else: %{s | pattern: pattern, pattern_number: number, pending: nil}

      {:reply, :ok, s}
    else
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:tempo, bpm}, _from, s),
    do: control(Audio.impl().set_tempo(bpm), %{s | tempo: bpm}, s)

  def handle_call({:swing, swing}, _from, s),
    do: control(Audio.impl().set_swing(swing), %{s | swing: swing}, s)

  def handle_call(:play, _from, %{playing: true} = s), do: {:reply, :ok, s}

  def handle_call(:play, _from, s),
    do: control(Audio.impl().play(), %{s | playing: true, step: nil}, s)

  def handle_call(:stop, _from, s),
    do: control(Audio.impl().stop(), %{s | playing: false, step: nil}, s)

  def handle_call(:state, _from, s) do
    {:reply,
     %{
       playing: s.playing,
       step: s.step,
       tempo: s.tempo,
       swing: s.swing,
       pattern: s.pattern,
       pending: with({_, pattern} <- s.pending, do: pattern),
       stream: s.stream
     }, s}
  end

  @impl true
  def handle_info({:magpie_audio, :loaded, id, result}, s) do
    case Map.get(s.loading, id, []) do
      [] ->
        {:noreply, s}

      [from | waiting] ->
        GenServer.reply(from, result)

        loading =
          if waiting == [], do: Map.delete(s.loading, id), else: Map.put(s.loading, id, waiting)

        {:noreply, loaded(%{s | loading: loading}, id, result)}
    end
  end

  def handle_info({:magpie_audio, :playhead, step, _frame} = msg, s) do
    forward(s, msg)
    {:noreply, %{s | step: step}}
  end

  def handle_info({:magpie_audio, :pattern, number, frame}, s) do
    case s.pending do
      {^number, pattern} ->
        forward(s, {:magpie_audio, :pattern, pattern, frame})
        {:noreply, %{s | pattern: pattern, pattern_number: number, pending: nil}}

      _ ->
        if number == s.pattern_number, do: forward(s, {:magpie_audio, :pattern, s.pattern, frame})
        {:noreply, s}
    end
  end

  def handle_info({:magpie_audio, kind, _, _} = msg, s) when kind in [:voice, :hit] do
    forward(s, msg)
    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp control(:ok, new, _old), do: {:reply, :ok, new}
  defp control({:error, _} = error, _new, old), do: {:reply, error, old}

  defp forward(s, msg), do: Enum.each(Map.keys(s.subscribers), &send(&1, msg))

  defp uses?(%Pad{sample: %Region{id: id}}, id), do: true
  defp uses?(_pad, _id), do: false

  defp put_pad(pads, index, nil), do: Map.delete(pads, index)
  defp put_pad(pads, index, pad), do: Map.put(pads, index, pad)

  # A sample (re)loaded: pads using it get their region in its frames again
  # (the engine's rate may have changed since they were set).
  defp loaded(s, id, {:ok, info}) do
    samples = Map.put(s.samples, id, info)

    for {index, pad} <- s.pads, uses?(pad, id) do
      with {:error, reason} <- apply_pad(index, pad, samples) do
        Logger.warning(
          "Magpie.Engine: pad #{index} after reloading #{inspect(id)}: #{inspect(reason)}"
        )
      end
    end

    %{s | samples: samples}
  end

  defp loaded(s, _id, {:error, _}), do: s

  defp apply_pad(index, pad, samples) do
    with {:ok, params} <- pad_params(pad, samples), do: Audio.impl().set_pad(index, params)
  end

  defp pad_params(nil, _samples), do: {:ok, nil}
  defp pad_params(%Pad{sample: nil}, _samples), do: {:ok, nil}

  defp pad_params(%Pad{sample: %Region{} = r} = pad, samples) do
    with {:ok, info} <- fetch_sample(samples, r.id),
         :ok <- check(:mode, pad.mode in @modes),
         :ok <- check(:choke, pad.choke in 0..3),
         :ok <- check(:midi_note, is_nil(pad.midi_note) or pad.midi_note in 0..127),
         :ok <- check(:gain_db, in_range?(r.gain_db, -48, 12)),
         :ok <- check(:pitch_st, in_range?(r.pitch_st, -24, 24)),
         :ok <- check(:fade_in_ms, in_range?(r.fade_in_ms, 0, 600_000)),
         :ok <- check(:fade_out_ms, in_range?(r.fade_out_ms, 0, 600_000)),
         :ok <- check(:reverse, is_boolean(r.reverse)),
         {:ok, first, last} <- region_frames(r, info) do
      {:ok,
       %{
         sample: r.id,
         start: first,
         end: last,
         gain_db: r.gain_db,
         pitch_st: r.pitch_st,
         reverse: r.reverse,
         fade_in_ms: r.fade_in_ms,
         fade_out_ms: r.fade_out_ms,
         mode: pad.mode,
         choke: pad.choke,
         root: pad.midi_note || 60
       }}
    end
  end

  defp fetch_sample(samples, id) do
    case Map.fetch(samples, id) do
      {:ok, info} -> {:ok, info}
      :error -> {:error, :unknown_sample}
    end
  end

  # The region in frames of the loaded sample; `end` 0 is to its end. A
  # region must keep at least one frame once rounded.
  defp region_frames(%Region{start: start, stop: stop}, %{frames: frames, rate: rate}) do
    cond do
      not in_range?(start, 0, :infinity) or round(start * rate) >= frames ->
        {:error, {:invalid, :start}}

      is_nil(stop) ->
        {:ok, round(start * rate), 0}

      not is_number(stop) or min(round(stop * rate), frames) <= round(start * rate) ->
        {:error, {:invalid, :stop}}

      true ->
        {:ok, round(start * rate), min(round(stop * rate), frames)}
    end
  end

  defp in_range?(x, lo, :infinity), do: is_number(x) and x >= lo
  defp in_range?(x, lo, hi), do: is_number(x) and x >= lo and x <= hi

  defp check(_field, true), do: :ok
  defp check(field, false), do: {:error, {:invalid, field}}

  # A kit pattern as the engine's flat list: straight ticks from the
  # pattern's start (step × 24 + tick, wrapped: step 0 tick -12 plays at
  # the very end), pads by index. Muted lanes are left out.
  defp compile(%Pattern{bank: bank, length: length, lanes: lanes}) do
    with :ok <- check(:bank, bank in @banks),
         :ok <- check(:length, length in [16, 32]),
         :ok <- check(:lanes, is_map(lanes)),
         {:ok, events} <- pattern_events(bank, length, lanes),
         :ok <- check(:steps, length(events) <= @max_events) do
      {:ok, %{length: length, events: Enum.sort(events)}}
    end
  end

  defp pattern_events(bank, length, lanes) do
    lanes
    |> Enum.reject(fn {_slot, lane} -> Map.get(lane, :mute, false) end)
    |> Enum.reduce_while({:ok, []}, fn {slot, lane}, {:ok, acc} ->
      case lane_events(bank, length, slot, Map.get(lane, :steps, [])) do
        {:ok, events} -> {:cont, {:ok, events ++ acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp lane_events(bank, length, slot, steps) when slot in 0..15 and is_list(steps) do
    pad = Kit.pad_index(bank, slot)

    Enum.reduce_while(steps, {:ok, []}, fn
      %Step{step: step, vel: vel, tick: tick, note: note}, {:ok, acc}
      when step in 0..(length - 1)//1 and vel in 1..127 and tick in -12..12 and
             (is_nil(note) or note in 0..127) ->
        {:cont, {:ok, [{Integer.mod(step * 24 + tick, length * 24), pad, vel, note} | acc]}}

      _step, _acc ->
        {:halt, {:error, {:invalid, {:step, slot}}}}
    end)
  end

  defp lane_events(_bank, _length, slot, _steps), do: {:error, {:invalid, {:lane, slot}}}
end
