defmodule Magpie.KitSessionTest do
  # One engine (the fake) and one library directory per VM: not async.
  use ExUnit.Case, async: false

  import Magpie.Test.Kits

  alias Magpie.Audio.Fake
  alias Magpie.{Engine, Kit, KitSession, Library, Repo, Wav}
  alias Magpie.Kit.{Pad, Pattern, Region, Step}

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

    test "update_pad/2 runs the function in the caller: a bad one leaves the session up" do
      assert_raise RuntimeError, fn -> KitSession.update_pad(0, fn _ -> raise "boom" end) end
      assert {:error, {:not_a_pad, :nope}} = KitSession.update_pad(0, fn _ -> :nope end)
      assert %Pad{} = KitSession.snapshot().kit.banks["A"][0]
    end

    test "clearing a pad stops its voices, empties it and unloads its now unused sample",
         %{kick: kick} do
      :ok = KitSession.update_pad(0, &%{&1 | mode: :gate})
      :ok = Engine.subscribe()
      :ok = Engine.trigger(0, 100)
      assert_receive {:magpie_audio, :voice, 0, :start}
      assert :ok = KitSession.clear_pad(0)

      assert_receive {:magpie_audio, :voice, 0, :end}
      assert Fake.state().pads == %{}
      refute Map.has_key?(Fake.state().samples, kick.id)
      assert KitSession.snapshot().kit.banks["A"] == %{}
      assert KitSession.snapshot().pads == %{}
    end

    test "a sounding toggle stops when the pad's mode changes, not when its pitch does" do
      :ok = KitSession.update_pad(0, &%{&1 | mode: :toggle})
      :ok = Engine.subscribe()
      :ok = Engine.trigger(0, 100)
      assert_receive {:magpie_audio, :voice, 0, :start}

      # Heard from its next trigger, like every other pad setting.
      :ok = KitSession.update_pad(0, fn pad -> put_in(pad.sample.pitch_st, 3) end)
      # Refused: nothing changes, the loop plays on.
      assert {:error, {:invalid, :pitch_st}} =
               KitSession.update_pad(
                 0,
                 &%{&1 | mode: :one_shot, sample: %{&1.sample | pitch_st: 99}}
               )

      refute_receive {:magpie_audio, :voice, 0, :end}

      :ok = KitSession.update_pad(0, &%{&1 | mode: :one_shot})
      assert_receive {:magpie_audio, :voice, 0, :end}
      assert %{mode: :one_shot, pitch_st: 3} = Fake.state().pads[0]
      # Nothing else was sent to stop it (a trigger would have played the one-shot).
      assert [{:trigger, 0, 100, 0}] = Fake.calls()
    end

    test "a sample the engine can't unload yet is unloaded once it can", %{kick: kick} do
      :ok = Fake.busy(:unload_sample, 1)
      :ok = KitSession.clear_pad(0)
      assert Map.has_key?(Fake.state().samples, kick.id)

      assert Enum.find_value(1..50, fn _ ->
               Process.sleep(20)
               not Map.has_key?(Fake.state().samples, kick.id)
             end)
    end

    test "a pad the engine refuses after its sample loads is marked, not ready" do
      long = sample!("Long", 0.5)
      # Schema-valid, but past the sound's end.
      :ok =
        KitSession.update_pad(5, fn _ ->
          %Pad{slot: 5, sample: %Region{id: long.id, start: 2.0}}
        end)

      assert %{5 => %{status: {:error, {:refused, {:invalid, :start}}}}} = await_loaded().pads
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

  describe "patterns, tempo and swing" do
    setup do
      kick = sample!("Kick", 0.25)
      snare = sample!("Snare", 0.25)
      start_session!(kit([{"A", pad(0, kick)}, {"A", pad(1, snare)}]), autosave_ms: 60_000)
      KitSession.subscribe()
      :ok
    end

    test "tempo, swing and pattern edits round-trip through autosave/load" do
      assert :ok = KitSession.set_tempo(134)
      assert :ok = KitSession.set_swing(0.62)
      assert :ok = KitSession.toggle_step("A", 0, 0, 110)
      assert :ok = KitSession.toggle_step("A", 1, 4, 95)
      assert :ok = KitSession.set_step_velocity("A", 0, 0, 120)

      assert %{tempo: 134, swing: 0.62} = Fake.state()
      assert_received {:magpie_kit, %{kit: %Kit{tempo: 134}}}
      assert_received {:magpie_kit, %{kit: %Kit{swing: 0.62}}}

      assert :ok = KitSession.flush()
      assert {:ok, saved} = Library.load_kit("test-kit")
      assert saved.tempo == 134
      assert saved.swing == 0.62

      assert [%Pattern{id: "A1", bank: "A", length: 16, lanes: lanes}] = saved.patterns
      assert %{0 => %{mute: false, steps: [%Step{step: 0, vel: 120, tick: 0}]}} = lanes
      assert %{1 => %{mute: false, steps: [%Step{step: 4, vel: 95, tick: 0}]}} = lanes

      # Toggling an existing step removes it; an empty unmuted lane is dropped.
      assert :ok = KitSession.toggle_step("A", 0, 0)
      assert %Pattern{lanes: %{1 => _}} = KitSession.pattern(KitSession.snapshot(), "A")
      refute Map.has_key?(KitSession.pattern(KitSession.snapshot(), "A").lanes, 0)
    end

    test "editing the playing pattern updates the engine at once (:now); switching applies at the bar (:bar)" do
      :ok = KitSession.toggle_step("A", 0, 0, 100)
      a1 = KitSession.pattern(KitSession.snapshot(), "A")
      :ok = Engine.set_pattern(a1, at: :now)
      :ok = Engine.play()
      Fake.advance(2)

      # Live edit on the playing pattern applies at once (:now) and sounds at step 3.
      assert :ok = KitSession.toggle_step("A", 1, 3, 88)
      assert %Pattern{id: "A1", lanes: %{0 => _, 1 => _}} = Engine.state().pattern
      assert Engine.state().pending == nil

      :ok = Engine.subscribe()
      Fake.advance(1)
      assert_receive {:magpie_audio, :playhead, 3, _}
      assert_receive {:magpie_audio, :voice, 1, :start}

      # Adding A2 while A1 plays queues A2 for the next bar (:bar).
      assert :ok = KitSession.add_pattern("A")
      assert KitSession.snapshot().pattern_ids["A"] == "A2"
      assert %Pattern{id: "A1"} = Engine.state().pattern
      assert %Pattern{id: "A2"} = Engine.state().pending

      # Editing the pending pattern A2 updates what will take over at the bar.
      assert :ok = KitSession.toggle_step("A", 0, 0, 77)

      assert %Pattern{id: "A2", lanes: %{0 => %{steps: [%Step{step: 0, vel: 77}]}}} =
               Engine.state().pending

      # Switching back to A1, which still plays: the queued A2 is dropped.
      assert :ok = KitSession.select_pattern("A", "A1")
      assert %{pattern: %Pattern{id: "A1"}, pending: nil} = Engine.state()

      # Re-select A2 and advance to the end of the 16-step bar: A2 takes over at step 0.
      assert :ok = KitSession.select_pattern("A", "A2")
      Fake.advance(13)
      assert %Pattern{id: "A2"} = Engine.state().pattern
      assert Engine.state().pending == nil
    end

    test "shrinking from 32 to 16 steps drops steps >= 16 and keeps steps < 16" do
      assert :ok = KitSession.set_pattern_length("A", 32)
      assert :ok = KitSession.toggle_step("A", 0, 4, 100)
      assert :ok = KitSession.toggle_step("A", 0, 16, 90)
      assert :ok = KitSession.toggle_step("A", 0, 31, 80)
      assert :ok = KitSession.toggle_step("A", 1, 20, 75)

      assert :ok = KitSession.set_pattern_length("A", 16)
      pattern = KitSession.pattern(KitSession.snapshot(), "A")
      assert pattern.length == 16
      assert %{0 => %{steps: [%Step{step: 4, vel: 100}]}} = pattern.lanes
      refute Map.has_key?(pattern.lanes, 1)
    end

    test "caps patterns at 4 per bank (A1..A4)" do
      assert [%Pattern{id: "A1"}] = KitSession.patterns(KitSession.snapshot(), "A")
      assert :ok = KitSession.add_pattern("A")
      assert :ok = KitSession.add_pattern("A")
      assert :ok = KitSession.add_pattern("A")

      ids = KitSession.snapshot() |> KitSession.patterns("A") |> Enum.map(& &1.id)
      assert ids == ["A1", "A2", "A3", "A4"]
      assert KitSession.snapshot().pattern_ids["A"] == "A4"
      assert %Pattern{id: "A4"} = KitSession.pattern(KitSession.snapshot(), "A")
      # pattern(%Kit{}, bank) is pure and always returns the kit's first pattern for the bank.
      assert %Pattern{id: "A1"} = KitSession.pattern(KitSession.snapshot().kit, "A")

      assert {:error, {:invalid, :pattern}} = KitSession.add_pattern("A")
      assert [_, _, _, _] = KitSession.patterns(KitSession.snapshot(), "A")
    end

    test "refuses invalid tempo, swing, length, velocity, step, unloaded slot, bank and pattern" do
      assert {:error, {:invalid, :tempo}} = KitSession.set_tempo(39)
      assert {:error, {:invalid, :tempo}} = KitSession.set_tempo(241)
      assert {:error, {:invalid, :swing}} = KitSession.set_swing(0.49)
      assert {:error, {:invalid, :swing}} = KitSession.set_swing(0.76)
      assert {:error, {:invalid, :length}} = KitSession.set_pattern_length("A", 24)
      assert {:error, {:invalid, :bank}} = KitSession.set_pattern_length("Z", 16)
      assert {:error, {:invalid, :vel}} = KitSession.toggle_step("A", 0, 0, 0)
      assert {:error, {:invalid, :vel}} = KitSession.set_step_velocity("A", 0, 0, 128)
      assert {:error, {:invalid, :step}} = KitSession.toggle_step("A", 0, 16, 100)
      assert {:error, {:invalid, :step}} = KitSession.set_step_velocity("A", 0, -1, 100)
      # Slot 2 has no loaded pad in bank A.
      assert {:error, {:invalid, :slot}} = KitSession.toggle_step("A", 2, 0, 100)
      assert {:error, {:invalid, :slot}} = KitSession.set_step_velocity("A", 2, 0, 100)
      assert {:error, {:invalid, :slot}} = KitSession.toggle_step("A", 16, 0, 100)
      assert {:error, {:invalid, :bank}} = KitSession.toggle_step("E", 0, 0, 100)
      assert {:error, {:invalid, :pattern}} = KitSession.select_pattern("A", "A9")
      assert {:error, {:invalid, :bank}} = KitSession.select_pattern("E", "E1")
      assert {:error, {:invalid, :bank}} = KitSession.add_pattern("E")
    end

    test "an engine error leaves the kit and selection unchanged" do
      :ok = KitSession.toggle_step("A", 0, 0, 100)
      a1 = KitSession.pattern(KitSession.snapshot(), "A")
      :ok = Engine.set_pattern(a1, at: :now)
      :ok = Engine.play()

      # Drain subscription mailbox before provoking an engine refusal.
      receive do
        {:magpie_kit, _} -> :ok
      after
        0 -> :ok
      end

      # Hand ownership of Fake away from Engine so engine control calls return {:error, :not_owner}.
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)
      {:ok, _} = Fake.open(other)

      assert {:error, :not_owner} = KitSession.set_tempo(140)
      assert {:error, :not_owner} = KitSession.set_swing(0.60)
      assert {:error, :not_owner} = KitSession.toggle_step("A", 1, 4, 100)
      assert {:error, :not_owner} = KitSession.add_pattern("A")

      snapshot = KitSession.snapshot()
      assert snapshot.kit.tempo == 120
      assert snapshot.kit.swing == 0.5
      assert snapshot.pattern_ids["A"] == "A1"
      assert KitSession.pattern(snapshot, "A") == a1
      refute_received {:magpie_kit, _}
    end

    test "selecting the pattern that plays leaves it playing on; selecting it over a queued one cancels that" do
      :ok = KitSession.set_pattern_length("A", 32)
      play!("A")
      Fake.advance(3)

      # Re-tapping its tab: no restart at the bar.
      assert :ok = KitSession.select_pattern("A", "A1")
      assert %{pattern: %Pattern{id: "A1"}, pending: nil} = Engine.state()
      Fake.advance(13)
      assert %{step: 16, pattern: %Pattern{id: "A1"}} = Engine.state()

      # A2 queued for the bar, then A1 again: A1 plays on from where it is.
      assert :ok = KitSession.add_pattern("A")
      assert %Pattern{id: "A2"} = Engine.state().pending
      assert :ok = KitSession.select_pattern("A", "A1")
      assert %{pattern: %Pattern{id: "A1"}, pending: nil} = Engine.state()
      Fake.advance(16)
      assert %{step: 0, pattern: %Pattern{id: "A1"}} = Engine.state()
    end
  end

  describe "live recording" do
    setup do
      kick = sample!("Kick", 0.25)
      snare = sample!("Snare", 0.25)

      start_session!(kit([{"A", pad(0, kick)}, {"A", pad(1, snare)}, {"B", pad(0, kick)}]),
        autosave_ms: 30
      )

      KitSession.subscribe()
      %{kick: kick}
    end

    test "Snap off keeps a hit's timing, Snap on puts it on the grid; the engine plays it at once" do
      play!("A")
      :ok = KitSession.set_recording(true)
      assert KitSession.snapshot().recording

      Fake.advance_ticks(3 * 24 + 5)
      :ok = Engine.trigger(0, 90)
      settle()
      assert %{steps: [%Step{step: 3, vel: 90, tick: 5, note: nil}]} = lane("A", 0)

      assert %Pattern{id: "A1", lanes: %{0 => %{steps: [%Step{step: 3, tick: 5}]}}} =
               Engine.state().pattern

      assert Engine.state().pending == nil

      :ok = KitSession.set_snap(true)
      # To step 6, 4 ticks early.
      Fake.advance_ticks(3 * 24 - 9)
      :ok = Engine.trigger(1, 70)
      settle()
      assert %{steps: [%Step{step: 6, vel: 70, tick: 0}]} = lane("A", 1)
    end

    test "a hit replaces the step at its index instead of adding a second one" do
      :ok = KitSession.toggle_step("A", 0, 2, 50)
      play!("A")
      :ok = KitSession.set_recording(true)

      Fake.advance_ticks(2 * 24 - 3)
      :ok = Engine.trigger(0, 100)
      settle()
      assert %{steps: [%Step{step: 2, vel: 100, tick: -3}]} = lane("A", 0)

      :ok = Engine.trigger(0, 60)
      settle()
      assert %{steps: [%Step{step: 2, vel: 60, tick: -3}]} = lane("A", 0)
    end

    test "hits on another bank, on a pad the kit doesn't have, or off the selected pattern are dropped",
         %{kick: kick} do
      play!("A")
      :ok = KitSession.set_recording(true)

      # Bank B isn't playing.
      :ok = Engine.trigger(Kit.pad_index("B", 0), 100)
      # A pad the engine has and the kit doesn't.
      :ok = Engine.set_pad(Kit.pad_index("A", 5), pad(5, kick))
      :ok = Engine.trigger(Kit.pad_index("A", 5), 100)
      settle()
      assert KitSession.snapshot().kit.patterns == []

      # A2 selected, A1 still playing until the bar.
      :ok = KitSession.add_pattern("A")
      :ok = Engine.trigger(0, 100)
      settle()
      assert Enum.all?(KitSession.patterns(KitSession.snapshot(), "A"), &(&1.lanes == %{}))
      assert KitSession.snapshot().recording
    end

    test "arming needs the engine playing; it stops, the session disarms and records no more" do
      assert {:error, :not_playing} = KitSession.set_recording(true)
      refute KitSession.snapshot().recording

      play!("A")
      :ok = KitSession.set_recording(true)
      assert_receive {:magpie_kit, %{recording: true}}
      :ok = Engine.stop()
      settle()
      refute KitSession.snapshot().recording

      play!("A")
      :ok = Engine.trigger(0, 100)
      settle()
      assert lane("A", 0) == nil
    end

    test "a hit the session handles after the engine stopped is dropped and disarms" do
      play!("A")
      :ok = KitSession.set_recording(true)
      Fake.advance(1)

      # The hit is forwarded before the stop, the session reads it after.
      :sys.suspend(KitSession)
      :ok = Engine.trigger(0, 100)
      :ok = Engine.stop()
      :sys.resume(KitSession)
      settle()

      assert lane("A", 0) == nil
      refute KitSession.snapshot().recording
    end

    test "the Engine exiting disarms" do
      play!("A")
      :ok = KitSession.set_recording(true)
      stop_supervised!(Engine)
      assert_receive {:magpie_kit, %{recording: false}}
    end

    test "what is recorded is autosaved with the kit" do
      play!("A")
      :ok = KitSession.set_recording(true)
      Fake.advance_ticks(5 * 24 + 1)
      :ok = Engine.trigger(1, 88)
      settle()
      Process.sleep(80)

      assert {:ok, %Kit{patterns: [%Pattern{id: "A1", lanes: lanes}]}} =
               Library.load_kit("test-kit")

      assert %{1 => %{steps: [%Step{step: 5, vel: 88, tick: 1}]}} = lanes
    end

    test "a hit recorded while another bank's pattern waits for the bar doesn't cancel it" do
      play!("A")
      :ok = KitSession.set_recording(true)
      # Pads switched to bank B: B1 waits for the bar.
      :ok = Engine.set_pattern(KitSession.pattern(KitSession.snapshot(), "B"), at: :bar)

      Fake.advance(2)
      :ok = Engine.trigger(0, 100)
      settle()

      assert %{steps: [%Step{step: 2}]} = lane("A", 0)
      assert %Pattern{id: "A1", lanes: %{0 => _}} = Engine.state().pattern
      assert %Pattern{id: "B1", bank: "B"} = Engine.state().pending

      Fake.advance(14)
      assert %{pattern: %Pattern{id: "B1", bank: "B"}, pending: nil} = Engine.state()
    end
  end

  defp play!(bank) do
    :ok = Engine.set_pattern(KitSession.pattern(KitSession.snapshot(), bank), at: :now)
    :ok = Engine.play()
  end

  # The engine has forwarded what the fake sent it, and the session handled it.
  defp settle do
    Engine.state()
    KitSession.snapshot()
  end

  defp lane(bank, slot),
    do: KitSession.snapshot() |> KitSession.pattern(bank) |> Map.fetch!(:lanes) |> Map.get(slot)
end
