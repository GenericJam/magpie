defmodule Magpie.Audio.Nif do
  @moduledoc """
  The `magpie_audio` NIF (`c_src/magpie_audio.c`, which includes
  `c_src/sampler.c`), statically linked into the Android app (`mob.exs`'s
  `:static_nifs`). Use it through `Magpie.Audio.Native`; the messages it
  sends are documented in `Magpie.Audio`.

  Off Android the library isn't there: the module still loads, and every
  function raises `:nif_not_loaded`.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    # The NIF only exists in the phone build; elsewhere the stubs below stay.
    _ = :erlang.load_nif(~c"magpie_audio", 0)
    :ok
  end

  @doc "Open the stream if it isn't, and make `owner` the owner. `{:ok, stream} | {:error, reason}`."
  def open(_owner), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close the stream (owner only)."
  def close, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Everything off and unloaded (owner only)."
  def reset, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Queue a file decode for sample `id` (owner only); the result arrives as a `:loaded` message."
  def load_sample(_id, _path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Queue f32le PCM for sample `id` (owner only); the result arrives as a `:loaded` message."
  def load_pcm(_id, _pcm, _rate, _channels), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decode a file to f32le PCM and peaks, synchronously (dirty IO)."
  def decode(_path), do: :erlang.nif_error(:nif_not_loaded)

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

  @doc "Diagnostics (dirty IO)."
  def info, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Start callback timing, trigger latency, the voice peak, steals and hard cuts over."
  def reset_stats, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Close any input, then open `source` (`:mic` | `:apps`): `{:ok, input}`
  (owner only, dirty IO). The outcome arrives as `{:magpie_audio, :input,
  input, :started, info}` or `{:magpie_audio, :input, input, :closed,
  reason}`.
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
end
