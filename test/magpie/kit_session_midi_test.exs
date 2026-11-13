defmodule Magpie.KitSessionMidiTest do
  # One engine (the fake) and one library directory per VM: not async.
  use ExUnit.Case, async: false

  import Magpie.Test.Kits

  alias Magpie.Audio.Fake
  alias Magpie.{Engine, Kit, KitSession, Library}
  alias Magpie.Midi.Map, as: MidiMap

  setup do
    setup_library()
  end

  defp drums do
    kick = sample!("Kick", 0.2)
    keys = sample!("Bell", 0.5)

    kit([
      {"A", pad(0, kick, midi_note: 36)},
      {"A", pad(1, kick, midi_note: 38, mode: :gate)},
      {"B", pad(5, keys, midi_note: 60, mode: :keys)}
    ])
  end

  @gate Kit.pad_index("A", 1)
  @keys Kit.pad_index("B", 5)

  test "the kit's MIDI table reaches the engine on start and follows every change" do
    kit = drums()
    start_session!(kit)
    assert Fake.state().midi == MidiMap.config(kit)
    assert Engine.state().midi == %{in_channel: :all, out_channel: 1, clock: :internal}

    # A pad's note moves: the table follows.
    :ok = KitSession.update_pad(0, &%{&1 | midi_note: 37})
    assert MidiMap.pads(Fake.state().midi, 37) == [0]
    assert MidiMap.pads(Fake.state().midi, 36) == [@keys]

    # A pad cleared claims nothing any more.
    :ok = KitSession.clear_pad(@gate)
    assert MidiMap.pads(Fake.state().midi, 38) == [@keys]
  end

  test "set_midi changes the kit's channel and clock, which are saved with it" do
    start_session!(drums())
    :ok = KitSession.set_midi(%{in_channel: 10})
    :ok = KitSession.set_midi(%{clock: :follow})

    assert %{midi: %{in_channel: 10, clock: :follow}} = KitSession.snapshot().kit
    assert %{in_channel: 10, out_channel: 10, clock: :follow} = Fake.state().midi
    :ok = KitSession.flush()
    {:ok, saved} = Library.load_kit("test-kit")
    assert saved.midi == %{in_channel: 10, clock: :follow}

    assert KitSession.set_midi(%{in_channel: 17}) == {:error, {:invalid, :in_channel}}
    assert KitSession.set_midi(%{clock: :sync}) == {:error, {:invalid, :clock}}
    assert %{midi: %{in_channel: 10, clock: :follow}} = KitSession.snapshot().kit
  end

  test "notes in play the kit's pads through the engine; subscribers see the voices" do
    start_session!(drums())
    :ok = KitSession.set_midi(%{in_channel: 2})
    :ok = Engine.subscribe()

    :ok = Fake.midi_in({0x90, 36, 100})
    refute_receive {:magpie_audio, :voice, 0, :start}, 50

    :ok = Fake.midi_in({0x91, 36, 100})
    assert_receive {:magpie_audio, :voice, 0, :start}

    :ok = Fake.midi_in({0x91, 38, 90})
    assert_receive {:magpie_audio, :voice, @gate, :start}
    :ok = Fake.midi_in({0x81, 38, 0})
    assert_receive {:magpie_audio, :voice, @gate, :end}

    :ok = Fake.midi_in({0x91, 67, 80})
    assert_receive {:magpie_audio, :voice, @keys, :start}
    :ok = Fake.midi_in({0x91, 67, 0})
    assert_receive {:magpie_audio, :voice, @keys, :end}
  end

  test "following a clock: Start and Stop move the Engine's state, the tempo shows" do
    start_session!(drums())
    :ok = KitSession.set_midi(%{clock: :follow})
    :ok = Engine.subscribe()

    :ok = Fake.follow({:tempo, 123.4})
    assert_receive {:magpie_audio, :tempo, 123.4}
    :ok = Fake.follow(:start)
    assert_receive {:magpie_audio, :transport, true, _frame}
    assert %{playing: true, follow_tempo: 123.4} = Engine.state()

    :ok = Fake.follow(:stop)
    assert_receive {:magpie_audio, :transport, false, _frame}
    refute Engine.state().playing

    # Back to the internal clock: no followed tempo any more.
    :ok = KitSession.set_midi(%{clock: :internal})
    assert Engine.state().follow_tempo == nil
  end
end
