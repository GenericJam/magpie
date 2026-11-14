defmodule Magpie.MidiScreen do
  @moduledoc """
  MIDI settings: a plain screen, **not designed** (the Connect board only
  shows the two summary rows "MIDI in · Magpie port · all ch" and "Clock ·
  follow FMutate"). Replace it when the design exists. Opened from the
  magpie menu button on the pads.

  Left: MIDI in channel (tap: all → 1 → … → 16 → all; notes out go on the
  same channel, 1 with all), clock (tap: internal ↔ send; no follow yet: a
  kit saying `follow` shows and plays internal), and the Magpie
  port's connections. Right: the devices (`Magpie.Midi`): tap one to turn
  it on or off; "Scan for Bluetooth MIDI" (asks for the `:midi_bluetooth`
  permission first if needed) lists what it finds, tap one to connect.

  Settings go to the kit (`Magpie.KitSession.set_midi/1`) and are saved
  with it. Every tap target has `on_press_out={held()}` (MOB-509): the
  screen re-renders on device and kit messages.
  """

  use Mob.Screen

  import Mob.Canvas

  alias Magpie.{KitSession, Midi, Style}

  @clocks [:internal, :send]

  @impl true
  def mount(_params, _session, socket) do
    snapshot = KitSession.subscribe()
    midi = Midi.subscribe()
    if device_calls?(), do: Mob.Device.lock_orientation(:landscape)

    {:ok,
     Mob.Socket.assign(socket,
       kit: snapshot.kit,
       midi: midi,
       notice: nil
     )}
  end

  defp device_calls?, do: Application.get_env(:magpie, :device_calls, true)

  defp held, do: {self(), :held}

  # ── Messages ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:magpie_kit, snapshot}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :kit, snapshot.kit)}

  # A scan that fails (no permission, Bluetooth off, ...) says why.
  def handle_info({:magpie_midi, midi}, socket) do
    socket =
      if midi.scan.error && midi.scan.error != socket.assigns.midi.scan.error,
        do: Mob.Socket.assign(socket, :notice, scan_error(midi.scan.error)),
        else: socket

    {:noreply, Mob.Socket.assign(socket, :midi, midi)}
  end

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :in_channel}, socket) do
    :ok = KitSession.set_midi(%{in_channel: next_channel(socket.assigns.kit.midi.in_channel)})
    {:noreply, socket}
  end

  def handle_info({:tap, :clock}, socket) do
    :ok = KitSession.set_midi(%{clock: next_clock(socket.assigns.kit.midi.clock)})
    {:noreply, socket}
  end

  def handle_info({:tap, {:device, id}}, socket) do
    device = Enum.find(socket.assigns.midi.devices, &(&1.id == id))
    if device, do: Midi.set_open(id, not device.wanted)
    {:noreply, socket}
  end

  # Scanning needs the :midi_bluetooth permission: ask (the answer comes at
  # once when it was given before), scan once granted.
  def handle_info({:tap, :scan}, socket) do
    if device_calls?(),
      do: {:noreply, Mob.Permissions.request(socket, :midi_bluetooth)},
      else: {:noreply, scan(socket)}
  end

  def handle_info({:tap, {:ble, address}}, socket) do
    notice =
      case Midi.ble_connect(address) do
        :ok -> "Connecting…"
        {:error, reason} -> "Can't connect (#{reason})."
      end

    {:noreply, Mob.Socket.assign(socket, :notice, notice)}
  end

  def handle_info({:permission, :midi_bluetooth, :granted}, socket), do: {:noreply, scan(socket)}

  def handle_info({:permission, :midi_bluetooth, _denied}, socket),
    do:
      {:noreply,
       Mob.Socket.assign(socket, :notice, "Bluetooth MIDI needs the Nearby devices permission.")}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp scan(socket) do
    case Midi.ble_scan() do
      :ok -> Mob.Socket.assign(socket, :notice, nil)
      {:error, reason} -> Mob.Socket.assign(socket, :notice, scan_error(reason))
    end
  end

  defp scan_error(:permission_denied), do: "Bluetooth MIDI needs the Nearby devices permission."
  defp scan_error(:bluetooth_off), do: "Bluetooth is off."
  defp scan_error(:location_off), do: "Turn location on to scan for Bluetooth MIDI."
  defp scan_error(:unsupported), do: "This phone can't scan for Bluetooth MIDI."
  defp scan_error(reason), do: "Bluetooth MIDI failed (#{reason})."

  @doc false
  def next_channel(:all), do: 1
  def next_channel(16), do: :all
  def next_channel(n) when n in 1..15, do: n + 1

  @doc false
  def next_clock(clock) do
    i = Enum.find_index(@clocks, &(&1 == clock)) || 0
    Enum.at(@clocks, rem(i + 1, length(@clocks)))
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~MOB"""
    <Column
      background={Style.color(:bg)}
      fill_width={true}
      fill_height={true}
      padding_left={28}
      padding_right={28}
      padding_top={8}
      padding_bottom={8}
      gap={8}
    >
      <Row gap={8} height={44}>
        <Canvas
          id="back"
          width={44}
          height={44}
          draw={back_ops()}
          on_tap={{self(), :back}}
          on_press_out={held()}
        />
        <Text text="MIDI" font={:bold} text_size={16} text_color={Style.color(:text)} />
      </Row>
      <Row gap={16} weight={1} fill_width={true}>
        {settings(assigns)}
        {devices(assigns)}
      </Row>
    </Column>
    """
  end

  defp settings(assigns) do
    midi = assigns.kit.midi

    ~MOB"""
    <Column weight={1} gap={8}>
      {setting_row("in_channel", "MIDI in", channel_label(midi.in_channel), :in_channel)}
      {setting_row("clock", "Clock", clock_label(midi.clock), :clock)}
      <Text
        id="port"
        text={port_label(assigns.midi.port)}
        text_size={12}
        text_color={Style.color(:muted)}
        max_lines={2}
      />
    </Column>
    """
  end

  defp setting_row(id, label, value, tap) do
    ~MOB"""
    <Row
      id={id}
      height={48}
      padding_left={12}
      padding_right={12}
      corner_radius={12}
      background={Style.color(:surface)}
      align={:center}
      on_tap={{self(), tap}}
      on_press_out={held()}
    >
      <Text text={label} font={:semibold} text_size={13} text_color={Style.color(:text)} />
      <Spacer />
      <Text text={value} font={:mono_semibold} text_size={12} text_color={Style.color(:fm)} />
    </Row>
    """
  end

  defp devices(assigns) do
    %{devices: devices, scan: scan} = assigns.midi

    ~MOB"""
    <Scroll weight={1}>
      <Column gap={6}>
        <Text
          text="DEVICES"
          font={:mono_semibold}
          text_size={11}
          letter_spacing={0.88}
          text_color={Style.color(:muted)}
        />
        <Text
          :if={devices == []}
          id="no_devices"
          text="Nothing plugged in. Other apps can play Magpie through its port."
          text_size={12}
          text_color={Style.color(:muted)}
          max_lines={2}
        />
        {for device <- devices, do: device_row(device)}
        <Row
          id="scan"
          height={44}
          padding_left={12}
          padding_right={12}
          corner_radius={12}
          background={Style.color(:raised)}
          align={:center}
          on_tap={{self(), :scan}}
          on_press_out={held()}
        >
          <Text
            text={scan_label(scan)}
            font={:semibold}
            text_size={13}
            text_color={Style.color(:text)}
          />
        </Row>
        {for found <- scan.found, do: found_row(found)}
        <Text
          :if={assigns.notice}
          id="notice"
          text={assigns.notice}
          text_size={12}
          text_color={Style.color(:text_2)}
          max_lines={2}
        />
      </Column>
    </Scroll>
    """
  end

  defp device_row(device) do
    on = device.wanted
    bg = Style.color(if on, do: :selected, else: :surface)

    ~MOB"""
    <Row
      id={"device_#{device.id}"}
      height={48}
      padding_left={12}
      padding_right={12}
      corner_radius={12}
      background={bg}
      align={:center}
      gap={8}
      on_tap={{self(), {:device, device.id}}}
      on_press_out={held()}
    >
      <Column weight={1}>
        <Text
          text={device.name}
          font={:semibold}
          text_size={13}
          text_color={Style.color(:text)}
          max_lines={1}
        />
        <Text
          text={device_detail(device)}
          text_size={11}
          text_color={Style.color(:muted)}
          max_lines={1}
        />
      </Column>
      <Text
        text={if(on, do: "on", else: "off")}
        font={:mono_semibold}
        text_size={12}
        text_color={Style.color(if on, do: :fm, else: :muted)}
      />
    </Row>
    """
  end

  defp found_row(found) do
    name = if found.name in [nil, ""], do: found.address, else: found.name

    ~MOB"""
    <Row
      id={"ble_#{found.address}"}
      height={44}
      padding_left={12}
      padding_right={12}
      corner_radius={12}
      background={Style.color(:surface)}
      align={:center}
      on_tap={{self(), {:ble, found.address}}}
      on_press_out={held()}
    >
      <Text text={name} text_size={13} text_color={Style.color(:text)} max_lines={1} />
      <Spacer />
      <Text text="connect" font={:mono_semibold} text_size={12} text_color={Style.color(:fm)} />
    </Row>
    """
  end

  @doc false
  def channel_label(:all), do: "all channels"
  def channel_label(n), do: "channel #{n}"

  @doc false
  def clock_label(:send), do: "send"
  # A kit's `follow` plays on the internal clock (not followed yet).
  def clock_label(_internal), do: "internal"

  @doc false
  def port_label(%{inputs: i, outputs: o}),
    do: "Magpie port: #{apps(i)} sending to it, #{apps(o)} listening"

  defp apps(1), do: "1 app"
  defp apps(n), do: "#{n} apps"

  @doc false
  def device_detail(device) do
    type =
      case device.type do
        :usb -> "USB"
        :bluetooth -> "Bluetooth"
        :virtual -> "app"
        :other -> "MIDI"
      end

    "#{type} · #{status_label(device.status)}"
  end

  defp status_label(:open), do: "open"
  defp status_label(:opening), do: "opening…"
  defp status_label(:closed), do: "closed"
  defp status_label({:failed, reason}), do: "can't open (#{reason})"

  defp scan_label(%{state: :scanning}), do: "Scanning for Bluetooth MIDI…"
  defp scan_label(_scan), do: "Scan for Bluetooth MIDI"

  defp back_ops do
    s = 18 / 24
    at = fn {x, y} -> {13 + x * s, 13 + y * s} end

    [
      circle(22, 22, 22, color: Style.color(:raised), fill: true),
      path(Enum.map([{15, 5}, {8, 12}, {15, 19}], at),
        color: Style.color(:text),
        width: 2,
        cap: :round,
        join: :round
      )
    ]
  end
end
