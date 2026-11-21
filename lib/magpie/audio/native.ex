defmodule Magpie.Audio.Native do
  @moduledoc """
  The phone's audio engine: `Magpie.Audio` over the `magpie_audio` NIF
  (`c_src/magpie_audio.c`, `c_src/magpie_io.c`, `c_src/sampler.c`,
  `c_src/recorder.c`) and `mob_audio_io`'s streams, on Android and iOS.

  `mob_audio_io` owns the streams (AAudio on Android, RemoteIO and the
  `AVAudioSession` on iOS) and decodes files (AMediaCodec, ExtAudioFile);
  `Magpie.Audio.Native.Io` opens and closes them. The output stream (stereo
  float at the device's own rate, low latency) runs the sampler in its
  callback (`"magpie_out"`): a 32-voice pool (plus 16 slots for voices
  fading out), choke groups, the step sequencer at 96 PPQN with swing.
  Calls only queue commands into a lock-free queue the callback drains at
  the start of its next buffer; an event thread turns what the callback
  did into messages. The microphone is a stream of its own on
  `"magpie_mic"`; other apps' audio (Android only) comes from
  `plugins/magpie_capture`. See the "audio engine" section of AGENTS.md
  for the design and the phones' numbers.

  | | Android | iOS |
  |--|--|--|
  | output, sampler, sequencer, MIDI | yes | yes |
  | `input_open(:mic)` | yes | yes |
  | `input_open(:apps)` | API 29+ (MediaProjection) | `{:error, :unsupported}` |
  | `decode/1`, `load_sample/2` | AMediaCodec | ExtAudioFile |

  `info/0` is the NIF's engine figures with the streams' from
  `MobAudioIo.status/1` merged in (and the whole status maps under `io`).
  """

  @behaviour Magpie.Audio

  alias Magpie.Audio.Native.{Decode, Io}

  @nif Application.compile_env(:magpie, :audio_nif, Magpie.Audio.Nif)

  @impl true
  def open(owner) when is_pid(owner) do
    with :ok <- @nif.open(owner),
         {:ok, _io} <- Io.start(owner),
         do: Io.open_output()
  end

  @impl true
  def close do
    with :ok <- @nif.close(), do: Io.close_output()
  end

  @impl true
  def reset, do: @nif.reset()

  # The file is decoded in a process of its own (the engine stays free);
  # the claim keeps this load in order with the other loads and unloads of
  # `id`, and the result reaches the owner as `:loaded`, as for load_pcm/4.
  @impl true
  def load_sample(id, path) do
    path = IO.chardata_to_string(path)

    with {:ok, ticket} <- @nif.load_claim(id) do
      {:ok, _pid} = Task.start(Decode, :load, [id, ticket, path])
      :ok
    end
  end

  @impl true
  def load_pcm(id, pcm, rate, channels) when is_binary(pcm),
    do: @nif.load_pcm(id, pcm, rate, channels)

  @impl true
  def decode(path), do: Decode.decode(path)

  @impl true
  def unload_sample(id), do: @nif.unload_sample(id)

  @impl true
  def set_pad(pad, nil, stop),
    do: @nif.set_pad(pad, {nil, 0, 0, 0.0, 0.0, false, 0.0, 0.0, :one_shot, 0, 60}, stop)

  def set_pad(pad, p, stop) do
    @nif.set_pad(
      pad,
      {p.sample, p.start, p.end, p.gain_db, p.pitch_st, p.reverse, p.fade_in_ms, p.fade_out_ms,
       p.mode, p.choke, p.root},
      stop
    )
  end

  @impl true
  def set_pattern(%{length: length, events: events}, at) when at in [:bar, :now] do
    events = for {pos, pad, vel, note} <- events, do: {pos, pad, vel, note || -1}
    @nif.set_pattern(length, events, at == :bar)
  end

  @impl true
  def set_tempo(bpm), do: @nif.set_tempo(bpm)

  @impl true
  def set_swing(swing), do: @nif.set_swing(swing)

  @impl true
  def play, do: @nif.play()

  @impl true
  def stop, do: @nif.stop()

  @impl true
  def trigger(pad, velocity, quantize), do: @nif.trigger(pad, velocity, quantize)

  @impl true
  def release(pad), do: @nif.release(pad)

  @impl true
  def note_on(pad, note, velocity), do: @nif.note_on(pad, note, velocity)

  @impl true
  def note_off(pad, note), do: @nif.note_off(pad, note)

  @impl true
  def clock, do: @nif.clock()

  @impl true
  def info do
    %{output: output, mic: mic} = io = Io.status()

    @nif.info()
    |> Map.merge(output_info(output))
    |> Map.update!(:input, &input_info(&1, mic))
    |> Map.put(:io, io)
  end

  @doc """
  Start callback timing, trigger latency, the voice peak, steals and hard
  cuts over, and the streams' worst-case counters (for measuring a stretch).
  """
  def reset_stats do
    :ok = Io.reset_stats()
    @nif.reset_stats()
  end

  @impl true
  def input_sources, do: @nif.input_sources()

  # The NIF closes what was open, then opens: the mic as an input waiting
  # for its stream, which Io opens next (the stream before it closed
  # first). A mic that can't open leaves no input, as before.
  @impl true
  def input_open(source) when source in [:mic, :apps] do
    case @nif.input_open(source) do
      {:error, :not_owner} = error ->
        error

      {:ok, id, rate} ->
        :ok = Io.close_mic()

        case Io.open_mic(rate) do
          :ok ->
            {:ok, id}

          {:error, _} = error ->
            :ok = @nif.input_close()
            error
        end

      result ->
        :ok = Io.close_mic()
        result
    end
  end

  @impl true
  def input_close do
    with :ok <- @nif.input_close(), do: Io.close_mic()
  end

  @impl true
  def record_start(%{mode: mode, max_seconds: max, threshold_db: db, pre_roll_ms: ms}),
    do: @nif.record_start(mode, max / 1, db / 1, ms / 1)

  @impl true
  def record_stop, do: @nif.record_stop()

  @impl true
  def record_cancel, do: @nif.record_cancel()

  # The table as the NIF takes it: in channel (0 all), out channel, clock,
  # per note a bit per pad (128 masks), per pad the note it sends (-1 none).
  @impl true
  def set_midi(nil), do: @nif.set_midi(nil)

  def set_midi(%{} = c) do
    masks =
      for note <- 0..127,
          do: c.notes |> Map.get(note, []) |> Enum.reduce(0, &Bitwise.bor(&2, Bitwise.bsl(1, &1)))

    out = for pad <- 0..63, do: Map.get(c.out_notes, pad, -1)
    in_channel = if c.in_channel == :all, do: 0, else: c.in_channel
    @nif.set_midi({in_channel, c.out_channel, c.clock, masks, out})
  end

  @impl true
  def midi_outputs(handles) when is_list(handles), do: @nif.midi_outputs(handles)

  @impl true
  def midi_sources_changed, do: @nif.midi_sources_changed()

  # The output stream's figures, under the keys the engine's info always had.
  defp output_info(nil) do
    %{
      burst: 0,
      buffer_frames: 0,
      buffer_capacity: 0,
      low_latency: nil,
      exclusive: false,
      device: 0,
      output_latency_ms: -1.0,
      underruns: 0,
      reopens: 0
    }
  end

  defp output_info(s) do
    %{
      burst: s.burst,
      buffer_frames: s.buffer,
      buffer_capacity: s.capacity,
      low_latency: nil,
      exclusive: s.sharing == :exclusive,
      device: s.device_id,
      output_latency_ms: s.latency_ms || -1.0,
      underruns: s.xruns,
      reopens: s.reopens
    }
  end

  defp input_info(nil, _mic), do: nil

  defp input_info(%{source: :mic} = input, %{} = mic),
    do:
      Map.merge(input, %{
        preset: mic.preset_granted,
        burst: mic.burst,
        overruns: mic.xruns,
        low_latency: nil
      })

  defp input_info(input, _mic),
    do: Map.merge(input, %{preset: 0, burst: 0, overruns: 0, low_latency: false})
end
