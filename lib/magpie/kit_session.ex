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
  - **Live recording into a pattern** (`set_recording/1`, the snapshot's
    `recording`): armed, the session subscribes to the engine and writes
    each hit (`{:magpie_audio, :hit, pad, %Magpie.Kit.Step{}}`: a touch, a
    MIDI note) into the pad's lane of its bank's selected pattern while the
    engine plays that pattern, replacing the step at that index: `tick: 0`
    with Snap on, the hit's tick off. Hits on pads the kit doesn't have, on
    another bank or pattern, or with the engine stopped are dropped. The
    edit goes to the engine at once (`at: :now`) and is autosaved. It
    disarms on the engine's `{:magpie_audio, :transport, :stopped, nil}`,
    and when the Engine exits (monitored while armed).

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
  alias Magpie.Kit.{Pad, Pattern, Region, Step}

  @start_kit_path Path.expand("../../design/kits/dusty-breaks.kit.json", __DIR__)
  @external_resource @start_kit_path
  @start_kit_json File.read!(@start_kit_path)

  @banks Style.pad().banks
  @lengths Style.sequencer().steps
  @max_patterns 4
  @wave_bars Style.pad().wave_bars
  @autosave_ms 1_000
  # A sample the engine couldn't unload yet, or a MIDI table it refused
  # (its command queue full), is tried again after this.
  @retry_ms 200

  defmodule Snapshot do
    @moduledoc """
    What a screen needs to draw the kit: the kit, the selected pattern id per
    bank (`pattern_ids`), whether live recording is armed (`recording`), and
    per pad index with a sample (`Magpie.Kit.pad_index/2`) its `status`
    (`:loading`, `:ready` or `{:error, reason}`: not in the library, failed
    to load, refused by the engine), its `wave`
    (#{Magpie.Style.pad().wave_bars} peaks 0..255 over the pad's region,
    reversed with it; empty until the sample is loaded) and `seconds` (the
    region's length at its pitch; nil until loaded).
    """
    defstruct [:kit, pads: %{}, pattern_ids: %{}, recording: false]

    @type pad_info :: %{
            status: :loading | :ready | {:error, term()},
            wave: [0..255],
            seconds: float() | nil
          }
    @type t :: %__MODULE__{
            kit: Magpie.Kit.t(),
            pads: %{(0..63) => pad_info()},
            pattern_ids: %{Magpie.Kit.bank_id() => String.t()},
            recording: boolean()
          }
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
    pattern_ids: %{},
    # Live recording armed, and the Engine's monitor meanwhile.
    recording: false,
    engine_ref: nil,
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

  @doc "Set the kit's tempo (40..240 bpm). Applies to the engine first."
  @spec set_tempo(number()) :: :ok | {:error, term()}
  def set_tempo(bpm) when is_number(bpm) and bpm >= 40 and bpm <= 240,
    do: GenServer.call(__MODULE__, {:tempo, bpm})

  def set_tempo(_bpm), do: {:error, {:invalid, :tempo}}

  @doc "Set the kit's swing (0.5..0.75). Applies to the engine first."
  @spec set_swing(number()) :: :ok | {:error, term()}
  def set_swing(swing) when is_number(swing) and swing >= 0.5 and swing <= 0.75,
    do: GenServer.call(__MODULE__, {:swing, swing})

  def set_swing(_swing), do: {:error, {:invalid, :swing}}

  @doc """
  The patterns of `bank` (1..#{@max_patterns} of them; an empty 16-step
  `\"<bank>1\"` when the kit has none).
  """
  @spec patterns(Kit.t() | Snapshot.t(), Kit.bank_id()) :: [Pattern.t()]
  def patterns(%Snapshot{kit: kit}, bank), do: patterns(kit, bank)

  def patterns(%Kit{patterns: patterns}, bank) when bank in @banks do
    case Enum.filter(patterns, &(&1.bank == bank)) do
      [] -> [%Pattern{id: "#{bank}1", bank: bank, length: 16}]
      found -> found
    end
  end

  @doc """
  Select pattern `id` for `bank`. While the engine plays `bank`, queues the
  pattern for the next bar (`at: :bar`) first; the pattern already playing
  is left playing (a pattern queued instead of it is dropped).
  """
  @spec select_pattern(Kit.bank_id(), String.t()) :: :ok | {:error, term()}
  def select_pattern(bank, id) when bank in @banks and is_binary(id),
    do: GenServer.call(__MODULE__, {:select_pattern, bank, id})

  def select_pattern(bank, _id) when bank not in @banks, do: {:error, {:invalid, :bank}}
  def select_pattern(_bank, _id), do: {:error, {:invalid, :pattern}}

  @doc """
  Add an empty 16-step pattern to `bank` (up to #{@max_patterns}:
  `\"<bank>1\"..\"<bank>4\"`) and select it. While the engine plays `bank`,
  queues the new pattern for the next bar (`at: :bar`) first.
  """
  @spec add_pattern(Kit.bank_id()) :: :ok | {:error, term()}
  def add_pattern(bank) when bank in @banks,
    do: GenServer.call(__MODULE__, {:add_pattern, bank})

  def add_pattern(_bank), do: {:error, {:invalid, :bank}}

  @doc """
  Set the length (16 or 32 steps) of `bank`'s selected pattern. Shrinking
  drops steps at index >= `length`. Applies `at: :now` to the engine first
  when the edited pattern is playing.
  """
  @spec set_pattern_length(Kit.bank_id(), 16 | 32) :: :ok | {:error, term()}
  def set_pattern_length(bank, length) when bank in @banks and length in @lengths,
    do: GenServer.call(__MODULE__, {:pattern_length, bank, length})

  def set_pattern_length(bank, _length) when bank not in @banks,
    do: {:error, {:invalid, :bank}}

  def set_pattern_length(_bank, _length), do: {:error, {:invalid, :length}}

  @doc """
  Toggle step `step` (0..length-1) on `slot` (0..15, must be a loaded pad in
  `bank`) in `bank`'s selected pattern: removes the step if present, else adds
  it at `vel` (1..127, default 100). Applies `at: :now` to the engine first
  when the edited pattern is playing.
  """
  @spec toggle_step(Kit.bank_id(), 0..15, non_neg_integer(), 1..127) :: :ok | {:error, term()}
  def toggle_step(bank, slot, step, vel \\ 100)

  def toggle_step(bank, _slot, _step, _vel) when bank not in @banks,
    do: {:error, {:invalid, :bank}}

  def toggle_step(_bank, slot, _step, _vel) when slot not in 0..15,
    do: {:error, {:invalid, :slot}}

  def toggle_step(_bank, _slot, _step, vel) when vel not in 1..127,
    do: {:error, {:invalid, :vel}}

  def toggle_step(bank, slot, step, vel) when is_integer(step) and step >= 0,
    do: GenServer.call(__MODULE__, {:toggle_step, bank, slot, step, vel})

  def toggle_step(_bank, _slot, _step, _vel), do: {:error, {:invalid, :step}}

  @doc """
  Set the velocity (1..127) of `step` (0..length-1) on `slot` (0..15, must be
  a loaded pad in `bank`) in `bank`'s selected pattern, creating the step if
  not present. Applies `at: :now` to the engine first when the edited pattern
  is playing.
  """
  @spec set_step_velocity(Kit.bank_id(), 0..15, non_neg_integer(), 1..127) ::
          :ok | {:error, term()}
  def set_step_velocity(bank, _slot, _step, _vel) when bank not in @banks,
    do: {:error, {:invalid, :bank}}

  def set_step_velocity(_bank, slot, _step, _vel) when slot not in 0..15,
    do: {:error, {:invalid, :slot}}

  def set_step_velocity(_bank, _slot, _step, vel) when vel not in 1..127,
    do: {:error, {:invalid, :vel}}

  def set_step_velocity(bank, slot, step, vel) when is_integer(step) and step >= 0,
    do: GenServer.call(__MODULE__, {:step_velocity, bank, slot, step, vel})

  def set_step_velocity(_bank, _slot, _step, _vel), do: {:error, {:invalid, :step}}

  @doc """
  The kit's MIDI settings: `in_channel` (`:all` or 1..16; notes out go on
  it, or 1 with `:all`) and `clock` (`:internal` or `:send` a MIDI clock).
  Either key may be left out. `:follow` is refused: Magpie doesn't follow
  an incoming clock yet (a kit file saying `follow` still loads, keeps it
  and plays on the internal clock; see `Magpie.Midi.Map.config/1`).
  """
  @spec set_midi(map()) :: :ok | {:error, {:invalid, atom()}}
  def set_midi(changes) when is_map(changes) do
    cond do
      not (Map.get(changes, :in_channel, :all) == :all or Map.get(changes, :in_channel) in 1..16) ->
        {:error, {:invalid, :in_channel}}

      Map.get(changes, :clock, :internal) not in [:internal, :send] ->
        {:error, {:invalid, :clock}}

      true ->
        GenServer.call(__MODULE__, {:midi, Map.take(changes, [:in_channel, :clock])})
    end
  end

  @doc """
  Arm (`true`) or disarm (`false`) live recording into the patterns (see
  the moduledoc). Arming needs the engine playing: `{:error, :not_playing}`
  otherwise. The session disarms by itself once the engine stops.
  """
  @spec set_recording(boolean()) :: :ok | {:error, :not_playing}
  def set_recording(on) when is_boolean(on), do: GenServer.call(__MODULE__, {:recording, on})

  @doc "Save now if a change is waiting for the autosave."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc """
  The pattern bank `bank` plays: from a `%Snapshot{}` the bank's selected
  pattern; from a `%Kit{}` its first one for the bank; else an empty
  16-step one.
  """
  @spec pattern(Kit.t() | Snapshot.t(), Kit.bank_id()) :: Pattern.t()
  def pattern(%Snapshot{kit: kit, pattern_ids: ids}, bank) when bank in @banks do
    pattern_by_id(kit, bank, Map.get(ids, bank))
  end

  def pattern(%Kit{patterns: patterns}, bank) do
    Enum.find(patterns, &(&1.bank == bank)) ||
      %Pattern{id: "#{bank}1", bank: bank, length: 16}
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

  def handle_call({:tempo, bpm}, _from, s) do
    case Engine.set_tempo(bpm) do
      :ok -> {:reply, :ok, s |> put_kit(%{s.kit | tempo: bpm}) |> publish()}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:swing, swing}, _from, s) do
    case Engine.set_swing(swing) do
      :ok -> {:reply, :ok, s |> put_kit(%{s.kit | swing: swing}) |> publish()}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:select_pattern, bank, id}, _from, s) do
    case Enum.find(patterns(s.kit, bank), &(&1.id == id)) do
      nil ->
        {:reply, {:error, {:invalid, :pattern}}, s}

      pattern ->
        case sync_switched_pattern(pattern) do
          :ok ->
            s = %{s | pattern_ids: Map.put(s.pattern_ids, bank, pattern.id)}
            {:reply, :ok, publish(s)}

          {:error, _} = error ->
            {:reply, error, s}
        end
    end
  end

  def handle_call({:add_pattern, bank}, _from, s) do
    existing = patterns(s.kit, bank)

    case next_pattern_id(bank, existing) do
      nil ->
        {:reply, {:error, {:invalid, :pattern}}, s}

      new_id ->
        new_pattern = %Pattern{id: new_id, bank: bank, length: 16, lanes: %{}}
        add_bank_pattern(s, bank, existing, new_pattern)
    end
  end

  def handle_call({:pattern_length, bank, length}, _from, s) do
    cur = selected_pattern(s, bank)

    lanes =
      Enum.reduce(cur.lanes, %{}, fn {slot, lane}, acc ->
        steps = Enum.filter(lane.steps, &(&1.step < length))
        put_lane(acc, slot, %{lane | steps: steps})
      end)

    reply(apply_pattern_edit(s, %{cur | length: length, lanes: lanes}))
  end

  def handle_call({:toggle_step, bank, slot, step, vel}, _from, s) do
    cur = selected_pattern(s, bank)

    cond do
      not loaded_pad?(s.kit, bank, slot) ->
        {:reply, {:error, {:invalid, :slot}}, s}

      step >= cur.length ->
        {:reply, {:error, {:invalid, :step}}, s}

      true ->
        lane = Map.get(cur.lanes, slot, %{mute: false, steps: []})

        steps =
          if Enum.any?(lane.steps, &(&1.step == step)) do
            Enum.reject(lane.steps, &(&1.step == step))
          else
            Enum.sort_by([%Step{step: step, vel: vel, tick: 0} | lane.steps], & &1.step)
          end

        lanes = put_lane(cur.lanes, slot, %{lane | steps: steps})
        reply(apply_pattern_edit(s, %{cur | lanes: lanes}))
    end
  end

  def handle_call({:step_velocity, bank, slot, step, vel}, _from, s) do
    cur = selected_pattern(s, bank)

    cond do
      not loaded_pad?(s.kit, bank, slot) ->
        {:reply, {:error, {:invalid, :slot}}, s}

      step >= cur.length ->
        {:reply, {:error, {:invalid, :step}}, s}

      true ->
        lane = Map.get(cur.lanes, slot, %{mute: false, steps: []})

        steps =
          case Enum.split_with(lane.steps, &(&1.step == step)) do
            {[existing | _], rest} ->
              Enum.sort_by([%{existing | vel: vel} | rest], & &1.step)

            {[], rest} ->
              Enum.sort_by([%Step{step: step, vel: vel, tick: 0} | rest], & &1.step)
          end

        lanes = put_lane(cur.lanes, slot, %{lane | steps: steps})
        reply(apply_pattern_edit(s, %{cur | lanes: lanes}))
    end
  end

  def handle_call({:midi, changes}, _from, s),
    do: {:reply, :ok, s |> put_kit(%{s.kit | midi: Map.merge(s.kit.midi, changes)}) |> publish()}

  def handle_call({:recording, true}, _from, %{recording: true} = s), do: {:reply, :ok, s}

  # Subscribed before reading `playing`, so no `:stopped` falls between the
  # two; what the engine sent before (a `:stopped` or hits from an earlier
  # subscription) is dropped, `playing` covers it.
  def handle_call({:recording, true}, _from, s) do
    :ok = Engine.subscribe()
    drop_engine_messages()

    if Engine.state().playing do
      s = %{s | recording: true, engine_ref: Process.monitor(Engine)}
      {:reply, :ok, publish(s)}
    else
      :ok = Engine.unsubscribe()
      {:reply, {:error, :not_playing}, s}
    end
  end

  def handle_call({:recording, false}, _from, %{recording: false} = s), do: {:reply, :ok, s}
  def handle_call({:recording, false}, _from, s), do: {:reply, :ok, s |> disarm() |> publish()}

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

  # The Engine went away: its sequencer with it.
  def handle_info({:DOWN, ref, :process, _pid, _}, %{engine_ref: ref} = s) when ref != nil,
    do: {:noreply, publish(%{s | recording: false, engine_ref: nil})}

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

  def handle_info(:sync_midi, s), do: {:noreply, sync_midi(s)}

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

  # ── Live recording ──────────────────────────────────────────────────────────

  def handle_info({:magpie_audio, :hit, index, %Step{} = hit}, %{recording: true} = s)
      when index in 0..63 do
    {bank, slot} = Kit.bank_slot(index)
    %Pattern{id: id} = cur = selected_pattern(s, bank)

    case Engine.state() do
      %{playing: false} ->
        {:noreply, s |> disarm() |> publish()}

      %{pattern: %Pattern{id: ^id, bank: ^bank}} ->
        {:noreply, record_hit(s, cur, slot, hit)}

      _other_pattern ->
        {:noreply, s}
    end
  end

  def handle_info({:magpie_audio, :transport, :stopped, _}, %{recording: true} = s),
    do: {:noreply, s |> disarm() |> publish()}

  # The rest of what the engine forwards while armed (playheads, voices,
  # meters…), and hits queued before disarming.
  def handle_info({:magpie_audio, _kind, _a, _b}, s), do: {:noreply, s}
  def handle_info({:magpie_audio, _kind, _a, _b, _c}, s), do: {:noreply, s}

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
        Process.send_after(self(), {:unload, id}, @retry_ms)
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

  # ── Patterns ────────────────────────────────────────────────────────────────

  defp pattern_by_id(%Kit{patterns: patterns}, bank, selected_id) do
    bank_patterns = Enum.filter(patterns, &(&1.bank == bank))

    (selected_id && Enum.find(bank_patterns, &(&1.id == selected_id))) ||
      List.first(bank_patterns) ||
      %Pattern{id: "#{bank}1", bank: bank, length: 16}
  end

  defp selected_pattern(s, bank),
    do: pattern_by_id(s.kit, bank, Map.get(s.pattern_ids, bank))

  defp loaded_pad?(%Kit{banks: banks}, bank, slot),
    do: match?(%Pad{sample: %Region{}}, get_in(banks, [bank, slot]))

  defp put_lane(lanes, slot, %{mute: false, steps: []}), do: Map.delete(lanes, slot)
  defp put_lane(lanes, slot, lane), do: Map.put(lanes, slot, lane)

  defp apply_pattern_edit(s, %Pattern{id: id, bank: bank} = updated) do
    case sync_edited_pattern(updated) do
      :ok ->
        patterns = upsert_pattern(s.kit.patterns, updated)

        s =
          %{s | pattern_ids: Map.put(s.pattern_ids, bank, id)}
          |> put_kit(%{s.kit | patterns: patterns})
          |> publish()

        {:ok, s}

      {:error, _} = error ->
        {error, s}
    end
  end

  # A hit on `slot` of the playing selected pattern `cur` becomes its step
  # at that index (replacing one there): on the grid with Snap on, at the
  # hit's tick off. Pads the kit doesn't have are left out.
  defp record_hit(s, %Pattern{bank: bank} = cur, slot, %Step{} = hit) do
    if loaded_pad?(s.kit, bank, slot) and hit.step < cur.length do
      lane = Map.get(cur.lanes, slot, %{mute: false, steps: []})
      step = if s.kit.snap, do: %{hit | tick: 0}, else: hit
      steps = Enum.sort_by([step | Enum.reject(lane.steps, &(&1.step == hit.step))], & &1.step)

      case apply_pattern_edit(s, %{cur | lanes: put_lane(cur.lanes, slot, %{lane | steps: steps})}) do
        {:ok, s} ->
          s

        {{:error, reason}, s} ->
          Logger.warning(
            "Magpie.KitSession: recording a hit on #{bank} #{slot}: #{inspect(reason)}"
          )

          s
      end
    else
      s
    end
  end

  defp disarm(s) do
    :ok = Engine.unsubscribe()
    Process.demonitor(s.engine_ref, [:flush])
    %{s | recording: false, engine_ref: nil}
  end

  defp drop_engine_messages do
    receive do
      {:magpie_audio, _kind, _a, _b} -> drop_engine_messages()
      {:magpie_audio, _kind, _a, _b, _c} -> drop_engine_messages()
    after
      0 -> :ok
    end
  end

  # An edit of the playing pattern goes in at once (`:now`, same position).
  # `:now` also drops a switch the engine has queued for the bar (the
  # Engine and the native sequencer alike), so a queued pattern is queued
  # again after it.
  defp sync_edited_pattern(%Pattern{id: id, bank: bank} = pattern) do
    case Engine.state() do
      %{playing: true, pending: %Pattern{id: ^id, bank: ^bank}} ->
        Engine.set_pattern(pattern, at: :bar)

      %{playing: true, pattern: %Pattern{id: ^id, bank: ^bank}, pending: pending} ->
        with :ok <- Engine.set_pattern(pattern, at: :now), do: requeue(pending)

      _ ->
        :ok
    end
  end

  defp requeue(nil), do: :ok

  defp requeue(%Pattern{} = pending) do
    with {:error, reason} <- Engine.set_pattern(pending, at: :bar) do
      Logger.warning(
        "Magpie.KitSession: queued pattern #{pending.id} lost to an edit: #{inspect(reason)}"
      )
    end

    :ok
  end

  # Selecting a pattern while its bank plays: a different one takes over at
  # the bar; the playing one is left alone (queued at the bar it would
  # restart from step 0), and one queued instead of it is dropped (`:now`
  # keeps the position).
  defp sync_switched_pattern(%Pattern{id: id, bank: bank} = pattern) do
    case Engine.state() do
      %{playing: true, pattern: %Pattern{id: ^id, bank: ^bank}, pending: nil} ->
        :ok

      %{playing: true, pattern: %Pattern{id: ^id, bank: ^bank}, pending: %Pattern{bank: ^bank}} ->
        Engine.set_pattern(pattern, at: :now)

      %{playing: true, pending: %Pattern{bank: ^bank}} ->
        Engine.set_pattern(pattern, at: :bar)

      %{playing: true, pending: nil, pattern: %Pattern{bank: ^bank}} ->
        Engine.set_pattern(pattern, at: :bar)

      _ ->
        :ok
    end
  end

  defp upsert_pattern(patterns, %Pattern{id: id, bank: bank} = updated) do
    if Enum.any?(patterns, &(&1.bank == bank and &1.id == id)),
      do: Enum.map(patterns, &replace_pattern(&1, updated)),
      else: patterns ++ [updated]
  end

  defp replace_pattern(%Pattern{id: id, bank: bank}, %Pattern{id: id, bank: bank} = updated),
    do: updated

  defp replace_pattern(other, _updated), do: other

  defp next_pattern_id(_bank, existing) when length(existing) >= @max_patterns, do: nil

  defp next_pattern_id(bank, existing) do
    used = MapSet.new(existing, & &1.id)
    Enum.find(for(n <- 1..@max_patterns, do: "#{bank}#{n}"), &(not MapSet.member?(used, &1)))
  end

  defp add_bank_pattern(s, bank, existing, %Pattern{id: new_id} = new_pattern) do
    case sync_switched_pattern(new_pattern) do
      :ok ->
        patterns = append_bank_pattern(s.kit.patterns, bank, existing, new_pattern)

        s =
          %{s | pattern_ids: Map.put(s.pattern_ids, bank, new_id)}
          |> put_kit(%{s.kit | patterns: patterns})
          |> publish()

        {:reply, :ok, s}

      {:error, _} = error ->
        {:reply, error, s}
    end
  end

  defp append_bank_pattern(patterns, bank, existing, new_pattern) do
    patterns =
      Enum.reduce(existing, patterns, fn p, acc ->
        if Enum.any?(acc, &(&1.bank == bank and &1.id == p.id)), do: acc, else: acc ++ [p]
      end)

    patterns ++ [new_pattern]
  end

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

    %Snapshot{kit: s.kit, pads: pads, pattern_ids: pattern_ids(s), recording: s.recording}
  end

  defp pattern_ids(s) do
    Map.new(@banks, fn bank -> {bank, selected_pattern(s, bank).id} end)
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
  # gives it the table again. One it refused is tried again after a delay,
  # with the kit's table as it is then. It stops once the engine takes it.
  defp sync_midi(s) do
    config = Magpie.Midi.Map.config(s.kit)

    cond do
      config == s.midi ->
        s

      Engine.set_midi(config) == :ok ->
        %{s | midi: config}

      true ->
        Logger.warning("Magpie.KitSession: the engine refused the MIDI table")
        Process.send_after(self(), :sync_midi, @retry_ms)
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
