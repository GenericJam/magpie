defmodule Magpie.Audio.Fake do
  @moduledoc """
  `Magpie.Audio` for host tests (`config :magpie, :audio`): no sound, the
  test drives time.

  Like the phone it is one engine for the whole VM: `open/1` makes the
  caller the owner, control calls from anyone else answer
  `{:error, :not_owner}`, live calls work from any process. Tests that use
  it therefore don't run `async`.

  It reads WAV files (`Magpie.Wav`) for `load_sample/2` and `decode/1`
  (anything else is `:unsupported`) and reports the frames, channels and
  peaks the phone would (resampled lengths at 48 kHz). Messages go to the
  owner as on the phone:

  - a loaded sample at once (`{:magpie_audio, :loaded, id, result}`);
  - live calls: `:voice` starts and ends per pad as on the phone (keys
    pads per note: releasing one note keeps the pad sounding while another
    is held; one-shot voices end only with `finish/1`), and a `:hit` while
    playing, stamped at the current position (nearest step, tick from it).
    `quantize:` starts at once;
  - the sequencer moves only with `advance/1` (steps) or `advance_ticks/1`:
    `:playhead` on each step, a pattern queued for the bar takes over there
    (`:pattern`, then step 0), steps start voices (gate, loop and keys pads
    for one step; stopping ends them). Swing isn't modelled: frames and
    gates follow the tempo in straight time.

  ## Input and recording

  `input_open/1` sends `:started` at once (48 kHz; the mic mono, other
  apps stereo) unless `fail_input/1` armed a failure, which closes it
  instead (`{:input, :closed, reason}`, as a refused consent does);
  `end_input/1` closes it as the system would. Audio arrives only through
  `feed/1`: interleaved f32le at the input's channels. Each call is one
  meter period: it runs the recorder over the frames and sends one
  `:meter` (the fed frames' peak dBFS; new peak bytes, one per 256
  recorded frames, the partial block flushed on stop, as the C does).

  The recorder: `:now` records from the next fed frame; `:on_sound`
  starts at the first frame with any |x| ≥ 10^(threshold_db / 20),
  keeping up to `pre_roll_ms` of what was fed since arming; `:count_in`
  needs the output (`{:error, :not_running}` without it), sends
  `:count_in` from the current frame to four beats later at the fake's
  tempo and records only after `downbeat/0` (no pre-roll). At
  `max_seconds` it sends `:full` and takes no more. `record_stop/0`
  without a recorded frame is `{:error, :not_started}`.
  """

  @behaviour Magpie.Audio

  use GenServer

  alias Magpie.Kit.Step
  alias Magpie.Wav

  @rate 48_000
  @peak_frames 256

  # ── Magpie.Audio ──────────────────────────────────────────────────────────

  @impl Magpie.Audio
  def open(owner) when is_pid(owner), do: call({:open, owner})

  @impl Magpie.Audio
  def close, do: call(:close)

  @impl Magpie.Audio
  def reset, do: call(:reset)

  @impl Magpie.Audio
  def load_sample(id, path), do: call({:load, id, {:file, path}})

  @impl Magpie.Audio
  def load_pcm(id, pcm, rate, channels) when is_binary(pcm),
    do: call({:load, id, {:pcm, pcm, rate, channels}})

  @impl Magpie.Audio
  def decode(path) do
    with {:ok, pcm, rate, channels} <- read_wav(path) do
      frames = div(byte_size(pcm), 4 * channels)

      {:ok,
       %{
         pcm: pcm,
         rate: rate,
         channels: channels,
         frames: frames,
         peaks: peaks(pcm, channels, frames, frames),
         peak_frames: @peak_frames
       }}
    end
  end

  @impl Magpie.Audio
  def unload_sample(id), do: call({:unload, id})

  @impl Magpie.Audio
  def set_pad(pad, params), do: call({:set_pad, pad, params})

  @impl Magpie.Audio
  def set_pattern(pattern, at), do: call({:set_pattern, pattern, at})

  @impl Magpie.Audio
  def set_tempo(bpm), do: call({:tempo, bpm})

  @impl Magpie.Audio
  def set_swing(swing), do: call({:swing, swing})

  @impl Magpie.Audio
  def play, do: call(:play)

  @impl Magpie.Audio
  def stop, do: call(:stop)

  @impl Magpie.Audio
  def trigger(pad, velocity, quantize), do: call({:live, {:trigger, pad, velocity, quantize}})

  @impl Magpie.Audio
  def release(pad), do: call({:live, {:release, pad}})

  @impl Magpie.Audio
  def note_on(pad, note, velocity), do: call({:live, {:note_on, pad, note, velocity}})

  @impl Magpie.Audio
  def note_off(pad, note), do: call({:live, {:note_off, pad, note}})

  @impl Magpie.Audio
  def clock, do: call(:clock)

  @impl Magpie.Audio
  def info, do: call(:info)

  @impl Magpie.Audio
  def input_open(source) when source in [:mic, :apps], do: call({:input_open, source})

  @impl Magpie.Audio
  def input_close, do: call(:input_close)

  @impl Magpie.Audio
  def record_start(%{mode: _, max_seconds: _, threshold_db: _, pre_roll_ms: _} = opts),
    do: call({:record_start, opts})

  @impl Magpie.Audio
  def record_stop, do: call(:record_stop)

  @impl Magpie.Audio
  def record_cancel, do: call(:record_cancel)

  # ── Driving it from a test ────────────────────────────────────────────────

  @doc "Run the sequencer `steps` 16th notes on."
  def advance(steps) when is_integer(steps) and steps >= 0, do: call({:advance, steps * 24})

  @doc "Run the sequencer `ticks` (96 PPQN) on."
  def advance_ticks(ticks) when is_integer(ticks) and ticks >= 0, do: call({:advance, ticks})

  @doc "End `pad`'s voices (`{:magpie_audio, :voice, pad, :end}`), as a one-shot reaching its end."
  def finish(pad), do: call({:finish, pad})

  @doc "Live calls so far, oldest first: `{:trigger, pad, velocity, quantize}`, `{:release, pad}`, …"
  def calls, do: call(:calls)

  @doc "What the engine holds: owner, samples, pads (engine params), pattern, pending, tempo, swing, playing."
  def state, do: call(:state)

  @doc "Make the next `open/1` fail with `reason` (nil: succeed again)."
  def fail_open(reason), do: call({:fail_open, reason})

  @doc "Make the next `input_open/1` close at once with `reason` (`:denied`: the consent refused)."
  def fail_input(reason), do: call({:fail_input, reason})

  @doc "The system closes the open input with `reason` (`:stopped`, `:disconnected`, …)."
  def end_input(reason), do: call({:end_input, reason})

  @doc """
  Audio into the open input: interleaved f32le at its channels (mic 1,
  apps 2). One meter period: runs the recorder, then sends one `:meter`.
  """
  def feed(pcm) when is_binary(pcm), do: call({:feed, pcm})

  @doc "The count-in's downbeat: a counting recorder starts recording."
  def downbeat, do: call(:downbeat)

  # ── Server ────────────────────────────────────────────────────────────────

  defp call(request) do
    pid =
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.call(pid, request)
  end

  defp fresh(owner, open, fail_open) do
    %{
      owner: owner,
      open: open,
      fail_open: fail_open,
      fail_input: nil,
      input: nil,
      rec: nil,
      samples: %{},
      pads: %{},
      pattern: nil,
      pattern_number: 0,
      pending: nil,
      tempo: 120,
      swing: 0.5,
      playing: false,
      local: 0,
      ticks: 0,
      play_frame: 0,
      sounding: %{},
      gated: [],
      calls: []
    }
  end

  @impl GenServer
  def init(nil), do: {:ok, fresh(nil, false, nil)}

  @impl GenServer
  def handle_call({:open, owner}, _from, %{fail_open: nil} = s),
    do:
      {:reply, {:ok, %{rate: @rate, burst: 192, buffer_frames: 384, low_latency: true}},
       %{s | owner: owner, open: true}}

  def handle_call({:open, owner}, _from, s),
    do: {:reply, {:error, s.fail_open}, %{s | owner: owner, open: false}}

  def handle_call({:fail_open, reason}, _from, s), do: {:reply, :ok, %{s | fail_open: reason}}
  def handle_call(:calls, _from, s), do: {:reply, Enum.reverse(s.calls), s}
  def handle_call(:state, _from, s), do: {:reply, Map.drop(s, [:calls, :fail_open]), s}
  def handle_call(:info, _from, s), do: {:reply, info(s), s}

  def handle_call(:clock, _from, %{open: true} = s),
    do: {:reply, %{frame: frame(s), time: System.monotonic_time(:nanosecond), rate: @rate}, s}

  def handle_call(:clock, _from, s), do: {:reply, nil, s}

  def handle_call({:live, call}, _from, %{open: false} = s),
    do: {:reply, {:error, :not_running}, %{s | calls: [call | s.calls]}}

  def handle_call({:live, call}, _from, s),
    do: {:reply, :ok, live(%{s | calls: [call | s.calls]}, call)}

  def handle_call({:finish, pad}, _from, s), do: {:reply, :ok, voice_end(s, pad, :all)}

  def handle_call({:advance, ticks}, _from, s), do: {:reply, :ok, advance(s, ticks)}

  def handle_call({:fail_input, reason}, _from, s), do: {:reply, :ok, %{s | fail_input: reason}}

  def handle_call({:end_input, _reason}, _from, %{input: nil} = s),
    do: {:reply, {:error, :no_input}, s}

  def handle_call({:end_input, reason}, _from, s) do
    send(s.owner, {:magpie_audio, :input, :closed, reason})
    {:reply, :ok, %{s | input: nil, rec: nil}}
  end

  def handle_call({:feed, _pcm}, _from, %{input: nil} = s), do: {:reply, {:error, :no_input}, s}
  def handle_call({:feed, pcm}, _from, s), do: {:reply, :ok, feed(s, pcm)}

  def handle_call(:downbeat, _from, %{rec: %{state: :counting} = rec} = s) do
    send(s.owner, {:magpie_audio, :record, :started, %{pre_roll_frames: 0, late_frames: 0}})
    {:reply, :ok, %{s | rec: %{rec | state: :recording}}}
  end

  def handle_call(:downbeat, _from, s), do: {:reply, {:error, :not_counting}, s}

  def handle_call(_request, {pid, _}, %{owner: owner} = s) when pid != owner,
    do: {:reply, {:error, :not_owner}, s}

  def handle_call(:close, _from, s), do: {:reply, :ok, %{s | open: false}}

  def handle_call(:reset, _from, s),
    do: {:reply, :ok, %{fresh(s.owner, s.open, s.fail_open) | fail_input: s.fail_input}}

  def handle_call({:input_open, source}, _from, %{fail_input: nil} = s) do
    channels = if source == :mic, do: 1, else: 2
    info = %{source: source, rate: @rate, channels: channels}
    send(s.owner, {:magpie_audio, :input, :started, info})
    {:reply, :ok, %{s | input: info, rec: nil}}
  end

  def handle_call({:input_open, _source}, _from, s) do
    send(s.owner, {:magpie_audio, :input, :closed, s.fail_input})
    {:reply, :ok, %{s | input: nil, rec: nil, fail_input: nil}}
  end

  def handle_call(:input_close, _from, s), do: {:reply, :ok, %{s | input: nil, rec: nil}}

  def handle_call({:record_start, _opts}, _from, %{input: nil} = s),
    do: {:reply, {:error, :no_input}, s}

  def handle_call({:record_start, _opts}, _from, %{rec: %{}} = s),
    do: {:reply, {:error, :recording}, s}

  def handle_call({:record_start, %{mode: :count_in}}, _from, %{open: false} = s),
    do: {:reply, {:error, :not_running}, s}

  def handle_call({:record_start, opts}, _from, s), do: {:reply, :ok, arm(s, opts)}

  def handle_call(:record_stop, _from, %{rec: nil} = s), do: {:reply, {:error, :not_recording}, s}

  def handle_call(:record_stop, _from, %{rec: %{frames: 0}} = s),
    do: {:reply, {:error, :not_started}, %{s | rec: nil}}

  def handle_call(:record_stop, _from, %{rec: rec} = s) do
    tail = if rec.acc_n > 0, do: <<peak_byte(rec.acc_peak)>>, else: <<>>

    recording = %{
      pcm: rec.pcm,
      rate: @rate,
      channels: s.input.channels,
      frames: rec.frames,
      peaks: rec.peaks <> tail,
      peak_frames: @peak_frames
    }

    {:reply, {:ok, recording}, %{s | rec: nil}}
  end

  def handle_call(:record_cancel, _from, s), do: {:reply, :ok, %{s | rec: nil}}

  def handle_call({:load, id, source}, _from, s) do
    result = load(source)
    send(s.owner, {:magpie_audio, :loaded, id, result})

    samples =
      case result do
        {:ok, info} -> Map.put(s.samples, id, info)
        {:error, _} -> s.samples
      end

    {:reply, :ok, %{s | samples: samples}}
  end

  def handle_call({:unload, id}, _from, s) do
    if Map.has_key?(s.samples, id) do
      pads = Map.reject(s.pads, fn {_, p} -> p.sample == id end)
      {:reply, :ok, %{s | samples: Map.delete(s.samples, id), pads: pads}}
    else
      {:reply, {:error, :unknown_sample}, s}
    end
  end

  def handle_call({:set_pad, pad, nil}, _from, s),
    do: {:reply, :ok, %{s | pads: Map.delete(s.pads, pad)}}

  def handle_call({:set_pad, pad, params}, _from, s) do
    if Map.has_key?(s.samples, params.sample),
      do: {:reply, :ok, %{s | pads: Map.put(s.pads, pad, params)}},
      else: {:reply, {:error, :unknown_sample}, s}
  end

  def handle_call({:set_pattern, pattern, at}, _from, s) do
    number = s.pattern_number + 1
    s = %{s | pattern_number: number}

    s =
      if s.playing and at == :bar do
        %{s | pending: {number, pattern}}
      else
        send(s.owner, {:magpie_audio, :pattern, number, frame(s)})
        %{s | pattern: pattern, pending: nil, local: rem(s.local, length_ticks(pattern))}
      end

    {:reply, {:ok, number}, s}
  end

  def handle_call({:tempo, bpm}, _from, s), do: {:reply, :ok, %{s | tempo: bpm}}
  def handle_call({:swing, swing}, _from, s), do: {:reply, :ok, %{s | swing: swing}}

  def handle_call(:play, _from, %{playing: true} = s), do: {:reply, :ok, s}

  def handle_call(:play, _from, s) do
    s = %{s | playing: true, local: 0, ticks: 0, play_frame: frame(s)}
    {:reply, :ok, at_tick(s)}
  end

  def handle_call(:stop, _from, s) do
    s =
      case s.pending do
        {number, pattern} ->
          send(s.owner, {:magpie_audio, :pattern, number, frame(s)})
          %{s | pattern: pattern, pending: nil}

        nil ->
          s
      end

    s = Enum.reduce(s.gated, s, fn {pad, key, _}, acc -> voice_end(acc, pad, key) end)
    {:reply, :ok, %{s | gated: [], playing: false, play_frame: frame(s), ticks: 0, local: 0}}
  end

  # ── Voices ────────────────────────────────────────────────────────────────
  #
  # `sounding` maps a pad to the keys of its voices: a note (keys mode), :hit
  # (a live trigger), {:seq, ref} (a sequenced step). A pad's first voice
  # sends :start, every later one too; its last one ending sends :end.

  defp live(s, {:trigger, pad, velocity, _quantize}), do: start(s, pad, velocity, nil)
  defp live(s, {:note_on, pad, note, velocity}), do: start(s, pad, velocity, note)
  defp live(s, {:release, pad}), do: release(s, pad, :all)
  defp live(s, {:note_off, pad, note}), do: release(s, pad, note)

  defp start(s, pad, velocity, note) do
    case s.pads[pad] do
      nil ->
        s

      %{mode: :keys, root: root} ->
        hit(s, pad, velocity, note || root)
        voice_start(s, pad, note || root)

      %{mode: :toggle} ->
        hit(s, pad, velocity, nil)
        toggle(s, pad)

      _ ->
        hit(s, pad, velocity, nil)
        voice_start(s, pad, :hit)
    end
  end

  # Gate and loop pads stop on release (or any note-off); keys pads on their
  # note's (a release: all of them).
  defp release(s, pad, note) do
    case s.pads[pad] do
      %{mode: :keys} -> voice_end(s, pad, note)
      %{mode: mode} when mode in [:gate, :loop] -> voice_end(s, pad, :all)
      _ -> s
    end
  end

  defp toggle(s, pad) do
    if Map.has_key?(s.sounding, pad), do: voice_end(s, pad, :all), else: voice_start(s, pad, :hit)
  end

  defp hit(%{playing: true} = s, pad, velocity, note) do
    steps = div(length_ticks(s.pattern), 24)
    step = div(s.local + 12, 24)

    send(
      s.owner,
      {:magpie_audio, :hit, pad,
       %Step{step: rem(step, steps), vel: velocity, tick: s.local - step * 24, note: note}}
    )
  end

  defp hit(_s, _pad, _velocity, _note), do: :ok

  defp voice_start(s, pad, key) do
    send(s.owner, {:magpie_audio, :voice, pad, :start})
    %{s | sounding: Map.update(s.sounding, pad, MapSet.new([key]), &MapSet.put(&1, key))}
  end

  defp voice_end(s, pad, key) do
    keys = Map.get(s.sounding, pad, MapSet.new())
    left = if key == :all, do: MapSet.new(), else: MapSet.delete(keys, key)

    cond do
      MapSet.size(keys) == 0 ->
        s

      MapSet.size(left) == 0 ->
        send(s.owner, {:magpie_audio, :voice, pad, :end})
        %{s | sounding: Map.delete(s.sounding, pad)}

      true ->
        %{s | sounding: Map.put(s.sounding, pad, left)}
    end
  end

  # ── The sequencer ─────────────────────────────────────────────────────────

  defp length_ticks(nil), do: 16 * 24
  defp length_ticks(%{length: steps}), do: steps * 24

  defp frame(%{playing: false} = s), do: s.play_frame
  defp frame(s), do: s.play_frame + ceil(s.ticks * 60 * @rate / (s.tempo * 96))

  defp advance(%{playing: false} = s, _ticks), do: s
  defp advance(s, 0), do: s

  defp advance(s, ticks) do
    s = %{s | ticks: s.ticks + 1, local: s.local + 1}

    s =
      case s.pending do
        {number, pattern} when rem(s.ticks, 384) == 0 ->
          send(s.owner, {:magpie_audio, :pattern, number, frame(s)})
          %{s | pattern: pattern, pending: nil, local: 0}

        _ ->
          %{s | local: rem(s.local, length_ticks(s.pattern))}
      end

    s |> at_tick() |> end_gates() |> advance(ticks - 1)
  end

  # What sounds at the current tick: the playhead on a step, the pattern's
  # events there.
  defp at_tick(s) do
    if rem(s.local, 24) == 0,
      do: send(s.owner, {:magpie_audio, :playhead, div(s.local, 24), frame(s)})

    events = if s.pattern, do: s.pattern.events, else: []

    Enum.reduce(events, s, fn
      {pos, pad, _vel, _note}, acc when pos == s.local -> seq_start(acc, pad)
      _, acc -> acc
    end)
  end

  # A step: gate, loop and keys pads sound for one step (straight: swing
  # isn't modelled), toggle pads toggle, one-shots ring until `finish/1`.
  defp seq_start(s, pad) do
    case s.pads[pad] do
      nil ->
        s

      %{mode: :toggle} ->
        toggle(s, pad)

      %{mode: mode} ->
        key = {:seq, make_ref()}
        s = voice_start(s, pad, key)

        if mode in [:gate, :loop, :keys],
          do: %{s | gated: [{pad, key, s.ticks + 24} | s.gated]},
          else: s
    end
  end

  defp end_gates(s) do
    {due, gated} = Enum.split_with(s.gated, fn {_, _, at} -> at <= s.ticks end)
    Enum.reduce(due, %{s | gated: gated}, fn {pad, key, _}, acc -> voice_end(acc, pad, key) end)
  end

  # ── Samples ───────────────────────────────────────────────────────────────

  defp load({:file, path}) do
    with {:ok, pcm, rate, channels} <- read_wav(path), do: from_pcm(pcm, rate, channels)
  end

  defp load({:pcm, pcm, rate, channels}) do
    keep = min(channels, 2)
    from_pcm(first_channels(pcm, channels, keep), rate, keep)
  end

  defp from_pcm(pcm, rate, channels) do
    source_frames = div(byte_size(pcm), 4 * channels)
    frames = if rate == @rate, do: source_frames, else: trunc(source_frames * @rate / rate)

    if frames == 0 do
      {:error, :no_audio}
    else
      {:ok,
       %{
         frames: frames,
         channels: channels,
         rate: @rate,
         peaks: peaks(pcm, channels, source_frames, frames),
         peak_frames: @peak_frames,
         bytes: frames * channels * 2,
         source_rate: rate,
         load_ms: 0.0
       }}
    end
  end

  defp read_wav(path) do
    with {:ok, bin} <- read_file(path),
         {:ok, %{rate: rate, channels: channels}, pcm} <- wav(bin) do
      keep = min(channels, 2)
      {:ok, first_channels(pcm, channels, keep), rate, keep}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp wav(bin) do
    case Wav.decode(bin) do
      {:ok, info, pcm} -> {:ok, info, pcm}
      {:error, _} -> {:error, :unsupported}
    end
  end

  defp first_channels(pcm, channels, channels), do: pcm

  defp first_channels(pcm, channels, keep) do
    size = channels * 4
    for <<frame::binary-size(^size) <- pcm>>, into: <<>>, do: binary_part(frame, 0, keep * 4)
  end

  # One byte per 256 frames at the engine's rate (`frames` of them), each
  # the largest |x| over the source frames it covers, 255 = full scale.
  defp peaks(pcm, channels, source_frames, frames) do
    levels = for <<x::float-32-little <- pcm>>, do: abs(x)
    per_frame = levels |> Enum.chunk_every(channels) |> Enum.map(&Enum.max/1) |> List.to_tuple()
    count = div(frames + @peak_frames - 1, @peak_frames)

    for p <- 0..(count - 1)//1, into: <<>> do
      from = div(p * @peak_frames * source_frames, frames)
      to = min(div((p + 1) * @peak_frames * source_frames, frames), source_frames)
      peak = Enum.reduce(from..(to - 1)//1, 0.0, &max(elem(per_frame, &1), &2))
      <<min(round(peak * 255), 255)>>
    end
  end

  # ── The recorder ──────────────────────────────────────────────────────────

  defp arm(s, opts) do
    rec = %{
      mode: opts.mode,
      state: :recording,
      max_frames: round(opts.max_seconds * @rate),
      threshold: :math.pow(10, opts.threshold_db / 20),
      pre_roll: round(opts.pre_roll_ms * @rate / 1000),
      ring: <<>>,
      pcm: <<>>,
      frames: 0,
      acc_peak: 0.0,
      acc_n: 0,
      peaks: <<>>,
      new: <<>>
    }

    case opts.mode do
      :now ->
        send(s.owner, {:magpie_audio, :record, :started, %{pre_roll_frames: 0, late_frames: 0}})
        %{s | rec: rec}

      :on_sound ->
        %{s | rec: %{rec | state: :waiting}}

      :count_in ->
        first = frame(s)
        send(s.owner, {:magpie_audio, :count_in, first, first + round(4 * 60 * @rate / s.tempo)})
        %{s | rec: %{rec | state: :counting}}
    end
  end

  defp feed(s, pcm) do
    size = 4 * s.input.channels
    pcm = binary_part(pcm, 0, byte_size(pcm) - rem(byte_size(pcm), size))
    rec = if s.rec, do: record(s, s.rec, pcm, size)

    meter =
      case rec do
        nil -> %{state: :idle, frames: 0, peaks: <<>>}
        rec -> %{state: rec.state, frames: rec.frames, peaks: rec.new}
      end

    send(s.owner, {:magpie_audio, :meter, level_db(pcm), meter})
    %{s | rec: rec && %{rec | new: <<>>}}
  end

  defp record(s, %{state: :waiting} = rec, pcm, size) do
    case first_loud(pcm, rec.threshold, size) do
      nil ->
        %{rec | ring: last_bytes(rec.ring <> pcm, rec.pre_roll * size)}

      at ->
        bytes = at * size
        <<before::binary-size(^bytes), rest::binary>> = pcm
        pre = last_bytes(rec.ring <> before, rec.pre_roll * size)
        started = %{pre_roll_frames: div(byte_size(pre), size), late_frames: 0}
        send(s.owner, {:magpie_audio, :record, :started, started})
        append(s, %{rec | state: :recording, ring: <<>>}, pre <> rest, size)
    end
  end

  defp record(s, %{state: :recording} = rec, pcm, size), do: append(s, rec, pcm, size)
  defp record(_s, rec, _pcm, _size), do: rec

  # Up to max_frames; reaching it sends :full once and takes no more.
  defp append(s, rec, pcm, size) do
    take = min(rec.max_frames - rec.frames, div(byte_size(pcm), size))
    chunk = binary_part(pcm, 0, take * size)
    rec = add_peaks(%{rec | pcm: rec.pcm <> chunk, frames: rec.frames + take}, chunk, size)

    if rec.frames >= rec.max_frames do
      send(s.owner, {:magpie_audio, :record, :full, rec.frames})
      %{rec | state: :full}
    else
      rec
    end
  end

  defp add_peaks(rec, chunk, size) do
    {peak, n, bytes} =
      for <<frame::binary-size(^size) <- chunk>>, reduce: {rec.acc_peak, rec.acc_n, []} do
        {peak, n, bytes} ->
          peak = max(peak, frame_peak(frame))

          if n + 1 == @peak_frames,
            do: {0.0, 0, [peak_byte(peak) | bytes]},
            else: {peak, n + 1, bytes}
      end

    new = bytes |> Enum.reverse() |> :binary.list_to_bin()
    %{rec | acc_peak: peak, acc_n: n, peaks: rec.peaks <> new, new: rec.new <> new}
  end

  defp first_loud(pcm, threshold, size) do
    Enum.find_index(for(<<frame::binary-size(^size) <- pcm>>, do: frame), fn frame ->
      frame_peak(frame) >= threshold
    end)
  end

  defp frame_peak(frame),
    do: Enum.reduce(for(<<x::float-32-little <- frame>>, do: abs(x)), 0.0, &max/2)

  defp peak_byte(peak), do: min(round(peak * 255), 255)

  defp last_bytes(bin, n) when byte_size(bin) <= n, do: bin
  defp last_bytes(bin, n), do: binary_part(bin, byte_size(bin) - n, n)

  defp level_db(pcm) do
    case frame_peak(pcm) do
      peak when peak > 0 -> max(20 * :math.log10(peak), -120.0)
      _ -> -120.0
    end
  end

  defp info(s) do
    %{
      running: s.open,
      rate: @rate,
      burst: 192,
      buffer_frames: 384,
      samples: map_size(s.samples),
      sample_bytes: s.samples |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum(),
      voices_active: s.sounding |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.sum(),
      playing: s.playing,
      frame: frame(s)
    }
  end
end
