defmodule Magpie.PadsScreenTest do
  # The engine (the fake) and the kit session are one per VM: not async.
  use Mob.ScreenCase, async: false

  import Magpie.Test.Kits

  alias Magpie.Audio.Fake
  alias Magpie.{Kit, KitSession, PadsScreen}
  alias Magpie.Kit.{Pad, Region}
  alias Mob.Event.Touch

  @h 155.0
  @w 91.0

  setup do
    setup_library()
    kick = sample!("KICK", 0.5)
    hat = sample!("HAT", 0.25)
    loop = sample!("BREAK", 1.0)

    kit =
      kit([
        {"A", pad(0, kick)},
        {"A", pad(1, hat, mode: :gate, color: :amber)},
        {"A", pad(2, kick, velocity: :fixed, fixed_velocity: 90)},
        {"A", pad(3, loop, mode: :loop, color: :lime)},
        {"A", pad(4, hat, mode: :keys)},
        {"B", pad(0, loop, name: "B KICK")}
      ])

    start_session!(kit)
    %{kick: kick}
  end

  defp mount, do: PadsScreen |> mount_screen() |> pump()

  # What the engine and the session sent the screen (it runs in this process).
  defp pump(view) do
    Magpie.Engine.state()
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

  defp down(view, pad, pointer, y, x \\ 40.0),
    do:
      render_touch(view, {:pad, pad}, :down,
        pointer_id: pointer,
        x: x,
        y: y,
        width: @w,
        height: @h
      )

  defp up(view, pad, pointer, y \\ 60.0, x \\ 40.0),
    do:
      render_touch(view, {:pad, pad}, :up, pointer_id: pointer, x: x, y: y, width: @w, height: @h)

  defp move(view, pad, pointer, x, y),
    do:
      render_touch(view, {:pad, pad}, :move,
        pointer_id: pointer,
        x: x,
        y: y,
        width: @w,
        height: @h
      )

  # A touch as native sends it, at the pad's top edge, for queueing.
  defp touch_message(pad, phase, pointer),
    do:
      Touch.message({:pad, pad}, phase,
        pointer_id: pointer,
        x: 40.0,
        y: 0.0,
        width: @w,
        height: @h
      )

  defp texts(view), do: for(%{type: :text, props: %{text: t}} <- flatten(view), do: t)

  defp triggers, do: for({:trigger, pad, vel, q} <- Fake.calls(), do: {pad, vel, q})
  defp releases, do: for({:release, pad} <- Fake.calls(), do: pad)

  # The pad's face: the Box inside the touch cell.
  defp face(view, index) do
    cell = Enum.find(flatten(view), &(&1.props[:id] == "pad_#{index}"))
    assert cell, "no pad_#{index}"
    hd(cell.children)
  end

  defp face_texts(view, index),
    do: for(%{type: :text, props: %{text: t}} <- flatten(face(view, index)), do: t)

  defp long_press_message(pointer) do
    assert_receive {:long_press, ^pointer, _token} = msg, 1_000
    msg
  end

  defp assert_every_tap_held(view) do
    taps = for node <- flatten(view), node.props[:on_tap] != nil, do: node
    assert taps != []

    for node <- taps do
      assert node.props[:on_press_out] == {self(), :held},
             "#{node.type} #{inspect(node.props[:id])} with on_tap #{inspect(node.props.on_tap)} has no on_press_out={held()}"
    end

    length(taps)
  end

  describe "rendering" do
    test "bank A's 16 pads: loaded ones with name, mode and wave, empty ones to record into" do
      view = mount()
      assert_renderable(view)

      cells =
        for node <- flatten(view),
            is_binary(node.props[:id]),
            String.starts_with?(node.props.id, "pad_"),
            do: node.props.id

      assert cells == for(i <- 0..15, do: "pad_#{i}")

      assert ["KICK", "one-shot"] == face_texts(view, 0)
      assert ["HAT", "gate"] == face_texts(view, 1)
      assert ["+", "record", "or load"] == face_texts(view, 9)

      # Idle: the colour at 26 % over raised; the wave's 12 bars.
      assert face(view, 0).props.background == Magpie.Style.pad_fill(:coral, :idle)

      bars =
        for %{type: :box, props: %{weight: 1, corner_radius: 1}} <- flatten(face(view, 0)),
            do: :bar

      assert Enum.count(bars) == 12

      assert "Test Kit" in texts(view)
      assert "120 bpm" in texts(view)
    end

    test "the bank tabs switch the pads shown" do
      view = mount() |> render_info({:tap, {:bank, "B"}})
      assert ["B KICK", "one-shot"] == face_texts(view, Kit.pad_index("B", 0))
      assert ["+", "record", "or load"] == face_texts(view, Kit.pad_index("B", 1))
    end

    test "every tap target also has on_press_out={held()}, with and without the sheet" do
      view = mount()
      assert assert_every_tap_held(view) >= 6

      view = down(view, 0, 1, 50.0)
      view = render_info(view, long_press_message(1))
      assert "Done" in texts(view)
      assert assert_every_tap_held(view) > 20
    end
  end

  describe "playing" do
    test "velocity from where the pad is hit, or the pad's fixed velocity, on touch-down" do
      view = mount()
      view = down(view, 0, 1, 0.0)
      assert triggers() == [{0, 127, 0}]
      view = down(view, 1, 2, @h)
      view = down(view, 2, 3, 10.0)
      _view = down(view, 0, 4, @h / 2)

      assert triggers() == [
               {0, 127, 0},
               {1, 19, 0},
               {2, 90, 0},
               {0, Magpie.Style.velocity(@h / 2, @h), 0}
             ]
    end

    test "touch-down paints the press: lit, ink, 2 pt lower, the landing line, ring and badge" do
      view = mount() |> down(0, 1, 40.0, 30.0)
      f = face(view, 0)

      assert f.props.background == Magpie.Style.pad_fill(:coral, :playing)
      assert f.props.offset_y == 2
      assert "v#{Magpie.Style.velocity(40.0, @h)}" in face_texts(view, 0)
      boxes = flatten(f)
      assert Enum.any?(boxes, &(&1.props[:height] == 2 and &1.props[:offset_y] == 39.0))

      assert Enum.any?(
               boxes,
               &(&1.props[:width] == 32 and &1.props[:offset_x] == 14.0 and
                   &1.props[:offset_y] == 24.0)
             )
    end

    test "fingers landing together are all triggered before the screen renders" do
      view = mount()
      send(self(), touch_message(1, :down, 2))
      send(self(), touch_message(3, :down, 3))
      view = down(view, 0, 1, 0.0)

      assert triggers() == [{0, 127, 0}, {1, 127, 0}, {3, 127, 0}]
      assert assigns(view).fingers |> Map.keys() |> Enum.sort() == [1, 2, 3]
      refute_received {:touch, _, _}
    end

    test "queued touches are handled in their order: an up before a down on the same gate pad releases first" do
      # Pointer 1 holds gate pad 1; it lifts, then pointer 3 lands on pad 1,
      # both queued while pad 0's down is handled.
      view = mount() |> down(1, 1, 0.0)
      send(self(), touch_message(1, :up, 1))
      send(self(), touch_message(1, :down, 3))
      view = down(view, 0, 2, 0.0)

      calls =
        for c <- Fake.calls(),
            match?({:trigger, _, _, _}, c) or match?({:release, _}, c),
            do: with({:trigger, p, v, _} <- c, do: {:trigger, p, v})

      assert calls == [{:trigger, 1, 127}, {:trigger, 0, 127}, {:release, 1}, {:trigger, 1, 127}]

      assert %{2 => %{pad: 0}, 3 => %{pad: 1}} = assigns(view).fingers
      refute_received {:touch, _, _}
    end

    test "fingers are independent: each releases its own pad" do
      view = mount() |> down(1, 10, 50.0) |> down(3, 11, 50.0)
      view = up(view, 1, 10)
      assert releases() == [1]
      # Pad 3 is still held: still pressed.
      assert face(view, 3).props.offset_y == 2
      assert face(view, 1).props.offset_y == 0

      _view = up(view, 3, 11)
      assert releases() == [1, 3]
    end

    test "a pad held by two fingers releases when the last one lifts" do
      view = mount() |> down(1, 1, 50.0) |> down(1, 2, 90.0)
      view = up(view, 1, 1)
      assert releases() == []

      _view =
        render_touch(view, {:pad, 1}, :cancel,
          pointer_id: 2,
          x: 0.0,
          y: 0.0,
          width: @w,
          height: @h
        )

      assert releases() == [1]
    end

    test "one-shot and toggle pads ignore the lift" do
      :ok = KitSession.update_pad(3, &%{&1 | mode: :toggle})
      # The mode change itself let pad 3's (silent) loop voices go.
      assert releases() == [3]
      view = mount() |> down(0, 1, 50.0) |> up(0, 1) |> down(3, 2, 50.0) |> up(3, 2)
      assert releases() == [3]
      assert [{0, _, 0}, {3, _, 0}] = triggers()
      assert_renderable(view)
    end

    test "Snap quantizes loop launches to a 16th, not one-shots" do
      view = mount() |> render_info({:tap, :snap}) |> pump()
      assert KitSession.snapshot().kit.snap
      _view = view |> down(3, 1, 0.0) |> down(0, 2, 0.0)
      assert triggers() == [{3, 127, 24}, {0, 127, 0}]
    end

    test "a sounding pad stays lit after the lift; a looping one shows the loop tint and progress" do
      view = mount() |> down(0, 1, 50.0) |> pump() |> up(0, 1)
      f = face(view, 0)
      assert f.props.background == Magpie.Style.pad_fill(:coral, :playing)
      assert f.props.offset_y == 0
      assert "v#{Magpie.Style.velocity(50.0, @h)}" in face_texts(view, 0)

      Fake.finish(0)
      view = pump(view)
      assert face(view, 0).props.background == Magpie.Style.pad_fill(:coral, :idle)

      view = view |> down(3, 2, 50.0) |> pump() |> up(3, 2) |> pump()
      # Released: the loop stops.
      assert face(view, 3).props.background == Magpie.Style.pad_fill(:lime, :idle)

      :ok = KitSession.update_pad(3, &%{&1 | mode: :toggle})
      view = view |> pump() |> down(3, 3, 50.0) |> pump() |> up(3, 3)
      assert face(view, 3).props.background == Magpie.Style.pad_fill(:lime, :loop)
      assert "toggle · playing" in face_texts(view, 3)
      # The frame timer runs while it loops.
      assert_receive {:tick, token}, 200
      view = render_info(view, {:tick, token})
      assert view |> assigns() |> Map.fetch!(:tick) != nil
    end
  end

  describe "long press" do
    test "opens the pad's settings 600 ms after the down, timed by a token per finger" do
      view = mount() |> down(1, 7, 50.0)
      refute_receive {:long_press, _, _}, 550
      view = render_info(view, long_press_message(7))

      assert assigns(view).sheet == 1
      assert "· pad A2" in texts(view)
      assert "Gate" in texts(view)
    end

    test "a lift before 600 ms cancels it, and a stale timer from that finger does nothing" do
      view = mount() |> down(1, 7, 50.0) |> up(1, 7)
      stale = long_press_message(7)
      # The same pointer id lands again: its new timer has a new token.
      view = down(view, 1, 7, 50.0)
      view = render_info(view, stale)
      assert assigns(view).sheet == nil

      view = render_info(view, long_press_message(7))
      assert assigns(view).sheet == 1
    end

    test "sliding off the pad cancels it; moving within it doesn't" do
      view = mount() |> down(0, 1, 50.0) |> move(0, 1, 60.0, 80.0)
      view = render_info(view, long_press_message(1))
      assert assigns(view).sheet == 0

      view = render_info(view, {:tap, :sheet_done})
      view = view |> up(0, 1) |> down(0, 2, 50.0) |> move(0, 2, @w + 30.0, 50.0)
      view = render_info(view, long_press_message(2))
      assert assigns(view).sheet == nil
    end

    test "moves are asked for only while a long press is pending" do
      view = mount()
      assert face_cell_touch(view, 0) == {self(), {:pad, 0}}
      view = down(view, 0, 1, 50.0)
      assert {_, {:pad, 0}, opts} = face_cell_touch(view, 0)
      assert opts[:moves]
      _ = long_press_message(1)
    end
  end

  defp face_cell_touch(view, index),
    do: Enum.find(flatten(view), &(&1.props[:id] == "pad_#{index}")).props.on_touch

  describe "empty pads" do
    test "a tap opens the Record screen for that pad" do
      view = mount() |> down(9, 1, 50.0) |> up(9, 1)
      assert navigated_to(view) == Magpie.RecordScreen
      assert triggers() == []
      refute_receive {:long_press, _, _}, 700
    end

    test "sliding off before the lift doesn't" do
      view = mount() |> down(9, 1, 50.0) |> move(9, 1, -20.0, 50.0) |> up(9, 1, 50.0, -20.0)
      assert navigated_to(view) == nil
    end
  end

  describe "the settings sheet" do
    setup do
      view = mount() |> down(0, 1, 50.0)
      view = view |> render_info(long_press_message(1)) |> up(0, 1)
      %{view: view}
    end

    test "every change goes through the kit session to the engine", %{view: view} do
      view =
        view
        |> render_info({:tap, {:mode, :gate}})
        |> render_info({:tap, {:choke, 2}})
        |> render_info({:tap, {:color, :violet}})
        |> render_info({:tap, {:velocity, :fixed}})
        |> pump()

      assert %Pad{mode: :gate, choke: 2, color: :violet, velocity: :fixed} =
               KitSession.snapshot().kit.banks["A"][0]

      assert %{mode: :gate, choke: 2} = Fake.state().pads[0]

      # The sheet shows it and the pad now plays at its fixed velocity.
      assert face(view, 0).props.border_width == 3
      _view = view |> render_info({:tap, :sheet_done}) |> down(0, 2, 0.0)
      assert List.last(triggers()) == {0, 100, 0}
    end

    test "dragging the pitch and MIDI note fields: up for more, 6 pt a step", %{view: view} do
      view =
        view
        |> render_touch({:field, :pitch}, :down,
          pointer_id: 5,
          x: 10.0,
          y: 20.0,
          width: 150.0,
          height: 40.0
        )
        |> render_touch({:field, :pitch}, :move,
          pointer_id: 5,
          x: 10.0,
          y: 8.0,
          width: 150.0,
          height: 40.0
        )
        |> pump()

      assert %Pad{sample: %Region{pitch_st: 2}} = KitSession.snapshot().kit.banks["A"][0]
      assert "+2 st" in texts(view)

      view =
        view
        |> render_touch({:field, :pitch}, :up,
          pointer_id: 5,
          x: 10.0,
          y: 8.0,
          width: 150.0,
          height: 40.0
        )
        |> render_touch({:field, :note}, :down,
          pointer_id: 6,
          x: 10.0,
          y: 20.0,
          width: 150.0,
          height: 40.0
        )
        |> render_touch({:field, :note}, :move,
          pointer_id: 6,
          x: 10.0,
          y: 32.0,
          width: 150.0,
          height: 40.0
        )
        |> pump()

      assert %Pad{midi_note: 58} = KitSession.snapshot().kit.banks["A"][0]
      assert "A#3 · 58" in texts(view)
    end

    test "Clear empties the pad and closes the sheet", %{view: view} do
      view = view |> render_info({:tap, :clear}) |> pump()
      assert assigns(view).sheet == nil
      assert KitSession.snapshot().kit.banks["A"][0] == nil
      assert ["+", "record", "or load"] == face_texts(view, 0)
    end

    test "Replace records into the pad", %{view: view} do
      view = render_info(view, {:tap, :replace})
      assert navigated_to(view) == Magpie.RecordScreen
    end
  end

  test "Play plays the bank's pattern; again stops" do
    view = mount() |> render_info({:tap, :play})
    assert %{playing: true, pattern: %{length: 16}} = Fake.state()
    assert assigns(view).playing
    view = render_info(view, {:tap, :play})
    refute Fake.state().playing
    refute assigns(view).playing
  end

  test "note_label/1 names notes with C4 = 60" do
    assert PadsScreen.note_label(38) == "D2 · 38"
    assert PadsScreen.note_label(60) == "C4 · 60"
    assert PadsScreen.note_label(nil) == "—"
  end
end
