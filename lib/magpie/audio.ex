defmodule Magpie.Audio do
  @moduledoc """
  The audio engine contract. `impl/0` is `Magpie.Audio.Native` on the phone
  (the `magpie_audio` NIF, `c_src/magpie_audio.c` + `c_src/sampler.c`) and
  `Magpie.Audio.Fake` in host tests (`config :magpie, :audio`).

  Use it through `Magpie.Engine`, which owns it: the engine converts kit
  pads and patterns (`Magpie.Kit`) into the engine's units (frames, flat
  step lists) and keeps a mirror of what is loaded. The control callbacks
  below answer `{:error, :not_owner}` to any process but the one that
  called `open/1`; the live ones (`trigger/3`, `release/1`, `note_on/3`,
  `note_off/2`) are open to every process and only queue a command for the
  audio thread.

  Messages to the owner:

      {:magpie_audio, :loaded, sample_id, {:ok, sample_info} | {:error, reason}}
      {:magpie_audio, :playhead, step, frame}        # a step started sounding (one per pass of the event thread)
      {:magpie_audio, :voice, pad, :start | :end}    # a voice of the pad started; the pad's last voice ended
      {:magpie_audio, :hit, pad, %Magpie.Kit.Step{}} # a live trigger while playing, where it was heard
      {:magpie_audio, :pattern, pattern_number, frame} # a pattern took over

  Frames are engine frames: frames rendered since the engine started, at
  the engine's rate (the device's own, 48 kHz on the phones tried).
  `clock/0` maps them onto `System.monotonic_time(:nanosecond)`.
  """

  @typedoc "A pad: bank × 16 + slot (`Magpie.Kit.pad_index/2`)."
  @type pad :: 0..63

  @typedoc """
  A loaded sample. `frames` at `rate` (the engine's rate: the source is
  resampled on load), `channels` 1 or 2 (more are cut to the first two),
  `peaks` (see `t:peaks/0`, at `rate`), `bytes` of RAM (16-bit samples:
  96 KB per second mono, 192 KB stereo at 48 kHz), the source's
  `source_rate`, and `load_ms` (decode + resample).
  """
  @type sample_info :: %{
          frames: non_neg_integer(),
          channels: 1 | 2,
          rate: pos_integer(),
          peaks: peaks(),
          peak_frames: pos_integer(),
          bytes: non_neg_integer(),
          source_rate: pos_integer(),
          load_ms: float()
        }

  @typedoc """
  A waveform: one byte per `peak_frames` (256) frames, the largest
  |sample| over the channels in that stretch, linear, 255 = full scale.
  Stored as an opaque binary by `Magpie.Library`; a 12-bar pad waveform
  takes the max of each twelfth.
  """
  @type peaks :: binary()

  @typedoc """
  A decoded file: interleaved f32le `pcm` at the file's own `rate`, up to
  two channels, with its `peaks` (per `peak_frames` frames at that rate).
  """
  @type decoded :: %{
          pcm: binary(),
          rate: pos_integer(),
          channels: 1 | 2,
          frames: non_neg_integer(),
          peaks: peaks(),
          peak_frames: pos_integer()
        }

  @typedoc """
  A pad in engine units. `start`/`end` are frames of the loaded sample
  (`end` 0: to its end), `root` the keys-mode root note.
  """
  @type pad_params :: %{
          sample: term(),
          start: non_neg_integer(),
          end: non_neg_integer(),
          gain_db: number(),
          pitch_st: number(),
          reverse: boolean(),
          fade_in_ms: number(),
          fade_out_ms: number(),
          mode: :one_shot | :gate | :loop | :toggle | :keys,
          choke: 0..3,
          root: 0..127
        }

  @typedoc """
  A pattern in engine units: `length` in steps, `events` as
  `{pos, pad, velocity, note}` with `pos` in straight ticks (96 PPQN, a
  step is 24) inside `[0, length × 24)` and `note` nil for the pad's root.
  """
  @type compiled_pattern :: %{
          length: 16 | 32,
          events: [{non_neg_integer(), pad(), 1..127, 0..127 | nil}]
        }

  @typedoc "Engine frame `frame` is heard at `time` (`System.monotonic_time(:nanosecond)`)."
  @type clock :: %{frame: integer(), time: integer(), rate: pos_integer()}

  @doc """
  Open the output stream (if it isn't) and become the owner:
  `{:ok, %{rate, burst, buffer_frames, low_latency}}`.
  """
  @callback open(owner :: pid()) :: {:ok, map()} | {:error, term()}
  @doc "Stop and close the stream; what is loaded stays."
  @callback close() :: :ok | {:error, term()}
  @doc "Everything off: voices fade, pads cleared, samples unloaded, no pattern, stopped, 120 bpm, straight."
  @callback reset() :: :ok | {:error, term()}
  @doc """
  Decode the file at `path` (Android: MediaCodec, so wav, mp3, aac/m4a,
  flac, ogg…) into RAM on the loader thread; the result arrives as
  `{:magpie_audio, :loaded, id, result}`. Errors there: `:not_found`,
  `:unsupported`, `:no_audio`, `:decode_error`, `:too_long` (over 5
  minutes), `:alloc`, `:cancelled` (a later load or unload of `id`).
  """
  @callback load_sample(id :: term(), path :: Path.t()) :: :ok | {:error, term()}
  @doc """
  Like `load_sample/2`, from interleaved f32le PCM (the library's
  canonical form, `Magpie.Library.pcm/1`): no decoder involved.
  """
  @callback load_pcm(
              id :: term(),
              pcm :: binary(),
              rate :: pos_integer(),
              channels :: pos_integer()
            ) ::
              :ok | {:error, term()}
  @doc """
  Decode a file for import into the library: f32le PCM at its own rate
  plus peaks. Synchronous, in the caller; touches no engine state.
  """
  @callback decode(path :: Path.t()) :: {:ok, decoded()} | {:error, term()}
  @doc "Unload a sample: its voices fade, pads using it are cleared."
  @callback unload_sample(id :: term()) :: :ok | {:error, term()}
  @doc "Set a pad (nil: clear it). Takes effect on the pad's next trigger."
  @callback set_pad(pad(), pad_params() | nil) :: :ok | {:error, term()}
  @doc """
  Set the pattern. `:bar`: while playing, it takes over at the next bar
  from its step 0; `:now` (and whenever stopped): at once, keeping the
  position. Returns the pattern's number, which its `:pattern` message
  carries.
  """
  @callback set_pattern(compiled_pattern(), at :: :bar | :now) ::
              {:ok, pos_integer()} | {:error, term()}
  @doc "Tempo in bpm; applies from the next audio block."
  @callback set_tempo(number()) :: :ok | {:error, term()}
  @doc "Swing 0.5 (straight) … 0.75; while playing it applies from the next 8th-note pair."
  @callback set_swing(number()) :: :ok | {:error, term()}
  @callback play() :: :ok | {:error, term()}
  @doc "Stop the sequencer (sounding voices ring on). A pattern waiting for a bar takes over."
  @callback stop() :: :ok | {:error, term()}
  @doc """
  Play a pad. `quantize` > 0 (ticks: 24 a 16th, 96 a beat, 384 a bar):
  while the sequencer plays, wait for the next point of that grid.
  """
  @callback trigger(pad(), velocity :: 1..127, quantize :: non_neg_integer()) ::
              :ok | {:error, :not_running | :busy}
  @doc "Let go of a pad: gate, loop and keys voices fade out."
  @callback release(pad()) :: :ok | {:error, :not_running | :busy}
  @doc "A keys pad plays `note` (chromatic from its root); any other pad just triggers."
  @callback note_on(pad(), note :: 0..127, velocity :: 1..127) ::
              :ok | {:error, :not_running | :busy}
  @callback note_off(pad(), note :: 0..127) :: :ok | {:error, :not_running | :busy}
  @doc "The engine clock, or nil before the stream has a timestamp."
  @callback clock() :: clock() | nil
  @doc "Diagnostics: stream, callback timing, underruns, voices, latency, memory."
  @callback info() :: map()

  @doc "The engine in use."
  def impl, do: Application.get_env(:magpie, :audio, Magpie.Audio.Native)

  @doc "When engine frame `frame` is heard, in `System.monotonic_time(:nanosecond)`."
  @spec frame_time(clock(), integer()) :: integer()
  def frame_time(%{frame: f, time: t, rate: rate}, frame),
    do: t + div((frame - f) * 1_000_000_000, rate)
end
