defmodule Magpie.Kit do
  @moduledoc """
  A kit: up to 4 banks of 16 pads, each pointing at a region of a library
  sample, plus step patterns. The file format is `magpie.kit/1`
  (`design/kit.schema.json`; example `design/kits/dusty-breaks.kit.json`).

  `decode/1` takes the JSON text or the decoded map and checks it against
  the schema's rules; `encode/1` and `to_json/1` give the map / JSON back.
  Field names and units are the schema's: sample regions in seconds, `swing`
  as the fraction of a 16th pair given to the first (0.5 = straight, 0.75 =
  hard shuffle), steps as `step` plus a `tick` offset at 96 PPQN.

  One rule goes beyond the schema: a step must lie inside its pattern
  (`step < length`), since a step past the end can never play.

  Banks are a map `"A".."D" => %{slot => Pad}`, patterns a list. Unknown
  keys inside pads, samples and patterns are ignored, as the schema allows;
  unknown top-level keys are rejected, as it requires.
  """

  alias __MODULE__.{Pad, Pattern, Region, Step}

  @format "magpie.kit/1"
  @bank_ids ~w(A B C D)
  @colors ~w(coral amber lime teal sky violet pink cream)
  @modes ~w(one_shot gate loop toggle keys)
  @clocks ~w(internal follow send)
  @top_keys ~w(format id name tempo swing snap midi banks patterns meta)
  # Every enum string the format allows, mapped to its atom at compile time.
  @atoms Map.new(@colors ++ @modes ++ @clocks ++ ~w(position fixed), &{&1, String.to_atom(&1)})

  @enforce_keys [:id, :name, :tempo]
  defstruct [
    :id,
    :name,
    :tempo,
    swing: 0.5,
    snap: true,
    midi: %{in_channel: :all, clock: :internal},
    banks: %{},
    patterns: [],
    meta: %{}
  ]

  @type bank_id :: String.t()
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          tempo: number(),
          swing: float(),
          snap: boolean(),
          midi: %{in_channel: :all | 1..16, clock: :internal | :follow | :send},
          banks: %{bank_id() => %{(0..15) => Pad.t()}},
          patterns: [Pattern.t()],
          meta: map()
        }

  defmodule Region do
    @moduledoc "A non-destructive region of a library sample. Times in seconds; `stop: nil` = to the end."
    @enforce_keys [:id]
    defstruct [
      :id,
      start: 0.0,
      stop: nil,
      fade_in_ms: 0,
      fade_out_ms: 0,
      gain_db: 0,
      pitch_st: 0,
      reverse: false
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            start: number(),
            stop: number() | nil,
            fade_in_ms: number(),
            fade_out_ms: number(),
            gain_db: number(),
            pitch_st: number(),
            reverse: boolean()
          }
  end

  defmodule Pad do
    @moduledoc """
    One pad. `velocity: :position` takes it from where the pad was hit,
    `:fixed` always plays `fixed_velocity`. `midi_note` triggers the pad from
    MIDI in and is sent out; in keys mode it is the root note.
    """
    @enforce_keys [:slot]
    defstruct [
      :slot,
      :name,
      :color,
      :sample,
      :midi_note,
      mode: :one_shot,
      choke: 0,
      velocity: :position,
      fixed_velocity: 100
    ]

    @type t :: %__MODULE__{
            slot: 0..15,
            name: String.t() | nil,
            color: atom() | nil,
            sample: Magpie.Kit.Region.t() | nil,
            midi_note: 0..127 | nil,
            mode: :one_shot | :gate | :loop | :toggle | :keys,
            choke: 0..3,
            velocity: :position | :fixed,
            fixed_velocity: 1..127
          }
  end

  defmodule Step do
    @moduledoc "A step that plays: `tick` is the offset from the step's start at 96 PPQN (0 when snapped)."
    @enforce_keys [:step, :vel]
    defstruct [:step, :vel, :note, tick: 0]

    @type t :: %__MODULE__{step: 0..31, vel: 1..127, tick: -12..12, note: 0..127 | nil}
  end

  defmodule Pattern do
    @moduledoc "A step pattern for one bank: `lanes` maps a slot to `%{mute: bool, steps: [Step]}`."
    @enforce_keys [:id, :bank, :length]
    defstruct [:id, :bank, :length, lanes: %{}]

    @type t :: %__MODULE__{
            id: String.t(),
            bank: String.t(),
            length: 16 | 32,
            lanes: %{(0..15) => %{mute: boolean(), steps: [Magpie.Kit.Step.t()]}}
          }
  end

  @typedoc "A problem found while decoding: where (a JSON path) and what."
  @type error :: {String.t(), String.t()}

  # ── Decode ──────────────────────────────────────────────────────────────────

  @doc "Read and decode a kit file."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [error()] | File.posix()}
  def load(path) do
    with {:ok, text} <- File.read(path), do: decode(text)
  end

  @doc """
  Decode a kit from JSON text or a decoded map. Returns every problem found,
  each as `{path, message}` (`{"banks[0].pads[2].choke", "must be 0..3"}`).
  """
  @spec decode(String.t() | map()) :: {:ok, t()} | {:error, [error()]}
  def decode(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, map} -> decode(map)
      {:error, reason} -> {:error, [{"", "not JSON: #{inspect(reason)}"}]}
    end
  end

  def decode(map) when is_map(map) do
    {kit, errors} = decode_kit(map)
    if errors == [], do: {:ok, kit}, else: {:error, Enum.reverse(errors)}
  end

  def decode(_), do: {:error, [{"", "must be an object"}]}

  defp decode_kit(m) do
    errs =
      []
      |> check(m["format"] == @format, "format", "must be \"#{@format}\"")
      |> check(
        unknown_keys(m, @top_keys) == [],
        "",
        "unknown keys: #{Enum.join(unknown_keys(m, @top_keys), ", ")}"
      )
      |> check(
        is_binary(m["id"]) and Regex.match?(~r/^[a-z0-9][a-z0-9_-]{0,63}$/, m["id"]),
        "id",
        "must match ^[a-z0-9][a-z0-9_-]{0,63}$"
      )
      |> check(string_max?(m["name"], 32), "name", "must be a string of at most 32 characters")
      |> check(number_in?(m["tempo"], 40, 240), "tempo", "must be a number 40..240")
      |> check(
        optional(m, "swing", &number_in?(&1, 0.5, 0.75)),
        "swing",
        "must be a number 0.5..0.75"
      )
      |> check(optional(m, "snap", &is_boolean/1), "snap", "must be true or false")

    {midi, errs} = decode_midi(Map.get(m, "midi", %{}), errs)
    {banks, errs} = decode_banks(m["banks"], errs)
    {patterns, errs} = decode_patterns(Map.get(m, "patterns", []), errs)

    errs = check(errs, is_map(Map.get(m, "meta", %{})), "meta", "must be an object")

    kit = %__MODULE__{
      id: m["id"],
      name: m["name"],
      tempo: m["tempo"],
      swing: num(Map.get(m, "swing", 0.5)) * 1.0,
      snap: Map.get(m, "snap", true),
      midi: midi,
      banks: banks,
      patterns: patterns,
      meta: Map.get(m, "meta", %{})
    }

    {kit, errs}
  end

  defp decode_midi(midi, errs) when is_map(midi) do
    in_channel = Map.get(midi, "in_channel", "all")
    clock = Map.get(midi, "clock", "internal")

    errs =
      errs
      |> check(
        in_channel == "all" or int_in?(in_channel, 1, 16),
        "midi.in_channel",
        "must be \"all\" or 1..16"
      )
      |> check(clock in @clocks, "midi.clock", "must be one of #{Enum.join(@clocks, ", ")}")

    in_channel = if in_channel == "all", do: :all, else: in_channel
    {%{in_channel: in_channel, clock: to_atom(clock, @clocks)}, errs}
  end

  defp decode_midi(_, errs),
    do: {%{in_channel: :all, clock: :internal}, [{"midi", "must be an object"} | errs]}

  defp decode_banks(banks, errs) when is_list(banks) and banks != [] do
    errs = check(errs, Enum.count_until(banks, 5) <= 4, "banks", "must be a list of 1..4 banks")

    banks
    |> Enum.with_index()
    |> Enum.reduce({%{}, errs}, fn {bank, i}, {acc, errs} ->
      path = "banks[#{i}]"
      id = is_map(bank) && bank["id"]

      errs =
        errs
        |> check(is_map(bank), path, "must be an object")
        |> check(id in @bank_ids, "#{path}.id", "must be one of A, B, C, D")
        |> check(not Map.has_key?(acc, id), "#{path}.id", "bank #{inspect(id)} appears twice")

      {pads, errs} = decode_pads(is_map(bank) && bank["pads"], path, errs)
      {Map.put(acc, id, pads), errs}
    end)
  end

  defp decode_banks(_, errs), do: {%{}, [{"banks", "must be a list of 1..4 banks"} | errs]}

  defp decode_pads(pads, bank_path, errs) when is_list(pads) do
    errs =
      check(
        errs,
        Enum.count_until(pads, 17) <= 16,
        "#{bank_path}.pads",
        "must be a list of at most 16 pads"
      )

    pads
    |> Enum.with_index()
    |> Enum.reduce({%{}, errs}, fn {pad, i}, {acc, errs} ->
      path = "#{bank_path}.pads[#{i}]"
      {pad, errs} = decode_pad(pad, path, errs)

      errs =
        check(
          errs,
          not Map.has_key?(acc, pad.slot),
          "#{path}.slot",
          "slot #{inspect(pad.slot)} appears twice"
        )

      {Map.put(acc, pad.slot, pad), errs}
    end)
  end

  defp decode_pads(_, bank_path, errs),
    do: {%{}, [{"#{bank_path}.pads", "must be a list of at most 16 pads"} | errs]}

  defp decode_pad(p, path, errs) when is_map(p) do
    errs =
      errs
      |> check(int_in?(p["slot"], 0, 15), "#{path}.slot", "must be 0..15")
      |> check(
        optional(p, "name", &string_max?(&1, 12)),
        "#{path}.name",
        "must be a string of at most 12 characters"
      )
      |> check(
        optional(p, "color", &(&1 in @colors)),
        "#{path}.color",
        "must be one of #{Enum.join(@colors, ", ")}"
      )
      |> check(
        optional(p, "mode", &(&1 in @modes)),
        "#{path}.mode",
        "must be one of #{Enum.join(@modes, ", ")}"
      )
      |> check(optional(p, "choke", &int_in?(&1, 0, 3)), "#{path}.choke", "must be 0..3")
      |> check(
        optional(p, "velocity", &(&1 in ~w(position fixed))),
        "#{path}.velocity",
        "must be position or fixed"
      )
      |> check(
        optional(p, "fixed_velocity", &int_in?(&1, 1, 127)),
        "#{path}.fixed_velocity",
        "must be 1..127"
      )
      |> check(
        optional(p, "midi_note", &int_in?(&1, 0, 127)),
        "#{path}.midi_note",
        "must be 0..127"
      )

    {sample, errs} =
      case p["sample"] do
        nil -> {nil, errs}
        s -> decode_region(s, "#{path}.sample", errs)
      end

    pad = %Pad{
      slot: p["slot"],
      name: p["name"],
      color: to_atom(p["color"], @colors),
      sample: sample,
      midi_note: p["midi_note"],
      mode: to_atom(Map.get(p, "mode", "one_shot"), @modes),
      choke: Map.get(p, "choke", 0),
      velocity: to_atom(Map.get(p, "velocity", "position"), ~w(position fixed)),
      fixed_velocity: Map.get(p, "fixed_velocity", 100)
    }

    {pad, errs}
  end

  defp decode_pad(_, path, errs), do: {%Pad{slot: nil}, [{path, "must be an object"} | errs]}

  defp decode_region(s, path, errs) when is_map(s) do
    errs =
      errs
      |> check(is_binary(s["id"]) and s["id"] != "", "#{path}.id", "must be a sample id")
      |> check(
        optional(s, "start", &number_in?(&1, 0, :infinity)),
        "#{path}.start",
        "must be ≥ 0 seconds"
      )
      |> check(
        optional(s, "end", &number_in?(&1, 0, :infinity)),
        "#{path}.end",
        "must be ≥ 0 seconds"
      )
      |> check(
        not (is_number(s["end"]) and is_number(Map.get(s, "start", 0)) and
               s["end"] <= Map.get(s, "start", 0)),
        "#{path}.end",
        "must be after start"
      )
      |> check(
        optional(s, "fade_in_ms", &number_in?(&1, 0, :infinity)),
        "#{path}.fade_in_ms",
        "must be ≥ 0"
      )
      |> check(
        optional(s, "fade_out_ms", &number_in?(&1, 0, :infinity)),
        "#{path}.fade_out_ms",
        "must be ≥ 0"
      )
      |> check(
        optional(s, "gain_db", &number_in?(&1, -48, 12)),
        "#{path}.gain_db",
        "must be -48..12"
      )
      |> check(
        optional(s, "pitch_st", &number_in?(&1, -24, 24)),
        "#{path}.pitch_st",
        "must be -24..24"
      )
      |> check(optional(s, "reverse", &is_boolean/1), "#{path}.reverse", "must be true or false")

    region = %Region{
      id: s["id"],
      start: Map.get(s, "start", 0.0),
      stop: s["end"],
      fade_in_ms: Map.get(s, "fade_in_ms", 0),
      fade_out_ms: Map.get(s, "fade_out_ms", 0),
      gain_db: Map.get(s, "gain_db", 0),
      pitch_st: Map.get(s, "pitch_st", 0),
      reverse: Map.get(s, "reverse", false)
    }

    {region, errs}
  end

  defp decode_region(_, path, errs), do: {nil, [{path, "must be an object"} | errs]}

  defp decode_patterns(patterns, errs) when is_list(patterns) do
    patterns
    |> Enum.with_index()
    |> Enum.map_reduce(errs, fn {p, i}, errs -> decode_pattern(p, "patterns[#{i}]", errs) end)
  end

  defp decode_patterns(_, errs), do: {[], [{"patterns", "must be a list"} | errs]}

  defp decode_pattern(p, path, errs) when is_map(p) do
    length = p["length"]

    errs =
      errs
      |> check(string_max?(p["id"], 8), "#{path}.id", "must be a string of at most 8 characters")
      |> check(p["bank"] in @bank_ids, "#{path}.bank", "must be one of A, B, C, D")
      |> check(length in [16, 32], "#{path}.length", "must be 16 or 32")

    {lanes, errs} =
      case p["lanes"] do
        lanes when is_list(lanes) ->
          lanes
          |> Enum.with_index()
          |> Enum.reduce({%{}, errs}, fn {lane, i}, {acc, errs} ->
            decode_lane(lane, "#{path}.lanes[#{i}]", length, acc, errs)
          end)

        _ ->
          {%{}, [{"#{path}.lanes", "must be a list"} | errs]}
      end

    {%Pattern{id: p["id"], bank: p["bank"], length: length, lanes: lanes}, errs}
  end

  defp decode_pattern(_, path, errs), do: {nil, [{path, "must be an object"} | errs]}

  defp decode_lane(lane, path, length, acc, errs) when is_map(lane) do
    slot = lane["slot"]

    errs =
      errs
      |> check(int_in?(slot, 0, 15), "#{path}.slot", "must be 0..15")
      |> check(not Map.has_key?(acc, slot), "#{path}.slot", "slot #{inspect(slot)} has two lanes")
      |> check(optional(lane, "mute", &is_boolean/1), "#{path}.mute", "must be true or false")

    {steps, errs} =
      case lane["steps"] do
        steps when is_list(steps) ->
          steps
          |> Enum.with_index()
          |> Enum.map_reduce(errs, fn {s, i}, errs ->
            decode_step(s, "#{path}.steps[#{i}]", length, errs)
          end)

        _ ->
          {[], [{"#{path}.steps", "must be a list"} | errs]}
      end

    {Map.put(acc, slot, %{mute: Map.get(lane, "mute", false), steps: steps}), errs}
  end

  defp decode_lane(_, path, _length, acc, errs), do: {acc, [{path, "must be an object"} | errs]}

  defp decode_step(s, path, length, errs) when is_map(s) do
    last = if length in [16, 32], do: length - 1, else: 31

    errs =
      errs
      |> check(int_in?(s["step"], 0, last), "#{path}.step", "must be 0..#{last}")
      |> check(int_in?(s["vel"], 1, 127), "#{path}.vel", "must be 1..127")
      |> check(optional(s, "tick", &int_in?(&1, -12, 12)), "#{path}.tick", "must be -12..12")
      |> check(optional(s, "note", &int_in?(&1, 0, 127)), "#{path}.note", "must be 0..127")

    {%Step{step: s["step"], vel: s["vel"], tick: Map.get(s, "tick", 0), note: s["note"]}, errs}
  end

  defp decode_step(_, path, _length, errs), do: {nil, [{path, "must be an object"} | errs]}

  # ── Encode ──────────────────────────────────────────────────────────────────

  @doc "The kit as a JSON-ready map (string keys; optional fields left out when unset)."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = kit) do
    %{
      "format" => @format,
      "id" => kit.id,
      "name" => kit.name,
      "tempo" => kit.tempo,
      "swing" => kit.swing,
      "snap" => kit.snap,
      "midi" => %{
        "in_channel" => if(kit.midi.in_channel == :all, do: "all", else: kit.midi.in_channel),
        "clock" => Atom.to_string(kit.midi.clock)
      },
      "banks" =>
        for id <- @bank_ids, Map.has_key?(kit.banks, id) do
          %{
            "id" => id,
            "pads" =>
              kit.banks[id] |> Map.values() |> Enum.sort_by(& &1.slot) |> Enum.map(&encode_pad/1)
          }
        end,
      "patterns" => Enum.map(kit.patterns, &encode_pattern/1),
      "meta" => kit.meta
    }
  end

  @doc "The kit as JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(kit), do: kit |> encode() |> JSON.encode!()

  defp encode_pad(%Pad{} = p) do
    %{
      "slot" => p.slot,
      "mode" => Atom.to_string(p.mode),
      "choke" => p.choke,
      "velocity" => Atom.to_string(p.velocity),
      "fixed_velocity" => p.fixed_velocity
    }
    |> put_some("name", p.name)
    |> put_some("color", p.color && Atom.to_string(p.color))
    |> put_some("midi_note", p.midi_note)
    |> put_some("sample", p.sample && encode_region(p.sample))
  end

  defp encode_region(%Region{} = r) do
    %{
      "id" => r.id,
      "start" => r.start,
      "fade_in_ms" => r.fade_in_ms,
      "fade_out_ms" => r.fade_out_ms,
      "gain_db" => r.gain_db,
      "pitch_st" => r.pitch_st,
      "reverse" => r.reverse
    }
    |> put_some("end", r.stop)
  end

  defp encode_pattern(%Pattern{} = p) do
    %{
      "id" => p.id,
      "bank" => p.bank,
      "length" => p.length,
      "lanes" =>
        p.lanes
        |> Enum.sort_by(fn {slot, _} -> slot end)
        |> Enum.map(fn {slot, lane} ->
          %{
            "slot" => slot,
            "mute" => lane.mute,
            "steps" =>
              Enum.map(lane.steps, fn s ->
                put_some(%{"step" => s.step, "vel" => s.vel, "tick" => s.tick}, "note", s.note)
              end)
          }
        end)
    }
  end

  # ── Addressing ──────────────────────────────────────────────────────────────

  @doc "The pad index 0..63 the engine uses for a bank and slot (`\"B\"`, 3 → 19)."
  @spec pad_index(bank_id(), 0..15) :: 0..63
  def pad_index(bank, slot) when bank in @bank_ids and slot in 0..15 do
    Enum.find_index(@bank_ids, &(&1 == bank)) * 16 + slot
  end

  @doc "The bank and slot behind an engine pad index (19 → `{\"B\", 3}`)."
  @spec bank_slot(0..63) :: {bank_id(), 0..15}
  def bank_slot(index) when index in 0..63,
    do: {Enum.at(@bank_ids, div(index, 16)), rem(index, 16)}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp check(errs, true, _path, _msg), do: errs
  defp check(errs, _false, path, msg), do: [{path, msg} | errs]

  defp optional(map, key, valid?), do: not Map.has_key?(map, key) or valid?.(map[key])

  defp unknown_keys(map, allowed),
    do: map |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort()

  defp string_max?(s, max), do: is_binary(s) and String.length(s) <= max
  defp int_in?(v, lo, hi), do: is_integer(v) and v >= lo and v <= hi
  defp number_in?(v, lo, :infinity), do: is_number(v) and v >= lo
  defp number_in?(v, lo, hi), do: is_number(v) and v >= lo and v <= hi

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0.5

  defp to_atom(nil, _allowed), do: nil
  defp to_atom(value, allowed), do: if(value in allowed, do: Map.fetch!(@atoms, value), else: nil)

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
