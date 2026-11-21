defmodule Magpie.RecordScreen do
  @moduledoc """
  Record a sample (`design/boards/Record.dc.html`, landscape, HANDOFF §5).

  Left: back, the title and the sources (Microphone, FMutate shown
  disabled until pairing exists, Other apps (disabled, "not on this
  phone", where `Magpie.Engine.input_sources/0` lacks it: iOS), Import a
  file). Right: the
  waveform card (one `<Canvas>`: the recording's peaks as 120 bars, the
  playhead, a status chip and the magpie), the IN meter, the start mode
  (Now / When sound starts / Count in 1 bar) and Record / Stop.

  The microphone is asked for on mount; granted, the screen subscribes to
  `Magpie.Engine` and opens the input, which then meters all the time
  (monitoring). Leaving (back, or the process ending) cancels a recording
  and closes the input: the mic is off once the screen is gone (the
  Engine also closes it when this process exits).

  Params: `%{pad: 0..63, reply_to: pid}` records into a pad (the empty-pad
  tap on the pads screen): the title names it ("Record into pad A15") and
  every sample saved here (recorded or imported) is sent to `reply_to` as
  `{:recorded, pad, %Magpie.Library.Sample{}}`. Without them it is "Record
  a sample" into the library only.

  Phases (`phase`):

  - `:monitoring`: "READY" (input open), "OPENING…" (other apps: waiting
    for the consent), "NO INPUT" / "NO MIC" (nothing open). The magpie
    listens while an input is open.
  - `:waiting`: "When sound starts" armed, "WAITING FOR SOUND". The
    threshold is 12 dB over the loudest of the last ~1 s of idle meters,
    clamped to -48..-12 dB (-30 before any meter); the meter shows it as
    a tick.
  - `:counting`: "COUNT-IN 1…4", the beat from the count-in's frames and
    the engine clock (a tokened ~30 ms frame timer runs only here).
  - `:recording`: "● REC 0:03.2", bars growing over a window of
    6 s × 2^k.
  - `:saving`: Stop pressed; the recording goes to the library in a
    `start_async/3` task ("SAVING…").
  - `:saved`: "SAVED 3.2 s", the whole sample's waveform, the magpie
    holding a coral trinket. Also after an import.
  - `:importing`: a picked file is being decoded ("IMPORTING…").

  Undesigned states get a plain fallback: the microphone denied (the
  magpie greyed, "Magpie needs the microphone to record." and Try again),
  and one-line notices under the sources (other apps not shared, stopped
  or not opening, the 60 s limit, an import or save error). Other apps
  lost for any reason go back to the microphone when it is granted.

  The screen keeps the input id `Engine.open_input/1` gave it and the
  take id `Engine.record/1` gave it, and ignores input, meter and
  recording messages about any other (one still queued from before a
  switch or a new take). A failed open leaves no input (the Engine closed
  the old one first). Leaving logs a mic that wouldn't close; the Engine
  keeps closing it.

  Every tap target also has `on_press_out={held()}` (MOB-509): the screen
  re-renders on every meter.
  """

  use Mob.Screen

  require Logger

  import Mob.Canvas

  alias Magpie.{Audio, Bird, Engine, Import, Library, LibraryScreen, Style}

  # Mob canvases have fixed sizes and a screen can't learn its window's
  # width, so the board's 844 × 390 is laid out to fit the narrowest
  # landscape phone tried: the moto g power 2021 leaves about 810 × 385 dp
  # once its cutout, navigation bar and status bar are inset (28 + 236 +
  # 12 + 496 + 28). Wider windows get room to the right.
  @left_w 236
  @card_w 496
  @card_h 264
  @bars 120
  @bar_gap 2
  @meter_w 404
  @meter_h 14
  @segments 30
  @window_s 6
  @peak_frames 256
  @ambient_meters 25
  @max_seconds 60
  @tick_ms 30
  @busy [:waiting, :counting, :recording]

  @file_ink 0xFFE4DFEE

  @sources [
    mic: %{icon: "MIC", ink: :pad_coral, name: "Microphone", sub: "phone mic or headset"},
    fmutate: %{icon: "FM", ink: :fm, name: "FMutate", sub: "pairing comes later"},
    apps: %{icon: "APPS", ink: :info, name: "Other apps", sub: "what this phone is playing"},
    file: %{icon: "FILE", ink: nil, name: "Import a file", sub: "wav, aiff, mp3, flac"},
    stash: %{icon: "LIB", ink: :pad_amber, name: "The stash", sub: "pick a saved sound"}
  ]

  @modes [now: "Now", on_sound: "When sound starts", count_in: "Count in 1 bar"]

  # ── Mount ───────────────────────────────────────────────────────────────

  @impl true
  def mount(params, _session, socket) do
    socket =
      Mob.Socket.assign(socket,
        target: target(params),
        mic: :asking,
        source: :mic,
        selected: :mic,
        input: nil,
        input_id: nil,
        take: nil,
        rate: 48_000,
        mode: :now,
        phase: :monitoring,
        level_db: -120.0,
        ambient: [],
        peaks: <<>>,
        frames: 0,
        count_in: nil,
        beat: 1,
        tick: nil,
        saved: nil,
        import_name: nil,
        sources: Engine.input_sources(),
        notice: nil
      )

    if device_calls?() do
      Mob.Device.lock_orientation(:landscape)
      {:ok, Mob.Permissions.request(socket, :microphone)}
    else
      {:ok, mic_granted(socket)}
    end
  end

  defp device_calls?, do: Application.get_env(:magpie, :device_calls, true)

  defp target(%{pad: pad, reply_to: pid}) when pad in 0..63 and is_pid(pid), do: {pad, pid}
  defp target(_params), do: nil

  @doc false
  # "Record into pad A15" (slots count from 1), else "Record a sample".
  def title(nil), do: "Record a sample"
  def title({pad, _pid}), do: "Record into pad #{pad_name(pad)}"

  @doc false
  def pad_name(pad) when pad in 0..63 do
    {bank, slot} = Magpie.Kit.bank_slot(pad)
    "#{bank}#{slot + 1}"
  end

  defp held, do: {self(), :held}

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    {card_w, card_h} = {@card_w, @card_h}

    ~MOB"""
    <Column
      background={Style.color(:bg)}
      fill_width={true}
      fill_height={true}
      padding_left={28}
      padding_right={28}
      padding_top={8}
      padding_bottom={8}
    >
      <Row gap={12} fill_width={true} fill_height={true} align={:top}>
        {left(assigns)}
        <Column weight={1} gap={10}>
          <Canvas id="wave" width={card_w} height={card_h} draw={card_ops(assigns)} />
          {bottom(assigns)}
        </Column>
      </Row>
    </Column>
    """
  end

  defp left(assigns) do
    left_w = @left_w

    ~MOB"""
    <Box width={left_w} fill_height={true}>
      <Column fill_width={true} fill_height={true} gap={4}>
        <Row align={:center} gap={8} height={44}>
          <Canvas
            id="back"
            width={44}
            height={44}
            draw={back_ops()}
            on_tap={{self(), :back}}
            on_press_out={held()}
          />
          <Text
            text={title(assigns.target)}
            font={:bold}
            text_size={16}
            text_color={Style.color(:text)}
            max_lines={1}
          />
        </Row>
        <Text
          text="SOURCE"
          font={:mono_semibold}
          text_size={11}
          line_height={1.0}
          letter_spacing={0.88}
          text_color={Style.color(:muted)}
        />
        <Scroll weight={1} fill_width={true}>
          <Column fill_width={true} gap={4}>
            {for {key, source} <- sources(), do: source_row(key, source, assigns)}
            <Text
              :if={assigns.notice}
              id="notice"
              text={assigns.notice}
              text_size={12}
              text_color={Style.color(:text_2)}
              max_lines={3}
            />
          </Column>
        </Scroll>
      </Column>
    </Box>
    """
  end

  defp sources, do: @sources

  # Other apps' audio is Android's (MediaProjection): elsewhere the row is
  # shown disabled, as FMutate's is until pairing exists.
  defp source_row(key, source, assigns) do
    unavailable = key == :apps and :apps not in assigns.sources
    disabled = key == :fmutate or unavailable
    source = if unavailable, do: %{source | sub: "not on this phone"}, else: source
    selected = key == assigns.selected
    tap = if not disabled, do: {self(), {:source, key}}

    {name_color, sub_color, ink} =
      if disabled,
        do: {Style.color(:faint), Style.color(:faint), Style.color(:faint)},
        else: {Style.color(:text), Style.color(:muted), source_ink(source.ink)}

    ~MOB"""
    <Box
      id={"source_#{key}"}
      fill_width={true}
      height={48}
      corner_radius={12}
      background={if(selected, do: Style.color(:raised_hi), else: Style.color(:surface))}
      border_color={if(selected, do: Style.color(:fm), else: Style.color(:surface))}
      border_width={if(selected, do: 2, else: 0)}
      padding_left={10}
      padding_right={10}
      align={:center}
      on_tap={tap}
      on_press_out={if(tap, do: held())}
    >
      <Row align={:center} gap={10} fill_width={true}>
        <Box
          width={34}
          height={24}
          corner_radius={6}
          background={Style.color(:line_soft)}
          align={:center}
        >
          <Text text={source.icon} font={:mono_bold} text_size={9} text_color={ink} />
        </Box>
        <Column weight={1}>
          <Text
            text={source.name}
            font={:semibold}
            text_size={13}
            line_height={1.15}
            text_color={name_color}
            max_lines={1}
          />
          <Text
            text={source.sub}
            font={:mono}
            text_size={10}
            line_height={1.15}
            text_color={sub_color}
            max_lines={1}
          />
        </Column>
      </Row>
    </Box>
    """
  end

  defp source_ink(nil), do: @file_ink
  defp source_ink(token), do: Style.color(token)

  defp bottom(%{mic: :denied, input: nil}) do
    ~MOB"""
    <Column id="no_mic" gap={8}>
      <Text
        text="Magpie needs the microphone to record."
        text_size={13}
        text_color={Style.color(:text)}
      />
      <Box
        id="try_again"
        fill_width={false}
        height={44}
        corner_radius={12}
        background={Style.color(:raised_hi)}
        padding_left={16}
        padding_right={16}
        align={:center}
        on_tap={{self(), :try_again}}
        on_press_out={held()}
      >
        <Text text="Try again" font={:semibold} text_size={13} text_color={Style.color(:text)} />
      </Box>
    </Column>
    """
  end

  defp bottom(assigns) do
    {meter_w, meter_h} = {@meter_w, @meter_h}

    ~MOB"""
    <Column gap={10}>
      <Row align={:center} gap={10} fill_width={true}>
        <Text text="IN" font={:mono_semibold} text_size={11} text_color={Style.color(:muted)} />
        <Canvas id="meter" width={meter_w} height={meter_h} draw={meter_ops(assigns)} />
        <Text
          id="level"
          text={level_text(assigns.level_db)}
          font={:mono_semibold}
          text_size={11}
          text_color={Style.color(:text_2)}
          width={56}
          max_lines={1}
          text_align="right"
        />
      </Row>
      <Row align={:center} gap={8} fill_width={true}>
        <Box width={330} corner_radius={12} background={Style.color(:surface)} padding={3}>
          <Row gap={3} fill_width={true}>
            {for {mode, label} <- modes(), do: mode_segment(mode, label, assigns.mode)}
          </Row>
        </Box>
        <Spacer />
        {record_button(assigns)}
      </Row>
    </Column>
    """
  end

  defp modes, do: @modes

  defp mode_segment(mode, label, chosen) do
    selected = mode == chosen

    ~MOB"""
    <Box
      id={"mode_#{mode}"}
      weight={1}
      height={40}
      corner_radius={9}
      background={if(selected, do: Style.color(:selected), else: Style.color(:surface))}
      align={:center}
      on_tap={{self(), {:mode, mode}}}
      on_press_out={held()}
    >
      <Text
        text={label}
        font={:semibold}
        text_size={12}
        text_color={if(selected, do: Style.color(:text), else: Style.color(:muted))}
        text_align="center"
      />
    </Box>
    """
  end

  defp record_button(assigns) do
    label = if assigns.phase in @busy, do: "■ Stop", else: "● Record"

    ~MOB"""
    <Box
      id="record"
      fill_width={false}
      height={52}
      corner_radius={16}
      background={Style.color(:pad_coral)}
      padding_left={22}
      padding_right={22}
      align={:center}
      on_tap={{self(), :record}}
      on_press_out={held()}
    >
      <Text text={label} font={:bold} text_size={15} text_color={Style.color(:ink)} />
    </Box>
    """
  end

  # ── Drawing ─────────────────────────────────────────────────────────────

  defp back_ops do
    # The board's `M15 5 l-7 7 7 7` in a 24 box drawn 18 wide, centred in 44.
    s = 18 / 24
    at = fn {x, y} -> {13 + x * s, 13 + y * s} end

    [
      circle(22, 22, 22, color: Style.color(:raised), fill: true),
      path(Enum.map([{15, 5}, {8, 12}, {15, 19}], at),
        color: Style.color(:text),
        width: 2,
        cap: :round,
        join: :round
      )
    ]
  end

  @doc false
  # The waveform card: surface, centre line, bars, playhead, chip, magpie.
  def card_ops(assigns) do
    {w, h} = {@card_w, @card_h}
    area_w = w - 28
    area_h = h - 40
    bar_w = (area_w - (@bars - 1) * @bar_gap) / @bars
    {bars, played} = bars(assigns)
    coral = Style.color(:pad_coral)
    line = Style.color(:line)

    bar_ops =
      bars
      |> Enum.with_index()
      |> Enum.map(fn {{frac, recorded}, i} ->
        bh = frac * area_h
        x = 14 + i * (bar_w + @bar_gap)

        rect(r(x), r((h - bh) / 2), r(bar_w), r(bh),
          color: if(recorded, do: coral, else: line),
          fill: true,
          radius: 1
        )
      end)

    chip = chip_text(assigns)
    chip_w = String.length(chip) * 12 * 0.6 + 16

    List.flatten([
      rect(0, 0, w, h, color: Style.color(:surface), fill: true, radius: 16),
      rect(14, r(h / 2), area_w, 1, color: line, fill: true),
      bar_ops,
      rect(r(14 + area_w * played - 1), 12, 2, h - 24, color: coral, fill: true),
      rect(14, 12, r(chip_w), 23, color: Style.color(:bg), fill: true, radius: 8),
      text(22, 16, chip,
        color: coral,
        size: 12,
        weight: :bold,
        family: Style.font_family(:mono_bold)
      ),
      Bird.ops(bird_mood(assigns), x: w - 12 - 48, y: 8, size: 0.75, trinket: :coral)
    ])
  end

  @doc false
  # 120 bars `{height 0..1, recorded?}` and the played fraction: the
  # recording's peaks over a window of 6 s × 2^k (the smallest that holds
  # it), or the whole sample once saved. A bar is the largest peak of its
  # group; recorded bars are at least 3 % high, the rest 2 %.
  def bars(%{peaks: peaks} = assigns) do
    have = byte_size(peaks)
    window = window(assigns, have)

    bars =
      for i <- 0..(@bars - 1) do
        from = div(i * window, @bars)
        to = max(div((i + 1) * window, @bars), from + 1)

        if from < have do
          group = binary_part(peaks, from, min(to, have) - from)
          {max(:binary.bin_to_list(group) |> Enum.max() |> Kernel./(255), 0.03), true}
        else
          {0.02, false}
        end
      end

    {bars, min(have / window, 1.0)}
  end

  defp window(%{phase: :saved}, have) when have > 0, do: have

  defp window(%{rate: rate}, have) do
    base = div(@window_s * rate, @peak_frames)
    Stream.iterate(base, &(&1 * 2)) |> Enum.find(&(&1 >= have))
  end

  defp meter_ops(assigns) do
    seg_w = (@meter_w - (@segments - 1) * 2) / @segments
    off = Style.color(:line_soft)

    segments =
      for i <- 0..(@segments - 1) do
        lit = assigns.level_db >= -60 + 2 * i

        color =
          cond do
            not lit -> off
            i < 22 -> Style.color(:fm)
            i < 27 -> Style.color(:warn)
            true -> Style.color(:pad_coral)
          end

        rect(r(i * (seg_w + 2)), 2, r(seg_w), 10, color: color, fill: true, radius: 2)
      end

    tick =
      if assigns.mode == :on_sound do
        x = (threshold(assigns.ambient) + 60) / 2 * (seg_w + 2) - 1
        [rect(r(max(x, 0)), 0, 2, @meter_h, color: Style.color(:muted), fill: true)]
      else
        []
      end

    segments ++ tick
  end

  defp r(v), do: Float.round(v * 1.0, 1)

  @doc false
  def chip_text(%{phase: :monitoring} = a) do
    cond do
      a.input == :open -> "READY"
      a.input == :opening -> "OPENING…"
      a.mic == :denied -> "NO MIC"
      true -> "NO INPUT"
    end
  end

  def chip_text(%{phase: :waiting}), do: "WAITING FOR SOUND"
  def chip_text(%{phase: :counting, beat: beat}), do: "COUNT-IN #{beat}"
  def chip_text(%{phase: :recording} = a), do: "● REC " <> clock(a.frames / a.rate)
  def chip_text(%{phase: :saving}), do: "SAVING…"
  def chip_text(%{phase: :importing}), do: "IMPORTING…"

  def chip_text(%{phase: :saved, saved: sample}),
    do: "SAVED #{:erlang.float_to_binary(sample.frames / sample.rate, decimals: 1)} s"

  defp clock(seconds) do
    tenths = trunc(seconds * 10)
    secs = div(tenths, 10)

    "#{div(secs, 60)}:#{secs |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}.#{rem(tenths, 10)}"
  end

  @doc false
  def bird_mood(%{mic: :denied, input: nil}), do: :nomic
  def bird_mood(%{phase: :saved}), do: :grab

  def bird_mood(%{input: :open, phase: phase}) when phase in [:monitoring | @busy],
    do: :listen

  def bird_mood(_assigns), do: :idle

  @doc false
  # "−6 dB" (U+2212), "−∞ dB" below -90.
  def level_text(db) when db < -90, do: "−∞ dB"

  def level_text(db) do
    case round(db) do
      n when n < 0 -> "−#{-n} dB"
      n -> "#{n} dB"
    end
  end

  @doc false
  # 12 dB over the loudest recent idle meter, -48..-12; -30 with none.
  def threshold([]), do: -30
  def threshold(ambient), do: (Enum.max(ambient) + 12) |> round() |> max(-48) |> min(-12)

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info({:permission, :microphone, :granted}, socket),
    do: {:noreply, mic_granted(socket)}

  def handle_info({:permission, :microphone, :denied}, socket) do
    if socket.assigns.input, do: close_input()

    {:noreply,
     Mob.Socket.assign(socket, mic: :denied, input: nil, input_id: nil, phase: :monitoring)}
  end

  def handle_info({:tap, :try_again}, socket), do: {:noreply, ask_mic(socket)}

  def handle_info({:tap, :back}, socket) do
    leave(socket)
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:tap, _}, %{assigns: %{phase: phase}} = socket)
      when phase in [:saving, :importing],
      do: {:noreply, socket}

  def handle_info({:tap, {:source, _}}, %{assigns: %{phase: phase}} = socket)
      when phase in @busy,
      do: {:noreply, socket}

  def handle_info({:tap, {:source, :mic}}, %{assigns: %{mic: :denied}} = socket),
    do: {:noreply, ask_mic(socket)}

  def handle_info({:tap, {:source, :file}}, socket) do
    socket = Mob.Socket.assign(socket, selected: :file, notice: nil)
    {:noreply, if(device_calls?(), do: Mob.Files.pick(socket, types: [:audio]), else: socket)}
  end

  def handle_info({:tap, {:source, :stash}}, socket) do
    leave(socket)

    params =
      case socket.assigns.target do
        {pad, pid} -> %{pad: pad, reply_to: pid}
        nil -> %{}
      end

    socket =
      socket
      |> monitoring()
      |> Mob.Socket.assign(input: nil, input_id: nil, selected: :stash, notice: nil)
      |> Mob.Socket.push_screen(LibraryScreen, params)

    {:noreply, socket}
  end

  def handle_info({:tap, {:source, source}}, socket) when source in [:mic, :apps],
    do: {:noreply, open(socket, source)}

  def handle_info({:tap, {:mode, mode}}, %{assigns: %{phase: phase}} = socket)
      when phase not in @busy,
      do: {:noreply, Mob.Socket.assign(socket, :mode, mode)}

  def handle_info({:tap, :record}, %{assigns: %{phase: phase}} = socket) when phase in @busy,
    do: {:noreply, save(socket)}

  def handle_info({:tap, :record}, socket), do: {:noreply, start(socket)}

  def handle_info({:files, :picked, items}, socket) do
    case Mob.Files.accept(items, [:audio]) do
      [%{path: path, name: name} | _] ->
        {:noreply, import_file(socket, path, name)}

      _ ->
        {:noreply,
         Mob.Socket.assign(socket,
           notice: "That isn't an audio file.",
           selected: socket.assigns.source
         )}
    end
  end

  def handle_info({:files, :cancelled}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :selected, socket.assigns.source)}

  # Input, meter and recording messages count for this screen's input and
  # take only: one queued from an earlier one is ignored.
  def handle_info({:magpie_audio, :input, id, :started, info}, %{assigns: %{input_id: id}} = s)
      when id != nil,
      do: {:noreply, Mob.Socket.assign(s, input: :open, source: info.source, rate: info.rate)}

  def handle_info({:magpie_audio, :input, id, :closed, reason}, %{assigns: %{input_id: id}} = s)
      when id != nil,
      do: {:noreply, input_closed(s, reason)}

  def handle_info({:magpie_audio, :meter, id, level_db, meter}, %{assigns: %{input_id: id}} = s)
      when id != nil,
      do: {:noreply, meter(s, level_db, meter)}

  def handle_info(
        {:magpie_audio, :record, take, :started, _info},
        %{assigns: %{take: take, phase: phase}} = s
      )
      when take != nil and phase in @busy,
      do: {:noreply, Mob.Socket.assign(s, phase: :recording, tick: nil)}

  def handle_info(
        {:magpie_audio, :record, take, :full, _frames},
        %{assigns: %{take: take, phase: phase}} = s
      )
      when take != nil and phase in @busy do
    s = save(s)
    {:noreply, Mob.Socket.assign(s, :notice, "Stopped at the #{@max_seconds} s limit")}
  end

  def handle_info(
        {:magpie_audio, :count_in, take, first, until},
        %{assigns: %{take: take, phase: :counting}} = s
      )
      when take != nil do
    s = Mob.Socket.assign(s, count_in: {first, until})
    {:noreply, s |> Mob.Socket.assign(:beat, beat(s.assigns)) |> tick()}
  end

  def handle_info({:tick, token}, %{assigns: %{tick: token, phase: :counting}} = socket)
      when token != nil,
      do: {:noreply, socket |> Mob.Socket.assign(:beat, beat(socket.assigns)) |> tick()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:save, {:ok, {:ok, sample}}, socket), do: {:noreply, saved(socket, sample)}

  def handle_async(:save, {:ok, {:error, :not_started}}, socket),
    do: {:noreply, monitoring(socket)}

  def handle_async(:save, result, socket) do
    {:noreply,
     socket
     |> monitoring()
     |> Mob.Socket.assign(:notice, "Couldn't save the recording: #{reason(result)}")}
  end

  def handle_async(:import, {:ok, {:ok, sample}}, socket), do: {:noreply, saved(socket, sample)}

  def handle_async(:import, result, socket) do
    name = socket.assigns.import_name

    {:noreply,
     socket
     |> monitoring()
     |> Mob.Socket.assign(
       selected: socket.assigns.source,
       notice: "Couldn't import #{name}: #{reason(result)}"
     )}
  end

  @impl true
  def terminate(_reason, socket), do: leave(socket)

  # ── Steps ───────────────────────────────────────────────────────────────

  defp ask_mic(socket) do
    if device_calls?(),
      do: Mob.Permissions.request(socket, :microphone),
      else: mic_granted(socket)
  end

  defp mic_granted(socket) do
    :ok = Engine.subscribe()
    socket |> Mob.Socket.assign(:mic, :granted) |> open(:mic)
  end

  # Opens `source` unless it is already the open (or opening) input.
  defp open(%{assigns: %{source: source, input: input}} = socket, source)
       when input in [:opening, :open],
       do: socket |> monitoring() |> Mob.Socket.assign(selected: source, notice: nil)

  defp open(socket, source) do
    case Engine.open_input(source) do
      {:ok, id} ->
        socket
        |> monitoring()
        |> Mob.Socket.assign(
          source: source,
          selected: source,
          input: :opening,
          input_id: id,
          notice: nil
        )

      {:error, reason} ->
        noun = source |> source_name() |> String.downcase()
        input_lost(socket, source, "Couldn't open #{noun} (#{error_text(reason)})")
    end
  end

  defp input_closed(socket, reason) do
    was = socket.assigns.source

    notice =
      case reason do
        :denied -> "Other apps weren't shared"
        reason -> "#{source_name(was)} stopped (#{reason})"
      end

    input_lost(socket, was, notice)
  end

  # No input any more (it closed, or a new one failed to open after the
  # Engine closed the old): other apps go back to the mic when it is
  # granted.
  defp input_lost(socket, was, notice) do
    socket =
      socket |> monitoring() |> Mob.Socket.assign(input: nil, input_id: nil, source: was)

    if was == :apps and socket.assigns.mic == :granted do
      socket = open(socket, :mic)

      if socket.assigns.input_id,
        do: Mob.Socket.assign(socket, :notice, notice <> "; back to the microphone."),
        else: socket
    else
      Mob.Socket.assign(socket, selected: was, notice: notice <> ".")
    end
  end

  defp source_name(:mic), do: "The microphone"
  defp source_name(:apps), do: "Other apps"

  # The take's peaks only from its own meters.
  defp meter(socket, level_db, meter) do
    a = socket.assigns

    ambient =
      if meter.state == :idle and a.phase not in @busy,
        do: Enum.take([level_db | a.ambient], @ambient_meters),
        else: a.ambient

    recording =
      if a.phase in @busy and meter.take == a.take,
        do: [peaks: a.peaks <> meter.peaks, frames: meter.frames],
        else: []

    Mob.Socket.assign(socket, [level_db: level_db, ambient: ambient] ++ recording)
  end

  defp start(socket) do
    a = socket.assigns

    opts =
      [mode: a.mode] ++
        if(a.mode == :on_sound, do: [threshold_db: threshold(a.ambient)], else: [])

    case Engine.record(opts) do
      {:ok, take} ->
        phase =
          case a.mode do
            :now -> :recording
            :on_sound -> :waiting
            :count_in -> :counting
          end

        Mob.Socket.assign(socket,
          phase: phase,
          take: take,
          peaks: <<>>,
          frames: 0,
          saved: nil,
          notice: nil,
          count_in: nil,
          beat: 1,
          selected: a.source
        )

      {:error, reason} ->
        Mob.Socket.assign(socket, :notice, record_error(reason))
    end
  end

  defp record_error(:no_input), do: "There's no input to record from yet."
  defp record_error(:not_running), do: "Count-in needs the sound output, which isn't running."
  defp record_error(reason), do: "Couldn't start recording: #{inspect(reason)}"

  defp save(socket) do
    meta = %{name: default_name(socket.assigns.source), source: :recorded}

    socket
    |> Mob.Socket.assign(phase: :saving, take: nil, tick: nil)
    |> Mob.Socket.start_async(:save, fn -> stop_and_save(meta) end)
  end

  defp stop_and_save(meta) do
    with {:ok, rec} <- Engine.stop_recording() do
      Library.put_pcm(
        rec.pcm,
        Map.merge(meta, %{rate: rec.rate, channels: rec.channels, peaks: rec.peaks})
      )
    end
  end

  defp default_name(source) do
    label = if source == :apps, do: "Other apps", else: "Mic"
    "#{label} #{Calendar.strftime(NaiveDateTime.local_now(), "%H:%M")}"
  end

  defp import_file(socket, path, name) do
    socket
    |> Mob.Socket.assign(phase: :importing, selected: :file, import_name: name, notice: nil)
    |> Mob.Socket.start_async(:import, fn -> Import.import(path, Path.rootname(name)) end)
  end

  defp saved(socket, sample) do
    with {pad, pid} <- socket.assigns.target, do: send(pid, {:recorded, pad, sample})
    Mob.Socket.assign(socket, phase: :saved, saved: sample, peaks: sample.peaks || <<>>)
  end

  defp monitoring(socket) do
    Mob.Socket.assign(socket,
      phase: :monitoring,
      take: nil,
      peaks: <<>>,
      frames: 0,
      saved: nil,
      count_in: nil,
      tick: nil
    )
  end

  defp reason({:ok, {:error, reason}}), do: error_text(reason)
  defp reason({:exit, _reason}), do: "it stopped unexpectedly"

  defp error_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_text(reason), do: inspect(reason)

  # The count-in's beat (1..4): how many of its clicks have been heard.
  defp beat(%{count_in: {first, until}}) do
    case Engine.clock() do
      nil ->
        1

      clock ->
        now = System.monotonic_time(:nanosecond)

        heard =
          Enum.count(0..3, fn k ->
            Audio.frame_time(clock, first + div(k * (until - first), 4)) <= now
          end)

        max(heard, 1)
    end
  end

  defp beat(_assigns), do: 1

  defp tick(socket) do
    token = make_ref()
    Process.send_after(self(), {:tick, token}, @tick_ms)
    Mob.Socket.assign(socket, :tick, token)
  end

  # Off with the mic: a recording is dropped, the input closed. The
  # landscape lock stays: each screen locks what it needs on mount.
  defp leave(socket) do
    if socket.assigns.phase in @busy, do: Engine.cancel_recording()
    close_input()
  end

  # A mic stream that wouldn't stop: the Engine has it closed to every
  # screen and keeps closing it on its own; this screen can only say so.
  defp close_input do
    with {:error, reason} <- Engine.close_input() do
      Logger.warning("Magpie.RecordScreen: the input didn't close (#{inspect(reason)})")
    end

    :ok
  end
end
