defmodule Magpie.SeqScreenTest do
  # The engine (the fake) and the kit session are one per VM: not async.
  use Mob.ScreenCase, async: false

  import Magpie.Test.Kits
  import Magpie.Test.Screens, only: [assert_every_tap_held: 1, texts: 1]

  alias Magpie.Audio.Fake
  alias Magpie.{Engine, KitSession, SeqScreen, Style}
  alias Magpie.Kit.Step

  setup do
    setup_library()
    kick = sample!("KICK", 0.5)
    snare = sample!("SNARE", 0.25)
    hat = sample!("HAT", 0.25)

    kit =
      kit([
        {"A", pad(0, kick)},
        {"A", pad(1, snare, velocity: :fixed, fixed_velocity: 90)},
        {"A", pad(4, hat, color: :amber)},
        {"B", pad(2, kick, name: "B KICK")}
      ])

    start_session!(kit)
    :ok
  end

  defp mount(params \\ %{}), do: SeqScreen |> mount_screen(params) |> pump()

  defp pump(view) do
    Engine.state()
    KitSession.snapshot()
    drain(view)
  end

  defp drain(view) do
    receive do
      {:magpie_audio, _, _, _} = msg -> view |> render_info(msg) |> drain()
      {:magpie_kit, _} = msg -> view |> render_info(msg) |> drain()
    after
      0 -> view
    end
  end

  defp press(view, tag), do: view |> render_info({:tap, tag}) |> pump()

  describe "rendering and empty bank" do
    test "renders lanes only for loaded pads in the bank and every tap target is held" do
      view = mount()
      assert_renderable(view)
      assert assert_every_tap_held(view) >= 8

      lane_ids =
        for node <- flatten(view),
            is_binary(node.props[:id]),
            String.starts_with?(node.props.id, "lane_row_"),
            do: node.props.id

      assert lane_ids == ["lane_row_0", "lane_row_1", "lane_row_4"]
      assert "KICK" in texts(view)
      assert "SNARE" in texts(view)
      assert "HAT" in texts(view)
      assert "16 steps" in texts(view)
      assert "swing 50%" in texts(view)
      assert "120 bpm" in texts(view)
    end

    test "shows a plain centred fallback when the bank has no loaded pads" do
      view = mount(%{bank: "C"})
      assert_renderable(view)
      assert_every_tap_held(view)
      assert "No pads loaded in bank C." in texts(view)
      assert find(view, :row, id: "playhead_bar") == nil
    end

    test "back pops to PadsScreen" do
      view = mount() |> press(:back)
      assert navigated_to(view) == {:pop}
    end
  end

  describe "steps and lane audition" do
    test "tapping a step toggles it on at velocity 100 and off again" do
      view = mount()
      assert find(view, :box, id: "fill_0_4") == nil

      view =
        view
        |> render_touch({:step, 0, 4}, :down,
          pointer_id: 1,
          x: 10.0,
          y: 24.0,
          width: 40.0,
          height: 48.0
        )
        |> render_touch({:step, 0, 4}, :up,
          pointer_id: 1,
          x: 10.0,
          y: 24.0,
          width: 40.0,
          height: 48.0
        )
        |> pump()

      fill = find(view, :box, id: "fill_0_4")
      assert fill != nil
      assert fill.props.height == round(48 * 100 / 127)

      pattern = KitSession.pattern(KitSession.snapshot(), "A")
      assert %{0 => %{steps: [%Step{step: 4, vel: 100}]}} = pattern.lanes

      # Tapping the active step toggles it off.
      view =
        view
        |> render_touch({:step, 0, 4}, :down,
          pointer_id: 2,
          x: 10.0,
          y: 24.0,
          width: 40.0,
          height: 48.0
        )
        |> render_touch({:step, 0, 4}, :up,
          pointer_id: 2,
          x: 10.0,
          y: 24.0,
          width: 40.0,
          height: 48.0
        )
        |> pump()

      assert find(view, :box, id: "fill_0_4") == nil
      assert KitSession.pattern(KitSession.snapshot(), "A").lanes == %{}
    end

    test "vertical drag on a step changes its velocity and clamps to 1..127 (min 25% fill)" do
      :ok = KitSession.toggle_step("A", 0, 2, 80)
      view = mount()

      # Drag up by 30 pt -> 80 + 60 = 140 -> clamped to 127 (48 pt fill).
      view =
        view
        |> render_touch({:step, 0, 2}, :down,
          pointer_id: 3,
          x: 10.0,
          y: 40.0,
          width: 40.0,
          height: 48.0
        )
        |> render_touch({:step, 0, 2}, :move,
          pointer_id: 3,
          x: 10.0,
          y: 10.0,
          width: 40.0,
          height: 48.0
        )
        |> pump()

      assert find(view, :box, id: "fill_0_2").props.height == 48

      assert %{0 => %{steps: [%Step{step: 2, vel: 127}]}} =
               KitSession.pattern(KitSession.snapshot(), "A").lanes

      # Drag down far below -> clamped to velocity 1 (25% min fill = 12 pt), and lift doesn't toggle off.
      view =
        view
        |> render_touch({:step, 0, 2}, :move,
          pointer_id: 3,
          x: 10.0,
          y: 120.0,
          width: 40.0,
          height: 48.0
        )
        |> render_touch({:step, 0, 2}, :up,
          pointer_id: 3,
          x: 10.0,
          y: 120.0,
          width: 40.0,
          height: 48.0
        )
        |> pump()

      assert find(view, :box, id: "fill_0_2").props.height == 12

      assert %{0 => %{steps: [%Step{step: 2, vel: 1}]}} =
               KitSession.pattern(KitSession.snapshot(), "A").lanes
    end

    test "tapping a lane label auditions the pad through Engine.trigger" do
      view = mount()
      _view = view |> press({:audition, 0}) |> press({:audition, 1})

      assert [{:trigger, 0, 100, 0}, {:trigger, 1, 90, 0}] = Fake.calls()
    end
  end

  describe "top bar controls: length, pattern tabs, tempo, swing, snap, playhead" do
    test "toggles pattern length between 16 and 32 steps in one row" do
      view = mount()
      assert find(view, :box, id: "step_0_15") != nil
      assert find(view, :box, id: "step_0_31") == nil

      view = press(view, :length)
      assert "32 steps" in texts(view)
      assert find(view, :box, id: "step_0_31") != nil
      assert KitSession.pattern(KitSession.snapshot(), "A").length == 32

      view = press(view, :length)
      assert "16 steps" in texts(view)
      assert find(view, :box, id: "step_0_31") == nil
    end

    test "adds up to 4 patterns per bank, hides + at 4, and switches between tabs" do
      view = mount()
      assert find(view, :box, id: "pattern_A1") != nil
      assert find(view, :box, id: "pattern_add") != nil

      view = view |> press(:add_pattern) |> press(:add_pattern) |> press(:add_pattern)
      for id <- ["A1", "A2", "A3", "A4"], do: assert(find(view, :box, id: "pattern_#{id}") != nil)
      assert find(view, :box, id: "pattern_add") == nil
      assert assigns(view).snapshot.pattern_ids["A"] == "A4"

      view = press(view, {:pattern, "A2"})
      assert assigns(view).snapshot.pattern_ids["A"] == "A2"
      assert find(view, :box, id: "pattern_A2").props.background == Style.color(:selected)
    end

    test "vertical drag on tempo and swing adjusts 6 pt/step and clamps at limits" do
      view = mount()

      # Tempo starts at 120: drag up 30 pt (+5 bpm -> 125), then down 600 pt (clamps to 40).
      view =
        view
        |> render_touch({:field, :tempo}, :down,
          pointer_id: 10,
          x: 10.0,
          y: 50.0,
          width: 70.0,
          height: 44.0
        )
        |> render_touch({:field, :tempo}, :move,
          pointer_id: 10,
          x: 10.0,
          y: 20.0,
          width: 70.0,
          height: 44.0
        )
        |> pump()

      assert "125 bpm" in texts(view)
      assert Fake.state().tempo == 125

      view =
        view
        |> render_touch({:field, :tempo}, :move,
          pointer_id: 10,
          x: 10.0,
          y: 650.0,
          width: 70.0,
          height: 44.0
        )
        |> render_touch({:field, :tempo}, :up,
          pointer_id: 10,
          x: 10.0,
          y: 650.0,
          width: 70.0,
          height: 44.0
        )
        |> pump()

      assert "40 bpm" in texts(view)
      assert Fake.state().tempo == 40

      # Swing starts at 50%: drag up 36 pt (+6% -> 56%), then up 300 pt (clamps to 75%).
      view =
        view
        |> render_touch({:field, :swing}, :down,
          pointer_id: 11,
          x: 10.0,
          y: 50.0,
          width: 80.0,
          height: 44.0
        )
        |> render_touch({:field, :swing}, :move,
          pointer_id: 11,
          x: 10.0,
          y: 14.0,
          width: 80.0,
          height: 44.0
        )
        |> pump()

      assert "swing 56%" in texts(view)
      assert_in_delta Fake.state().swing, 0.56, 1.0e-6

      view =
        view
        |> render_touch({:field, :swing}, :move,
          pointer_id: 11,
          x: 10.0,
          y: -250.0,
          width: 80.0,
          height: 44.0
        )
        |> render_touch({:field, :swing}, :up,
          pointer_id: 11,
          x: 10.0,
          y: -250.0,
          width: 80.0,
          height: 44.0
        )
        |> pump()

      assert "swing 75%" in texts(view)
      assert_in_delta Fake.state().swing, 0.75, 1.0e-6
    end

    test "Snap toggles KitSession.set_snap" do
      view = mount()
      refute assigns(view).snapshot.kit.snap

      view = press(view, :snap)
      assert assigns(view).snapshot.kit.snap
      assert find(view, :box, id: "snap").props.background == Style.color(:selected)
    end

    test "Play starts the selected pattern, playhead messages move the bar, and Stop clears it" do
      :ok = KitSession.toggle_step("A", 0, 2, 100)
      view = mount() |> press(:play)

      assert assigns(view).playing
      assert Fake.state().playing
      assert find(view, :box, id: "playhead_0").props.background == Style.color(:text)

      Fake.advance(1)
      view = pump(view)
      lanes = grid(view)

      Fake.advance(1)
      view = pump(view)
      assert assigns(view).step == 2
      assert find(view, :box, id: "playhead_0").props.background == 0x00000000
      assert find(view, :box, id: "playhead_2").props.background == Style.color(:text)
      # The lanes stay as they are from step to step: only the bar moves.
      assert grid(view) == lanes

      view = press(view, :play)
      refute assigns(view).playing
      refute Fake.state().playing
      assert assigns(view).step == nil
      assert find(view, :box, id: "playhead_2").props.background == 0x00000000
    end

    test "with a switch queued, the playhead follows the pattern playing until the new one takes over" do
      :ok = KitSession.toggle_step("A", 0, 0, 100)
      a1 = KitSession.pattern(KitSession.snapshot(), "A")
      :ok = Engine.set_pattern(a1, at: :now)
      :ok = Engine.play()
      Fake.advance(3)
      # A2 selected (queued for the bar) while A1 plays.
      :ok = KitSession.add_pattern("A")

      view = mount()
      assert assigns(view).snapshot.pattern_ids["A"] == "A2"
      refute Enum.any?(0..15, &(playhead_bg(view, &1) == Style.color(:text)))

      Fake.advance(13)
      view = pump(view)
      assert playhead_bg(view, 0) == Style.color(:text)
    end

    test "live record starts the selected pattern and arms; auditioned pads land in it; again disarms" do
      view = mount() |> press(:record)
      assert %{playing: true, pattern: %{id: "A1"}} = Engine.state()
      assert assigns(view).playing
      assert assigns(view).snapshot.recording
      assert find(view, :box, id: "record_pattern").props.background == Style.color(:danger)

      Fake.advance(3)
      view = press(view, {:audition, 1})
      assert find(view, :box, id: "fill_1_3") != nil

      assert %{1 => %{steps: [%Step{step: 3, vel: 90, tick: 0}]}} =
               KitSession.pattern(assigns(view).snapshot, "A").lanes

      view = press(view, :record)
      refute assigns(view).snapshot.recording
      assert Engine.state().playing
      assert find(view, :box, id: "record_pattern").props.background == Style.color(:raised)
    end

    test "Stop disarms live record" do
      view = mount() |> press(:play) |> press(:record)
      assert assigns(view).snapshot.recording

      view = press(view, :play)
      refute Engine.state().playing
      refute assigns(view).snapshot.recording
      assert find(view, :box, id: "record_pattern").props.background == Style.color(:raised)
    end

    test "Play/Stop follows a start or stop made elsewhere (the pads)" do
      :ok = KitSession.toggle_step("A", 0, 1, 100)
      view = mount()

      :ok = Engine.set_pattern(KitSession.pattern(KitSession.snapshot(), "A"), at: :now)
      :ok = Engine.play()
      Fake.advance(1)
      view = pump(view)
      assert assigns(view).playing
      assert playhead_bg(view, 1) == Style.color(:text)

      :ok = Engine.stop()
      view = pump(view)
      refute assigns(view).playing
      assert playhead_bg(view, 1) == 0x00000000
    end
  end

  defp playhead_bg(view, step), do: find(view, :box, id: "playhead_#{step}").props.background

  # Every lane row as rendered.
  defp grid(view),
    do:
      for(
        node <- flatten(view),
        String.starts_with?(node.props[:id] || "", "lane_row_"),
        do: node
      )
end
