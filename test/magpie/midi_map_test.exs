defmodule Magpie.Midi.MapTest do
  use ExUnit.Case, async: true

  alias Magpie.Kit
  alias Magpie.Kit.{Pad, Region}
  alias Magpie.Midi.Map, as: MidiMap

  defp pad(slot, opts),
    do: struct(%Pad{slot: slot, sample: %Region{id: "s#{slot}"}}, opts)

  defp kit(pads, midi \\ %{}) do
    banks =
      Enum.reduce(pads, %{}, fn {bank, pad}, acc ->
        Map.update(acc, bank, %{pad.slot => pad}, &Map.put(&1, pad.slot, pad))
      end)

    %Kit{
      id: "k",
      name: "K",
      tempo: 120,
      banks: banks,
      midi: Map.merge(%{in_channel: :all, clock: :internal}, midi)
    }
  end

  # Note-on / note-off on channel `ch` (1..16).
  defp on(ch, note, vel), do: {0x90 + ch - 1, note, vel}
  defp off(ch, note), do: {0x80 + ch - 1, note, 64}

  # The board's drums on A plus a keys pad, and a layer on C.
  defp drum_kit(midi \\ %{}) do
    kit(
      [
        {"A", pad(0, midi_note: 36)},
        {"A", pad(1, midi_note: 38, mode: :gate)},
        {"A", pad(12, midi_note: 52, mode: :loop)},
        {"A", pad(13, midi_note: 60, mode: :keys)},
        {"A", pad(14, midi_note: 40, mode: :toggle)},
        {"C", pad(0, midi_note: 36)}
      ],
      midi
    )
  end

  @kick Kit.pad_index("A", 0)
  @snare Kit.pad_index("A", 1)
  @break Kit.pad_index("A", 12)
  @keys Kit.pad_index("A", 13)
  @toggle Kit.pad_index("A", 14)
  @layer Kit.pad_index("C", 0)

  describe "notes in" do
    test "a note plays every pad whose midi_note it is, in any bank, with its velocity" do
      config = MidiMap.config(drum_kit())

      assert MidiMap.route(config, on(1, 36, 101)) == [
               {:trigger, @kick, 101},
               {:trigger, @layer, 101}
             ]

      assert MidiMap.route(config, on(1, 38, 7)) == [{:trigger, @snare, 7}]
    end

    test "a note no other pad claims goes to the keys pad, chromatically" do
      config = MidiMap.config(drum_kit())
      assert MidiMap.route(config, on(1, 67, 90)) == [{:note_on, @keys, 67, 90}]
      # Its own root: the keys pad at the root.
      assert MidiMap.route(config, on(1, 60, 90)) == [{:note_on, @keys, 60, 90}]
      assert MidiMap.route(config, off(1, 67)) == [{:note_off, @keys, 67}]
    end

    test "a drum pad's note wins over the keys pad: move the pad's note to free it" do
      config = MidiMap.config(drum_kit())
      assert MidiMap.route(config, on(1, 52, 90)) == [{:trigger, @break, 90}]

      moved = put_in(drum_kit().banks["A"][12].midi_note, 53)
      assert MidiMap.route(MidiMap.config(moved), on(1, 52, 90)) == [{:note_on, @keys, 52, 90}]
    end

    test "two keys pads both play an unclaimed note (each from its own root)" do
      config =
        MidiMap.config(
          kit([{"A", pad(0, mode: :keys, midi_note: 48)}, {"B", pad(3, mode: :keys)}])
        )

      b3 = Kit.pad_index("B", 3)

      assert MidiMap.route(config, on(1, 50, 80)) == [
               {:note_on, 0, 50, 80},
               {:note_on, b3, 50, 80}
             ]
    end

    test "no keys pad: an unclaimed note plays nothing" do
      config = MidiMap.config(kit([{"A", pad(0, midi_note: 36)}]))
      assert MidiMap.route(config, on(1, 37, 100)) == []
      assert MidiMap.pads(config, 37) == []
    end

    test "pads without a sample or without a midi_note claim nothing" do
      no_sample = %Pad{slot: 2, midi_note: 36}

      config =
        MidiMap.config(kit([{"A", no_sample}, {"A", pad(3, [])}, {"A", pad(4, mode: :keys)}]))

      assert MidiMap.route(config, on(1, 36, 100)) == [{:note_on, 4, 36, 100}]
    end

    test "note-off releases gate and loop pads; one-shots and toggles ignore it" do
      config = MidiMap.config(drum_kit())
      assert MidiMap.route(config, off(1, 38)) == [{:release, @snare}]
      assert MidiMap.route(config, off(1, 52)) == [{:release, @break}]
      assert MidiMap.route(config, off(1, 36)) == []
      assert MidiMap.route(config, off(1, 40)) == []
      assert MidiMap.route(config, on(1, 40, 100)) == [{:trigger, @toggle, 100}]
    end

    test "note-on velocity 0 is a note-off" do
      config = MidiMap.config(drum_kit())
      assert MidiMap.route(config, on(1, 38, 0)) == [{:release, @snare}]
      assert MidiMap.route(config, on(1, 70, 0)) == [{:note_off, @keys, 70}]
    end

    test "in_channel: all takes every channel, a number only its own" do
      all = MidiMap.config(drum_kit())
      assert MidiMap.route(all, on(16, 36, 100)) != []

      ten = MidiMap.config(drum_kit(%{in_channel: 10}))

      assert MidiMap.route(ten, on(10, 36, 100)) == [
               {:trigger, @kick, 100},
               {:trigger, @layer, 100}
             ]

      assert MidiMap.route(ten, on(1, 36, 100)) == []
      assert MidiMap.route(ten, off(9, 38)) == []
      assert MidiMap.route(ten, off(10, 38)) == [{:release, @snare}]
    end

    test "anything but notes routes nowhere here (clock, CC, pitch bend are the engine's)" do
      config = MidiMap.config(drum_kit())

      for message <- [{0xF8, 0, 0}, {0xFA, 0, 0}, {0xB0, 123, 0}, {0xE0, 0, 64}, {0xC0, 5, 0}],
          do: assert(MidiMap.route(config, message) == [])
    end
  end

  describe "out and clock" do
    test "pads with a midi_note send it; out channel is in_channel, or 1 with all" do
      config = MidiMap.config(drum_kit(%{in_channel: 10, clock: :send}))
      assert config.out_notes[@kick] == 36
      assert config.out_notes[@keys] == 60
      assert config.out_channel == 10
      assert config.clock == :send
      assert MidiMap.config(drum_kit()).out_channel == 1

      silent = MidiMap.config(kit([{"A", pad(0, [])}]))
      assert silent.out_notes == %{}
    end
  end
end
