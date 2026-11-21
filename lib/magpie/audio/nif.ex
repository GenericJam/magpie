defmodule Magpie.Audio.Nif do
  @moduledoc """
  The `magpie_audio` NIF (`c_src/magpie_audio.c`, which includes
  `c_src/magpie_io.c`, `c_src/sampler.c` and `c_src/recorder.c`),
  statically linked into the app on Android and iOS (`mob.exs`'s
  `:static_nifs`). Use it through `Magpie.Audio.Native`; the messages it
  sends are documented in `Magpie.Audio`.

  Loading it registers two `mob_audio_io` processors (`mai_register`):
  `"magpie_out"` (render: the sampler) and `"magpie_mic"` (capture: the
  recorder). Their streams are `Magpie.Audio.Native.Io`'s, opened with
  `MobAudioIo.open/3` and `module: #{inspect(__MODULE__)}`.

  Off the phone the library isn't there: the module still loads, and every
  function raises `:nif_not_loaded`.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    # The NIF only exists in the phone build; elsewhere the stubs below stay.
    _ = :erlang.load_nif(~c"magpie_audio", 0)
    :ok
  end

  @doc """
  Make `owner` the owner and start the event and MIDI sending threads:
  `:ok | {:error, :thread | :processors}` (`:processors`: they didn't
  register, so no stream can open).
  """
  def open(_owner), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stop the event and MIDI sending threads (owner only); the streams are `Magpie.Audio.Native.Io`'s."
  def close, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Everything off and unloaded (owner only)."
  def reset, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Queue f32le PCM for sample `id` (owner only); the result arrives as a `:loaded` message."
  def load_pcm(_id, _pcm, _rate, _channels), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A file load of sample `id` begins (owner only): `{:ok, ticket}`, its
  place among the loads and unloads of `id`. `load_ticket/5` or
  `load_ticket_failed/3` finishes it; the result arrives as a `:loaded`
  message.
  """
  def load_claim(_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The claimed load's decoded f32le PCM (anyone); `{:error, :cancelled}` if `id` was loaded or unloaded since."
  def load_ticket(_id, _ticket, _pcm, _rate, _channels), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The claimed load's file didn't decode (anyone): `reason` (`:not_found`,
  `:unsupported`, `:no_audio`, `:decode_error`, `:too_long`, `:alloc`,
  `:busy`, `:cancelled`) reaches the owner in the load's turn.
  """
  def load_ticket_failed(_id, _ticket, _reason), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A decoded chunk (native-endian f32, `channels` per frame) as the library
  keeps it: `{pcm, peaks}`, the first two channels clipped to ±1 and one
  peak byte per 256 frames (anyone).
  """
  def import_chunk(_chunk, _channels), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Unload sample `id` (owner only)."
  def unload_sample(_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set pad `pad` from `{sample_id | nil, start_frame, end_frame, gain_db,
  pitch_st, reverse, fade_in_ms, fade_out_ms, mode, choke, root}` (owner
  only). `end_frame` 0: to the sample's end. `stop`: the pad's sounding
  voices fade and its waiting quantized launches go first, in one step.
  """
  def set_pad(_pad, _params, _stop), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Set the pattern: `steps` 16 | 32, events `[{pos, pad, vel, note}]` (`pos`
  straight ticks, `note` -1 for the root), `at_bar` boolean (owner only).
  `{:ok, number}`.
  """
  def set_pattern(_steps, _events, _at_bar), do: :erlang.nif_error(:nif_not_loaded)

  def set_tempo(_bpm), do: :erlang.nif_error(:nif_not_loaded)
  def set_swing(_swing), do: :erlang.nif_error(:nif_not_loaded)
  def play, do: :erlang.nif_error(:nif_not_loaded)
  def stop, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Play `pad` (anyone). `quantize` ticks, 0 for now."
  def trigger(_pad, _velocity, _quantize), do: :erlang.nif_error(:nif_not_loaded)

  def release(_pad), do: :erlang.nif_error(:nif_not_loaded)
  def note_on(_pad, _note, _velocity), do: :erlang.nif_error(:nif_not_loaded)
  def note_off(_pad, _note), do: :erlang.nif_error(:nif_not_loaded)

  @doc "`%{frame, time, rate}` or nil."
  def clock, do: :erlang.nif_error(:nif_not_loaded)

  @doc "The engine's diagnostics (dirty IO); `Magpie.Audio.Native.info/0` adds the streams'."
  def info, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Start callback timing, trigger latency, the voice peak, steals and hard cuts over."
  def reset_stats, do: :erlang.nif_error(:nif_not_loaded)

  @doc "The sources `input_open/1` can open here: `[:mic, :apps]` on Android, `[:mic]` on iOS."
  def input_sources, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Close any input, then open `source` (owner only, dirty IO): the mic
  answers `{:ok, input, rate}` and is opening until `"magpie_mic"`'s stream
  (at `rate`) starts; other apps answer `{:ok, input}`. The outcome arrives
  as `{:magpie_audio, :input, input, :started, info}` or `{:magpie_audio,
  :input, input, :closed, reason}`.
  """
  def input_open(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close the input; a recording in progress is dropped (owner only, dirty IO)."
  def input_close, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Arm the recorder on the open input: `mode` `:now | :on_sound |
  :count_in`, `max_seconds`, `threshold_db` (`:on_sound`), `pre_roll_ms`
  (`:on_sound`): `{:ok, take}` (owner only, dirty IO).
  """
  def record_start(_mode, _max_seconds, _threshold_db, _pre_roll_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stop recording: `{:ok, %{pcm, rate, channels, frames, peaks, peak_frames}}` (owner only, dirty IO)."
  def record_stop, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Drop the recording (owner only, dirty IO)."
  def record_cancel, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The kit's MIDI table (owner only): `{in_channel (0 all), out_channel,
  clock, [128 note masks, a bit per pad], [64 out notes, -1 none]}`, or nil
  for MIDI off.
  """
  def set_midi(_table), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The MIDI outputs: mob_midi output handles (anyone, dirty IO)."
  def midi_outputs(_handles), do: :erlang.nif_error(:nif_not_loaded)

  @doc "An input closed or changed hands: what closed inputs held ends (anyone, dirty IO)."
  def midi_sources_changed, do: :erlang.nif_error(:nif_not_loaded)
end
