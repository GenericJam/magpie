defmodule Magpie.Audio.Native do
  @moduledoc """
  The phone's audio engine: `Magpie.Audio` over the `magpie_audio` NIF
  (`c_src/magpie_audio.c` and `c_src/sampler.c`, Android).

  An AAudio output stream (low-latency mode, shared, stereo float at the
  device's own rate) runs the sampler in its callback: a 32-voice pool
  (plus 16 slots for voices fading out), choke groups, the step sequencer
  at 96 PPQN with swing. Calls only queue commands into a lock-free queue
  the callback drains at the start of its next buffer; an event thread
  turns what the callback did into messages. See the "audio engine"
  section of AGENTS.md for the design and the phone's numbers.
  """

  @behaviour Magpie.Audio

  alias Magpie.Audio.Nif

  @impl true
  def open(owner) when is_pid(owner), do: Nif.open(owner)

  @impl true
  def close, do: Nif.close()

  @impl true
  def reset, do: Nif.reset()

  @impl true
  def load_sample(id, path), do: Nif.load_sample(id, IO.chardata_to_string(path))

  @impl true
  def load_pcm(id, pcm, rate, channels) when is_binary(pcm),
    do: Nif.load_pcm(id, pcm, rate, channels)

  @impl true
  def decode(path), do: Nif.decode(IO.chardata_to_string(path))

  @impl true
  def unload_sample(id), do: Nif.unload_sample(id)

  @impl true
  def set_pad(pad, nil, stop),
    do: Nif.set_pad(pad, {nil, 0, 0, 0.0, 0.0, false, 0.0, 0.0, :one_shot, 0, 60}, stop)

  def set_pad(pad, p, stop) do
    Nif.set_pad(
      pad,
      {p.sample, p.start, p.end, p.gain_db, p.pitch_st, p.reverse, p.fade_in_ms, p.fade_out_ms,
       p.mode, p.choke, p.root},
      stop
    )
  end

  @impl true
  def set_pattern(%{length: length, events: events}, at) when at in [:bar, :now] do
    events = for {pos, pad, vel, note} <- events, do: {pos, pad, vel, note || -1}
    Nif.set_pattern(length, events, at == :bar)
  end

  @impl true
  def set_tempo(bpm), do: Nif.set_tempo(bpm)

  @impl true
  def set_swing(swing), do: Nif.set_swing(swing)

  @impl true
  def play, do: Nif.play()

  @impl true
  def stop, do: Nif.stop()

  @impl true
  def trigger(pad, velocity, quantize), do: Nif.trigger(pad, velocity, quantize)

  @impl true
  def release(pad), do: Nif.release(pad)

  @impl true
  def note_on(pad, note, velocity), do: Nif.note_on(pad, note, velocity)

  @impl true
  def note_off(pad, note), do: Nif.note_off(pad, note)

  @impl true
  def clock, do: Nif.clock()

  @impl true
  def info, do: Nif.info()

  @doc "Start callback timing, trigger latency, the voice peak, steals and hard cuts over (for measuring a stretch)."
  def reset_stats, do: Nif.reset_stats()

  @impl true
  def input_open(source) when source in [:mic, :apps], do: Nif.input_open(source)

  @impl true
  def input_close, do: Nif.input_close()

  @impl true
  def record_start(%{mode: mode, max_seconds: max, threshold_db: db, pre_roll_ms: ms}),
    do: Nif.record_start(mode, max / 1, db / 1, ms / 1)

  @impl true
  def record_stop, do: Nif.record_stop()

  @impl true
  def record_cancel, do: Nif.record_cancel()

  # The table as the NIF takes it: in channel (0 all), out channel, clock,
  # per note a bit per pad (128 masks), per pad the note it sends (-1 none).
  @impl true
  def set_midi(nil), do: Nif.set_midi(nil)

  def set_midi(%{} = c) do
    masks =
      for note <- 0..127,
          do: c.notes |> Map.get(note, []) |> Enum.reduce(0, &Bitwise.bor(&2, Bitwise.bsl(1, &1)))

    out = for pad <- 0..63, do: Map.get(c.out_notes, pad, -1)
    in_channel = if c.in_channel == :all, do: 0, else: c.in_channel
    Nif.set_midi({in_channel, c.out_channel, c.clock, masks, out})
  end

  @impl true
  def midi_listen(pid) when is_pid(pid), do: Nif.midi_listen(pid)

  @impl true
  def midi_devices do
    with {:ok, json} <- Nif.midi_devices(),
         do: {:ok, json |> JSON.decode!() |> Enum.map(&Magpie.Midi.device/1)}
  end

  @impl true
  def midi_open(id) when is_integer(id), do: Nif.midi_open(id)

  @impl true
  def midi_close(id) when is_integer(id), do: Nif.midi_close(id)

  @impl true
  def midi_ble_scan(ms) when is_integer(ms) and ms > 0, do: Nif.midi_ble_scan(ms)

  @impl true
  def midi_ble_connect(address) when is_binary(address), do: Nif.midi_ble_connect(address)

  @impl true
  def midi_ble_disconnect(address) when is_binary(address), do: Nif.midi_ble_disconnect(address)
end
