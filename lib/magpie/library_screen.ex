defmodule Magpie.LibraryScreen do
  @moduledoc """
  The stash (`design/boards/Library.dc.html`, landscape, HANDOFF §6): the
  Samples tab of the library (the Kits tab is not designed yet).

  Top: back, the title ("The stash" in browse mode, "Load into pad A15" when
  opened for a pad), starter-pack progress while importing, "+ Import", and
  the proud magpie. Below: search (`Magpie.Library.list(%{source:, q:})`),
  source filter chips (`All`, `Recorded`, `From FMutate`, `Packs`,
  `Imported`), and a `<LazyList>` of sample rows with an audition button,
  name, duration/source/tag metadata, and a 16-bar mini waveform drawn from
  the sample's engine peaks.

  Audition plays through `Mob.Audio.play/2` / `Mob.Audio.stop_playback/1`
  (an independent MediaPlayer stream, so it never alters the kit or stops the
  engine). Leaving, terminating, or picking a sample stops any active
  audition first.

  Params `%{pad: 0..63, reply_to: pid}` open the stash in pick mode: tapping
  a row's body sends `{:recorded, pad, %Magpie.Library.Sample{}}` to
  `reply_to` (`Magpie.KitSession`) and pops back to `Magpie.PadsScreen`
  (`Mob.Socket.pop_to/2`). Without params (browse mode), tapping a row body
  toggles audition.

  Every tap target declares `on_press_out={held()}` (MOB-509).
  """

  use Mob.Screen

  import Mob.Canvas, only: [circle: 4, path: 2, rect: 5]

  alias Magpie.{Bird, Import, Library, PadsScreen, RecordScreen, StarterPack, Style}
  alias Magpie.Library.Sample

  @wave_bars 16
  @wave_h 22

  @filters [
    all: "All",
    recorded: "Recorded",
    fmutate: "From FMutate",
    pack: "Packs",
    imported: "Imported"
  ]

  # ── Mount ───────────────────────────────────────────────────────────────

  @impl true
  def mount(params, _session, socket) do
    if device_calls?(), do: Mob.Device.lock_orientation(:landscape)

    # One call: the import holds the process for a file at a time.
    {starter_pack, credit} =
      if Process.whereis(StarterPack),
        do: StarterPack.subscribe(),
        else: {nil, StarterPack.credit()}

    socket =
      socket
      |> Mob.Socket.assign(
        target: target(params),
        source: :all,
        q: "",
        samples: [],
        pack_present?: false,
        credit: credit,
        starter_pack: starter_pack,
        playing_id: nil,
        playing_path: nil,
        importing: false,
        import_name: nil,
        notice: nil
      )
      |> reload_samples()

    {:ok, socket}
  end

  defp device_calls?, do: Application.get_env(:magpie, :device_calls, true)

  defp target(%{pad: pad, reply_to: pid}) when pad in 0..63 and is_pid(pid), do: {pad, pid}
  defp target(_params), do: nil

  @doc false
  def title(nil), do: "The stash"
  def title({pad, _pid}), do: "Load into pad #{RecordScreen.pad_name(pad)}"

  defp held, do: {self(), :held}

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    search_change = {self(), :search}

    ~MOB"""
    <Column
      background={Style.color(:bg)}
      fill_width={true}
      fill_height={true}
      padding_left={28}
      padding_right={28}
      padding_top={8}
      padding_bottom={8}
      gap={8}
    >
      {top_bar(assigns)}
      <Row align={:center} gap={10} fill_width={true}>
        <Box weight={1}>
          <TextField
            id="search"
            value={@q}
            placeholder="Search names and tags"
            on_change={search_change}
            background={Style.color(:surface)}
            text_color={Style.color(:text)}
            placeholder_color={Style.color(:muted)}
            border_color={Style.color(:surface)}
            corner_radius={14}
            text_size={14}
            underline={false}
          />
        </Box>
        <Row gap={6} fill_width={false} align={:center}>
          {for {key, label} <- filters(), do: filter_chip(key, label, @source)}
        </Row>
      </Row>
      <Text
        :if={@notice}
        id="notice"
        text={@notice}
        text_size={12}
        text_color={Style.color(:text_2)}
        max_lines={2}
      />
      <LazyList id="samples" weight={1}>
        {for sample <- @samples, do: sample_row(sample, @playing_id == sample.id)}
      </LazyList>
      <Text
        :if={@samples == []}
        id="empty"
        text="No samples in the stash match."
        text_size={13}
        text_color={Style.color(:muted)}
      />
      {footer(assigns)}
    </Column>
    """
  end

  defp top_bar(assigns) do
    back_tap = {self(), :back}
    import_tap = {self(), :import}
    import_label = if assigns.importing, do: "Importing…", else: "+ Import"

    ~MOB"""
    <Row align={:center} gap={10} fill_width={true} height={44}>
      <Canvas
        id="back"
        width={44}
        height={44}
        draw={back_ops()}
        on_tap={back_tap}
        on_press_out={held()}
      />
      <Text
        text={title(assigns.target)}
        font={:display}
        text_size={22}
        text_color={Style.color(:text)}
      />
      <Box
        fill_width={false}
        height={28}
        padding_left={10}
        padding_right={10}
        corner_radius={9}
        background={Style.color(:selected)}
        align={:center}
      >
        <Text
          id="sample_count"
          text={"Samples · #{length(assigns.samples)}"}
          font={:semibold}
          text_size={12}
          text_color={Style.color(:text)}
        />
      </Box>
      <Text
        :if={importing_pack?(assigns.starter_pack)}
        id="starter_progress"
        text={starter_progress_text(assigns.starter_pack)}
        font={:mono_semibold}
        text_size={11}
        text_color={Style.color(:pad_amber)}
      />
      <Spacer />
      <Box
        id="import"
        fill_width={false}
        height={40}
        padding_left={14}
        padding_right={14}
        corner_radius={12}
        background={Style.color(:raised_hi)}
        align={:center}
        on_tap={import_tap}
        on_press_out={held()}
      >
        <Text text={import_label} font={:semibold} text_size={13} text_color={Style.color(:text)} />
      </Box>
      <Canvas id="bird" width={48} height={42} draw={Bird.ops(:proud, x: 0, y: 0, size: 0.75)} />
    </Row>
    """
  end

  defp filters, do: @filters

  defp filter_chip(key, label, current) do
    selected = key == current
    tap = {self(), {:filter, key}}
    bg = if selected, do: Style.color(:text), else: Style.color(:raised)
    fg = if selected, do: Style.color(:ink), else: Style.color(:text_2)

    ~MOB"""
    <Box
      id={"filter_#{key}"}
      fill_width={false}
      height={34}
      padding_left={12}
      padding_right={12}
      corner_radius={17}
      background={bg}
      align={:center}
      on_tap={tap}
      on_press_out={held()}
    >
      <Text text={label} font={:semibold} text_size={12} text_color={fg} />
    </Box>
    """
  end

  defp sample_row(%Sample{} = sample, playing) do
    audition_tap = {self(), {:audition, sample.id}}
    row_tap = {self(), {:sample, sample.id}}
    bg = if playing, do: Style.color(:raised_hi), else: Style.color(:surface)
    border = if playing, do: Style.color(:fm), else: Style.color(:surface)
    border_w = if playing, do: 1, else: 0
    color = wave_color(sample.source, playing)
    bars = sample.peaks |> wave_heights() |> Enum.map(&wave_bar(&1, color))

    ~MOB"""
    <Box
      id={"row_#{sample.id}"}
      fill_width={true}
      corner_radius={14}
      background={bg}
      border_color={border}
      border_width={border_w}
      padding_left={6}
      padding_right={8}
      padding_top={6}
      padding_bottom={6}
    >
      <Row align={:center} gap={10} fill_width={true}>
        <Box
          id={"audition_#{sample.id}"}
          width={44}
          height={44}
          corner_radius={12}
          background={Style.color(:raised_hi)}
          align={:center}
          on_tap={audition_tap}
          on_press_out={held()}
        >
          <Canvas width={14} height={14} draw={audition_ops(playing)} />
        </Box>
        <Box id={"sample_#{sample.id}"} weight={1} on_tap={row_tap} on_press_out={held()}>
          <Row align={:center} gap={10} fill_width={true}>
            <Column weight={1} gap={2}>
              <Text
                text={sample.name}
                font={:semibold}
                text_size={14}
                text_color={Style.color(:text)}
                max_lines={1}
              />
              <Text
                text={sample_meta(sample)}
                font={:mono}
                text_size={10}
                text_color={Style.color(:muted)}
                max_lines={1}
              />
            </Column>
            <Row id={"wave_#{sample.id}"} width={64} height={22} gap={1} align={:center}>
              {bars}
            </Row>
          </Row>
        </Box>
      </Row>
    </Box>
    """
  end

  defp footer(assigns) do
    ~MOB"""
    <Row :if={assigns.pack_present?} align={:center} gap={8} fill_width={true}>
      <Text
        id="credit"
        text={"Starter Drums: #{assigns.credit}"}
        text_size={11}
        text_color={Style.color(:muted)}
        max_lines={1}
      />
    </Row>
    """
  end

  # ── Waveform & Drawing ──────────────────────────────────────────────────

  defp back_ops do
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

  defp audition_ops(false),
    do: [path([{4, 2}, {12, 7}, {4, 12}], color: Style.color(:text), fill: true)]

  defp audition_ops(true),
    do: [rect(2, 2, 10, 10, color: Style.color(:fm), fill: true, radius: 1)]

  @doc false
  def wave_peaks(peaks) when is_binary(peaks) and byte_size(peaks) > 0 do
    n = byte_size(peaks)

    for b <- 0..(@wave_bars - 1) do
      lo = div(n * b, @wave_bars)
      hi = max(div(n * (b + 1), @wave_bars), lo + 1)

      if lo < n do
        peaks |> binary_part(lo, min(hi, n) - lo) |> :binary.bin_to_list() |> Enum.max()
      else
        0
      end
    end
  end

  def wave_peaks(_peaks), do: List.duplicate(0, @wave_bars)

  @doc false
  def wave_heights(peaks) do
    bars = wave_peaks(peaks)

    case Enum.max(bars, fn -> 0 end) do
      0 -> List.duplicate(2, @wave_bars)
      top -> Enum.map(bars, &max(2, round(@wave_h * &1 / top)))
    end
  end

  defp wave_bar(height, color) do
    ~MOB(<Box weight={1} height={height} corner_radius={1} background={color} />)
  end

  defp wave_color(_source, true), do: Style.color(:fm)
  defp wave_color(:recorded, false), do: Style.color(:pad_coral)
  defp wave_color(:fmutate, false), do: Style.color(:info)
  defp wave_color(:pack, false), do: Style.color(:pad_amber)
  defp wave_color(:imported, false), do: Style.color(:pad_violet)

  defp sample_meta(%Sample{} = sample) do
    duration = format_seconds(Sample.seconds(sample))
    source = source_label(sample.source)
    parts = [duration, source | sample.tags]
    Enum.join(parts, " · ")
  end

  defp format_seconds(s) when s >= 10.0,
    do: "#{:erlang.float_to_binary(s, decimals: 1)} s"

  defp format_seconds(s),
    do: "#{:erlang.float_to_binary(s, decimals: 2)} s"

  defp source_label(:recorded), do: "recorded"
  defp source_label(:fmutate), do: "from FMutate"
  defp source_label(:pack), do: "pack"
  defp source_label(:imported), do: "imported"

  defp importing_pack?(%{state: :importing}), do: true
  defp importing_pack?(_), do: false

  defp starter_progress_text(%{done: done, total: total}) when total > 0,
    do: "Adding starter drums #{done}/#{total}"

  defp starter_progress_text(%{done: done}),
    do: "Adding starter drums #{done}/100"

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:press_out, :held}, socket), do: {:noreply, socket}

  def handle_info({:tap, :back}, socket) do
    {:noreply, socket |> stop_audition() |> Mob.Socket.pop_screen()}
  end

  def handle_info({:tap, {:filter, source}}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:source, source)
     |> reload_samples()}
  end

  def handle_info({:change, :search, q}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:q, q)
     |> reload_samples()}
  end

  def handle_info({:tap, {:audition, id}}, socket) do
    {:noreply, toggle_audition(socket, id)}
  end

  def handle_info({:tap, {:sample, id}}, %{assigns: %{target: nil}} = socket) do
    {:noreply, toggle_audition(socket, id)}
  end

  def handle_info({:tap, {:sample, id}}, %{assigns: %{target: {pad, reply_to}}} = socket) do
    case Enum.find(socket.assigns.samples, &(&1.id == id)) || Library.get(id) do
      %Sample{} = sample ->
        socket = stop_audition(socket)
        send(reply_to, {:recorded, pad, sample})
        {:noreply, Mob.Socket.pop_to(socket, PadsScreen)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:tap, :import}, %{assigns: %{importing: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:tap, :import}, socket) do
    socket = Mob.Socket.assign(socket, :notice, nil)
    {:noreply, if(device_calls?(), do: Mob.Files.pick(socket, types: [:audio]), else: socket)}
  end

  def handle_info({:files, :picked, items}, socket) do
    case Mob.Files.accept(items, [:audio]) do
      [%{path: path, name: name} | _] ->
        {:noreply,
         socket
         |> Mob.Socket.assign(importing: true, import_name: name, notice: nil)
         |> Mob.Socket.start_async(:import, fn -> Import.import(path, Path.rootname(name)) end)}

      _ ->
        {:noreply, Mob.Socket.assign(socket, :notice, "That isn't an audio file.")}
    end
  end

  def handle_info({:files, :cancelled}, socket), do: {:noreply, socket}

  # While the pack imports, the progress line moves on every file; the list
  # is read again every 10 files and when the import ends.
  def handle_info({:starter_pack, %{state: :importing, done: done} = status}, socket)
      when rem(done, 10) != 0,
      do: {:noreply, Mob.Socket.assign(socket, :starter_pack, status)}

  def handle_info({:starter_pack, status}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:starter_pack, status)
     |> reload_samples()}
  end

  def handle_info(
        {:audio, :playback_finished, %{path: path}},
        %{assigns: %{playing_path: path}} = socket
      )
      when is_binary(path) do
    {:noreply, Mob.Socket.assign(socket, playing_id: nil, playing_path: nil)}
  end

  def handle_info({:audio, :playback_finished, _}, socket), do: {:noreply, socket}

  def handle_info({:audio, :playback_error, %{reason: reason}}, socket) do
    {:noreply,
     Mob.Socket.assign(socket,
       playing_id: nil,
       playing_path: nil,
       notice: "Couldn't play sample: #{error_text(reason)}"
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:import, {:ok, {:ok, _sample}}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(importing: false, import_name: nil, notice: nil)
     |> reload_samples()}
  end

  def handle_async(:import, result, socket) do
    name = socket.assigns.import_name

    {:noreply,
     socket
     |> Mob.Socket.assign(
       importing: false,
       import_name: nil,
       notice: "Couldn't import #{name}: #{reason(result)}"
     )}
  end

  @impl true
  def terminate(_reason, socket) do
    _ = stop_audition(socket)
    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp reload_samples(socket) do
    a = socket.assigns
    samples = Library.list(%{source: a.source, q: a.q})
    pack_present? = pack_present?(a.source, a.q, samples)
    Mob.Socket.assign(socket, samples: samples, pack_present?: pack_present?)
  end

  defp pack_present?(:all, "", samples), do: Enum.any?(samples, &(&1.source == :pack))

  defp pack_present?(_source, _q, samples),
    do: Enum.any?(samples, &(&1.source == :pack)) or Library.list(%{source: :pack}) != []

  defp toggle_audition(%{assigns: %{playing_id: id}} = socket, id) when is_binary(id),
    do: stop_audition(socket)

  defp toggle_audition(socket, id) when is_binary(id) do
    path = Library.path(id)
    socket = Mob.Socket.assign(socket, playing_id: id, playing_path: path, notice: nil)
    if device_calls?(), do: Mob.Audio.play(socket, path), else: socket
  end

  defp stop_audition(%{assigns: %{playing_id: nil}} = socket), do: socket

  defp stop_audition(socket) do
    socket = Mob.Socket.assign(socket, playing_id: nil, playing_path: nil)
    if device_calls?(), do: Mob.Audio.stop_playback(socket), else: socket
  end

  defp reason({:ok, {:error, reason}}), do: error_text(reason)
  defp reason({:exit, _reason}), do: "it stopped unexpectedly"

  defp error_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_text(reason), do: inspect(reason)
end
