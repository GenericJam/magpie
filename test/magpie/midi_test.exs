defmodule Magpie.MidiTest do
  # One fake engine per VM: not async.
  use ExUnit.Case, async: false

  alias Magpie.Audio.Fake
  alias Magpie.{Engine, Midi}

  @usb %{id: 11, name: "Keystep", type: :usb, inputs: 1, outputs: 1}
  @ble %{id: 12, name: "WIDI", type: :bluetooth, inputs: 1, outputs: 1}
  @humdinger %{id: 13, name: "Humdinger", type: :virtual, inputs: 0, outputs: 1}
  @own %{id: 14, name: "Magpie", type: :virtual, inputs: 1, outputs: 1, own: true}

  setup do
    :ok = Fake.fail_open(nil)
    :ok = Fake.fail_midi_open(nil)
    start_supervised!(Engine)
    {:ok, devices} = Fake.midi_devices()
    for d <- devices, do: Fake.unplug(d.id)
    :ok
  end

  defp start!(devices \\ []) do
    Enum.each(devices, &Fake.plug/1)
    start_supervised!({Midi, persist: false})
    Midi.subscribe()
  end

  defp device(view, id), do: Enum.find(view.devices, &(&1.id == id))

  defp next_view do
    assert_receive {:magpie_midi, view}
    view
  end

  # Wait for the view in which `fun` holds.
  defp await(fun, tries \\ 20) do
    receive do
      {:magpie_midi, view} -> if fun.(view), do: view, else: await(fun, tries)
    after
      200 -> if tries > 0, do: await(fun, tries - 1), else: flunk("no such view")
    end
  end

  test "USB and Bluetooth devices there at start open; other apps' ports and Magpie's own don't" do
    view = start!([@usb, @ble, @humdinger, @own])

    view =
      if device(view, 11).status == :open,
        do: view,
        else: await(&(device(&1, 12).status == :open))

    assert %{status: :open, wanted: true} = device(view, 11)
    assert %{status: :open, wanted: true} = device(view, 12)
    assert %{status: :closed, wanted: false} = device(view, 13)
    refute device(view, 14), "Magpie's own port isn't a device to pick"
    assert Fake.state().midi_devices[13].open == false
  end

  test "hot-plug: a USB device plugged in later opens; unplugged it goes" do
    start!()
    Fake.plug(@usb)
    view = await(&(device(&1, 11) && device(&1, 11).status == :open))
    assert device(view, 11).type == :usb

    Fake.unplug(11)
    view = await(&(device(&1, 11) == nil))
    assert view.devices == []
  end

  test "turning a port on opens it; off closes it, and stays off when it comes back" do
    start!([@humdinger, @usb])
    :ok = Midi.set_open(13, true)
    view = await(&(device(&1, 13).status == :open))
    assert device(view, 13).wanted

    :ok = Midi.set_open(11, false)
    view = await(&(device(&1, 11).status == :closed))
    refute device(view, 11).wanted
    assert Fake.state().midi_devices[11].open == false

    Fake.unplug(11)
    await(&(device(&1, 11) == nil))
    Fake.plug(@usb)
    view = await(&(device(&1, 11) != nil))
    assert %{status: :closed, wanted: false} = device(view, 11)
    assert Midi.set_open(99, true) == {:error, :unknown_device}
  end

  test "a device that can't open says why" do
    :ok = Fake.fail_midi_open(:open_failed)
    start!()
    Fake.plug(@usb)
    view = await(&match?(%{status: {:failed, _}}, device(&1, 11)))
    assert device(view, 11).status == {:failed, :open_failed}
  end

  test "the Magpie port's connections and a Bluetooth scan" do
    start!()
    Fake.midi_event(:port, %{inputs: 1, outputs: 2})
    assert %{port: %{inputs: 1, outputs: 2}} = next_view()

    :ok = Midi.ble_scan()
    assert %{scan: %{state: :scanning, found: []}} = next_view()
    assert {:scan, 10_000} in Fake.calls()

    Fake.midi_event(:ble_found, %{address: "AA:BB:CC:DD:EE:FF", name: "WIDI", rssi: -50})
    assert %{scan: %{found: [%{address: "AA:BB:CC:DD:EE:FF", name: "WIDI"}]}} = next_view()

    Fake.midi_event(:ble_scan_done, %{error: "bluetooth_off"})
    assert %{scan: %{state: :idle, error: :bluetooth_off}} = next_view()

    :ok = Midi.ble_connect("AA:BB:CC:DD:EE:FF")
    assert {:connect, "AA:BB:CC:DD:EE:FF"} in Fake.calls()
  end
end
