defmodule Magpie.MidiTest do
  # One fake engine and one fake mob_midi per VM: not async.
  use ExUnit.Case, async: false

  alias Magpie.Audio.Fake, as: Audio
  alias Magpie.{Engine, Midi}
  alias Magpie.Midi.Fake

  @usb %{id: 11, name: "Keystep", type: :usb, input_ports: 1, output_ports: 1}
  @ble %{id: 12, name: "WIDI", type: :bluetooth, input_ports: 2, output_ports: 1}
  @humdinger %{id: 13, name: "Humdinger", type: :virtual, input_ports: 1, output_ports: 0}
  @own %{id: 14, name: "Magpie", type: :virtual, input_ports: 1, output_ports: 1, own: true}

  setup do
    :ok = Audio.fail_open(nil)
    :ok = Fake.reset()
    start_supervised!(Engine)
    :ok
  end

  defp start!(devices \\ [@own]) do
    Enum.each(devices, &Fake.plug/1)
    start_supervised!({Midi, persist: false})
  end

  defp device(view, id), do: Enum.find(view.devices, &(&1.id == id))

  # The view once `fun` holds for it (mob_midi's answers arrive on their
  # own, so poll rather than trust the order of the published views).
  defp await(fun, tries \\ 200) do
    view = Midi.snapshot()

    cond do
      fun.(view) -> view
      tries > 0 -> await_again(fun, tries)
      true -> flunk("no such view: #{inspect(view)}")
    end
  end

  defp await_again(fun, tries) do
    Process.sleep(10)
    await(fun, tries - 1)
  end

  defp handle(id), do: Fake.state().devices[id].output

  test "USB and Bluetooth devices there at start open; other apps' ports and Magpie's own don't" do
    start!([@usb, @ble, @humdinger, @own])
    view = await(&(device(&1, 11) && device(&1, 12) && device(&1, 12).status == :open))

    assert %{status: :open, wanted: true} = device(view, 11)
    assert %{status: :open, wanted: true, input_ports: 2} = device(view, 12)
    assert %{status: :closed, wanted: false} = device(view, 13)
    refute device(view, 14), "Magpie's own device isn't a device to pick"
    assert %{input: true} = Fake.state().devices[12]
    assert %{input: false, output: nil} = Fake.state().devices[13]
  end

  test "the engine sends to Magpie's own output and every opened device's output port 0" do
    start!([@usb, @own])
    await(&(device(&1, 11) && device(&1, 11).status == :open))
    own = handle(14)
    assert is_integer(own)
    assert Audio.state().midi_outputs == [own, handle(11)]

    :ok = Midi.set_open(11, false)
    await(&(device(&1, 11).status == :closed))
    assert Audio.state().midi_outputs == [own]
  end

  test "hot-plug: a USB device plugged in later opens; unplugged it goes, and what it held ends" do
    start!()
    Fake.plug(@usb)
    view = await(&(device(&1, 11) && device(&1, 11).status == :open))
    assert device(view, 11).type == :usb
    changed = Audio.state().midi_sources_changed

    Fake.unplug(11)
    view = await(&(device(&1, 11) == nil))
    assert view.devices == []
    assert Audio.state().midi_sources_changed > changed
    assert Audio.state().midi_outputs == [handle(14)]
  end

  test "turning a port on opens it; off closes it, and stays off when it comes back" do
    start!([@humdinger, @usb, @own])
    await(&(device(&1, 11) && device(&1, 11).status == :open))
    :ok = Midi.set_open(13, true)
    view = await(&(device(&1, 13).status == :open))
    assert device(view, 13).wanted
    assert Fake.state().devices[13].input

    :ok = Midi.set_open(11, false)
    view = await(&(device(&1, 11).status == :closed))
    refute device(view, 11).wanted
    assert %{input: false, output: nil} = Fake.state().devices[11]

    Fake.unplug(11)
    await(&(device(&1, 11) == nil))
    Fake.plug(@usb)
    view = await(&(device(&1, 11) != nil))
    assert %{status: :closed, wanted: false} = device(view, 11)
    assert Midi.set_open(99, true) == {:error, :unknown_device}
  end

  test "an :opened that raced a close is old news: the device stays closed" do
    start!()
    Fake.plug(@usb)
    await(&(device(&1, 11) && device(&1, 11).status == :open))
    :ok = Midi.set_open(11, false)
    await(&(device(&1, 11).status == :closed))

    # Already in the mailbox when close/2 returned.
    Fake.event(:opened, %{device: 11, port: 0, direction: :output, handle: 99})
    assert %{status: :closed, wanted: false} = device(Midi.snapshot(), 11)
    refute 99 in Audio.state().midi_outputs
  end

  test "a device that can't open says why; a close cancelling an open isn't a failure" do
    :ok = Fake.fail_open(:open_failed)
    start!()
    Fake.plug(@usb)
    view = await(&match?(%{status: {:failed, _}}, device(&1, 11)))
    assert device(view, 11).status == {:failed, :open_failed}

    :ok = Fake.fail_open(nil)
    :ok = Midi.set_open(11, true)
    await(&(device(&1, 11).status == :open))
    Fake.event(:error, %{device: 11, op: :open_input, reason: :closed, dropped: 0})
    assert device(Midi.snapshot(), 11).status == :open
  end

  test "Magpie's device: its connections, and a sender leaving ends what it held" do
    start!()
    changed = Audio.state().midi_sources_changed
    Fake.event(:virtual_status, %{device: 14, senders: 1, listeners: 2})
    await(&(&1.port == %{inputs: 1, outputs: 2}))
    assert Audio.state().midi_sources_changed == changed + 1
  end

  test "a Bluetooth scan, what it finds, why it stopped; connecting a device found" do
    start!()
    :ok = Midi.ble_scan()
    assert %{scan: %{state: :scanning, found: []}} = Midi.snapshot()
    assert {:scan, 10_000} in Fake.calls()

    Fake.event(:bluetooth_device, %{address: "AA:BB:CC:DD:EE:FF", name: "WIDI", rssi: -50})

    assert %{scan: %{found: [%{address: "AA:BB:CC:DD:EE:FF", name: "WIDI"}]}} =
             await(&(&1.scan.found != []))

    Fake.event(:error, %{device: 0, op: :scan_bluetooth, reason: :bluetooth_off, dropped: 0})
    assert %{scan: %{state: :idle, error: :bluetooth_off}} = await(&(&1.scan.state == :idle))

    :ok = Midi.ble_connect("AA:BB:CC:DD:EE:FF")
    assert {:connect, "AA:BB:CC:DD:EE:FF"} in Fake.calls()
  end
end
