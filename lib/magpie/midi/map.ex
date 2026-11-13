defmodule Magpie.Midi.Map do
  @moduledoc """
  The kit's MIDI, compiled for the engine (`Magpie.Engine.set_midi/1`): which
  pads a note plays, which note a pad sends, the channels and the clock
  mode. The renderer applies it to every incoming message without asking
  the BEAM (`c_src/sampler.c`, "MIDI in"); `route/2` is the same rule in
  Elixir (the Fake engine plays through it, and it documents the rule).

  ## The rule

  - A note plays every pad, in any bank, whose `midi_note` it is, unless
    that pad is in keys mode. Several pads on one note all play (layers).
  - A note no such pad claims goes to every keys pad, which plays it
    chromatically from its root (its `midi_note`, 60 without one). So a
    drum kit stays a drum kit and a keys pad takes the rest of the keyboard;
    move a pad's note (the PadSheet) to free one.
  - Only pads with a sample take part.
  - Note-on passes its velocity; velocity 0 is a note-off. Note-off
    releases gate, loop and keys pads (keys: that note's voice); one-shots
    ring on and toggles ignore it.
  - `in_channel` `:all` takes every channel; 1..16 only that one.
  - Out: a pad with a `midi_note` sends it (a keys pad the note it plays) on
    the out channel: `in_channel`, or 1 with `:all`.
  """

  alias Magpie.Kit
  alias Magpie.Kit.{Pad, Region}

  @type pad :: 0..63

  @type t :: %{
          in_channel: :all | 1..16,
          out_channel: 1..16,
          clock: :internal | :follow | :send,
          notes: %{(0..127) => [pad()]},
          out_notes: %{pad() => 0..127},
          modes: %{pad() => :one_shot | :gate | :loop | :toggle | :keys}
        }

  @typedoc "What a message does: the `Magpie.Engine` live calls it amounts to."
  @type action ::
          {:trigger, pad(), 1..127}
          | {:note_on, pad(), 0..127, 1..127}
          | {:release, pad()}
          | {:note_off, pad(), 0..127}

  @doc "Compile `kit`'s pads and `midi` settings."
  @spec config(Kit.t()) :: t()
  def config(%Kit{midi: midi} = kit) do
    pads =
      for {bank, slots} <- kit.banks,
          {slot, %Pad{sample: %Region{}} = pad} <- slots,
          do: {Kit.pad_index(bank, slot), pad}

    {keys, others} = Enum.split_with(pads, fn {_, pad} -> pad.mode == :keys end)
    keys = keys |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    claimed =
      others
      |> Enum.filter(fn {_, pad} -> pad.midi_note != nil end)
      |> Enum.group_by(fn {_, pad} -> pad.midi_note end, &elem(&1, 0))

    notes =
      for note <- 0..127,
          into: %{},
          do: {note, claimed |> Map.get(note, keys) |> Enum.sort()}

    %{
      in_channel: midi.in_channel,
      out_channel: if(midi.in_channel == :all, do: 1, else: midi.in_channel),
      clock: midi.clock,
      notes: Map.reject(notes, fn {_, list} -> list == [] end),
      out_notes: for({i, %Pad{midi_note: n}} <- pads, n != nil, into: %{}, do: {i, n}),
      modes: Map.new(pads, fn {i, pad} -> {i, pad.mode} end)
    }
  end

  @doc "The pads note `note` plays."
  @spec pads(t(), 0..127) :: [pad()]
  def pads(%{notes: notes}, note), do: Map.get(notes, note, [])

  @doc """
  What one message (`{status, data1, data2}`) does under the rule. Messages
  on another channel, and anything but notes, do nothing here (the clock
  and CC 120 / 123 are the engine's).
  """
  @spec route(t(), {0..255, 0..127, 0..127}) :: [action()]
  def route(config, {status, d1, d2}) when status in 0x80..0xEF do
    if channel_ok?(config.in_channel, Bitwise.band(status, 0x0F) + 1),
      do: note(config, Bitwise.band(status, 0xF0), d1, d2),
      else: []
  end

  def route(_config, _message), do: []

  defp channel_ok?(:all, _channel), do: true
  defp channel_ok?(wanted, channel), do: wanted == channel

  defp note(config, 0x90, note, vel) when vel > 0 do
    for pad <- pads(config, note) do
      if config.modes[pad] == :keys, do: {:note_on, pad, note, vel}, else: {:trigger, pad, vel}
    end
  end

  defp note(config, type, note, _vel) when type in [0x80, 0x90] do
    for pad <- pads(config, note),
        action = off(config.modes[pad], pad, note),
        action != nil,
        do: action
  end

  defp note(_config, _type, _d1, _d2), do: []

  defp off(:keys, pad, note), do: {:note_off, pad, note}
  defp off(mode, pad, _note) when mode in [:gate, :loop], do: {:release, pad}
  defp off(_mode, _pad, _note), do: nil
end
