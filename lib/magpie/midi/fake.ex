defmodule Magpie.Midi.Fake do
  @moduledoc """
  `MobMidi` for host tests (`config :magpie, :midi`): the calls
  `Magpie.Midi` makes, answering with the messages mob_midi sends on
  Android, to the calling process. One fake for the whole VM, like the
  phone's MIDI service; tests that use it don't run `async`.

  - `list_devices/1` answers `{:midi, :devices, devices}` and makes the
    caller the one hot-plug goes to (`plug/1`, `unplug/1`:
    `{:midi, :device_added | :device_removed, nil}`).
  - `open_input/3` answers one `{:midi, :opened, %{direction: :input}}`
    per port it opens (`port: :all`: every one), `open_output/3` one with
    a new `handle`; both answer `{:midi, :error, %{op, reason}}` instead
    while `fail_open/1` says so, or for a device it doesn't know.
  - `open_virtual/3` opens an own device of that name (`own: true`),
    `output_handle/2` gives an open output's handle (or the own device's).
  - `scan_bluetooth/2` answers `{:midi, :bluetooth_scan, :started}`;
    it and `connect_bluetooth/2` are recorded in `calls/0`.
  - `event/2` sends the hot-plug process anything else.

  `state/0`'s devices carry `input: true` / `output: handle` while open.
  """

  use GenServer

  # ── MobMidi ─────────────────────────────────────────────────────────────────

  def list_devices(socket), do: answer(socket, {:list, self()})

  def open_input(socket, id, opts \\ []) when is_integer(id),
    do: answer(socket, {:open_input, self(), id, Keyword.get(opts, :port, 0)})

  def open_output(socket, id, opts \\ []) when is_integer(id),
    do: answer(socket, {:open_output, self(), id, Keyword.get(opts, :port, 0)})

  def close(socket, id) when is_integer(id), do: answer(socket, {:close, id})

  def open_virtual(socket, name, _opts \\ []) when is_binary(name),
    do: answer(socket, {:open_virtual, self(), name})

  def output_handle(id, _opts \\ []) when is_integer(id), do: call({:output_handle, id})

  def scan_bluetooth(socket, opts \\ []),
    do: answer(socket, {:call, self(), {:scan, Keyword.get(opts, :duration_ms, 10_000)}})

  def connect_bluetooth(socket, address) when is_binary(address),
    do: answer(socket, {:call, self(), {:connect, address}})

  # ── Driving it from a test ──────────────────────────────────────────────────

  @doc """
  A device appears: `%{id, name, type, input_ports, output_ports}` (`own`
  and `address` optional).
  """
  def plug(%{id: id} = device) when is_integer(id), do: call({:plug, device})

  @doc "Device `id` goes away (its ports close)."
  def unplug(id) when is_integer(id), do: call({:unplug, id})

  @doc "Opens answer `{:midi, :error, ...}` with `reason` (nil: they open again)."
  def fail_open(reason), do: call({:fail_open, reason})

  @doc "Send the hot-plug process `{:midi, tag, data}`."
  def event(tag, data), do: call({:event, tag, data})

  @doc "No devices, no failure armed, no calls."
  def reset, do: call(:reset)

  def state, do: call(:state)

  @doc "`scan_bluetooth/2` and `connect_bluetooth/2` calls, oldest first."
  def calls, do: :state |> call() |> Map.fetch!(:calls) |> Enum.reverse()

  # ── Server ──────────────────────────────────────────────────────────────────

  # MobMidi's calls hand the socket back.
  defp answer(socket, request) do
    :ok = call(request)
    socket
  end

  defp call(request) do
    pid =
      case GenServer.start(__MODULE__, nil, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.call(pid, request)
  end

  defp fresh(listener),
    do: %{devices: %{}, listener: listener, fail: nil, calls: [], handle: 0, source: 0}

  @impl true
  def init(nil), do: {:ok, fresh(nil)}

  @impl true
  def handle_call({:list, pid}, _from, s) do
    send(
      pid,
      {:midi, :devices, Enum.map(Map.values(s.devices), &Map.drop(&1, [:input, :output]))}
    )

    {:reply, :ok, %{s | listener: pid}}
  end

  def handle_call({:open_input, pid, id, port}, _from, s) do
    case opening(s, id, :open_input) do
      {:error, error} ->
        send(pid, {:midi, :error, error})
        {:reply, :ok, s}

      :ok ->
        ports =
          if port == :all, do: Enum.to_list(0..(s.devices[id].input_ports - 1)//1), else: [port]

        s =
          Enum.reduce(ports, s, fn p, acc ->
            source = rem(acc.source, 63) + 1
            send(pid, {:midi, :opened, %{device: id, port: p, direction: :input, source: source}})
            %{acc | source: source}
          end)

        {:reply, :ok, put_in(s.devices[id].input, true)}
    end
  end

  def handle_call({:open_output, pid, id, port}, _from, s) do
    case opening(s, id, :open_output) do
      {:error, error} ->
        send(pid, {:midi, :error, error})
        {:reply, :ok, s}

      :ok ->
        handle = s.handle + 1
        send(pid, {:midi, :opened, %{device: id, port: port, direction: :output, handle: handle}})
        {:reply, :ok, %{put_in(s.devices[id].output, handle) | handle: handle}}
    end
  end

  def handle_call({:close, id}, _from, s) do
    s =
      if s.devices[id],
        do: update_in(s.devices[id], &Map.merge(&1, %{input: false, output: nil})),
        else: s

    {:reply, :ok, s}
  end

  def handle_call({:open_virtual, pid, name}, _from, s) do
    case Enum.find(Map.values(s.devices), &(&1.own and &1.name == name)) do
      nil ->
        error = %{device: 0, op: :open_virtual, reason: :no_such_device, dropped: 0}
        send(pid, {:midi, :error, error})
        {:reply, :ok, s}

      device ->
        handle = s.handle + 1
        send(pid, {:midi, :opened, %{device: device.id, direction: :virtual, name: name}})
        {:reply, :ok, %{put_in(s.devices[device.id].output, handle) | handle: handle}}
    end
  end

  def handle_call({:output_handle, id}, _from, s) do
    case s.devices[id] do
      %{output: handle} when is_integer(handle) -> {:reply, {:ok, handle}, s}
      _ -> {:reply, {:error, :not_open}, s}
    end
  end

  def handle_call({:call, pid, {:scan, _} = call}, _from, s) do
    send(pid, {:midi, :bluetooth_scan, :started})
    {:reply, :ok, %{s | calls: [call | s.calls]}}
  end

  def handle_call({:call, _pid, call}, _from, s),
    do: {:reply, :ok, %{s | calls: [call | s.calls]}}

  def handle_call({:plug, device}, _from, s) do
    defaults = %{
      own: false,
      address: "",
      manufacturer: "",
      direction: :both,
      input: false,
      output: nil
    }

    device = Map.merge(defaults, device)
    tell(s, :device_added, nil)
    {:reply, :ok, put_in(s.devices[device.id], device)}
  end

  def handle_call({:unplug, id}, _from, s) do
    case Map.pop(s.devices, id) do
      {nil, _} ->
        {:reply, :ok, s}

      {_device, devices} ->
        tell(s, :device_removed, nil)
        {:reply, :ok, %{s | devices: devices}}
    end
  end

  def handle_call({:fail_open, reason}, _from, s), do: {:reply, :ok, %{s | fail: reason}}

  def handle_call({:event, tag, data}, _from, s) do
    tell(s, tag, data)
    {:reply, :ok, s}
  end

  def handle_call(:reset, _from, s), do: {:reply, :ok, fresh(s.listener)}
  def handle_call(:state, _from, s), do: {:reply, s, s}

  defp opening(s, id, op) do
    cond do
      s.devices[id] == nil -> {:error, %{device: id, op: op, reason: :no_such_device, dropped: 0}}
      s.fail -> {:error, %{device: id, op: op, reason: s.fail, dropped: 0}}
      true -> :ok
    end
  end

  defp tell(%{listener: nil}, _tag, _data), do: :ok
  defp tell(s, tag, data), do: send(s.listener, {:midi, tag, data})
end
