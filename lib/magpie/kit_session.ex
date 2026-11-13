defmodule Magpie.KitSession do
  @moduledoc """
  The kit being played: one process, started from `Magpie.App.on_start/0`
  after `Magpie.Engine`, that holds the current `%Magpie.Kit{}`, gets it into
  the engine and keeps it saved.

  - **Loading.** Every sample the kit uses goes from the library into the
    engine (`Magpie.Library.pcm/1` → `Magpie.Engine.load_pcm/4`), one at a
    time in a loader process, so this process keeps answering while a long
    sample loads. A pad goes to the engine (`Magpie.Engine.set_pad/2`) as soon
    as its sample is in.
  - **Changes** (`update_pad/2`, `put_sample/2`, `clear_pad/1`, `set_snap/1`)
    apply to the engine at once and are autosaved through
    `Magpie.Library.save_kit/1` a moment later (`autosave_ms:`, 1 s);
    `flush/0` saves what is pending now.
  - **Subscribers** (`subscribe/1`, monitored) get `{:magpie_kit,
    %Magpie.KitSession.Snapshot{}}` after every change and every load.
  - **Recording into a pad:** `Magpie.RecordScreen` sends `{:recorded, pad,
    %Magpie.Library.Sample{}}` to the pid it is given; give it this process
    (`whereis/0`) and the sample lands on the pad (`put_sample/2`).

  ## Which kit

  The most recently saved kit in the library (autosave keeps that the one
  last played). With none saved: `design/kits/dusty-breaks.kit.json`, the
  kit the Pads board shows, keeping only the pads whose samples are in the
  library (its pattern lanes for the others go too). On a fresh install
  that is an empty kit named "Dusty Breaks": the first-run / empty-kit
  design doesn't exist yet, and this invents no demo content.
  """

  use GenServer

  require Logger

  alias Magpie.{Engine, Kit, Library, Style}
  alias Magpie.Kit.{Pad, Region}

  @start_kit_path Path.expand("../../design/kits/dusty-breaks.kit.json", __DIR__)
  @external_resource @start_kit_path
  @start_kit_json File.read!(@start_kit_path)

  @wave_bars Style.pad().wave_bars
  @autosave_ms 1_000
  # A sample the engine couldn't unload yet (its command queue full) is
  # tried again after this.
  @unload_retry_ms 200

  defmodule Snapshot do
    @moduledoc """
    What a screen needs to draw the kit: the kit, and per pad index with a
    sample (`Magpie.Kit.pad_index/2`) its `status` (`:loading`, `:ready` or
    `{:error, reason}`: not in the library, failed to load, refused by the
    engine), its `wave` (#{Magpie.Style.pad().wave_bars} peaks 0..255 over
    the pad's region, reversed with it; empty until the sample is loaded)
    and `seconds` (the region's length at its pitch; nil until loaded).
    """
    defstruct [:kit, pads: %{}]

    @type pad_info :: %{
            status: :loading | :ready | {:error, term()},
            wave: [0..255],
            seconds: float() | nil
          }
    @type t :: %__MODULE__{kit: Magpie.Kit.t(), pads: %{(0..63) => pad_info()}}
  end

  defstruct [
    :kit,
    :loader,
    :save_token,
    autosave_ms: @autosave_ms,
    samples: %{},
    refused: %{},
    queue: [],
    subscribers: %{},
    # The MIDI table last given to the engine (`Magpie.Midi.Map.config/1`).
    midi: nil
  ]

  # ── API ─────────────────────────────────────────────────────────────────────

  @doc """
  Options: `kit:` play this kit instead of the saved / starting one,
  `autosave_ms:` (default #{@autosave_ms}).
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The session's pid, or nil (for `Magpie.RecordScreen`'s `reply_to`)."
  def whereis, do: Process.whereis(__MODULE__)

  @doc "Send `{:magpie_kit, snapshot}` to `pid` on every change until it exits. Returns the snapshot now."
  @spec subscribe(pid()) :: Snapshot.t()
  def subscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @spec snapshot() :: Snapshot.t()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Change pad `index` (0..63): `fun` gets the pad (nil for an empty slot)
  and returns the new one, or nil to clear it. `fun` runs in the caller (a
  bad one can't take the session down) and again if the pad changed
  meanwhile. The engine gets the pad at once if its sample is loaded (its
  errors come back and leave the kit as it was); a sample not loaded yet
  is loaded.
  """
  @spec update_pad(0..63, (Pad.t() | nil -> Pad.t() | nil)) :: :ok | {:error, term()}
  def update_pad(index, fun) when index in 0..63 and is_function(fun, 1) do
    old = GenServer.call(__MODULE__, {:pad, index})

    case fun.(old) do
      new when is_nil(new) or is_struct(new, Pad) ->
        with {:error, :changed} <- GenServer.call(__MODULE__, {:put_pad, index, old, new}),
             do: update_pad(index, fun)

      other ->
        {:error, {:not_a_pad, other}}
    end
  end

  @doc "Empty pad `index`."
  def clear_pad(index), do: update_pad(index, fn _ -> nil end)

  @doc """
  Put library sample `sample_id` on pad `index`, the whole sample. A pad
  already there keeps its settings and gets the sample and its name; a new
  pad takes the sample's name and a palette colour by slot.
  """
  @spec put_sample(0..63, String.t()) :: :ok | {:error, term()}
  def put_sample(index, sample_id) when index in 0..63 and is_binary(sample_id),
    do: GenServer.call(__MODULE__, {:put_sample, index, sample_id})

  @doc "Snap on or off (the kit's `snap`)."
  def set_snap(on) when is_boolean(on), do: GenServer.call(__MODULE__, {:snap, on})

  @doc """
  The kit's MIDI settings: `in_channel` (`:all` or 1..16; notes out go on
  it, or 1 with `:all`) and `clock` (`:internal`, `:follow` an incoming
  MIDI clock, `:send` one). Either key may be left out.
  """
  @spec set_midi(map()) :: :ok | {:error, {:invalid, atom()}}
  def set_midi(changes) when is_map(changes) do
    cond do
      not (Map.get(changes, :in_channel, :all) == :all or Map.get(changes, :in_channel) in 1..16) ->
        {:error, {:invalid, :in_channel}}

      Map.get(changes, :clock, :internal) not in [:internal, :follow, :send] ->
        {:error, {:invalid, :clock}}

      true ->
        GenServer.call(__MODULE__, {:midi, Map.take(changes, [:in_channel, :clock])})
    end
  end

  @doc "Save now if a change is waiting for the autosave."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc """
  The pattern bank `bank` plays: the kit's first one for it, else an empty
  16-step one.
  """
  @spec pattern(Kit.t(), Kit.bank_id()) :: Kit.Pattern.t()
  def pattern(%Kit{patterns: patterns}, bank) do
    Enum.find(patterns, &(&1.bank == bank)) ||
      %Kit.Pattern{id: "#{bank}1", bank: bank, length: 16}
  end

  @doc "The kit the app starts with when none is saved (see the moduledoc)."
  @spec start_kit() :: Kit.t()
  def start_kit do
    {:ok, kit} = Kit.decode(@start_kit_json)

    keep = fn pad ->
      match?(%Pad{sample: %Region{id: id}} when is_binary(id), pad) and
        Library.get(pad.sample.id) != nil
    end

    banks =
      Map.new(kit.banks, fn {bank, pads} ->
        {bank, Map.filter(pads, fn {_, pad} -> keep.(pad) end)}
      end)

    patterns =
      Enum.map(kit.patterns, fn pattern ->
        %{
          pattern
          | lanes:
              Map.filter(pattern.lanes, fn {slot, _} ->
                Map.has_key?(banks[pattern.bank] || %{}, slot)
              end)
        }
      end)

    %{kit | banks: banks, patterns: patterns}
  end

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    kit = Keyword.get_lazy(opts, :kit, &saved_or_start_kit/0)
    autosave_ms = Keyword.get(opts, :autosave_ms, @autosave_ms)
    {:ok, %__MODULE__{kit: kit, autosave_ms: autosave_ms}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, s) do
    _ = Engine.set_tempo(s.kit.tempo)
    _ = Engine.set_swing(s.kit.swing)
    {:noreply, s |> sync_midi() |> enqueue(sample_ids(s.kit)) |> next_load() |> publish()}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, s) do
    subscribers =
      if Map.has_key?(s.subscribers, pid),
        do: s.subscribers,
        else: Map.put(s.subscribers, pid, Process.monitor(pid))

    {:reply, snapshot(s), %{s | subscribers: subscribers}}
  end

  def handle_call(:snapshot, _from, s), do: {:reply, snapshot(s), s}

  def handle_call({:pad, index}, _from, s), do: {:reply, pad_at(s.kit, index), s}

  def handle_call({:put_pad, index, old, new}, _from, s) do
    {_bank, slot} = Kit.bank_slot(index)

    cond do
      pad_at(s.kit, index) != old -> {:reply, {:error, :changed}, s}
      new == nil -> reply(set_pad(s, index, nil))
      true -> reply(set_pad(s, index, %{new | slot: slot}))
    end
  end

  def handle_call({:put_sample, index, id}, _from, s) do
    {result, s} = put_sample_on(s, index, id)
    {:reply, result, s}
  end

  def handle_call({:snap, on}, _from, s),
    do: {:reply, :ok, s |> put_kit(%{s.kit | snap: on}) |> publish()}

  def handle_call({:midi, changes}, _from, s),
    do: {:reply, :ok, s |> put_kit(%{s.kit | midi: Map.merge(s.kit.midi, changes)}) |> publish()}

  def handle_call(:flush, _from, s) do
    {result, s} = save(s)
    {:reply, result, s}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{loader: {ref, id}} = s) do
    result =
      case reason do
        {:loaded, result} -> result
        other -> {:error, {:loader, other}}
      end

    s = %{s | loader: nil, samples: Map.put(s.samples, id, sample_state(result))}
    s = if match?({:ok, _}, result), do: apply_pads_of(s, id), else: s
    # Unused by the time it loaded (its pad was cleared or replaced).
    s = drop_unused(s, id)
    {:noreply, s |> next_load() |> publish()}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  def handle_info({:autosave, token}, %{save_token: token} = s),
    do: {:noreply, s |> save() |> elem(1)}

  def handle_info({:autosave, _stale}, s), do: {:noreply, s}

  def handle_info({:unload, id}, s), do: {:noreply, drop_unused(s, id)}

  # Magpie.RecordScreen's reply: a sample saved for a pad.
  def handle_info({:recorded, index, %Library.Sample{id: id}}, s) when index in 0..63 do
    {result, s} = put_sample_on(s, index, id)

    with {:error, reason} <- result,
         do:
           Logger.warning(
             "Magpie.KitSession: recorded sample for pad #{index}: #{inspect(reason)}"
           )

    {:noreply, s}
  end

  # ── Pads ────────────────────────────────────────────────────────────────────

  defp put_sample_on(s, index, id) do
    case Library.get(id) do
      nil ->
        {{:error, :not_in_library}, s}

      sample ->
        {_bank, slot} = Kit.bank_slot(index)
        name = String.slice(sample.name, 0, 12)
        region = %Region{id: id}

        pad =
          case pad_at(s.kit, index) do
            nil -> %Pad{slot: slot, name: name, color: palette_color(slot), sample: region}
            pad -> %{pad | name: name, sample: region}
          end

        set_pad(s, index, pad)
    end
  end

  # Pad `index` becomes `pad` (nil: empty) in the engine, then in the kit.
  # When its sample or mode changes (or it is emptied), the engine stops the
  # old pad's voices and waiting launches in the same step as the change
  # (`stop:`), so neither a release nor a toggle's second trigger has to go
  # by a definition the engine no longer has. A sample no pad uses any more
  # is unloaded.
  defp set_pad(s, index, pad) do
    id = with %Pad{sample: %Region{id: id}} <- pad, do: id
    old = pad_at(s.kit, index)
    old_id = with %Pad{sample: %Region{id: old_id}} <- old, do: old_id
    stop = old != nil and (pad == nil or old_id != id or old.mode != pad.mode)

    result =
      case Map.get(s.samples, id) do
        {:ok, _info} -> Engine.set_pad(index, pad, stop: stop)
        # Not loaded (yet, or failing): the engine must not keep the old pad.
        _ -> Engine.clear_pad(index, stop: stop)
      end

    case result do
      :ok ->
        s =
          %{s | refused: Map.delete(s.refused, index)}
          |> put_kit(put_pad(s.kit, index, pad))
          |> drop_unused(old_id)
          |> enqueue(List.wrap(id))
          |> next_load()

        {:ok, publish(s)}

      {:error, _} = error ->
        {error, s}
    end
  end

  # Unload sample `id` (and forget it) once no pad of the kit uses it. One
  # still loading is dropped when its load ends; one the engine can't
  # unload yet (its command queue is full) is tried again shortly.
  defp drop_unused(s, nil), do: s

  defp drop_unused(s, id) do
    cond do
      pads_on(s.kit, id) != [] ->
        s

      match?({_ref, ^id}, s.loader) ->
        s

      match?({:ok, _}, s.samples[id]) and Engine.unload_sample(id) == {:error, :busy} ->
        Process.send_after(self(), {:unload, id}, @unload_retry_ms)
        s

      true ->
        %{s | samples: Map.delete(s.samples, id), queue: List.delete(s.queue, id)}
    end
  end

  defp reply({result, s}), do: {:reply, result, s}

  defp pad_at(kit, index) do
    {bank, slot} = Kit.bank_slot(index)
    get_in(kit.banks, [bank, slot])
  end

  defp put_pad(kit, index, pad) do
    {bank, slot} = Kit.bank_slot(index)
    pads = Map.get(kit.banks, bank, %{})
    pads = if pad, do: Map.put(pads, slot, pad), else: Map.delete(pads, slot)
    %{kit | banks: Map.put(kit.banks, bank, pads)}
  end

  # Every pad on sample `id` to the engine, now that it has loaded; a pad
  # the engine refuses (a region past the sound's end) is marked so.
  defp apply_pads_of(s, id) do
    Enum.reduce(pads_on(s.kit, id), s, fn {index, pad}, s ->
      case Engine.set_pad(index, pad) do
        :ok ->
          %{s | refused: Map.delete(s.refused, index)}

        {:error, reason} ->
          Logger.warning("Magpie.KitSession: pad #{index} refused: #{inspect(reason)}")
          %{s | refused: Map.put(s.refused, index, reason)}
      end
    end)
  end

  defp pads_on(kit, id) do
    for {bank, pads} <- kit.banks,
        {slot, %Pad{sample: %Region{id: ^id}} = pad} <- pads,
        do: {Kit.pad_index(bank, slot), pad}
  end

  defp palette_color(slot), do: Enum.at(Style.pad_palette(), rem(slot, 8))

  # ── Loading ─────────────────────────────────────────────────────────────────

  defp sample_ids(kit) do
    for {_bank, pads} <- kit.banks,
        {_slot, %Pad{sample: %Region{id: id}}} <- pads,
        uniq: true,
        do: id
  end

  # Samples not loaded or loading; one that failed is tried again.
  defp enqueue(s, ids) do
    new = Enum.reject(ids, &(match?({:ok, _}, s.samples[&1]) or s.samples[&1] == :loading))
    %{s | queue: s.queue ++ new, samples: Map.merge(s.samples, Map.new(new, &{&1, :loading}))}
  end

  defp next_load(%{loader: nil, queue: [id | rest]} = s) do
    {_pid, ref} = spawn_monitor(fn -> exit({:loaded, load(id)}) end)
    %{s | loader: {ref, id}, queue: rest}
  end

  defp next_load(s), do: s

  # In the loader process: the PCM passes through it, not the session.
  defp load(id) do
    case Library.get(id) do
      nil ->
        {:error, :not_in_library}

      sample ->
        with {:ok, pcm} <- Library.pcm(id),
             do: Engine.load_pcm(id, pcm, sample.rate, sample.channels)
    end
  end

  # Keep what the waves need, not the engine's whole info.
  defp sample_state({:ok, info}),
    do: {:ok, Map.take(info, [:frames, :rate, :peaks, :peak_frames])}

  defp sample_state({:error, _} = error), do: error

  # ── Snapshot ────────────────────────────────────────────────────────────────

  defp snapshot(s) do
    pads =
      for {bank, pads} <- s.kit.banks,
          {slot, %Pad{sample: %Region{id: id} = region}} <- pads,
          index = Kit.pad_index(bank, slot),
          into: %{} do
        state =
          case s.refused do
            %{^index => reason} -> {:error, {:refused, reason}}
            _ -> Map.get(s.samples, id, :loading)
          end

        {index, pad_info(state, region)}
      end

    %Snapshot{kit: s.kit, pads: pads}
  end

  defp pad_info({:ok, info}, region),
    do: %{status: :ready, wave: wave(info, region), seconds: seconds(info, region)}

  defp pad_info({:error, _} = error, _region), do: %{status: error, wave: [], seconds: nil}
  defp pad_info(:loading, _region), do: %{status: :loading, wave: [], seconds: nil}

  # The region's peaks in @wave_bars bars, each the loudest peak it covers.
  defp wave(%{peaks: peaks, rate: rate, peak_frames: per}, %Region{} = r)
       when byte_size(peaks) > 0 do
    n = byte_size(peaks)
    from = min(trunc(r.start * rate / per), n - 1)
    to = if r.stop, do: min(ceil(r.stop * rate / per), n), else: n
    to = max(to, from + 1)

    bars =
      for b <- 0..(@wave_bars - 1) do
        lo = from + div((to - from) * b, @wave_bars)
        hi = max(from + div((to - from) * (b + 1), @wave_bars), lo + 1)
        peaks |> binary_part(lo, min(hi, n) - lo) |> :binary.bin_to_list() |> Enum.max()
      end

    if r.reverse, do: Enum.reverse(bars), else: bars
  end

  defp wave(_info, _region), do: List.duplicate(0, @wave_bars)

  defp seconds(%{frames: frames, rate: rate}, %Region{} = r) do
    stop = if r.stop, do: min(r.stop, frames / rate), else: frames / rate
    max(stop - r.start, 0.0) / :math.pow(2, r.pitch_st / 12)
  end

  defp publish(s) do
    if map_size(s.subscribers) > 0 do
      message = {:magpie_kit, snapshot(s)}
      Enum.each(Map.keys(s.subscribers), &send(&1, message))
    end

    s
  end

  # ── Saving ──────────────────────────────────────────────────────────────────

  defp put_kit(s, kit) do
    token = make_ref()
    Process.send_after(self(), {:autosave, token}, s.autosave_ms)
    sync_midi(%{s | kit: kit, save_token: token})
  end

  # The engine plays MIDI by the kit's pads and settings: a change to either
  # gives it the table again. One it refused is tried with the next change.
  defp sync_midi(s) do
    config = Magpie.Midi.Map.config(s.kit)

    cond do
      config == s.midi ->
        s

      Engine.set_midi(config) == :ok ->
        %{s | midi: config}

      true ->
        Logger.warning("Magpie.KitSession: the engine refused the MIDI table")
        %{s | midi: nil}
    end
  end

  defp save(%{save_token: nil} = s), do: {:ok, s}

  # A failed save stays pending and is tried again after the delay.
  defp save(s) do
    case Library.save_kit(s.kit) do
      {:ok, _} ->
        {:ok, %{s | save_token: nil}}

      {:error, reason} = error ->
        Logger.warning("Magpie.KitSession: autosave failed: #{inspect(reason)}")
        {error, put_kit(s, s.kit)}
    end
  end

  defp saved_or_start_kit do
    with [%{id: id} | _] <- Library.list_kits(),
         {:ok, kit} <- Library.load_kit(id) do
      kit
    else
      [] ->
        start_kit()

      {:error, reason} ->
        Logger.warning(
          "Magpie.KitSession: saved kit unreadable (#{inspect(reason)}), starting fresh"
        )

        start_kit()
    end
  end
end
