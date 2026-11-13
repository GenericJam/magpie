defmodule Magpie.KitTest do
  use ExUnit.Case, async: true

  alias Magpie.Kit
  alias Magpie.Kit.{Pad, Region, Step}

  @example "design/kits/dusty-breaks.kit.json"

  setup_all do
    schema = "design/kit.schema.json" |> File.read!() |> JSON.decode!()
    example = @example |> File.read!() |> JSON.decode!()
    %{root: JSV.build!(schema), example: example}
  end

  defp schema_valid?(map, root), do: match?({:ok, _}, JSV.validate(map, root))

  test "the designer's example kit is valid by the schema (fixture sanity)", %{
    root: root,
    example: ex
  } do
    assert schema_valid?(ex, root)
  end

  describe "decode/1 of the example kit" do
    setup %{example: ex} do
      {:ok, kit} = Kit.decode(ex)
      %{kit: kit}
    end

    test "kit settings", %{kit: kit} do
      assert %Kit{id: "dusty-breaks", name: "Dusty Breaks", tempo: 96, swing: 0.54, snap: true} =
               kit

      assert kit.midi == %{in_channel: :all, clock: :internal}
    end

    test "pads take the schema's defaults where the file is silent", %{kit: kit} do
      kick = kit.banks["A"][0]

      assert %Pad{
               name: "KICK",
               color: :coral,
               mode: :one_shot,
               choke: 0,
               velocity: :position,
               fixed_velocity: 100,
               midi_note: 36
             } = kick

      assert %Region{
               id: "s_kick01",
               start: +0.0,
               stop: nil,
               gain_db: 0,
               pitch_st: 0,
               reverse: false
             } = kick.sample
    end

    test "choke groups, modes and regions come through", %{kit: kit} do
      a = kit.banks["A"]
      assert a[2].choke == 1 and a[3].choke == 1
      assert a[6].mode == :gate
      assert a[12].mode == :loop
      assert %Pad{mode: :keys, midi_note: 60, sample: %Region{fade_out_ms: 400}} = a[13]
      assert %Region{id: "s_break96", start: 0.48, stop: 0.98} = a[9].sample
      assert map_size(a) == 14
    end

    test "pattern lanes keep their steps in order with ticks at 0", %{kit: kit} do
      [pattern] = kit.patterns
      assert %{id: "A1", bank: "A", length: 16} = pattern
      assert Enum.map(pattern.lanes[0].steps, & &1.step) == [0, 4, 8, 10, 12]
      assert %Step{step: 10, vel: 45, tick: 0, note: nil} = Enum.at(pattern.lanes[0].steps, 3)
      assert pattern.lanes[9].mute == false
    end
  end

  describe "encode/1" do
    test "round-trips the example and stays valid by the schema", %{root: root, example: ex} do
      {:ok, kit} = Kit.decode(ex)
      encoded = Kit.encode(kit)

      assert schema_valid?(encoded, root)
      assert {:ok, ^kit} = Kit.decode(encoded)
      assert {:ok, ^kit} = kit |> Kit.to_json() |> Kit.decode()
    end

    test "a kit using every optional field is schema-valid and round-trips", %{root: root} do
      kit = %Kit{
        id: "full_1",
        name: "Everything",
        tempo: 140.5,
        swing: 0.75,
        snap: false,
        midi: %{in_channel: 10, clock: :send},
        banks: %{
          "B" => %{
            15 => %Pad{
              slot: 15,
              name: "STAB",
              color: :violet,
              mode: :keys,
              choke: 3,
              velocity: :fixed,
              fixed_velocity: 64,
              midi_note: 48,
              sample: %Region{
                id: "abc",
                start: 0.25,
                stop: 1.5,
                fade_in_ms: 5,
                fade_out_ms: 30,
                gain_db: -6.5,
                pitch_st: -12,
                reverse: true
              }
            }
          }
        },
        patterns: [
          %Magpie.Kit.Pattern{
            id: "B2",
            bank: "B",
            length: 32,
            lanes: %{
              15 => %{
                mute: true,
                steps: [
                  %Step{step: 31, vel: 1, tick: -12, note: 60},
                  %Step{step: 0, vel: 127, tick: 12}
                ]
              }
            }
          }
        ],
        meta: %{"author" => "kevin"}
      }

      encoded = Kit.encode(kit)
      assert schema_valid?(encoded, root)
      assert {:ok, ^kit} = Kit.decode(encoded)
    end
  end

  describe "decode/1 rejects what the schema rejects" do
    # Each mutation of the example breaks one rule. The schema must reject it
    # too, so the decoder and the designer's schema can't drift apart.
    @mutations [
      {"format", {:top, "format", "magpie.kit/2"}},
      {"tempo", {:top, "tempo", 300}},
      {"swing", {:top, "swing", 0.8}},
      {"id", {:top, "id", "Has Spaces"}},
      {"", {:top, "colour", "blue"}},
      {"midi.clock", {:midi, "clock", "auto"}},
      {"banks[0].id", {:bank, "id", "E"}},
      {"banks[0].pads[0].choke", {:pad, "choke", 4}},
      {"banks[0].pads[0].color", {:pad, "color", "blue"}},
      {"banks[0].pads[0].mode", {:pad, "mode", "reverse"}},
      {"banks[0].pads[0].sample.gain_db", {:pad, "sample", %{"id" => "x", "gain_db" => 20}}},
      {"patterns[0].lanes[0].steps[0].vel", {:step, "vel", 0}},
      {"patterns[0].lanes[0].steps[0].tick", {:step, "tick", 13}}
    ]

    for {path, mutation} <- @mutations do
      test "#{path} out of bounds", %{root: root, example: ex} do
        bad = apply_mutation(ex, unquote(Macro.escape(mutation)))

        refute schema_valid?(bad, root),
               "the schema accepts this; the decoder shouldn't be stricter"

        assert {:error, errors} = Kit.decode(bad)
        assert Enum.any?(errors, fn {p, _} -> p == unquote(path) end), inspect(errors)
      end
    end
  end

  describe "decode/1 rules beyond the schema" do
    test "a step past the pattern's end", %{example: ex} do
      assert {:error, [{"patterns[0].lanes[0].steps[0].step", "must be 0..15"}]} =
               Kit.decode(update_step(ex, "step", 16))
    end

    test "a region that ends before it starts", %{example: ex} do
      bad = update_pad(ex, 0, "sample", %{"id" => "x", "start" => 1.0, "end" => 0.5})
      assert {:error, [{"banks[0].pads[0].sample.end", "must be after start"}]} = Kit.decode(bad)
    end

    test "two pads in one slot", %{example: ex} do
      bad = update_pad(ex, 1, "slot", 0)
      assert {:error, [{"banks[0].pads[1].slot", "slot 0 appears twice"}]} = Kit.decode(bad)
    end

    test "every problem is reported, not only the first", %{example: ex} do
      bad = ex |> Map.put("tempo", 1) |> update_pad(0, "choke", 9)
      assert {:error, errors} = Kit.decode(bad)
      assert Enum.map(errors, &elem(&1, 0)) == ["tempo", "banks[0].pads[0].choke"]
    end

    test "text that isn't JSON" do
      assert {:error, [{"", "not JSON: " <> _}]} = Kit.decode("{nope")
    end
  end

  test "pad_index/2 and bank_slot/1 address all 64 pads both ways" do
    for bank <- ~w(A B C D), slot <- 0..15 do
      assert bank |> Kit.pad_index(slot) |> Kit.bank_slot() == {bank, slot}
    end

    assert Kit.pad_index("B", 3) == 19

    assert Enum.uniq(for b <- ~w(A B C D), s <- 0..15, do: Kit.pad_index(b, s)) ==
             Enum.to_list(0..63)
  end

  defp apply_mutation(kit, {:top, key, value}), do: Map.put(kit, key, value)
  defp apply_mutation(kit, {:midi, key, value}), do: put_in(kit, ["midi", key], value)

  defp apply_mutation(kit, {:bank, key, value}),
    do: update_in(kit, ["banks"], fn [b] -> [Map.put(b, key, value)] end)

  defp apply_mutation(kit, {:pad, key, value}), do: update_pad(kit, 0, key, value)
  defp apply_mutation(kit, {:step, key, value}), do: update_step(kit, key, value)

  defp update_pad(kit, index, key, value) do
    update_in(kit, ["banks"], fn [bank] ->
      [
        update_in(
          bank,
          ["pads"],
          &List.update_at(&1, index, fn pad -> Map.put(pad, key, value) end)
        )
      ]
    end)
  end

  defp update_step(kit, key, value) do
    update_in(kit, ["patterns"], fn [p] ->
      [
        update_in(p, ["lanes"], fn [lane | rest] ->
          [update_in(lane, ["steps"], fn [s | ss] -> [Map.put(s, key, value) | ss] end) | rest]
        end)
      ]
    end)
  end
end
