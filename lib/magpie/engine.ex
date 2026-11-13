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

  and the input and recording messages of `Magpie.Audio` (see
  "Recording" below), each tagged with the input or the take it is about:

      {:magpie_audio, :input, input, :started, %{source, rate, channels}}
      {:magpie_audio, :input, input, :closed, reason}   # :denied, :disconnected, :stopped, :error
      {:magpie_audio, :meter, input, level_db, %{take, state, frames, peaks}}  # ~40 ms while an input is open
      {:magpie_audio, :record, take, :started, %{pre_roll_frames, late_frames}}
      {:magpie_audio, :record, take, :full, frames}    # max length reached
      {:magpie_audio, :count_in, take, first_frame, until_frame}

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

  ## Recording

  `open_input(:mic | :apps)` closes any input and opens this one,
  answering `{:ok, input}` (an id the input's messages carry), and
  monitors the caller: when it exits the input closes, so the mic is
  never left on by a screen that went away. `state/0`'s `input` follows
  it (`:opening`, then `:open` with its rate and channels; nil once
  closed; `:closing` while a mic stream that wouldn't stop is being
  closed again, every second and slower, until it is released). If the
  new source can't open, what was open is closed all the same: the
  input is nil. Meters arrive every ~40 ms while it is open: `level_db`
  (peak dBFS) and, while a take is armed, the take, its frames so far and
  the new peak bytes (append them for the waveform). `record/1` arms the
  recorder (`:now`, `:on_sound` above a threshold with a pre-roll,
  `:count_in` one bar of clicks first) and answers `{:ok, take}`;
  `stop_recording/0` returns `t:Magpie.Audio.recording/0` (f32le at the
  input's rate plus peaks, ready for `Magpie.Library.put_pcm/2`);
  `cancel_recording/0` drops it. Messages about an input or a take that
  is over (still queued when the next one began) are dropped here, and a
  subscriber matches the ids it was given for the same reason.
  """

  use GenServer

  require Logger

  alias Magpie.{Audio, Kit}
  alias Magpie.Kit.{Pad, Pattern, Region, Step}

  @load_timeout 120_000
  @record_defaults %{mode: :now, max_seconds: 60, threshold_db: -30, pre_roll_ms: 150}
  @close_retry_ms 1_000
  @close_retry_max_ms 30_000
  # state/0's input while a close is retried and nothing else was known.
  @closing %{id: nil, source: nil, status: :closing, rate: nil, channels: nil}
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
            subscribers: %{},
            input: nil,
            input_ref: nil,
            take: nil,
            close_retry_ms: @close_retry_ms,
            close_backoff: @close_retry_ms,
            retry: nil

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Start the Engine. `close_retry_ms:` (1000) is the first wait before a
  mic that wouldn't stop is closed again (doubling, up to 30 s).
  """
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

  `stop: true`: the pad's sounding voices fade (each by its own release)
  and its quantized launches still waiting are dropped, in the same step
  as the change and with no output stream too, whatever the old or new
  mode (a later `release/1` would go by the new mode, and a second trigger
  would start a toggle that has already ended). An error changes nothing.
  """
  @spec set_pad(Audio.pad(), Pad.t() | nil, keyword()) :: :ok | {:error, term()}
  def set_pad(index, pad, opts \\ [])
      when index in 0..63 and (is_nil(pad) or is_struct(pad, Pad)),
      do: GenServer.call(__MODULE__, {:set_pad, index, pad, Keyword.get(opts, :stop, false)})

  def clear_pad(index, opts \\ []) when index in 0..63, do: set_pad(index, nil, opts)

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

  @doc "`%{playing, step, tempo, swing, pattern, pending, stream, input}`."
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

  @doc """
  Close any input, then open `:mic` or `:apps` (what other apps play; the
  phone asks the user first). `{:ok, input}` means it is opening:
  `{:magpie_audio, :input, input, :started, info}` or `{:magpie_audio,
  :input, input, :closed, reason}` follows. An error after the close
  leaves no input (`:input_stuck`: the old mic wouldn't stop; the Engine
  keeps closing it). The input closes when the caller exits.
  """
  @spec open_input(:mic | :apps) :: {:ok, Audio.input()} | {:error, term()}
  def open_input(source) when source in [:mic, :apps],
    do: GenServer.call(__MODULE__, {:open_input, source, self()})

  def open_input(_source), do: {:error, {:invalid, :source}}

  @doc """
  Close the input (a recording in progress is dropped). `{:error,
  :input_stuck}`: the mic stream wouldn't stop; it is closed to every
  screen and the Engine tries again on its own until it is released.
  """
  @spec close_input() :: :ok | {:error, term()}
  def close_input, do: GenServer.call(__MODULE__, :close_input)

  @doc """
  Arm the recorder on the open input. Options: `mode:` `:now` (default),
  `:on_sound` (from the first sound at or above `threshold_db:`, -90..0,
  default -30, keeping `pre_roll_ms:`, 0..500, default 150, from before
  it) or `:count_in` (after one bar of clicks; needs the output stream);
  `max_seconds:` 1..300, default 60. `{:ok, take}`: the id the take's
  messages carry. `{:error, {:invalid, field}}` for a bad option, else
  the engine's answer (`:no_input`, `:recording`, `:not_running`,
  `:alloc`).
  """
  @spec record(keyword()) :: {:ok, Audio.take()} | {:error, term()}
  def record(opts \\ []) do
    with {:ok, params} <- record_params(opts),
         do: GenServer.call(__MODULE__, {:record, params})
  end

  @doc """
  Stop and take the recording: `{:ok, recording}` (`t:Magpie.Audio.recording/0`)
  or `{:error, :not_recording | :not_started}` (armed, but it never
  began). The recorder is disarmed either way.
  """
  @spec stop_recording() :: {:ok, Audio.recording()} | {:error, term()}
  def stop_recording, do: GenServer.call(__MODULE__, :stop_recording, @load_timeout)

  @doc "Disarm the recorder and drop what it recorded."
  @spec cancel_recording() :: :ok | {:error, term()}
  def cancel_recording, do: GenServer.call(__MODULE__, :cancel_recording)

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
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

    retry = Keyword.get(opts, :close_retry_ms, @close_retry_ms)
    s = %__MODULE__{stream: stream, close_retry_ms: retry, close_backoff: retry}

    # A restarted engine never inherits an open input (the mic stays off).
    {_, s} = close_input(s)
    {:ok, s}
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

  def handle_call({:set_pad, index, pad, stop}, _from, s) do
    case apply_pad(index, pad, s.samples, stop) do
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
       stream: s.stream,
       input: s.input
     }, s}
  end

  def handle_call({:open_input, source, pid}, _from, s) do
    case Audio.impl().input_open(source) do
      {:ok, id} ->
        input = %{id: id, source: source, status: :opening, rate: nil, channels: nil}
        s = drop_input(s)
        {:reply, {:ok, id}, %{s | input: input, input_ref: Process.monitor(pid)}}

      {:error, :not_owner} = error ->
        {:reply, error, s}

      {:error, :input_stuck} = error ->
        {:reply, error, stuck(s)}

      # What was open was closed before the new source failed.
      {:error, _} = error ->
        {:reply, error, drop_input(s)}
    end
  end

  def handle_call(:close_input, _from, s) do
    {result, s} = close_input(s)
    {:reply, result, s}
  end

  def handle_call({:record, params}, _from, s) do
    case Audio.impl().record_start(params) do
      {:ok, take} -> {:reply, {:ok, take}, %{s | take: take}}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  # The recording passed through this process: hibernating frees it now.
  def handle_call(:stop_recording, _from, s),
    do: {:reply, Audio.impl().record_stop(), %{s | take: nil}, :hibernate}

  def handle_call(:cancel_recording, _from, s),
    do: {:reply, Audio.impl().record_cancel(), %{s | take: nil}}

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

  # Input and recording messages count only for the current input and take:
  # one about an earlier one (queued before it closed) is dropped.
  def handle_info(
        {:magpie_audio, :input, id, :started, info} = msg,
        %{input: %{id: id, status: :opening}} = s
      ) do
    forward(s, msg)
    {:noreply, %{s | input: Map.merge(s.input, Map.put(info, :status, :open))}}
  end

  # The native side marks the source closed; input_close/0 releases the
  # stream and stops the capture service (or, stuck, is tried again).
  def handle_info(
        {:magpie_audio, :input, id, :closed, _reason} = msg,
        %{input: %{id: id, status: status}} = s
      )
      when status in [:opening, :open] do
    {_, s} = close_input(s)
    forward(s, msg)
    {:noreply, s}
  end

  def handle_info({:magpie_audio, :meter, id, _, _} = msg, %{input: %{id: id}} = s) do
    forward(s, msg)
    {:noreply, s}
  end

  def handle_info({:magpie_audio, kind, take, _, _} = msg, %{take: take} = s)
      when kind in [:record, :count_in] and take != nil do
    forward(s, msg)
    {:noreply, s}
  end

  def handle_info({:magpie_audio, kind, _, _, _}, s)
      when kind in [:input, :meter, :record, :count_in],
      do: {:noreply, s}

  def handle_info({:magpie_audio, kind, _, _} = msg, s) when kind in [:voice, :hit] do
    forward(s, msg)
    {:noreply, s}
  end

  def handle_info({:retry_close, ref}, %{retry: ref} = s) when ref != nil do
    {_, s} = close_input(s)
    {:noreply, s}
  end

  def handle_info({:retry_close, _ref}, s), do: {:noreply, s}

  # The input's opener exited: the mic goes off with it.
  def handle_info({:DOWN, ref, :process, _pid, _}, %{input_ref: ref} = s) when ref != nil,
    do: {:noreply, s |> close_input() |> elem(1)}

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # A mic stream that won't stop is closed to everyone (the native side
  # takes no more from it) but not released: the Engine closes it again
  # later, on its own, whoever asked.
  defp close_input(s) do
    case Audio.impl().input_close() do
      :ok ->
        {:ok, drop_input(s)}

      {:error, :input_stuck} = error ->
        {error, stuck(s)}

      {:error, reason} = error ->
        Logger.warning("Magpie.Engine: closing the input: #{inspect(reason)}")
        {error, s}
    end
  end

  defp drop_input(s) do
    if s.input_ref, do: Process.demonitor(s.input_ref, [:flush])

    %{
      s
      | input: nil,
        input_ref: nil,
        take: nil,
        retry: nil,
        close_backoff: s.close_retry_ms
    }
  end

  defp stuck(s) do
    Logger.warning(
      "Magpie.Engine: the input wouldn't close; trying again in #{s.close_backoff} ms"
    )

    if s.input_ref, do: Process.demonitor(s.input_ref, [:flush])
    retry = make_ref()
    Process.send_after(self(), {:retry_close, retry}, s.close_backoff)

    %{
      s
      | input: %{(s.input || @closing) | status: :closing},
        input_ref: nil,
        take: nil,
        retry: retry,
        close_backoff: min(s.close_backoff * 2, @close_retry_max_ms)
    }
  end

  defp record_params(opts) do
    Enum.reduce_while(opts, {:ok, @record_defaults}, fn {key, value}, {:ok, params} ->
      if record_opt?(key, value),
        do: {:cont, {:ok, Map.put(params, key, value)}},
        else: {:halt, {:error, {:invalid, key}}}
    end)
  end

  defp record_opt?(:mode, mode), do: mode in [:now, :on_sound, :count_in]
  defp record_opt?(:max_seconds, s), do: in_range?(s, 1, 300)
  defp record_opt?(:threshold_db, db), do: in_range?(db, -90, 0)
  defp record_opt?(:pre_roll_ms, ms), do: in_range?(ms, 0, 500)
  defp record_opt?(_key, _value), do: false

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
      with {:error, reason} <- apply_pad(index, pad, samples, false) do
        Logger.warning(
          "Magpie.Engine: pad #{index} after reloading #{inspect(id)}: #{inspect(reason)}"
        )
      end
    end

    %{s | samples: samples}
  end

  defp loaded(s, _id, {:error, _}), do: s

  defp apply_pad(index, pad, samples, stop) do
    with {:ok, params} <- pad_params(pad, samples), do: Audio.impl().set_pad(index, params, stop)
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
