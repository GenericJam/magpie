defmodule Magpie.Midi do
  @moduledoc """
  MIDI devices: which ones are open, one process started from
  `Magpie.App.on_start/0` after the Engine. Devices and ports are mob_midi's
  (`MobMidi`; `impl/0` is `Magpie.Midi.Fake` in host tests). Notes and clock
  never pass through here: inputs open with `deliver: :native`, so their
  bytes go from mob_midi's receive threads straight to the engine's C, and
  the engine sends to the output handles this process gives it
  (`c:Magpie.Audio.midi_outputs/1`); see `decisions/2026-11-13-midi.md`.

  - **The Magpie device** (Magpie's own virtual device "Magpie", one input
    and one output, declared by `mix mob_midi.gen.virtual_device`) is always
    there for other apps; `snapshot/0`'s `port` counts the apps connected
    to it (`inputs`: sending to Magpie, `outputs`: listening).
  - **USB and Bluetooth devices open when they appear** (hot-plug): every
    port Magpie can read (`port: :all`) and output port 0. Other apps'
    virtual devices (Humdinger's "Humdinger") open only when the user turns
    them on: opening one starts that app's service.
  - `set_open/2` turns a device on or off and remembers it by type and
    name (`Mob.State`, when it runs), so a device the user turned off stays
    off when plugged in again, and a port turned on reopens next time.
  - **Bluetooth MIDI**: `ble_scan/0` (10 s; needs the `:midi_bluetooth`
    permission), `ble_connect/1`; a connected device then appears as a
    `:bluetooth` device and opens. The last one connected is reconnected
    at start.

  Subscribers (`subscribe/1`, monitored) get `{:magpie_midi, %{devices,
  port, scan}}` on every change. Each device: `%{id, name, type, address,
  input_ports, output_ports}` (`MobMidi.parse_devices/1`; `input_ports`
  are what Magpie reads, `output_ports` what it sends to) plus `status`
  (`:open | :opening | :closed | {:failed, reason}`) and `wanted` (what the
  policy above says). `scan`: `%{state: :idle | :scanning, found:
  [%{address, name, rssi}], error: atom | nil}`.

  Without MIDI (the host, a phone without the MIDI service) the list is
  empty and nothing fails.
  """

  use GenServer

  require Logger

  alias Magpie.Audio

  @name "Magpie"
  @scan_ms 10_000
  @prefs_key :magpie_midi_devices
  @ble_key :magpie_midi_ble

  defstruct devices: %{},
            own: nil,
            handles: %{},
            pushed: nil,
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

  @doc """
  Scan for Bluetooth-MIDI devices (10 s): `:ok`, then the snapshot's
  `scan` (what it finds, or why it couldn't: `:permission_denied`,
  `:bluetooth_off`, `:location_off`, ...). `{:error, :unsupported}` without
  Bluetooth MIDI.
  """
  @spec ble_scan() :: :ok | {:error, term()}
  def ble_scan, do: GenServer.call(__MODULE__, :ble_scan)

  @doc "Connect a Bluetooth-MIDI device found by a scan (a failure shows as the scan's `error`)."
  @spec ble_connect(String.t()) :: :ok | {:error, term()}
  def ble_connect(address) when is_binary(address),
    do: GenServer.call(__MODULE__, {:ble_connect, address})

  @doc "`MobMidi` on the phone, `Magpie.Midi.Fake` in host tests (`config :magpie, :midi`)."
  def impl, do: Application.get_env(:magpie, :midi, MobMidi)

  # ── Server ──────────────────────────────────────────────────────────────────

  # MobMidi's calls take a Mob socket and hand it back; this process has none.
  @socket nil

  @impl true
  def init(opts) do
    s = %__MODULE__{persist: Keyword.get(opts, :persist, true)}
    s = %{s | prefs: recall(s, @prefs_key, %{}), ble: recall(s, @ble_key, nil)}
    # Answers arrive as {:midi, ...} messages.
    _ = impl().list_devices(@socket)
    _ = impl().open_virtual(@socket, @name, deliver: :native)
    if s.ble, do: _ = impl().connect_bluetooth(@socket, s.ble)
    {:ok, s}
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
    case impl().scan_bluetooth(@socket, duration_ms: @scan_ms) do
      {:error, _} = error ->
        {:reply, error, s}

      _socket ->
        {:reply, :ok, publish(%{s | scan: %{state: :scanning, found: [], error: nil}})}
    end
  end

  def handle_call({:ble_connect, address}, _from, s) do
    case impl().connect_bluetooth(@socket, address) do
      {:error, _} = error -> {:reply, error, s}
      _socket -> {:reply, :ok, s}
    end
  end

  @impl true
  def handle_info({:midi, tag, data}, s), do: {:noreply, s |> midi(tag, data) |> publish()}

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # ── mob_midi's messages ─────────────────────────────────────────────────────

  defp midi(s, :devices, payload), do: payload |> MobMidi.parse_devices() |> listed(s)

  # Hot-plug: list again (mob_midi has closed a removed device's ports).
  defp midi(s, event, _) when event in [:device_added, :device_removed] do
    _ = impl().list_devices(@socket)
    s
  end

  defp midi(s, :opened, %{direction: :virtual, device: id}) do
    handle =
      case impl().output_handle(id) do
        {:ok, h} -> h
        {:error, _} -> nil
      end

    push_outputs(%{s | own: %{id: id, handle: handle}})
  end

  defp midi(s, :opened, %{direction: :input, device: id}), do: part(s, id, :input, :open)

  defp midi(s, :opened, %{direction: :output, device: id, handle: handle}) do
    case part(s, id, :output, :open) do
      ^s -> s
      s -> push_outputs(put_in(s.handles[id], handle))
    end
  end

  # Another app started or stopped sending into Magpie's own device, or
  # listening to it: what a sender that left held ends.
  defp midi(s, :virtual_status, %{senders: senders, listeners: listeners}) do
    sources_changed()
    %{s | port: %{inputs: senders, outputs: listeners}}
  end

  # An open close/2 cancelled: that close already set the device straight.
  defp midi(s, :error, %{reason: :closed}), do: s

  defp midi(s, :error, %{op: op, device: id, reason: reason})
       when op in [:open_input, :open_output] do
    part(s, id, if(op == :open_input, do: :input, else: :output), {:failed, reason})
  end

  defp midi(s, :error, %{op: :scan_bluetooth, reason: reason}),
    do: %{s | scan: %{s.scan | state: :idle, error: reason}}

  defp midi(s, :error, %{op: :connect_bluetooth, reason: reason}),
    do: put_in(s.scan.error, reason)

  defp midi(s, :error, %{op: op, reason: reason}) do
    Logger.info("Magpie.Midi: #{op} failed (#{inspect(reason)})")
    s
  end

  defp midi(s, :bluetooth_scan, :started), do: %{s | scan: %{s.scan | state: :scanning}}
  defp midi(s, :bluetooth_scan, :stopped), do: %{s | scan: %{s.scan | state: :idle}}

  defp midi(s, :bluetooth_device, %{address: address} = found) do
    found = %{address: address, name: Map.get(found, :name) || "", rssi: Map.get(found, :rssi)}
    others = Enum.reject(s.scan.found, &(&1.address == address))
    put_in(s.scan.found, others ++ [found])
  end

  defp midi(s, :connected, %{address: address}) do
    remember(s, @ble_key, address)
    %{s | ble: address}
  end

  # :raw (inputs go to the engine), :drained (the engine owes and retries
  # itself), anything newer.
  defp midi(s, _tag, _data), do: s

  # ── Devices ─────────────────────────────────────────────────────────────────

  # A fresh list: devices gone are dropped (mob_midi closed their ports),
  # new ones added, the rest keep their state.
  defp listed(devices, s) do
    ids = MapSet.new(devices, & &1.id)
    {gone, kept} = Map.split_with(s.devices, fn {id, _} -> not MapSet.member?(ids, id) end)
    s = %{s | devices: kept, handles: Map.drop(s.handles, Map.keys(gone))}
    if map_size(gone) > 0, do: sources_changed()

    devices
    |> Enum.reject(&(&1.own or Map.has_key?(s.devices, &1.id)))
    |> Enum.reduce(s, &add(&2, &1))
    |> push_outputs()
  end

  defp add(s, device) do
    device = device |> Map.take(~w(id name type address input_ports output_ports)a)
    device = Map.put(device, :parts, %{})
    s |> put_in([Access.key(:devices), device.id], device) |> apply_policy(device.id)
  end

  # mob_midi answers each port it opens (`port: :all`: every one) with
  # :opened or an error; these refuse the whole open at once.
  @device_errors [:no_midi_service, :no_such_device, :no_such_port]

  # A port's answer for a device still waiting for it; an answer for a
  # device closed since is old news.
  defp part(s, id, which, answer) do
    case s.devices[id] do
      %{parts: %{^which => %{pending: pending} = part}} when pending > 0 ->
        put_in(s.devices[id].parts[which], answered(part, answer))

      _ ->
        s
    end
  end

  defp answered(part, :open), do: %{part | pending: part.pending - 1, open: part.open + 1}

  defp answered(part, {:failed, reason}) when reason in @device_errors,
    do: %{part | pending: 0, error: reason}

  defp answered(part, {:failed, reason}), do: %{part | pending: part.pending - 1, error: reason}

  # :open when a port is, else :opening while one is awaited, {:failed,
  # reason} when every port asked for failed, :closed when none was.
  defp status(%{parts: parts}) do
    parts = Map.values(parts)

    cond do
      Enum.any?(parts, &(&1.open > 0)) -> :open
      Enum.any?(parts, &(&1.pending > 0)) -> :opening
      error = Enum.find_value(parts, & &1.error) -> {:failed, error}
      true -> :closed
    end
  end

  # Why a port failed on a device whose other ports opened (nil: none did).
  defp port_error(%{parts: parts} = device) do
    if status(device) == :open, do: parts |> Map.values() |> Enum.find_value(& &1.error)
  end

  # ── Policy ──────────────────────────────────────────────────────────────────

  # Open a wanted device that isn't, close an unwanted one that is.
  defp apply_policy(s, id) do
    device = s.devices[id]
    status = status(device)

    cond do
      wanted?(s, device) and (status == :closed or match?({:failed, _}, status)) ->
        open(s, device)

      not wanted?(s, device) and status in [:open, :opening] ->
        _ = impl().close(@socket, id)
        sources_changed()
        s = put_in(s.devices[id].parts, %{})
        push_outputs(%{s | handles: Map.delete(s.handles, id)})

      true ->
        s
    end
  end

  # Every port Magpie can read, into the engine; output port 0 for what it
  # sends. Each port answers :opened or an error.
  defp open(s, device) do
    parts =
      [
        {:input, device.input_ports,
         fn -> impl().open_input(@socket, device.id, port: :all, deliver: :native) end},
        {:output, min(device.output_ports, 1), fn -> impl().open_output(@socket, device.id) end}
      ]
      |> Enum.filter(fn {_, ports, _} -> ports > 0 end)
      |> Map.new(fn {which, ports, open} ->
        case open.() do
          {:error, reason} -> {which, %{pending: 0, open: 0, error: reason}}
          _socket -> {which, %{pending: ports, open: 0, error: nil}}
        end
      end)

    put_in(s.devices[device.id].parts, parts)
  end

  defp wanted?(_s, %{input_ports: 0, output_ports: 0}), do: false

  defp wanted?(s, device) do
    case Map.fetch(s.prefs, key(device)) do
      {:ok, on} -> on
      :error -> device.type in [:usb, :bluetooth]
    end
  end

  defp key(device), do: {device.type, device.name}

  # ── The engine ──────────────────────────────────────────────────────────────

  # The outputs the engine sends to: Magpie's own device and every opened
  # device's port 0, given when they change.
  defp push_outputs(s) do
    own = if s.own && s.own.handle, do: [s.own.handle], else: []
    handles = own ++ (s.handles |> Enum.sort() |> Enum.map(&elem(&1, 1)))

    if handles == s.pushed do
      s
    else
      :ok = Audio.impl().midi_outputs(handles)
      %{s | pushed: handles}
    end
  end

  defp sources_changed, do: :ok = Audio.impl().midi_sources_changed()

  # ── The view ────────────────────────────────────────────────────────────────

  defp view(s) do
    devices =
      s.devices
      |> Map.values()
      |> Enum.map(fn d ->
        d
        |> Map.delete(:parts)
        |> Map.merge(%{status: status(d), error: port_error(d), wanted: wanted?(s, d)})
      end)
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
