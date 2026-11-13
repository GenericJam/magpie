defmodule Magpie.KitSessionTest do
  # One engine (the fake) and one library directory per VM: not async.
  use ExUnit.Case, async: false

  import Magpie.Test.Kits

  alias Magpie.Audio.Fake
  alias Magpie.{Kit, KitSession, Library, Repo, Wav}
  alias Magpie.Kit.{Pad, Region}

  setup do
    setup_library()
  end

  describe "starting" do
    test "with nothing saved: the board's kit, empty, as the library has none of its samples" do
      start_supervised!({KitSession, autosave_ms: 60_000})
      %{kit: kit, pads: pads} = KitSession.snapshot()

      assert %Kit{id: "dusty-breaks", name: "Dusty Breaks", tempo: 96, swing: 0.54} = kit
      assert Enum.all?(kit.banks, fn {_, pads} -> pads == %{} end)
      assert pads == %{}
      assert [%{bank: "A", lanes: lanes}] = kit.patterns
      assert lanes == %{}
      # Its tempo and swing reached the engine.
      assert %{tempo: 96, swing: 0.54} = Fake.state()
    end

    test "with nothing saved, the board kit keeps the pads whose samples the library has" do
      # A library row under the kit file's own id for its kick.
      pcm = for _ <- 1..4800, into: <<>>, do: <<0.5::float-32-little>>
      File.mkdir_p!(Library.dir())
      File.write!(Library.path("s_kick01"), Wav.encode_f32(pcm, 48_000, 1))

      Repo.insert!(%Library.Sample{
        id: "s_kick01",
        name: "Kick",
        source: :imported,
        rate: 48_000,
        channels: 1,
        frames: 4800
      })

      start_supervised!({KitSession, autosave_ms: 60_000})
      snapshot = await_loaded()

      assert %{"A" => %{0 => %Pad{name: "KICK", sample: %Region{id: "s_kick01"}}} = pads} =
               snapshot.kit.banks

      assert map_size(pads) == 1
      assert [%{lanes: lanes}] = snapshot.kit.patterns
      assert Map.keys(lanes) == [0]
      assert %{0 => %{status: :ready}} = snapshot.pads
      assert %{0 => %{sample: "s_kick01"}} = Fake.state().pads
    end

    test "resumes the most recently saved kit" do
      kick = sample!("Kick")
      {:ok, _} = Library.save_kit(kit([{"B", pad(3, kick)}], id: "mine", name: "Mine"))

      start_supervised!({KitSession, autosave_ms: 60_000})
      snapshot = await_loaded()

      assert %Kit{id: "mine", name: "Mine"} = snapshot.kit
      index = Kit.pad_index("B", 3)
      assert %{^index => %{status: :ready}} = snapshot.pads
    end
  end

  describe "loading" do
    test "loads every sample into the engine and applies its pads" do
      kick = sample!("Kick", 0.5)
      snare = sample!("Snare", 0.25)

      pads = [
        {"A", pad(0, kick)},
        {"A", pad(1, snare, mode: :gate)},
        {"C", pad(15, kick, choke: 2)}
      ]

      snapshot = start_session!(kit(pads))

      engine = Fake.state()
      assert Map.keys(engine.samples) |> Enum.sort() == Enum.sort([kick.id, snare.id])
      assert %{sample: k1, mode: :one_shot} = engine.pads[0]
      assert %{mode: :gate} = engine.pads[1]
      assert %{sample: k2, choke: 2} = engine.pads[Kit.pad_index("C", 15)]
      assert k1 == kick.id and k2 == kick.id

      assert %{status: :ready, seconds: 0.5, wave: wave} = snapshot.pads[0]
      # Loud first half, quiet second half.
      assert Enum.count(wave) == 12
      assert Enum.take(wave, 6) |> Enum.all?(&(&1 >= 200))
      assert Enum.drop(wave, 6) |> Enum.all?(&(&1 < 40))
    end

    test "the wave covers the pad's region, reversed with it, and the length follows pitch" do
      sound = sample!("Sound", 1.0)
      # 0.25..1 s: a third loud then quiet, reversed: quiet then loud.
      region = %Region{id: sound.id, start: 0.25, reverse: true, pitch_st: 12}
      snapshot = start_session!(kit([{"A", %Pad{slot: 0, sample: region}}]))

      assert %{wave: wave, seconds: seconds} = snapshot.pads[0]
      assert wave |> Enum.take(7) |> Enum.all?(&(&1 < 40))
      assert wave |> Enum.drop(8) |> Enum.all?(&(&1 >= 200))
      # 0.75 s an octave up.
      assert_in_delta seconds, 0.375, 1.0e-9
    end

    test "a sample the library doesn't have leaves its pad silent, marked missing" do
      pad = %Pad{slot: 2, name: "GONE", sample: %Region{id: "nope"}}
      snapshot = start_session!(kit([{"A", pad}]))

      assert %{2 => %{status: {:error, :not_in_library}, wave: []}} = snapshot.pads
      assert Fake.state().pads == %{}
      assert snapshot.kit.banks["A"][2] == pad
    end
  end

  describe "changes" do
    setup do
      kick = sample!("Kick")
      start_session!(kit([{"A", pad(0, kick)}]), autosave_ms: 20)
      KitSession.subscribe()
      %{kick: kick}
    end

    test "go to the engine, to subscribers and, after the autosave delay, to the library" do
      assert :ok = KitSession.update_pad(0, &%{&1 | mode: :loop, choke: 1, color: :teal})

      assert %{mode: :loop, choke: 1} = Fake.state().pads[0]

      assert_received {:magpie_kit,
                       %{kit: %{banks: %{"A" => %{0 => %Pad{mode: :loop, color: :teal}}}}}}

      # Not saved yet, then saved.
      assert Library.list_kits() == []
      Process.sleep(60)

      assert {:ok, %Kit{banks: %{"A" => %{0 => %Pad{mode: :loop, choke: 1, color: :teal}}}}} =
               Library.load_kit("test-kit")
    end

    test "flush/0 saves at once" do
      :ok = KitSession.set_snap(true)
      :ok = KitSession.flush()
      assert {:ok, %Kit{snap: true}} = Library.load_kit("test-kit")
    end

    test "a change the engine refuses comes back as its error and leaves the kit alone" do
      assert {:error, {:invalid, :pitch_st}} =
               KitSession.update_pad(0, fn pad -> put_in(pad.sample.pitch_st, 99) end)

      assert %{sample: %Region{pitch_st: 0}} = KitSession.snapshot().kit.banks["A"][0]
      assert %{pitch_st: 0} = Fake.state().pads[0]
      refute_received {:magpie_kit, _}
    end

    test "clearing a pad empties it in the engine and the kit" do
      assert :ok = KitSession.clear_pad(0)
      assert Fake.state().pads == %{}
      assert KitSession.snapshot().kit.banks["A"] == %{}
      assert KitSession.snapshot().pads == %{}
    end

    test "put_sample/2 makes a new pad of a library sample, named after it" do
      snare = sample!("Snare from the mic", 0.5)
      index = Kit.pad_index("B", 9)

      assert :ok = KitSession.put_sample(index, snare.id)
      snapshot = await_loaded()

      assert %Pad{slot: 9, name: "Snare from t", color: color, sample: %Region{id: id}} =
               snapshot.kit.banks["B"][9]

      assert id == snare.id
      assert color == Enum.at(Magpie.Style.pad_palette(), 1)
      assert %{^index => %{status: :ready}} = snapshot.pads
      assert %{sample: ^id} = Fake.state().pads[index]
    end

    test "put_sample/2 on a pad keeps its settings and swaps the sound", %{kick: kick} do
      :ok = KitSession.update_pad(0, &%{&1 | mode: :gate, choke: 3})
      snare = sample!("Snare", 0.5)
      :ok = KitSession.put_sample(0, snare.id)
      await_loaded()

      assert %Pad{mode: :gate, choke: 3, name: "Snare", sample: %Region{id: id}} =
               KitSession.snapshot().kit.banks["A"][0]

      assert id == snare.id and id != kick.id
      assert %{sample: ^id, mode: :gate} = Fake.state().pads[0]
    end

    test "put_sample/2 refuses a sample not in the library" do
      assert {:error, :not_in_library} = KitSession.put_sample(5, "nope")
    end

    test "a recording sent for a pad lands on it" do
      sound = sample!("Mic 1", 0.5)
      send(KitSession.whereis(), {:recorded, 4, sound})
      snapshot = await_loaded()

      assert %Pad{name: "Mic 1", sample: %Region{id: id}} = snapshot.kit.banks["A"][4]
      assert id == sound.id
      assert %{4 => %{status: :ready}} = snapshot.pads
    end
  end

  test "pattern/2: the kit's pattern for the bank, else an empty one" do
    {:ok, kit} = Kit.load("design/kits/dusty-breaks.kit.json")

    assert %Kit.Pattern{id: "A1", bank: "A"} = KitSession.pattern(kit, "A")

    assert %Kit.Pattern{id: "B1", bank: "B", length: 16, lanes: %{}} =
             KitSession.pattern(kit, "B")
  end
end
