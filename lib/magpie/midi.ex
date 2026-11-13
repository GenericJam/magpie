defmodule Magpie.Midi do
  @moduledoc """
  MIDI devices: which ones are open, one process started from
  `Magpie.App.on_start/0` after the Engine. Notes and clock never pass
  through here (the engine and the plugin's Kotlin move them, see
  `decisions/2026-11-13-midi.md`); this process only decides what is
  connected.

  - **The Magpie port** (a virtual device "Magpie", one input and one
    output) is always there for other apps; `snapshot/0`'s `port` counts the
    apps connected to it (`inputs`: sending to Magpie, `outputs`:
    listening).
  - **USB and Bluetooth devices open when they appear** (hot-plug), both
    ways. Other apps' virtual ports (Humdinger's "Humdinger") open only when
    the user turns them on: opening one starts that app's service.
  - `set_open/2` turns a device on or off and remembers it by type and
    name (`Mob.State`, when it runs), so a device the user turned off stays
    off when plugged in again, and a port turned on reopens next time.
  - **Bluetooth MIDI**: `ble_scan/0` (10 s; needs the `:midi_bluetooth`
    permission), `ble_connect/1`; a connected device then appears as a
    `:bluetooth` device and opens. The last one connected is reconnected
    at start.

  Subscribers (`subscribe/1`, monitored) get `{:magpie_midi, %{devices,
  port, scan}}` on every change. Each device: `t:Magpie.Audio.midi_device/0`
  plus `status` (`:open | :opening | :closed | {:failed, reason}`) and
  `wanted` (what the policy above says). `scan`: `%{state: :idle |
  :scanning, found: [%{address, name, rssi}], error: atom | nil}`.

  Without MIDI (the host's Fake without devices, a phone without the
  service) the list is empty and nothing fails.
  """

  use GenServer

  require Logger

  alias Magpie.Audio

  @scan_ms 10_000
  @prefs_key :magpie_midi_devices
  @ble_key :magpie_midi_ble

  defstruct devices: %{},
            prefs: %{},
            ble: nil,
            persist: true,
            port: %{inputs: 0, outputs: 0},
            scan: %{state: :idle, found: [], error: nil},
            subscribers: %{}

  # ── API ─────────────────────────────────────────────────────────────────────

  @doc "Options: `persist:` (true) keeps the user's choices in `Mob.State` when it runs."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Send `{:magpie_midi, snapshot}` to `pid` on every change. Returns the snapshot now."
  def subscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Turn device `id` on (open both ways) or off, and remember it."
  @spec set_open(integer(), boolean()) :: :ok | {:error, :unknown_device}
  def set_open(id, on) when is_integer(id) and is_boolean(on),
    do: GenServer.call(__MODULE__, {:set_open, id, on})

  @doc "Scan for Bluetooth-MIDI devices (10 s). Errors as `c:Magpie.Audio.midi_ble_scan/1`."
  def ble_scan, do: GenServer.call(__MODULE__, :ble_scan)

  @doc "Connect a Bluetooth-MIDI device found by a scan."
  def ble_connect(address) when is_binary(address),
    do: GenServer.call(__MODULE__, {:ble_connect, address})

  @doc false
  # A device as the engine's JSON has it (string keys) → `t:Magpie.Audio.midi_device/0`.
  def device(%{"id" => id} = d) do
    %{
      id: id,
      name: Map.get(d, "name", "MIDI device"),
      type: type(Map.get(d, "type")),
      inputs: Map.get(d, "inputs", 0),
      outputs: Map.get(d, "outputs", 0),
      own: Map.get(d, "own", false),
      address: Map.get(d, "address", "")
    }
  end

  defp type("usb"), do: :usb
  defp type("bluetooth"), do: :bluetooth
  defp type(_), do: :virtual

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    s = %__MODULE__{persist: Keyword.get(opts, :persist, true)}
    s = %{s | prefs: recall(s, @prefs_key, %{}), ble: recall(s, @ble_key, nil)}

    with :ok <- Audio.impl().midi_listen(self()),
         {:ok, devices} <- Audio.impl().midi_devices() do
      s = Enum.reduce(devices, s, &add(&2, &1))
      if s.ble, do: _ = Audio.impl().midi_ble_connect(s.ble)
      {:ok, s}
    else
      {:error, reason} ->
        Logger.info("Magpie.Midi: no MIDI (#{inspect(reason)})")
        {:ok, s}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, s) do
    subscribers =
      if Map.has_key?(s.subscribers, pid),
        do: s.subscribers,
        else: Map.put(s.subscribers, pid, Process.monitor(pid))

    {:reply, view(s), %{s | subscribers: subscribers}}
  end

  def handle_call(:snapshot, _from, s), do: {:reply, view(s), s}

  def handle_call({:set_open, id, on}, _from, s) do
    case s.devices[id] do
      nil ->
        {:reply, {:error, :unknown_device}, s}

      device ->
        prefs = Map.put(s.prefs, key(device), on)
        remember(s, @prefs_key, prefs)
        s = %{s | prefs: prefs}
        {:reply, :ok, s |> apply_policy(id) |> publish()}
    end
  end

  def handle_call(:ble_scan, _from, s) do
    case Audio.impl().midi_ble_scan(@scan_ms) do
      :ok -> {:reply, :ok, publish(%{s | scan: %{state: :scanning, found: [], error: nil}})}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:ble_connect, address}, _from, s),
    do: {:reply, Audio.impl().midi_ble_connect(address), s}

  @impl true
  def handle_info({:magpie_midi, tag, json}, s) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, data} when is_map(data) ->
        {:noreply, s |> event(tag, data) |> publish()}

      _ ->
        Logger.warning("Magpie.Midi: unreadable #{tag} event #{inspect(json)}")
        {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # ── Events ──────────────────────────────────────────────────────────────────

  defp event(s, :added, data), do: add(s, device(data))
  defp event(s, :removed, %{"id" => id}), do: %{s | devices: Map.delete(s.devices, id)}
  defp event(s, :opened, %{"id" => id}), do: status(s, id, :open)
  defp event(s, :closed, %{"id" => id}), do: status(s, id, :closed)

  defp event(s, :open_failed, %{"id" => id} = data),
    do: status(s, id, {:failed, reason(Map.get(data, "reason"))})

  defp event(s, :port, data),
    do: %{s | port: %{inputs: Map.get(data, "inputs", 0), outputs: Map.get(data, "outputs", 0)}}

  defp event(s, :ble_found, %{"address" => address} = data) do
    found = %{address: address, name: Map.get(data, "name", ""), rssi: Map.get(data, "rssi")}
    others = Enum.reject(s.scan.found, &(&1.address == address))
    put_in(s.scan.found, others ++ [found])
  end

  defp event(s, :ble_scan_done, data),
    do: %{s | scan: %{s.scan | state: :idle, error: reason(Map.get(data, "error"))}}

  defp event(s, :ble_connected, %{"address" => address}) do
    remember(s, @ble_key, address)
    %{s | ble: address}
  end

  defp event(s, :ble_failed, data), do: put_in(s.scan.error, reason(Map.get(data, "reason")))
  defp event(s, _tag, _data), do: s

  # Why the plugin says something failed (a known word, else :error).
  @reasons ~w(no_permission bluetooth_off location_off no_bluetooth scan_failed open_failed
              no_activity no_midi_service bad_address unknown_device unavailable)a

  defp reason(nil), do: nil
  defp reason(r) when is_binary(r), do: Enum.find(@reasons, :error, &(Atom.to_string(&1) == r))

  # ── Policy ──────────────────────────────────────────────────────────────────

  defp add(s, device) do
    device = Map.merge(device, %{status: :closed})
    s |> put_in([Access.key(:devices), device.id], device) |> apply_policy(device.id)
  end

  defp status(s, id, status) do
    case s.devices[id] do
      nil -> s
      _ -> put_in(s.devices[id].status, status)
    end
  end

  # Open a wanted device that isn't, close an unwanted one that is.
  defp apply_policy(s, id) do
    device = s.devices[id]
    wanted = wanted?(s, device)

    cond do
      wanted and (device.status == :closed or match?({:failed, _}, device.status)) ->
        open(s, device)

      not wanted and device.status in [:open, :opening] ->
        _ = Audio.impl().midi_close(id)
        status(s, id, :closed)

      true ->
        s
    end
  end

  defp open(s, device) do
    case Audio.impl().midi_open(device.id) do
      :ok -> status(s, device.id, :opening)
      {:error, reason} -> status(s, device.id, {:failed, reason})
    end
  end

  defp wanted?(_s, %{own: true}), do: false
  defp wanted?(_s, %{inputs: 0, outputs: 0}), do: false

  defp wanted?(s, device) do
    case Map.fetch(s.prefs, key(device)) do
      {:ok, on} -> on
      :error -> device.type in [:usb, :bluetooth]
    end
  end

  defp key(device), do: {device.type, device.name}

  defp view(s) do
    devices =
      s.devices
      |> Map.values()
      |> Enum.reject(& &1.own)
      |> Enum.map(&Map.put(&1, :wanted, wanted?(s, &1)))
      |> Enum.sort_by(&{&1.type, &1.name, &1.id})

    %{devices: devices, port: s.port, scan: s.scan}
  end

  defp publish(s) do
    if map_size(s.subscribers) > 0 do
      message = {:magpie_midi, view(s)}
      Enum.each(Map.keys(s.subscribers), &send(&1, message))
    end

    s
  end

  # ── Remembering ─────────────────────────────────────────────────────────────

  defp recall(%{persist: true}, key, default) do
    if Process.whereis(Mob.State), do: Mob.State.get(key, default), else: default
  end

  defp recall(_s, _key, default), do: default

  defp remember(%{persist: true}, key, value) do
    if Process.whereis(Mob.State), do: Mob.State.put(key, value)
    :ok
  end

  defp remember(_s, _key, _value), do: :ok
end
