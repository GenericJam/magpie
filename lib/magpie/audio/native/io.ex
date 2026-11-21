defmodule Magpie.Audio.Native.Io do
  @moduledoc """
  The engine's `mob_audio_io` streams, owned by this process for the
  engine's owner (`Magpie.Engine`): the output on `"magpie_out"` and the
  microphone on `"magpie_mic"` (`c_src/magpie_io.c`). One at a time,
  registered under this module's name: `start/1` replaces the last one
  (closing its streams first, so two outputs never render the one
  sampler), and it stops when the owner exits.

  The plugin's messages for these streams come here. What the engine needs
  of them reaches it in C through the processors' stream events: the
  renderer's role and rate on every start and stop of the output (the
  plugin reopens it after a lost device or a route change), and a lost
  microphone, which the NIF reports to the owner as `{:magpie_audio,
  :input, input, :closed, :disconnected}`. `MobAudioIo.Log` logs every
  plugin event with a `[mob_audio_io]` prefix; this process logs what it
  decides with `[magpie_audio]`.

  The microphone opens mono at the engine's rate, `:unprocessed` (no AGC
  or noise suppression; iOS's Measurement mode), and falls back to the
  platform's default preset (Android's VOICE_RECOGNITION) when the device
  refuses it.
  """

  use GenServer

  require Logger

  @nif Application.compile_env(:magpie, :audio_nif, Magpie.Audio.Nif)

  @doc "Start the streams' owner for `owner`, replacing (and closing) any earlier one."
  @spec start(pid()) :: {:ok, pid()} | {:error, term()}
  def start(owner) when is_pid(owner) do
    stop()
    GenServer.start(__MODULE__, owner, name: __MODULE__)
  end

  @doc "Close the streams and stop. `:ok` also when none runs."
  @spec stop() :: :ok
  def stop do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    # It ended (its owner exited) between the lookup and the stop.
    :exit, _ -> :ok
  end

  @doc """
  Open the output stream: `{:ok, %{rate, burst, buffer_frames,
  low_latency}}` (`low_latency` nil: the plugin asks for AAudio's
  low-latency mode and doesn't report what it got) or `{:error, reason}`
  (`:output_unavailable`: the platform refused it).
  """
  @spec open_output() :: {:ok, map()} | {:error, term()}
  def open_output, do: call(:open_output)

  @doc "Close the output stream (`:ok` with none)."
  @spec close_output() :: :ok
  def close_output, do: call(:close_output, :ok)

  @doc """
  Open the microphone at `rate` for the input the NIF just made opening
  (any mic stream before is closed): `:ok`, or `{:error, :no_permission |
  :input_unavailable | reason}`.
  """
  @spec open_mic(pos_integer()) :: :ok | {:error, term()}
  def open_mic(rate) when is_integer(rate), do: call({:open_mic, rate})

  @doc "Close the microphone's stream (`:ok` with none)."
  @spec close_mic() :: :ok
  def close_mic, do: call(:close_mic, :ok)

  @doc "The streams' `MobAudioIo.status/1` maps: `%{output: map | nil, mic: map | nil}`."
  @spec status() :: %{output: map() | nil, mic: map() | nil}
  def status, do: call(:status, %{output: nil, mic: nil})

  @doc "Zero the streams' worst-case counters (`MobAudioIo.reset_stats/1`)."
  @spec reset_stats() :: :ok
  def reset_stats, do: call(:reset_stats, :ok)

  defp call(request, without \\ {:error, :not_open}) do
    case GenServer.whereis(__MODULE__) do
      nil -> without
      pid -> GenServer.call(pid, request, 15_000)
    end
  catch
    :exit, {:noproc, _} -> without
    :exit, {:normal, _} -> without
  end

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(owner),
    do: {:ok, %{owner: owner, owner_ref: Process.monitor(owner), output: nil, mic: nil}}

  @impl true
  def handle_call(:open_output, _from, s) do
    s = close(s, :output)

    case MobAudioIo.open(self(), :output, processor: "magpie_out", module: @nif) do
      {:ok, stream} ->
        {:reply, {:ok, output_info(MobAudioIo.status(stream))}, %{s | output: stream}}

      {:error, {:unavailable, detail}} ->
        Logger.warning("[magpie_audio] no output: #{detail}")
        {:reply, {:error, :output_unavailable}, s}

      {:error, _} = error ->
        {:reply, error, s}
    end
  end

  def handle_call(:close_output, _from, s), do: {:reply, :ok, close(s, :output)}

  def handle_call({:open_mic, rate}, _from, s) do
    s = close(s, :mic)

    case open_mic(rate, :unprocessed) do
      {:ok, stream} -> {:reply, :ok, %{s | mic: stream}}
      {:error, reason} -> {:reply, {:error, mic_error(reason)}, s}
    end
  end

  def handle_call(:close_mic, _from, s), do: {:reply, :ok, close(s, :mic)}

  def handle_call(:status, _from, s),
    do: {:reply, %{output: stream_status(s.output), mic: stream_status(s.mic)}, s}

  def handle_call(:reset_stats, _from, s) do
    for stream <- [s.output, s.mic], stream != nil, do: MobAudioIo.reset_stats(stream)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info({:mob_audio_io, kind, mic, _}, %{mic: mic} = s)
      when mic != nil and kind in [:device_lost, :interrupted] do
    Logger.info("[magpie_audio] the microphone went (#{kind}): the input closes")
    {:noreply, s}
  end

  def handle_info({:mob_audio_io, :stopped, stream, %{reason: reason}}, s)
      when reason in [:closed, :owner_exit] do
    {:noreply, forget(s, stream)}
  end

  # Starts, reopens, xruns, errors of reopens: the plugin handles them (and
  # logs them); the engine hears of them through the stream events.
  def handle_info({:mob_audio_io, _kind, _stream, _payload}, s), do: {:noreply, s}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = s), do: {:stop, :normal, s}

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    s |> close(:mic) |> close(:output)
    :ok
  end

  # The preset the device refuses, then its default (Android's
  # VOICE_RECOGNITION), as the engine did before the plugin.
  defp open_mic(rate, preset) do
    opts = [processor: "magpie_mic", module: @nif, rate: rate, input_channels: 1, preset: preset]

    case MobAudioIo.open(self(), :input, opts) do
      {:error, {:unavailable, detail}} when preset == :unprocessed ->
        Logger.info("[magpie_audio] unprocessed input refused (#{detail}): the default preset")
        open_mic(rate, :default)

      result ->
        result
    end
  end

  defp mic_error(:permission), do: :no_permission

  defp mic_error({:unavailable, detail}) do
    Logger.warning("[magpie_audio] no microphone: #{detail}")
    :input_unavailable
  end

  defp mic_error(reason), do: reason

  defp close(s, which) do
    case Map.fetch!(s, which) do
      nil ->
        s

      stream ->
        _ = MobAudioIo.close(stream)
        Map.put(s, which, nil)
    end
  end

  defp forget(%{output: stream} = s, stream), do: %{s | output: nil}
  defp forget(%{mic: stream} = s, stream), do: %{s | mic: nil}
  defp forget(s, _stream), do: s

  defp stream_status(nil), do: nil

  defp stream_status(stream) do
    case MobAudioIo.status(stream) do
      %{} = status -> status
      {:error, _} -> nil
    end
  end

  defp output_info(%{} = status),
    do: %{rate: status.rate, burst: status.burst, buffer_frames: status.buffer, low_latency: nil}

  defp output_info({:error, _}),
    do: %{rate: nil, burst: nil, buffer_frames: nil, low_latency: nil}
end
