defmodule Magpie.MidiScreenTest do
  # The engine (the fake), the kit session and the MIDI devices are one per VM: not async.
  use Mob.ScreenCase, async: false

  import Magpie.Test.Kits
  import Magpie.Test.Screens, only: [assert_every_tap_held: 1, texts: 1]

  alias Magpie.{KitSession, Midi, MidiScreen}
  alias Magpie.Midi.Fake

  @usb %{id: 21, name: "Keystep", type: :usb, input_ports: 1, output_ports: 1}
  @humdinger %{id: 22, name: "Humdinger", type: :virtual, input_ports: 1, output_ports: 0}

  setup do
    setup_library()
    :ok = Fake.reset()
    Fake.plug(@usb)
    Fake.plug(@humdinger)
    start_session!(kit([{"A", pad(0, sample!("Kick", 0.2), midi_note: 36)}]))
    start_supervised!({Midi, persist: false})
    :ok
  end

  defp mount, do: MidiScreen |> mount_screen() |> pump()

  defp pump(view) do
    Magpie.Engine.state()
    KitSession.snapshot()
    Midi.snapshot()
    drain(view)
  end

  defp drain(view) do
    receive do
      {:magpie_kit, _} = msg -> view |> render_info(msg) |> drain()
      {:magpie_midi, _} = msg -> view |> render_info(msg) |> drain()
    after
      0 -> view
    end
  end

  defp press(view, tag), do: view |> render_info({:tap, tag}) |> pump()

  test "shows the channel, the clock, the port and the devices; every tap is held" do
    view = mount()
    all = texts(view)
    assert "all channels" in all
    assert "internal" in all
    assert "Magpie port: 0 apps sending to it, 0 apps listening" in all
    assert "Keystep" in all
    assert "USB · open" in all
    assert "Humdinger" in all
    assert "app · closed" in all
    assert assert_every_tap_held(view) > 0
  end

  test "MIDI in steps all → 1 … 16 → all, the clock internal ↔ send" do
    view = mount() |> press(:in_channel)
    assert KitSession.snapshot().kit.midi.in_channel == 1
    assert "channel 1" in texts(view)

    view = Enum.reduce(1..15, view, fn _, v -> press(v, :in_channel) end)
    assert KitSession.snapshot().kit.midi.in_channel == 16
    view = press(view, :in_channel)
    assert KitSession.snapshot().kit.midi.in_channel == :all

    view = press(view, :clock)
    assert KitSession.snapshot().kit.midi.clock == :send
    assert "send" in texts(view)
    view = press(view, :clock)
    assert KitSession.snapshot().kit.midi.clock == :internal
    assert "internal" in texts(view)
  end

  test "a kit saying follow shows internal (what plays); a tap goes to send" do
    kit = KitSession.snapshot().kit
    stop_supervised!(KitSession)
    start_session!(%{kit | midi: %{in_channel: :all, clock: :follow}})
    view = mount()
    assert "internal" in texts(view)
    _view = press(view, :clock)
    assert KitSession.snapshot().kit.midi.clock == :send
  end

  test "tapping a device turns it on or off" do
    view = mount() |> press({:device, 22})
    assert "app · open" in texts(view)
    view = press(view, {:device, 21})
    assert "USB · closed" in texts(view)
    assert %{input: false, output: nil} = Fake.state().devices[21]
  end

  test "a Bluetooth scan lists what it finds, says why it stopped; a tap connects" do
    view = mount() |> press(:scan)
    assert "Scanning for Bluetooth MIDI…" in texts(view)
    Fake.event(:bluetooth_device, %{address: "AA:BB:CC:DD:EE:FF", name: "WIDI Jack", rssi: -60})
    view = pump(view)
    assert "WIDI Jack" in texts(view)
    Fake.event(:error, %{device: 0, op: :scan_bluetooth, reason: :location_off, dropped: 0})
    view = pump(view)
    assert "Turn location on to scan for Bluetooth MIDI." in texts(view)
    view = press(view, {:ble, "AA:BB:CC:DD:EE:FF"})
    assert {:connect, "AA:BB:CC:DD:EE:FF"} in Fake.calls()
    assert "Connecting…" in texts(view)
  end
end
