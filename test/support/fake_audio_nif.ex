defmodule Magpie.Test.FakeAudioNif do
  @moduledoc """
  A double of `Magpie.Audio.Nif` for `Magpie.Audio.Native`'s own tests
  (`config :magpie, :audio_nif` in the test env), beside
  `MobAudioIo.Fake` for the plugin: every call is sent to the test process
  as `{:fake_nif, name, args}` and answers what `answer/2` set (or a
  plausible default). `import_chunk/2` is the C's conversion in Elixir.

  Global (one Agent): `async: false` tests, `start/1` in `setup`.
  """

  use Agent

  @doc "Start (or restart) for `test`, which gets the calls."
  def start(test) do
    case Agent.start(fn -> %{test: test, answers: %{}, ids: 0} end, name: __MODULE__) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        Agent.update(__MODULE__, fn _ -> %{test: test, answers: %{}, ids: 0} end)
    end
  end

  @doc "`name`'s next calls answer `result` (a fun of the args, or a term)."
  def answer(name, result), do: Agent.update(__MODULE__, &put_in(&1, [:answers, name], result))

  defp call(name, args, default) do
    {test, answer} = Agent.get(__MODULE__, &{&1.test, Map.get(&1.answers, name)})
    result = reply(answer, args, default)
    send(test, {:fake_nif, name, args})
    result
  end

  defp reply(nil, _args, default), do: default.()
  defp reply(fun, args, _default) when is_function(fun), do: apply(fun, args)
  defp reply(term, _args, _default), do: term

  defp next_id, do: Agent.get_and_update(__MODULE__, &{&1.ids + 1, %{&1 | ids: &1.ids + 1}})

  def open(owner), do: call(:open, [owner], fn -> :ok end)
  def close, do: call(:close, [], fn -> :ok end)
  def reset, do: call(:reset, [], fn -> :ok end)
  def load_pcm(id, pcm, rate, ch), do: call(:load_pcm, [id, pcm, rate, ch], fn -> :ok end)
  def load_claim(id), do: call(:load_claim, [id], fn -> {:ok, next_id()} end)

  def load_ticket(ticket, pcm, rate, ch),
    do: call(:load_ticket, [ticket, pcm, rate, ch], fn -> :ok end)

  def load_ticket_failed(ticket, reason),
    do: call(:load_ticket_failed, [ticket, reason], fn -> :ok end)

  def import_chunk(chunk, channels), do: library_form(chunk, channels)
  def unload_sample(id), do: call(:unload_sample, [id], fn -> :ok end)
  def set_pad(pad, params, stop), do: call(:set_pad, [pad, params, stop], fn -> :ok end)

  def set_pattern(steps, events, at_bar),
    do: call(:set_pattern, [steps, events, at_bar], fn -> {:ok, 1} end)

  def set_tempo(bpm), do: call(:set_tempo, [bpm], fn -> :ok end)
  def set_swing(swing), do: call(:set_swing, [swing], fn -> :ok end)
  def play, do: call(:play, [], fn -> :ok end)
  def stop, do: call(:stop, [], fn -> :ok end)
  def trigger(pad, vel, q), do: call(:trigger, [pad, vel, q], fn -> :ok end)
  def release(pad), do: call(:release, [pad], fn -> :ok end)
  def note_on(pad, note, vel), do: call(:note_on, [pad, note, vel], fn -> :ok end)
  def note_off(pad, note), do: call(:note_off, [pad, note], fn -> :ok end)
  def clock, do: call(:clock, [], fn -> nil end)

  def info do
    call(:info, [], fn ->
      %{running: true, rate: 48_000, callbacks: 10, frame: 2400, input: nil, midi: %{}}
    end)
  end

  def reset_stats, do: call(:reset_stats, [], fn -> :ok end)
  def input_sources, do: call(:input_sources, [], fn -> [:mic, :apps] end)

  def input_open(source) do
    call(:input_open, [source], fn ->
      if source == :mic, do: {:ok, next_id(), 48_000}, else: {:ok, next_id()}
    end)
  end

  def input_close, do: call(:input_close, [], fn -> :ok end)

  def record_start(mode, max, db, ms),
    do: call(:record_start, [mode, max, db, ms], fn -> {:ok, 1} end)

  def record_stop, do: call(:record_stop, [], fn -> {:error, :not_recording} end)
  def record_cancel, do: call(:record_cancel, [], fn -> :ok end)
  def set_midi(table), do: call(:set_midi, [table], fn -> :ok end)
  def midi_outputs(handles), do: call(:midi_outputs, [handles], fn -> :ok end)
  def midi_sources_changed, do: call(:midi_sources_changed, [], fn -> :ok end)

  # c_src/magpie_io.c's mio_import_chunk: the first two channels, clipped to
  # ±1, and a peak byte per 256 frames.
  defp library_form(chunk, channels) do
    keep = min(channels, 2)
    frame_bytes = 4 * channels

    frames =
      for <<frame::binary-size(^frame_bytes) <- chunk>> do
        for <<x::float-32-native <- binary_part(frame, 0, 4 * keep)>>,
          do: x |> max(-1.0) |> min(1.0)
      end

    pcm = for frame <- frames, x <- frame, into: <<>>, do: <<x::float-32-native>>

    peaks =
      frames
      |> Enum.chunk_every(256)
      |> Enum.map(fn block ->
        peak = block |> List.flatten() |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)
        p16 = round(peak * 32_768)
        <<div(p16 * 255 + 16_384, 32_768)>>
      end)
      |> IO.iodata_to_binary()

    {pcm, peaks}
  end
end
