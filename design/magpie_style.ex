defmodule Magpie.Style do
  @moduledoc """
  Magpie-specific tokens on top of the family tokens in `FMutate.Style`
  (copy `family_style.ex` as the base; rename the module if you prefer `Family.Style`).
  """

  # Pad colours the player can pick. Idle pads show the colour at `pad_idle_tint` over
  # `raised`; playing pads show it at 100 % with `ink` text.
  @pad_palette [
    coral: "#FF9A7A",
    amber: "#FFB547",
    lime: "#C6F24E",
    teal: "#5ED6C0",
    sky: "#8FD8FF",
    violet: "#B9A2FF",
    pink: "#FF8FC7",
    cream: "#F3EBD6"
  ]

  @pad %{
    radius: 14,
    gap: 8,
    idle_tint: 0.26,
    loop_tint: 0.55,
    press_offset: 2,
    empty_outline: 2,
    wave_bars: 12,
    long_press_ms: 600,
    # landscape 8 × 2, portrait (bus mode) 4 × 4
    grid: %{landscape: {8, 2}, portrait: {4, 4}},
    banks: ~w(A B C D)
  }

  @velocity %{max: 127, floor_factor: 0.85, fixed_default: 100}

  @sequencer %{
    steps: [16, 32],
    ppqn: 96,
    step_radius: 7,
    step_gap: 3,
    lane_min_height: 48,
    min_fill: 0.25,
    tempo_range: 40..240,
    swing_default: 0.54
  }

  # The magpie's own colours (see creature.md)
  @bird %{
    body: "#2E2A3B",
    outline: "#4A4560",
    belly: "#F3EFF8",
    wing: "#3FA7C9",
    beak: "#8F89A3",
    legs: "#6B6580"
  }

  def pad_palette, do: @pad_palette
  def pad_color(name), do: Keyword.fetch!(@pad_palette, name)
  def pad, do: @pad
  def sequencer, do: @sequencer
  def bird, do: @bird

  @doc "Velocity from where a pad was hit. `y` is measured from the pad's top edge."
  def velocity(y, pad_height) when pad_height > 0 do
    frac = min(max(y / pad_height, 0.0), 1.0)
    round(@velocity.max * (1 - @velocity.floor_factor * frac))
  end
end
