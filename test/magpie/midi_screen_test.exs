defmodule Magpie.MidiScreenTest do
  # The engine (the fake), the kit session and the MIDI devices are one per VM: not async.
  use Mob.ScreenCase, async: false

  import Magpie.Test.Kits
  import Magpie.Test.Screens, only: [assert_every_tap_held: 1, texts: 1]

  alias Magpie.Audio.Fake
  alias Magpie.{KitSession, Midi, MidiScreen}

  @usb %{id: 21, name: "Keystep", type: :usb, inputs: 1, outputs: 1}
  @humdinger %{id: 22, name: "Humdinger", type: :virtual, inputs: 0, outputs: 1}

  setup do
    setup_library()
    :ok = Fake.fail_midi_open(nil)
    {:ok, devices} = Fake.midi_devices()
    for d <- devices, do: Fake.unplug(d.id)
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
      {:magpie_audio, :tempo, _} = msg -> view |> render_info(msg) |> drain()
      {:magpie_audio, _, _, _} -> drain(view)
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

  test "MIDI in steps all → 1 … 16 → all, the clock internal → follow → send → internal" do
    view = mount() |> press(:in_channel)
    assert KitSession.snapshot().kit.midi.in_channel == 1
    assert "channel 1" in texts(view)

    view = Enum.reduce(1..15, view, fn _, v -> press(v, :in_channel) end)
    assert KitSession.snapshot().kit.midi.in_channel == 16
    view = press(view, :in_channel)
    assert KitSession.snapshot().kit.midi.in_channel == :all

    view = press(view, :clock)
    assert "follow · waiting for a clock" in texts(view)
    :ok = Fake.follow({:tempo, 97.04})
    view = pump(view)
    assert "follow · 97.0 bpm" in texts(view)
    view = view |> press(:clock) |> press(:clock)
    assert KitSession.snapshot().kit.midi.clock == :internal
    assert "internal" in texts(view)
  end

  test "tapping a device turns it on or off" do
    view = mount() |> press({:device, 22})
    assert "app · open" in texts(view)
    view = press(view, {:device, 21})
    assert "USB · closed" in texts(view)
    assert Fake.state().midi_devices[21].open == false
  end

  test "a Bluetooth scan lists what it finds; a tap connects" do
    view = mount() |> press(:scan)
    assert "Scanning for Bluetooth MIDI…" in texts(view)
    Fake.midi_event(:ble_found, %{address: "AA:BB:CC:DD:EE:FF", name: "WIDI Jack", rssi: -60})
    view = pump(view)
    assert "WIDI Jack" in texts(view)
    view = press(view, {:ble, "AA:BB:CC:DD:EE:FF"})
    assert {:connect, "AA:BB:CC:DD:EE:FF"} in Fake.calls()
    assert "Connecting…" in texts(view)
  end
end
