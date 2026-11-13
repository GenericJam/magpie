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

  Input and recording (`c:input_open/1`, `c:record_start/1`):

      {:magpie_audio, :input, input, :started, %{source: :mic | :apps, rate: rate, channels: 1 | 2}}
      {:magpie_audio, :input, input, :closed, reason}
      {:magpie_audio, :meter, input, level_db, %{take: take | nil, state: state, frames: frames, peaks: new_peaks}}
      {:magpie_audio, :record, take, :started, %{pre_roll_frames: n, late_frames: n}}
      {:magpie_audio, :record, take, :full, frames}
      {:magpie_audio, :count_in, take, first_frame, until_frame}

  MIDI devices (`c:midi_listen/1`), to the listener, each with a JSON
  object (`Magpie.Midi` decodes them):

      {:magpie_midi, :added | :removed, json}   # a device (see `t:midi_device/0`) appeared or went
      {:magpie_midi, :opened | :closed, json}   # %{"id"}: a device opened (both ways) or closed
      {:magpie_midi, :open_failed, json}        # %{"id", "reason"}
      {:magpie_midi, :port, json}               # %{"inputs", "outputs"}: apps connected to the Magpie port
      {:magpie_midi, :ble_found, json}          # %{"address", "name", "rssi"}: a Bluetooth-MIDI device seen by a scan
      {:magpie_midi, :ble_scan_done, json}      # %{} or %{"error"}
      {:magpie_midi, :ble_connected, json}      # %{"address", "id", "name"}: it is a MIDI device now
      {:magpie_midi, :ble_failed, json}         # %{"address", "reason"}

  `input` is the id `c:input_open/1` returned, `take` the one
  `c:record_start/1` returned (positive integers, never reused): a
  message about an input or a take that is over can still be on its way
  when the next one starts, so match on the id.

  - `:input, :started`: the input runs. The mic starts at once (mono at
    the engine's rate); other apps after the MediaProjection consent and
    the capture service start (stereo).
  - `:input, :closed`: `:denied` (consent refused), `:disconnected`,
    `:stopped` (the user ended the projection) or `:error`. Call
    `c:input_close/0` to release it.
  - `:meter`, every ~40 ms while an input is open: `level_db` is the
    input's peak dBFS since the previous meter (float, floor -120.0);
    `take` the armed take (nil: none); `state` is `:idle` (monitoring
    only), `:waiting` (`:on_sound` armed), `:counting` (count-in armed),
    `:recording` or `:full` (max length reached); `frames` the take's
    frames so far (at the input's rate); `peaks` its new peak bytes since
    the previous meter (append them; see `t:peaks/0`).
  - `:record, :started`: the take began: at once for `:now`, at the
    first frame at or above the threshold (less the pre-roll) for
    `:on_sound`, on the downbeat after the count-in.
  - `:record, :full`: max length reached; the recorder keeps what it has
    and takes no more audio. `c:record_stop/0` returns it.
  - `:count_in`: four clicks (one bar of 4/4 at the current tempo) at
    engine frames `first + k × (until − first) / 4`, k = 0..3; the
    recording starts with the audio captured when `until` is heard.
    While the sequencer plays, `first` is its next bar.

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
  A finished recording: exactly `t:decoded/0` (interleaved f32le at the
  input's rate, peaks per 256 frames).
  """
  @type recording :: decoded()

  @typedoc "An opened input (`c:input_open/1`); every input message carries it."
  @type input :: pos_integer()

  @typedoc "An armed take (`c:record_start/1`); every recording message carries it."
  @type take :: pos_integer()

  @typedoc """
  How a recording starts (`:now`; `:on_sound` at `threshold_db`, keeping
  `pre_roll_ms` from before it; `:count_in`, after one bar of clicks) and
  its length limit.
  """
  @type record_opts :: %{
          mode: :now | :on_sound | :count_in,
          max_seconds: number(),
          threshold_db: number(),
          pre_roll_ms: number()
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

  @typedoc """
  A MIDI device the phone knows: USB, Bluetooth (once connected) or
  another app's virtual port. `own` is Magpie's own port; `inputs` and
  `outputs` count its ports (an output port is what Magpie receives from).
  """
  @type midi_device :: %{
          id: integer(),
          name: String.t(),
          type: :usb | :bluetooth | :virtual,
          inputs: non_neg_integer(),
          outputs: non_neg_integer(),
          own: boolean(),
          address: String.t()
        }

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
  @doc """
  Set a pad (nil: clear it). Takes effect on the pad's next trigger. With
  `stop` true the pad's sounding voices fade (each by its own release) and
  its waiting quantized launches are dropped, in the same step as the
  change, whatever the old or new mode, and with no stream too.
  """
  @callback set_pad(pad(), pad_params() | nil, stop :: boolean()) :: :ok | {:error, term()}
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
  @doc """
  Close any open input, then open `:mic` or `:apps` (other apps'
  playback, Android 10+) as a new input id. The outcome arrives as
  `{:magpie_audio, :input, input, :started, info}` or `{:magpie_audio,
  :input, input, :closed, reason}`. Errors returned directly:
  `:not_owner` (nothing changed); `:input_stuck` (the open mic wouldn't
  stop: it is closed to the owner but still allocated, and the next
  close or open tries again); after the close, `:unsupported` (apps
  below API 29), `:busy` (a consent dialog is still up),
  `:no_permission` (RECORD_AUDIO not granted), `:input_unavailable`
  (AAudio refused), `{:missing, lib}`.
  """
  @callback input_open(source :: :mic | :apps) :: {:ok, input()} | {:error, term()}
  @doc """
  Close the input; a recording in progress is dropped. `:input_stuck`:
  the mic stream wouldn't stop (closed to the owner, still allocated):
  try again later.
  """
  @callback input_close() :: :ok | {:error, term()}
  @doc """
  Arm the recorder on the open input as a new take id. `:not_running`:
  `:count_in` needs the output stream (the engine renders its clicks);
  `:recording`: already armed.
  """
  @callback record_start(record_opts()) ::
              {:ok, take()}
              | {:error, :no_input | :recording | :not_running | :alloc | :not_owner}
  @doc """
  Stop and take the recording. `:not_started`: armed but the recording
  never began (no sound yet, count-in not done); the recorder is disarmed
  either way.
  """
  @callback record_stop() :: {:ok, recording()} | {:error, :not_recording | :not_started}
  @doc "Disarm the recorder and drop what it has."
  @callback record_cancel() :: :ok | {:error, term()}
  @doc """
  The kit's MIDI (`Magpie.Midi.Map.config/1`): the renderer maps every
  incoming message through it, sends notes and clock by it. nil: MIDI off.
  """
  @callback set_midi(Magpie.Midi.Map.t() | nil) :: :ok | {:error, term()}
  @doc "Send the `:magpie_midi` device messages to `pid` (one listener). `:unavailable` without MIDI."
  @callback midi_listen(pid()) :: :ok | {:error, :unavailable}
  @callback midi_devices() :: {:ok, [midi_device()]} | {:error, :unavailable}
  @doc """
  Open a device both ways (its output ports into Magpie, its input port 0
  for what Magpie sends). The outcome arrives as `:opened` or
  `:open_failed`.
  """
  @callback midi_open(id :: integer()) :: :ok | {:error, term()}
  @callback midi_close(id :: integer()) :: :ok | {:error, term()}
  @doc """
  Scan for Bluetooth-MIDI devices for `ms`: `:ble_found` per device, then
  `:ble_scan_done`. Errors: `:no_permission` (ask for the
  `:midi_bluetooth` capability), `:bluetooth_off`, `:location_off`,
  `:no_bluetooth`, `:unavailable`.
  """
  @callback midi_ble_scan(ms :: pos_integer()) :: :ok | {:error, term()}
  @doc "Connect a scanned device: `:ble_connected` (then `:added`) or `:ble_failed`."
  @callback midi_ble_connect(address :: String.t()) :: :ok | {:error, term()}
  @callback midi_ble_disconnect(address :: String.t()) :: :ok | {:error, term()}

  @doc "The engine in use."
  def impl, do: Application.get_env(:magpie, :audio, Magpie.Audio.Native)

  @doc "When engine frame `frame` is heard, in `System.monotonic_time(:nanosecond)`."
  @spec frame_time(clock(), integer()) :: integer()
  def frame_time(%{frame: f, time: t, rate: rate}, frame),
    do: t + div((frame - f) * 1_000_000_000, rate)
end
