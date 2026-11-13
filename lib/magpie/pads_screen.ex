defmodule Magpie.PadsScreen do
  @moduledoc """
  The pads, the app's home (`design/boards/Pads.dc.html`, HANDOFF §3):
  landscape (locked on mount), a top bar and one bank's 16 pads, 8 × 2, in
  the instrument area (28 pt side gutters, 8 pt gaps). Long-press a pad for
  its settings sheet (`design/boards/PadSheet.dc.html`).

  ## Playing

  Every pad cell has its own `on_touch` (MOB-518), so each finger plays its
  own pad and a finger that slides onto another pad doesn't play it. On
  `:down` the screen calls `Magpie.Engine.trigger/3` straight away (the
  velocity from where the pad was hit, `Magpie.Style.velocity/2`, or the
  pad's fixed one; Snap on quantizes loop and toggle launches to 1/16 while
  the sequencer plays) and only then updates its state, so the press paints
  in the same render. `:up` / `:cancel` release gate, loop and keys pads once
  the pad's last finger lifts; one-shot and toggle pads ignore the lift.

  The engine's `{:magpie_audio, :voice, pad, :start | :end}` says what is
  sounding: a sounding pad stays lit after the finger lifts, a sounding loop
  or toggle pad shows the loop tint and a progress bar along its bottom
  (estimated from when its voice started and the region's length; a tokened
  50 ms frame timer runs only while one loops).

  ## Pad looks (HANDOFF §3, `Magpie.Style.pad_fill/2`)

  - empty: a 2 pt `line` outline, "+ record or load"; a tap opens
    `Magpie.RecordScreen` for that pad, the sample landing on it through
    `Magpie.KitSession`.
  - loaded: the colour at 26 % over `raised`; name, mode, a 12-bar wave of
    the region's peaks.
  - pressed: the colour at 100 %, ink text and wave, 2 pt lower, a line
    where the finger landed, a ring at the finger, the velocity badge
    (`v103`). Still sounding after the lift: lit, the line and badge stay.
  - looping: 55 % plus the progress bar, "loop · playing".

  ## Long press

  600 ms (`Magpie.Style.pad().long_press_ms`) timed here from the `:down`
  (`{:long_press, pointer_id, token}`, the token per finger, so a timer from
  a finger already lifted does nothing). A lift, a cancel or the finger
  leaving the pad cancels it. Loaded pads always ask for moves: Mob reads a
  node's move rule when the finger lands, so turning moves on once a long
  press is pending would never apply to that finger. The first long press
  to fire opens the sheet and cancels every other one pending; none opens
  while the sheet is up. Every change in the sheet goes through
  `Magpie.KitSession`.

  ## Not designed / not built yet (inert, shown as the board has them)

  The menu (the magpie button), the kit name (kit save / load sheet), the
  tempo, Record pattern and Seq in the top bar, and the sheet's "Edit
  sample" (no editor yet). Play plays the selected bank's pattern
  (`Magpie.KitSession.pattern/2`); while it plays the button shows a stop
  square (the board has only the play state).

  Every tap target also declares `on_press_out={held()}` (MOB-509): this
  screen re-renders on every touch, voice and frame tick.
  """

  use Mob.Screen

  import Mob.Canvas, only: [path: 2, rect: 5]

  alias Magpie.{Engine, Kit, KitSession, Style}
  alias Magpie.Kit.{Pad, Region}

  @banks Style.pad().banks
  @long_press_ms Style.pad().long_press_ms
  @press_offset Style.pad().press_offset
  @radius Style.pad().radius
  @gutter Style.edge_gutter()
  @gap Style.pad().gap
  @tick_ms 50
  # Snap 1/16: a 16th at 96 PPQN.
  @snap_ticks 24
  # A pitch / MIDI note field moves one step per 6 pt of drag (the family's
  # encoder, `Style.knob().encoder_pt_per_click`).
  @pt_per_step Style.knob().encoder_pt_per_click
  @modes [one_shot: "One-shot", gate: "Gate", loop: "Loop", toggle: "Toggle", keys: "Keys"]
  @chokes [{0, "None"}, {1, "Grp 1"}, {2, "Grp 2"}, {3, "Grp 3"}]
  @notes ~w(C C# D D# E F F# G G# A A# B)
  # The board's Clear outline (the bird's outline colour).
  @clear_line 0xFF4A4560

  @record_screen Magpie.RecordScreen

  # ── Mount ───────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    snapshot = KitSession.subscribe()
    :ok = Engine.subscribe()
    if device_calls?(), do: Mob.Device.lock_orientation(:landscape)
    state = Engine.state()

    socket =
      Mob.Socket.assign(socket,
        bank: "A",
        snapshot: snapshot,
        trig: trig(snapshot.kit),
        fingers: %{},
        voices: %{},
        last_hit: %{},
        sheet: nil,
        drag: nil,
        playing: state.playing,
        audio: is_map(state.stream),
        now: now(),
        tick: nil
      )

    {:ok, socket}
  end

  defp device_calls?, do: Application.get_env(:magpie, :device_calls, true)

  defp held, do: {self(), :held}

  # ── Touch ───────────────────────────────────────────────────────────────

  # The hot path: the trigger before anything else. Fingers landing together
  # arrive as one message each; every `:down` already waiting is triggered
  # here too, so the second finger doesn't wait for the first one's render.
  @impl true
  def handle_info({:touch, {:pad, index}, %{phase: :down} = t}, socket),
    do: {:noreply, socket |> press(index, t) |> press_waiting()}

  def handle_info({:touch, {:pad, _index}, %{phase: :move, pointer_id: id} = t}, socket) do
    # Moves matter only while the finger's long press is pending.
    case socket.assigns.fingers do
      %{^id => %{token: token} = f} when token != nil ->
        if inside?(t),
          do: {:noreply, socket},
          else: {:noreply, put_finger(socket, id, %{f | token: nil})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:touch, {:pad, index}, %{phase: phase} = t}, socket)
      when phase in [:up, :cancel] do
    {finger, fingers} = Map.pop(socket.assigns.fingers, t.pointer_id)
    socket = Mob.Socket.assign(socket, :fingers, fingers)

    cond do
      finger == nil ->
        {:noreply, socket}

      finger.vel != nil ->
        release(finger, index, fingers)
        {:noreply, socket}

      phase == :up and inside?(t) ->
        {:noreply, record(socket, index)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:long_press, pointer_id, token}, socket) do
    a = socket.assigns

    case a.fingers do
      %{^pointer_id => %{token: ^token, pad: index}}
      when token != nil and a.sheet == nil ->
        # One sheet: every other long press pending is off too.
        fingers = Map.new(a.fingers, fn {id, f} -> {id, %{f | token: nil}} end)
        socket = Mob.Socket.assign(socket, fingers: fingers, drag: nil)

        if pad_at(a, index),
          do: {:noreply, Mob.Socket.assign(socket, :sheet, index)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # The sheet's pitch and MIDI note fields: drag up for more.
  def handle_info({:touch, {:field, field}, %{phase: :down} = t}, socket) do
    case sheet_pad(socket.assigns) do
      %Pad{} = pad ->
        {:noreply,
         Mob.Socket.assign(socket, :drag, {t.pointer_id, field, t.y, field_value(pad, field)})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:touch, {:field, field}, %{phase: :move} = t}, socket) do
    case socket.assigns.drag do
      {pointer, ^field, y0, v0} when pointer == t.pointer_id ->
        value = clamp_field(field, v0 + round((y0 - t.y) / @pt_per_step))

        if value != field_value(sheet_pad(socket.assigns), field),
          do: edit(socket, &put_field(&1, field, value))

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:touch, {:field, _field}, %{phase: phase}}, socket)
      when phase in [:up, :cancel],
      do: {:noreply, Mob.Socket.assign(socket, :drag, nil)}

  # ── The engine and the kit ──────────────────────────────────────────────

  def handle_info({:magpie_audio, :voice, pad, :start}, socket) do
    socket = Mob.Socket.update(socket, :voices, &Map.put(&1, pad, now()))
    {:noreply, socket |> Mob.Socket.assign(:now, now()) |> ensure_tick()}
  end

  def handle_info({:magpie_audio, :voice, pad, :end}, socket),
    do: {:noreply, Mob.Socket.update(socket, :voices, &Map.delete(&1, pad))}

  def handle_info({:magpie_audio, _kind, _a, _b}, socket), do: {:noreply, socket}

  def handle_info({:magpie_kit, snapshot}, socket) do
    socket = Mob.Socket.assign(socket, snapshot: snapshot, trig: trig(snapshot.kit))
    # The sheet's pad was cleared (here or elsewhere): close it.
    socket =
      if sheet_pad(socket.assigns), do: socket, else: Mob.Socket.assign(socket, :sheet, nil)

    {:noreply, socket}
  end

  def handle_info({:tick, token}, %{assigns: %{tick: token}} = socket) when token != nil do
    socket = Mob.Socket.assign(socket, tick: nil, now: now())
    {:noreply, ensure_tick(socket)}
  end

  def handle_info({:tick, _stale}, socket), do: {:noreply, socket}

  # ── Taps ────────────────────────────────────────────────────────────────

  def handle_info({:tap, {:bank, bank}}, socket) when bank in @banks do
    if socket.assigns.playing,
      do: Engine.set_pattern(KitSession.pattern(kit(socket.assigns), bank), at: :bar)

    {:noreply, Mob.Socket.assign(socket, :bank, bank)}
  end

  def handle_info({:tap, :play}, %{assigns: %{playing: true}} = socket) do
    _ = Engine.stop()
    {:noreply, Mob.Socket.assign(socket, :playing, false)}
  end

  def handle_info({:tap, :play}, socket) do
    a = socket.assigns

    with :ok <- Engine.set_pattern(KitSession.pattern(kit(a), a.bank), at: :now),
         :ok <- Engine.play() do
      {:noreply, Mob.Socket.assign(socket, :playing, true)}
    else
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info({:tap, :snap}, socket) do
    :ok = KitSession.set_snap(not kit(socket.assigns).snap)
    {:noreply, socket}
  end

  def handle_info({:tap, :sheet_done}, socket),
    do: {:noreply, Mob.Socket.assign(socket, sheet: nil, drag: nil)}

  def handle_info({:tap, {:color, color}}, socket),
    do: {:noreply, edit(socket, &%{&1 | color: color})}

  def handle_info({:tap, {:mode, mode}}, socket),
    do: {:noreply, edit(socket, &%{&1 | mode: mode})}

  def handle_info({:tap, {:choke, group}}, socket),
    do: {:noreply, edit(socket, &%{&1 | choke: group})}

  def handle_info({:tap, {:velocity, mode}}, socket),
    do: {:noreply, edit(socket, &%{&1 | velocity: mode})}

  def handle_info({:tap, :clear}, %{assigns: %{sheet: index}} = socket) when index != nil do
    :ok = KitSession.clear_pad(index)
    {:noreply, Mob.Socket.assign(socket, sheet: nil, drag: nil)}
  end

  def handle_info({:tap, :replace}, %{assigns: %{sheet: index}} = socket) when index != nil,
    do: {:noreply, socket |> Mob.Socket.assign(sheet: nil, drag: nil) |> record(index)}

  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── State ───────────────────────────────────────────────────────────────

  # Per pad index with a sample: {velocity, quantize, release?}, so the
  # trigger path is one map lookup.
  defp trig(%Kit{} = kit) do
    for {bank, pads} <- kit.banks, {slot, %Pad{sample: %Region{}} = pad} <- pads, into: %{} do
      velocity = if pad.velocity == :fixed, do: pad.fixed_velocity, else: :position
      quantize = if kit.snap and pad.mode in [:loop, :toggle], do: @snap_ticks, else: 0
      {Kit.pad_index(bank, slot), {velocity, quantize, pad.mode in [:gate, :loop, :keys]}}
    end
  end

  defp press(socket, index, t) do
    {vel, release} =
      case socket.assigns.trig do
        %{^index => {velocity, quantize, release}} ->
          vel = if velocity == :position, do: Style.velocity(t.y, t.height), else: velocity
          _ = Engine.trigger(index, vel, quantize: quantize)
          {vel, release}

        _empty ->
          {nil, false}
      end

    finger_down(socket, index, t, vel, release)
  end

  # Pad touches already queued, kit changes and long-press timers among
  # them, in their order: downs trigger, the rest are handled as usual; one
  # render follows.
  defp press_waiting(socket) do
    receive do
      {:touch, {:pad, index}, %{phase: :down} = t} ->
        socket |> press(index, t) |> press_waiting()

      {:touch, {:pad, _index}, _t} = touch ->
        {:noreply, socket} = handle_info(touch, socket)
        press_waiting(socket)

      {:magpie_kit, _snapshot} = change ->
        {:noreply, socket} = handle_info(change, socket)
        press_waiting(socket)

      {:long_press, _pointer_id, _token} = timer ->
        {:noreply, socket} = handle_info(timer, socket)
        press_waiting(socket)
    after
      0 -> socket
    end
  end

  # `release`: the pad's mode at the press wants a release on the lift
  # (gate, loop, keys), whatever it has been changed to since.
  defp finger_down(socket, index, t, vel, release) do
    token = if vel, do: make_ref()
    if token, do: Process.send_after(self(), {:long_press, t.pointer_id, token}, @long_press_ms)

    finger = %{pad: index, x: t.x, y: t.y, vel: vel, release: release, token: token}
    socket = put_finger(socket, t.pointer_id, finger)

    if vel,
      do: Mob.Socket.update(socket, :last_hit, &Map.put(&1, index, {t.x, t.y, vel})),
      else: socket
  end

  defp put_finger(socket, pointer_id, finger),
    do: Mob.Socket.update(socket, :fingers, &Map.put(&1, pointer_id, finger))

  # Gate, loop and keys pads stop when the last finger on them lifts.
  defp release(%{release: true}, index, fingers_left) do
    if not Enum.any?(fingers_left, fn {_, f} -> f.pad == index end), do: Engine.release(index)
  end

  defp release(_finger, _index, _fingers_left), do: :ok

  defp inside?(%{x: x, y: y, width: w, height: h}), do: x >= 0 and x <= w and y >= 0 and y <= h

  defp record(socket, index) do
    Mob.Socket.push_screen(socket, @record_screen, %{pad: index, reply_to: KitSession.whereis()})
  end

  defp edit(%{assigns: %{sheet: index}} = socket, fun) when index != nil do
    _ = KitSession.update_pad(index, fn pad -> pad && fun.(pad) end)
    socket
  end

  defp edit(socket, _fun), do: socket

  defp kit(assigns), do: assigns.snapshot.kit

  defp pad_at(assigns, index) do
    {bank, slot} = Kit.bank_slot(index)
    get_in(kit(assigns).banks, [bank, slot])
  end

  defp sheet_pad(%{sheet: nil}), do: nil
  defp sheet_pad(assigns), do: pad_at(assigns, assigns.sheet)

  defp now, do: System.monotonic_time(:millisecond)

  # The frame timer runs while a loop or toggle pad sounds.
  defp ensure_tick(%{assigns: %{tick: nil} = a} = socket) do
    if Enum.any?(a.voices, fn {index, _} -> looping_mode?(a, index) end) do
      token = make_ref()
      Process.send_after(self(), {:tick, token}, @tick_ms)
      Mob.Socket.assign(socket, :tick, token)
    else
      socket
    end
  end

  defp ensure_tick(socket), do: socket

  defp looping_mode?(assigns, index),
    do: match?(%Pad{mode: m} when m in [:loop, :toggle], pad_at(assigns, index))

  defp field_value(%Pad{sample: %Region{pitch_st: st}}, :pitch), do: round(st)
  defp field_value(%Pad{midi_note: note}, :note), do: note || 60
  defp field_value(_pad, _field), do: 0

  defp clamp_field(:pitch, v), do: v |> max(-24) |> min(24)
  defp clamp_field(:note, v), do: v |> max(0) |> min(127)

  defp put_field(%Pad{sample: %Region{} = r} = pad, :pitch, v),
    do: %{pad | sample: %{r | pitch_st: v}}

  defp put_field(%Pad{} = pad, :note, v), do: %{pad | midi_note: v}

  # ── Render ──────────────────────────────────────────────────────────────
  #
  # Module attributes can't appear inside `~MOB` expressions (`@x` there
  # means `assigns.x`), so the helpers bind them to locals first.

  @impl true
  def render(assigns) do
    gutter = @gutter
    gap = @gap
    bank = assigns.bank
    rows = for row <- [0, 1], do: for(col <- 0..7, do: Kit.pad_index(bank, row * 8 + col))

    ~MOB"""
    <Box background={Style.color(:bg)} fill_width={true} fill_height={true}>
      <Column
        fill_width={true}
        fill_height={true}
        padding_left={gutter}
        padding_right={gutter}
        padding_top={8}
        padding_bottom={12}
        gap={gap}
      >
        {top_bar(assigns)}
        <Column weight={1} fill_width={true} gap={gap}>
          <Row :for={indexes <- rows} weight={1} fill_width={true} gap={gap}>
            {Enum.map(indexes, &pad_cell(assigns, &1))}
          </Row>
        </Column>
      </Column>
      {sheet(assigns, sheet_pad(assigns))}
    </Box>
    """
  end

  # ── Top bar ─────────────────────────────────────────────────────────────

  defp top_bar(assigns) do
    kit = kit(assigns)
    snap_tap = {self(), :snap}
    play_tap = {self(), :play}
    snap_bg = Style.color(if kit.snap, do: :selected, else: :surface)
    snap_fg = Style.color(if kit.snap, do: :fm, else: :muted)
    tabs = for bank <- @banks, do: bank_tab(bank, bank == assigns.bank)

    ~MOB"""
    <Row height={44} fill_width={true} gap={8}>
      <Box width={44} height={44} corner_radius={22} background={Style.color(:raised)} align="center">
        <Canvas id="menu_bird" width={32} height={28} draw={bird_ops(bird_mood(assigns))} />
      </Box>
      <Row
        fill_width={false}
        background={Style.color(:surface)}
        corner_radius={12}
        padding={3}
        gap={3}
      >
        {tabs}
      </Row>
      <Row
        fill_width={false}
        height={44}
        padding_left={12}
        padding_right={12}
        corner_radius={12}
        background={Style.color(:surface)}
        gap={6}
      >
        <Text
          text={kit.name}
          font={:semibold}
          text_size={13}
          text_color={Style.color(:text)}
          max_lines={1}
        />
        <Text text="▾" text_size={13} text_color={Style.color(:muted)} />
      </Row>
      <Spacer />
      <Box
        fill_width={false}
        height={44}
        padding_left={10}
        padding_right={10}
        corner_radius={12}
        background={Style.color(:surface)}
        align="center"
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
      <Box width={48} height={44} corner_radius={12} background={Style.color(:raised)} align="center">
        <Box width={14} height={14} corner_radius={7} background={Style.color(:pad_coral)} />
      </Box>
      <Box
        fill_width={false}
        height={44}
        padding_left={12}
        padding_right={12}
        corner_radius={12}
        background={Style.color(:raised)}
        align="center"
      >
        <Text text="Seq" font={:semibold} text_size={13} text_color={Style.color(:text)} />
      </Box>
    </Row>
    """
  end

  defp bank_tab(bank, selected) do
    tap = {self(), {:bank, bank}}
    bg = if selected, do: Style.color(:selected), else: 0x00000000
    fg = Style.color(if selected, do: :text, else: :muted)

    ~MOB"""
    <Box
      id={"bank_#{bank}"}
      width={40}
      height={38}
      corner_radius={9}
      background={bg}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={bank} font={:mono_bold} text_size={13} text_color={fg} />
    </Box>
    """
  end

  defp play_icon(false),
    do: [path([{5, 3}, {14, 8}, {5, 13}], color: Style.color(:ink), fill: true)]

  defp play_icon(true), do: [rect(3, 3, 10, 10, color: Style.color(:ink), fill: true, radius: 1)]

  defp format_tempo(t) when is_float(t) and t == trunc(t), do: trunc(t)
  defp format_tempo(t), do: t

  # The magpie's mood on the menu button (creature.md: transport state):
  # playing while the sequencer runs, asleep with no audio output.
  defp bird_mood(%{audio: false}), do: :sleep
  defp bird_mood(%{playing: true}), do: :play
  defp bird_mood(_assigns), do: :idle

  # Slot for Magpie.Bird (branch `record`): its ops at size 0.5.
  defp bird_ops(_mood), do: []

  # ── Pads ────────────────────────────────────────────────────────────────

  defp pad_cell(assigns, index) do
    # Moves for every loaded pad, from before the finger lands (see Long
    # press in the moduledoc); an empty pad's lift checks where it is.
    touch =
      if Map.has_key?(assigns.trig, index),
        do: {self(), {:pad, index}, moves: true, throttle: 32, delta: 4},
        else: {self(), {:pad, index}}

    face = assigns |> look(index) |> pad_face()

    ~MOB"""
    <Box id={"pad_#{index}"} weight={1} fill_height={true} on_touch={touch}>
      {face}
    </Box>
    """
  end

  # What a pad shows, from the kit, the fingers on it and the engine.
  defp look(assigns, index) do
    pad = pad_at(assigns, index)
    info = Map.get(assigns.snapshot.pads, index)

    if pad == nil or info == nil,
      do: %{state: :empty, selected: assigns.sheet == index},
      else: loaded_look(assigns, index, pad, info)
  end

  defp loaded_look(assigns, index, pad, info) do
    base = &base(pad, info, &1, assigns.sheet == index)
    finger = assigns.fingers |> Map.values() |> Enum.filter(&(&1.pad == index)) |> List.last()

    case {finger, Map.get(assigns.voices, index)} do
      {%{vel: vel} = f, _} when vel != nil ->
        %{base.(:playing) | marks: {f.x, f.y, vel, true}, dy: @press_offset}

      {_, nil} ->
        base.(:idle)

      {_, started} when pad.mode in [:loop, :toggle] ->
        %{
          base.(:loop)
          | progress: progress(assigns.now - started, info.seconds),
            mode: mode_label(pad, info) <> " · playing"
        }

      {_, _started} ->
        marks = with {x, y, vel} <- Map.get(assigns.last_hit, index), do: {x, y, vel, false}
        %{base.(:playing) | marks: marks}
    end
  end

  defp base(pad, info, state, selected) do
    color = pad.color || :cream
    ink = state == :playing

    %{
      state: state,
      selected: selected,
      fill: Style.pad_fill(color, state),
      fg: Style.color(if ink, do: :ink, else: :text),
      sub: Style.color(if ink, do: :ink, else: :text_2),
      wave_color: if(ink, do: Style.color(:ink), else: Style.pad_color(color)),
      name: pad.name || "",
      mode: mode_label(pad, info),
      wave: info.wave,
      marks: nil,
      progress: nil,
      dy: 0
    }
  end

  defp progress(_elapsed, seconds) when not is_number(seconds) or seconds <= 0, do: 0.0

  defp progress(elapsed, seconds) do
    ms = max(round(seconds * 1000), 1)
    rem(max(elapsed, 0), ms) / ms
  end

  defp mode_label(_pad, %{status: :loading}), do: "loading…"
  defp mode_label(_pad, %{status: {:error, :not_in_library}}), do: "sample missing"
  defp mode_label(_pad, %{status: {:error, _}}), do: "can't load"

  defp mode_label(%Pad{mode: mode, choke: choke}, _info) do
    label = mode |> Atom.to_string() |> String.replace("_", "-")

    cond do
      choke == 0 -> label
      mode == :one_shot -> "choke #{choke}"
      true -> "#{label} · choke #{choke}"
    end
  end

  defp pad_face(%{state: :empty} = look) do
    radius = @radius
    outline = if look.selected, do: 3, else: Style.pad().empty_outline
    line = Style.color(if look.selected, do: :text, else: :line)
    muted = Style.color(:muted)

    ~MOB"""
    <Box
      fill_width={true}
      fill_height={true}
      corner_radius={radius}
      border_width={outline}
      border_color={line}
      align="center"
    >
      <Column fill_width={true}>
        <Text text="+" text_size={26} text_color={muted} text_align="center" fill_width={true} />
        <Text
          text="record"
          font={:semibold}
          text_size={12}
          text_color={muted}
          text_align="center"
          fill_width={true}
        />
        <Text
          text="or load"
          font={:semibold}
          text_size={12}
          text_color={muted}
          text_align="center"
          fill_width={true}
        />
      </Column>
    </Box>
    """
  end

  defp pad_face(look) do
    radius = @radius
    ring_width = if look.selected, do: 3, else: 1
    bars = Enum.map(look.wave, &wave_bar(&1, look.wave_color))

    ~MOB"""
    <Box
      fill_width={true}
      fill_height={true}
      offset_y={look.dy}
      corner_radius={radius}
      background={look.fill}
      border_width={ring_width}
      border_color={pad_ring(look)}
    >
      <Column fill_width={true} fill_height={true} padding={9}>
        <Text text={look.name} font={:bold} text_size={12} text_color={look.fg} max_lines={2} />
        <Spacer />
        <Row fill_width={true} height={26} gap={2}>
          {bars}
        </Row>
        <Spacer size={9} />
        <Text
          text={look.mode}
          font={:mono_semibold}
          text_size={10}
          text_color={look.sub}
          max_lines={1}
        />
      </Column>
      {marks(look.marks)}
      {loop_bar(look.progress)}
    </Box>
    """
  end

  defp pad_ring(%{selected: true}), do: Style.color(:text)
  defp pad_ring(%{state: :playing, fill: fill}), do: fill
  defp pad_ring(_look), do: Style.color(:line_soft)

  # The board's bars: 4 + 22 × level pt.
  defp wave_bar(peak, color) do
    height = 4 + round(22 * peak / 255)
    ~MOB(<Box weight={1} height={height} corner_radius={1} background={color} />)
  end

  defp marks(nil), do: []

  defp marks({x, y, vel, ring}) do
    ink = Style.color(:ink)
    line = Style.alpha(ink, 0.6)
    ring = if ring, do: finger_ring(x, y, ink), else: []

    ~MOB"""
    <Box fill_width={true} fill_height={true}>
      <Box fill_width={true} height={2} offset_y={max(y - 1, 0)} background={line} />
      {ring}
      <Row fill_width={true} offset_y={max(6, y - 22)}>
        <Spacer />
        <Box
          fill_width={false}
          corner_radius={5}
          padding_left={5}
          padding_right={5}
          padding_top={2}
          padding_bottom={2}
          background={ink}
        >
          <Text text={"v#{vel}"} font={:mono_bold} text_size={10} text_color={Style.color(:text)} />
        </Box>
        <Spacer size={7} />
      </Row>
    </Box>
    """
  end

  defp finger_ring(x, y, ink) do
    ring = Style.alpha(ink, 0.45)

    ~MOB"""
    <Box
      width={32}
      height={32}
      corner_radius={16}
      border_width={2}
      border_color={ring}
      offset_x={x - 16}
      offset_y={y - 16}
    />
    """
  end

  defp loop_bar(nil), do: []

  defp loop_bar(p) do
    bar = Style.alpha(Style.color(:ink), 0.55)

    ~MOB"""
    <Column fill_width={true} fill_height={true}>
      <Spacer />
      <Row fill_width={true} height={4}>
        <Box weight={max(p, 0.001)} height={4} background={bar} />
        <Box weight={max(1 - p, 0.001)} height={4} />
      </Row>
    </Column>
    """
  end

  # ── Pad settings sheet ──────────────────────────────────────────────────

  defp sheet(_assigns, nil), do: []

  defp sheet(assigns, %Pad{} = pad) do
    {bank, slot} = Kit.bank_slot(assigns.sheet)
    color = pad.color || :cream
    surface = Style.color(:surface)
    scrim = Style.alpha(Style.color(:bg_deep), 0.6)
    gutter = @gutter
    clear_line = @clear_line
    done = {self(), :sheet_done}
    replace = {self(), :replace}
    clear = {self(), :clear}
    swatches = for c <- Style.pad_palette(), do: swatch(c, c == color)

    rows = [
      segmented(
        "Play",
        for({mode, label} <- @modes, do: {label, {:mode, mode}, pad.mode == mode})
      ),
      segmented(
        "Cuts off",
        for({group, label} <- @chokes, do: {label, {:choke, group}, pad.choke == group})
      ),
      segmented("Velocity", [
        {"Where you hit", {:velocity, :position}, pad.velocity == :position},
        {"Fixed #{pad.fixed_velocity}", {:velocity, :fixed}, pad.velocity == :fixed}
      ])
    ]

    fields = [
      field(:pitch, "Pitch", pitch_label(pad)),
      field(:note, "MIDI note", note_label(pad.midi_note))
    ]

    ~MOB"""
    <Row fill_width={true} fill_height={true}>
      <Box
        weight={1}
        fill_height={true}
        background={scrim}
        padding_left={gutter}
        padding_top={22}
        on_tap={done}
        on_press_out={held()}
      >
        <Text
          text="Long-press a pad for its settings"
          text_size={12}
          text_color={Style.color(:muted)}
        />
      </Box>
      <Box width={412} fill_height={true} background={scrim}>
        <Box width={24} fill_height={true} offset_x={388} background={surface} />
        <Column
          fill_width={true}
          fill_height={true}
          corner_radius={24}
          background={surface}
          padding_top={14}
          padding_bottom={14}
          padding_left={20}
          padding_right={gutter}
          gap={10}
        >
          <Row fill_width={true} gap={10}>
            <Box width={22} height={22} corner_radius={6} background={Style.pad_color(color)} />
            <Row weight={1} gap={6}>
              <Text
                text={pad.name || ""}
                font={:bold}
                text_size={16}
                text_color={Style.color(:text)}
                max_lines={1}
              />
              <Text
                text={"· pad #{bank}#{slot + 1}"}
                font={:mono}
                text_size={11}
                text_color={Style.color(:muted)}
              />
            </Row>
            <Box
              id="sheet_done"
              fill_width={false}
              height={36}
              padding_left={14}
              padding_right={14}
              corner_radius={18}
              background={Style.color(:fm)}
              align="center"
              on_tap={done}
              on_press_out={held()}
            >
              <Text text="Done" font={:bold} text_size={13} text_color={Style.color(:ink)} />
            </Box>
          </Row>
          <Row fill_width={true} gap={6}>
            {swatches}
          </Row>
          {rows}
          <Row fill_width={true} gap={8}>
            {fields}
          </Row>
          <Spacer />
          <Row fill_width={true} gap={8}>
            <Box
              weight={1}
              height={44}
              corner_radius={12}
              background={Style.color(:raised_hi)}
              align="center"
            >
              <Text
                text="Edit sample"
                font={:semibold}
                text_size={13}
                text_color={Style.color(:text)}
              />
            </Box>
            <Box
              id="sheet_replace"
              weight={1}
              height={44}
              corner_radius={12}
              background={Style.color(:raised_hi)}
              align="center"
              on_tap={replace}
              on_press_out={held()}
            >
              <Text text="Replace" font={:semibold} text_size={13} text_color={Style.color(:text)} />
            </Box>
            <Box
              id="sheet_clear"
              fill_width={false}
              height={44}
              padding_left={14}
              padding_right={14}
              corner_radius={12}
              border_width={1}
              border_color={clear_line}
              align="center"
              on_tap={clear}
              on_press_out={held()}
            >
              <Text
                text="Clear"
                font={:semibold}
                text_size={13}
                text_color={Style.color(:danger_text)}
              />
            </Box>
          </Row>
        </Column>
      </Box>
    </Row>
    """
  end

  defp swatch(color, selected) do
    tap = {self(), {:color, color}}
    border = if selected, do: 2, else: 0

    ~MOB"""
    <Box
      id={"swatch_#{color}"}
      width={36}
      height={30}
      corner_radius={8}
      background={Style.pad_color(color)}
      border_width={border}
      border_color={Style.color(:text)}
      on_tap={tap}
      on_press_out={held()}
    />
    """
  end

  # Five options don't fit "One-shot" at the board's 12 pt in 412 pt: 11.
  defp segmented(label, options) do
    size = if Enum.count_until(options, 5) == 5, do: 11, else: 12
    segments = for {text, tag, on} <- options, do: segment(text, tag, on, size)

    ~MOB"""
    <Row fill_width={true} gap={10}>
      <Text text={label} width={70} font={:semibold} text_size={13} text_color={Style.color(:text)} />
      <Row weight={1} background={Style.color(:bg)} corner_radius={12} padding={3} gap={3}>
        {segments}
      </Row>
    </Row>
    """
  end

  defp segment(text, tag, on, size) do
    tap = {self(), tag}
    bg = if on, do: Style.color(:selected), else: 0x00000000
    fg = Style.color(if on, do: :text, else: :muted)

    ~MOB"""
    <Box
      weight={1}
      height={34}
      corner_radius={9}
      background={bg}
      align="center"
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={text} font={:semibold} text_size={size} text_color={fg} max_lines={1} />
    </Box>
    """
  end

  defp field(field, label, value) do
    touch = {self(), {:field, field}, moves: true, throttle: 16, delta: 2}

    ~MOB"""
    <Row
      id={"field_#{field}"}
      weight={1}
      height={40}
      corner_radius={12}
      background={Style.color(:bg)}
      padding_left={12}
      padding_right={12}
      on_touch={touch}
    >
      <Text text={label} text_size={12} text_color={Style.color(:muted)} />
      <Spacer />
      <Text text={value} font={:mono} text_size={12} text_color={Style.color(:text)} />
    </Row>
    """
  end

  defp pitch_label(%Pad{sample: %Region{pitch_st: st}}) do
    st = round(st)
    if st < 0, do: "#{st} st", else: "+#{st} st"
  end

  defp pitch_label(_pad), do: "+0 st"

  @doc false
  # "D2 · 38" (60 = C4), "—" without a note.
  def note_label(nil), do: "—"
  def note_label(n), do: "#{Enum.at(@notes, rem(n, 12))}#{div(n, 12) - 1} · #{n}"
end
