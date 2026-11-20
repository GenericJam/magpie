defmodule Magpie.SeqScreen do
  @moduledoc """
  The step sequencer (`design/boards/Seq.dc.html`, landscape, HANDOFF §4).

  Top bar: back to `Magpie.PadsScreen` ("‹ Pads"), pattern tabs for the bank
  (`A1..A4`, plus `+` while fewer than 4), pattern length (`16 steps` /
  `32 steps`), swing (`swing 50%..75%`, vertical drag 6 pt/step), tempo
  (`40..240 bpm`, vertical drag 6 pt/step), `Snap 1/16`, Play/Stop, and the
  live-record button (`id: "record_pattern"`): it arms
  `Magpie.KitSession.set_recording/1` (pads and MIDI notes played meanwhile
  write steps into the bank's selected pattern while it plays), starting the
  selected pattern first when stopped, as Play does; pressed again it
  disarms, and the session disarms when the sequencer stops. Armed it shows
  the snapshot's `recording` in the Record board's recording look (a
  `danger` button, ink dot): the Seq board has only the idle button.

  Grid: one 48 pt lane per loaded pad in the current bank, inside a vertical
  `<Scroll>`. Each lane has a 92 pt label (pad colour chip + name; tap to
  audition via `Magpie.Engine.trigger/3`) and 16 or 32 weighted step cells.
  Alternate 4-step groups use `raised` / `surface`. Active steps fill from the
  bottom in the pad's colour to `max(25%, vel / 127)` of the cell height.
  Tapping a step cell toggles it on (velocity 100) or off; dragging up or down
  adjusts its velocity (`1..127`) live through `Magpie.KitSession`.

  The playhead bar above the grid follows the engine's `{:magpie_audio,
  :playhead, step, frame}` messages while the selected pattern is the one
  playing (`Engine.state/0`'s `pattern`; a queued one moves it when it takes
  over). The board also rings the playing column; not drawn: Mob paints the
  whole tree on every change, and a ring would change a column of cells per
  lane on every step. Play/Stop follows
  the engine's `{:magpie_audio, :transport, :started | :stopped, nil}`, so a
  start or stop from another screen shows here. Drags end after 1 s
  of silence (`{:drag_timeout, token}`, MOB-511). Every tap target declares
  `on_press_out={held()}` (MOB-509).
  """

  use Mob.Screen

  import Mob.Canvas, only: [path: 2, rect: 5]

  alias Magpie.{Engine, Kit, KitSession, Style}
  alias Magpie.Kit.{Pad, Pattern, Region}

  @banks Style.pad().banks
  @lane_h Style.sequencer().lane_min_height
  @label_w 92
  @min_fill Style.sequencer().min_fill
  @pt_per_step Style.knob().encoder_pt_per_click
  # Velocity drag sensitivity: 2 velocity units per pt (~64 pt full range).
  @vel_per_pt 2
  @drag_slop 4
  @drag_quiet_ms 1_000
  @max_patterns 4

  # ── Mount ───────────────────────────────────────────────────────────────

  @impl true
  def mount(params, _session, socket) do
    if device_calls?(), do: Mob.Device.lock_orientation(:landscape)
    snapshot = KitSession.subscribe()
    :ok = Engine.subscribe()
    state = Engine.state()
    bank = bank_param(params)
    selected = KitSession.pattern(snapshot, bank)
    # The pattern sounding now; a queued one moves the playhead when it
    # takes over (`{:magpie_audio, :pattern, …}`).
    engine_pattern = state.pattern

    step =
      if state.playing and same_pattern?(engine_pattern, selected),
        do: state.step,
        else: nil

    socket =
      Mob.Socket.assign(socket,
        bank: bank,
        snapshot: snapshot,
        playing: state.playing,
        engine_pattern: engine_pattern,
        step: step,
        drag: nil,
        drag_token: nil
      )

    {:ok, socket}
  end

  defp device_calls?, do: Application.get_env(:magpie, :device_calls, true)

  defp bank_param(%{bank: bank}) when bank in @banks, do: bank
  defp bank_param(_params), do: "A"

  defp held, do: {self(), :held}

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    gutter = Style.edge_gutter()
    kit = assigns.snapshot.kit
    selected = KitSession.pattern(assigns.snapshot, assigns.bank)
    lanes = loaded_lanes(kit, assigns.bank)
    active_step = active_step(assigns, selected)

    ~MOB"""
    <Column
      background={Style.color(:bg)}
      fill_width={true}
      fill_height={true}
      padding_left={gutter}
      padding_right={gutter}
      padding_top={8}
      padding_bottom={8}
      gap={6}
    >
      {top_bar(assigns, kit, selected)}
      {body(assigns.bank, lanes, selected, active_step)}
    </Column>
    """
  end

  defp top_bar(assigns, kit, selected) do
    back_tap = {self(), :back}
    length_tap = {self(), :length}
    snap_tap = {self(), :snap}
    play_tap = {self(), :play}
    record_tap = {self(), :record}
    armed = assigns.snapshot.recording
    record_bg = Style.color(if armed, do: :danger, else: :raised)
    record_dot = Style.color(if armed, do: :ink, else: :pad_coral)
    swing_touch = {self(), {:field, :swing}, moves: true, throttle: 16, delta: 2}
    tempo_touch = {self(), {:field, :tempo}, moves: true, throttle: 16, delta: 2}
    snap_bg = Style.color(if kit.snap, do: :selected, else: :surface)
    snap_fg = Style.color(if kit.snap, do: :fm, else: :muted)
    patterns = KitSession.patterns(assigns.snapshot, assigns.bank)
    can_add? = length(patterns) < @max_patterns

    ~MOB"""
    <Row height={44} fill_width={true} gap={8} align={:center}>
      <Box
        id="back"
        fill_width={false}
        height={44}
        padding_left={8}
        padding_right={12}
        corner_radius={12}
        background={Style.color(:raised)}
        align="center"
        on_tap={back_tap}
        on_press_out={held()}
      >
        <Row fill_width={false} gap={4} align={:center}>
          <Canvas width={18} height={18} draw={back_ops()} />
          <Text text="Pads" font={:semibold} text_size={13} text_color={Style.color(:text)} />
        </Row>
      </Box>
      <Row
        id="pattern_tabs"
        fill_width={false}
        height={44}
        background={Style.color(:surface)}
        corner_radius={12}
        padding={3}
        gap={3}
      >
        {for p <- patterns, do: pattern_tab(p.id, p.id == selected.id)}
        {if can_add?, do: add_pattern_tab()}
      </Row>
      <Box
        id="length"
        fill_width={false}
        height={44}
        padding_left={10}
        padding_right={10}
        corner_radius={12}
        background={Style.color(:surface)}
        align="center"
        on_tap={length_tap}
        on_press_out={held()}
      >
        <Text
          text={"#{selected.length} steps"}
          font={:mono_semibold}
          text_size={12}
          text_color={Style.color(:text)}
        />
      </Box>
      <Box
        id="swing"
        fill_width={false}
        height={44}
        padding_left={10}
        padding_right={10}
        corner_radius={12}
        background={Style.color(:surface)}
        align="center"
        on_touch={swing_touch}
      >
        <Text
          text={"swing #{round(kit.swing * 100)}%"}
          font={:mono_semibold}
          text_size={12}
          text_color={Style.color(:text)}
        />
      </Box>
      <Spacer />
      <Box
        id="tempo"
        fill_width={false}
        height={44}
        padding_left={10}
        padding_right={10}
        corner_radius={12}
        background={Style.color(:surface)}
        align="center"
        on_touch={tempo_touch}
      >
        <Text
          text={"#{format_tempo(kit.tempo)} bpm"}
          font={:mono_semibold}
          text_size={12}
          text_color={Style.color(:text)}
        />
      </Box>
      <Box
        id="snap"
        fill_width={false}
        height={44}
        padding_left={10}
        padding_right={10}
        corner_radius={12}
        background={snap_bg}
        align="center"
        on_tap={snap_tap}
        on_press_out={held()}
      >
        <Text text="Snap 1/16" font={:mono_semibold} text_size={12} text_color={snap_fg} />
      </Box>
      <Box
        id="play"
        width={48}
        height={44}
        corner_radius={12}
        background={Style.color(:fm)}
        align="center"
        on_tap={play_tap}
        on_press_out={held()}
      >
        <Canvas width={16} height={16} draw={play_icon(assigns.playing)} />
      </Box>
      <Box
        id="record_pattern"
        width={48}
        height={44}
        corner_radius={12}
        background={record_bg}
        align="center"
        on_tap={record_tap}
        on_press_out={held()}
      >
        <Box width={14} height={14} corner_radius={7} background={record_dot} />
      </Box>
    </Row>
    """
  end

  defp pattern_tab(id, selected) do
    tap = {self(), {:pattern, id}}
    bg = if selected, do: Style.color(:selected), else: 0x00000000
    fg = Style.color(if selected, do: :text, else: :muted)

    ~MOB"""
    <Box
      id={"pattern_#{id}"}
      width={44}
      height={38}
      corner_radius={9}
      background={bg}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={id} font={:mono_bold} text_size={12} text_color={fg} />
    </Box>
    """
  end

  defp add_pattern_tab do
    tap = {self(), :add_pattern}

    ~MOB"""
    <Box
      id="pattern_add"
      width={44}
      height={38}
      corner_radius={9}
      background={0x00000000}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text="+" font={:mono_bold} text_size={12} text_color={Style.color(:muted)} />
    </Box>
    """
  end

  defp body(bank, [], _selected, _active_step) do
    ~MOB"""
    <Box weight={1} fill_width={true} align="center">
      <Text
        id="empty_bank"
        text={"No pads loaded in bank #{bank}."}
        text_size={13}
        text_color={Style.color(:muted)}
      />
    </Box>
    """
  end

  # Only the playhead bar follows the playing step: Mob paints the whole tree
  # on every change, and keeping the step cells the same from step to step
  # leaves native one small node to change instead of a column per lane.
  defp body(_bank, lanes, selected, active_step) do
    label_w = @label_w
    gap = if selected.length == 32, do: 2, else: 3

    ~MOB"""
    <Column weight={1} fill_width={true} gap={3}>
      <Row id="playhead_bar" fill_width={true} height={4} gap={gap}>
        <Box width={label_w} height={4} fill_width={false} />
        {for s <- 0..(selected.length - 1), do: playhead_cell(s, s == active_step)}
      </Row>
      <Scroll weight={1} fill_width={true}>
        <Column fill_width={true} gap={4}>
          {for {slot, pad} <- lanes, do: lane_row(slot, pad, selected, gap)}
        </Column>
      </Scroll>
    </Column>
    """
  end

  defp playhead_cell(step, active?) do
    bg = if active?, do: Style.color(:text), else: 0x00000000

    ~MOB"""
    <Box id={"playhead_#{step}"} weight={1} height={4} corner_radius={2} background={bg} />
    """
  end

  defp lane_row(slot, %Pad{} = pad, %Pattern{} = pattern, gap) do
    label_w = @label_w
    lane_h = @lane_h
    audition_tap = {self(), {:audition, slot}}
    chip_color = Style.pad_color(pad.color)
    steps_map = lane_steps_map(pattern, slot)

    ~MOB"""
    <Row id={"lane_row_#{slot}"} fill_width={true} height={lane_h} gap={gap} align={:center}>
      <Box
        id={"lane_#{slot}"}
        width={label_w}
        height={lane_h}
        corner_radius={10}
        background={Style.color(:surface)}
        padding_left={10}
        padding_right={10}
        align="center"
        on_tap={audition_tap}
        on_press_out={held()}
      >
        <Row fill_width={true} gap={8} align={:center}>
          <Box width={10} height={10} corner_radius={3} background={chip_color} fill_width={false} />
          <Text
            text={pad.name}
            font={:bold}
            text_size={11}
            text_color={Style.color(:text)}
            max_lines={1}
          />
        </Row>
      </Box>
      {for step <- 0..(pattern.length - 1),
           do: step_cell(slot, step, Map.get(steps_map, step), chip_color)}
    </Row>
    """
  end

  defp step_cell(slot, step, vel, pad_color) do
    lane_h = @lane_h
    even_group? = rem(div(step, 4), 2) == 0
    bg = Style.color(if even_group?, do: :raised, else: :surface)
    touch = {self(), {:step, slot, step}, moves: true, throttle: 32, delta: 3}

    fill_h =
      if vel,
        do: round(lane_h * max(@min_fill, vel / 127)),
        else: 0

    fill_color = if vel, do: Style.blend(pad_color, bg, 0.85), else: 0x00000000

    ~MOB"""
    <Box
      id={"step_#{slot}_#{step}"}
      weight={1}
      height={lane_h}
      corner_radius={7}
      background={bg}
      align="bottom"
      on_touch={touch}
    >
      <Box
        :if={vel != nil}
        id={"fill_#{slot}_#{step}"}
        fill_width={true}
        height={fill_h}
        corner_radius={5}
        background={fill_color}
      />
    </Box>
    """
  end

  defp back_ops do
    s = 18 / 24
    at = fn {x, y} -> {x * s, y * s} end

    [
      path(Enum.map([{15, 5}, {8, 12}, {15, 19}], at),
        color: Style.color(:text),
        width: 2,
        cap: :round,
        join: :round
      )
    ]
  end

  defp play_icon(false),
    do: [path([{5, 3}, {14, 8}, {5, 13}], color: Style.color(:ink), fill: true)]

  defp play_icon(true),
    do: [rect(3, 3, 10, 10, color: Style.color(:ink), fill: true, radius: 1)]

  defp format_tempo(t) when is_float(t) and t == trunc(t), do: trunc(t)
  defp format_tempo(t), do: t

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info({:tap, :back}, socket),
    do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, {:pattern, id}}, socket) do
    _ = KitSession.select_pattern(socket.assigns.bank, id)
    {:noreply, socket}
  end

  def handle_info({:tap, :add_pattern}, socket) do
    _ = KitSession.add_pattern(socket.assigns.bank)
    {:noreply, socket}
  end

  def handle_info({:tap, :length}, socket) do
    a = socket.assigns
    selected = KitSession.pattern(a.snapshot, a.bank)
    next_len = if selected.length == 16, do: 32, else: 16
    _ = KitSession.set_pattern_length(a.bank, next_len)
    {:noreply, socket}
  end

  def handle_info({:tap, :snap}, socket) do
    kit = socket.assigns.snapshot.kit
    :ok = KitSession.set_snap(not kit.snap)
    {:noreply, socket}
  end

  def handle_info({:tap, :play}, %{assigns: %{playing: true}} = socket) do
    _ = Engine.stop()
    {:noreply, Mob.Socket.assign(socket, playing: false, step: nil)}
  end

  def handle_info({:tap, :play}, socket) do
    selected = KitSession.pattern(socket.assigns.snapshot, socket.assigns.bank)

    case play(selected) do
      :ok -> {:noreply, Mob.Socket.assign(socket, playing: true, engine_pattern: selected)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info({:tap, :record}, %{assigns: %{snapshot: %{recording: true}}} = socket) do
    _ = KitSession.set_recording(false)
    {:noreply, socket}
  end

  def handle_info({:tap, :record}, socket) do
    selected = KitSession.pattern(socket.assigns.snapshot, socket.assigns.bank)

    if Engine.state().playing do
      _ = KitSession.set_recording(true)
      {:noreply, socket}
    else
      with :ok <- play(selected),
           :ok <- KitSession.set_recording(true) do
        {:noreply, Mob.Socket.assign(socket, playing: true, engine_pattern: selected)}
      else
        {:error, _} -> {:noreply, socket}
      end
    end
  end

  def handle_info({:tap, {:audition, slot}}, socket) do
    a = socket.assigns

    case get_in(a.snapshot.kit.banks, [a.bank, slot]) do
      %Pad{} = pad ->
        index = Kit.pad_index(a.bank, slot)
        vel = if pad.velocity == :fixed, do: pad.fixed_velocity, else: Style.fixed_velocity()
        _ = Engine.trigger(index, vel)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # ── Step touch (tap toggles, vertical drag changes velocity) ────────────

  def handle_info({:touch, {:step, slot, step}, %{phase: :down} = t}, socket) do
    vel = current_step_vel(socket.assigns, slot, step)

    drag = %{
      kind: :step,
      pointer_id: t.pointer_id,
      slot: slot,
      step: step,
      y0: t.y,
      v0: vel || Style.fixed_velocity(),
      last_vel: vel,
      moved?: false
    }

    {:noreply, put_drag(socket, drag)}
  end

  def handle_info({:touch, {:step, slot, step}, %{phase: :move} = t}, socket) do
    case socket.assigns.drag do
      %{kind: :step, pointer_id: pointer, slot: ^slot, step: ^step} = drag
      when pointer == t.pointer_id ->
        {:noreply, move_step_drag(socket, drag, t.y)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:touch, {:step, slot, step}, %{phase: :up} = t}, socket) do
    case socket.assigns.drag do
      %{kind: :step, pointer_id: pointer, slot: ^slot, step: ^step, moved?: moved?}
      when pointer == t.pointer_id ->
        if not moved? do
          _ = KitSession.toggle_step(socket.assigns.bank, slot, step, Style.fixed_velocity())
        end

        {:noreply, clear_drag(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:touch, {:step, _slot, _step}, %{phase: :cancel} = t}, socket) do
    case socket.assigns.drag do
      %{kind: :step, pointer_id: pointer} when pointer == t.pointer_id ->
        {:noreply, clear_drag(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Tempo and swing vertical drag (6 pt a step) ─────────────────────────

  def handle_info({:touch, {:field, field}, %{phase: :down} = t}, socket)
      when field in [:tempo, :swing] do
    kit = socket.assigns.snapshot.kit
    v0 = field_value(kit, field)

    drag = %{
      kind: :field,
      field: field,
      pointer_id: t.pointer_id,
      y0: t.y,
      v0: v0,
      last_val: v0
    }

    {:noreply, put_drag(socket, drag)}
  end

  def handle_info({:touch, {:field, field}, %{phase: :move} = t}, socket)
      when field in [:tempo, :swing] do
    case socket.assigns.drag do
      %{kind: :field, field: ^field, pointer_id: pointer} = drag
      when pointer == t.pointer_id ->
        {:noreply, move_field_drag(socket, drag, t.y)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:touch, {:field, field}, %{phase: phase} = t}, socket)
      when field in [:tempo, :swing] and phase in [:up, :cancel] do
    case socket.assigns.drag do
      %{kind: :field, field: ^field, pointer_id: pointer} when pointer == t.pointer_id ->
        {:noreply, clear_drag(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # MOB-511: a drag whose end was lost on Android ends after 1 s quiet.
  def handle_info({:drag_timeout, token}, %{assigns: %{drag_token: token}} = socket)
      when token != nil,
      do: {:noreply, clear_drag(socket)}

  def handle_info({:drag_timeout, _stale}, socket), do: {:noreply, socket}

  # ── Engine and KitSession updates ───────────────────────────────────────

  def handle_info({:magpie_kit, snapshot}, socket) do
    {:noreply, Mob.Socket.assign(socket, :snapshot, snapshot)}
  end

  def handle_info({:magpie_audio, :playhead, step, _frame}, socket) do
    a = socket.assigns
    selected = KitSession.pattern(a.snapshot, a.bank)

    if a.playing and same_pattern?(a.engine_pattern, selected) and a.step != step do
      {:noreply, Mob.Socket.assign(socket, :step, step)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:magpie_audio, :pattern, %Pattern{} = pattern, _frame}, socket) do
    a = socket.assigns
    selected = KitSession.pattern(a.snapshot, a.bank)
    step = if same_pattern?(pattern, selected), do: a.step, else: nil
    {:noreply, Mob.Socket.assign(socket, engine_pattern: pattern, step: step)}
  end

  # Whoever started or stopped the sequencer (this screen, PadsScreen).
  def handle_info({:magpie_audio, :transport, :stopped, _}, socket),
    do: {:noreply, Mob.Socket.assign(socket, playing: false, step: nil)}

  def handle_info({:magpie_audio, :transport, :started, _}, socket),
    do:
      {:noreply, Mob.Socket.assign(socket, playing: true, engine_pattern: Engine.state().pattern)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Helpers ─────────────────────────────────────────────────────────────

  # The selected pattern from its start.
  defp play(%Pattern{} = selected) do
    with :ok <- Engine.set_pattern(selected, at: :now), do: Engine.play()
  end

  defp loaded_lanes(%Kit{banks: banks}, bank) do
    banks
    |> Map.get(bank, %{})
    |> Enum.filter(fn {_slot, pad} -> match?(%Pad{sample: %Region{}}, pad) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp lane_steps_map(%Pattern{lanes: lanes}, slot) do
    case Map.get(lanes, slot) do
      %{steps: steps} -> Map.new(steps, &{&1.step, &1.vel})
      _ -> %{}
    end
  end

  defp current_step_vel(assigns, slot, step) do
    assigns.snapshot
    |> KitSession.pattern(assigns.bank)
    |> lane_steps_map(slot)
    |> Map.get(step)
  end

  defp move_step_drag(socket, drag, y) do
    dy = drag.y0 - y

    if not drag.moved? and abs(dy) < @drag_slop do
      put_drag(socket, drag)
    else
      vel = clamp(drag.v0 + round(dy * @vel_per_pt), 1, 127)

      if vel != drag.last_vel do
        _ = KitSession.set_step_velocity(socket.assigns.bank, drag.slot, drag.step, vel)
      end

      put_drag(socket, %{drag | moved?: true, last_vel: vel})
    end
  end

  defp move_field_drag(socket, drag, y) do
    steps = round((drag.y0 - y) / @pt_per_step)
    val = clamp_field(drag.field, drag.v0 + steps)

    if val != drag.last_val do
      apply_field(drag.field, val)
    end

    put_drag(socket, %{drag | last_val: val})
  end

  defp field_value(%Kit{tempo: tempo}, :tempo), do: round(tempo)
  defp field_value(%Kit{swing: swing}, :swing), do: round(swing * 100)

  defp clamp_field(:tempo, v), do: clamp(v, 40, 240)
  defp clamp_field(:swing, v), do: clamp(v, 50, 75)

  defp apply_field(:tempo, bpm), do: _ = KitSession.set_tempo(bpm)
  defp apply_field(:swing, pct), do: _ = KitSession.set_swing(pct / 100)

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp put_drag(socket, drag) do
    token = make_ref()
    Process.send_after(self(), {:drag_timeout, token}, @drag_quiet_ms)
    Mob.Socket.assign(socket, drag: drag, drag_token: token)
  end

  defp clear_drag(socket), do: Mob.Socket.assign(socket, drag: nil, drag_token: nil)

  defp active_step(%{playing: true, step: step, engine_pattern: engine_pattern}, selected)
       when is_integer(step) do
    if same_pattern?(engine_pattern, selected) and step < selected.length,
      do: step,
      else: nil
  end

  defp active_step(_assigns, _selected), do: nil

  defp same_pattern?(%Pattern{id: id, bank: bank}, %Pattern{id: id, bank: bank}), do: true
  defp same_pattern?(_, _), do: false
end
