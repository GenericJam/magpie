defmodule Magpie.Style do
  @moduledoc """
  Design tokens for Magpie: the family tokens (`design/family_style.ex`,
  FMutate's flat skin, shared with Humdinger) plus Magpie's own
  (`design/magpie_style.ex`: pad palette, pad geometry, sequencer, the bird).

  The token maps below are copied verbatim from those two files, hex strings
  and all, so they diff cleanly against the designer's copies. Colour
  accessors return ARGB integers (`0xAARRGGBB`), which node colour props and
  `Mob.Canvas` ops take directly (Mob does not parse hex strings); the
  conversion happens at compile time.

  Lime (`color(:fm)`) means "live / pressed / primary action" in chrome and
  nothing else. Violet (`color(:agent)`) marks anything driven by another
  app. Pad colours are the player's choice per pad.
  """

  import Bitwise

  # ── Family tokens (design/family_style.ex) ────────────────────────────────

  @colors %{
    bg: "#14121A",
    bg_deep: "#0E0D12",
    surface: "#1C1925",
    raised: "#221F2B",
    raised_hi: "#2A2636",
    selected: "#34304A",
    line: "#34304A",
    line_soft: "#2E2A3B",
    text: "#F3EFF8",
    text_2: "#C9C3D6",
    muted: "#A9A3B8",
    faint: "#6B6580",
    key_white: "#ECE7F2",
    key_black: "#2A2633",
    key_label_on_black: "#B9B2C8",
    led_off: "#3A3548",
    led_off_on_white: "#D3CCDD",
    fm: "#C6F24E",
    fm_dim: "#7FA62A",
    fm_tint: "#4C5A2A",
    led: "#FF9F2E",
    agent: "#A98BFF",
    agent_bg: "#2A2240",
    slider_fill: "#3A3450",
    danger: "#FF9A7A",
    danger_bg: "#4A1F1A",
    danger_text: "#FFB4A3",
    warn: "#FFB547",
    warn_line: "#7A5A22",
    info: "#8FD8FF",
    pad_coral: "#FF9A7A",
    pad_amber: "#FFB547",
    pad_sky: "#8FD8FF",
    pad_violet: "#B9A2FF",
    paper: "#F3EFF8",
    paper_2: "#E2DCEB",
    ink: "#14121A",
    ink_2: "#5E5870",
    brand_violet: "#7B5CF0",
    brand_violet_text: "#5B3FD6"
  }

  @space %{xs: 4, s: 8, m: 12, l: 16, xl: 20, xxl: 28}
  @edge_gutter 28
  @top_bottom_inset 12
  @touch 48
  @grid %{min_cell: 48, gap: 8}

  @radius %{
    key_white_top: 3,
    key_white_bottom: 9,
    key_black_top: 2,
    key_black_bottom: 7,
    button: 10,
    pad: 12,
    slider: 14,
    card: 18,
    sheet: 24,
    chip: 999,
    pill: 999
  }

  @screen_bezel 6
  @press_offset 2

  @type_scale %{
    display: %{font: :display, size: 32, weight: 800, line: 1.0},
    title: %{font: :display, size: 22, weight: 800, line: 1.1},
    body: %{font: :ui, size: 15, weight: 400, line: 1.4},
    body_strong: %{font: :ui, size: 15, weight: 600, line: 1.4},
    small: %{font: :ui, size: 13, weight: 400, line: 1.4},
    caption: %{font: :ui, size: 12, weight: 400, line: 1.45},
    control_label: %{font: :mono, size: 10, weight: 600, line: 1.0, tracking: 0.04},
    button_label: %{font: :ui, size: 11, weight: 600, line: 1.1},
    section_label: %{font: :mono, size: 11, weight: 600, line: 1.0, tracking: 0.08, upper: true}
  }

  @motion %{
    press_ms: 0,
    fine_hold_ms: 400,
    edit_hold_ms: 600,
    edge_move_ms: 500,
    rail_follow_ms: 150,
    toast_ms: 4000
  }

  @knob %{
    size: 56,
    cap_r: 15,
    track_r: 22,
    track_w: 4,
    pot_sweep_deg: 270,
    pot_full_range_pt: 200,
    encoder_ticks: 16,
    encoder_tick_r: 1.7,
    encoder_pt_per_click: 6,
    fine_factor: 0.25
  }

  # ── Magpie tokens (design/magpie_style.ex) ────────────────────────────────

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

  @bird %{
    body: "#2E2A3B",
    outline: "#4A4560",
    belly: "#F3EFF8",
    wing: "#3FA7C9",
    beak: "#8F89A3",
    legs: "#6B6580"
  }

  # Sleep / no-mic bird (design/creature.md).
  @bird_asleep %{body: "#4A4560", belly: "#8F89A3", wing: "#5A5470"}

  # ── Fonts (static instances in priv/fonts, OFL.txt) ───────────────────────
  #
  # Display: Bricolage Grotesque 800. UI: Inter. Control labels and numbers:
  # JetBrains Mono. The family's `:ui` font is the `:default` token here.

  @font_files [
    default: "Inter-Regular",
    medium: "Inter-Medium",
    semibold: "Inter-SemiBold",
    bold: "Inter-Bold",
    mono: "JetBrainsMono-Medium",
    mono_semibold: "JetBrainsMono-SemiBold",
    mono_bold: "JetBrainsMono-Bold",
    display: "BricolageGrotesque-ExtraBold"
  ]

  # ── Compile-time conversion ───────────────────────────────────────────────

  to_argb = fn tokens ->
    Map.new(tokens, fn {k, "#" <> hex} when byte_size(hex) == 6 ->
      {k, 0xFF000000 ||| String.to_integer(hex, 16)}
    end)
  end

  @argb to_argb.(@colors)
  @pad_argb to_argb.(@pad_palette)
  @bird_argb to_argb.(@bird)
  @bird_asleep_argb to_argb.(@bird_asleep)

  # ── Colour ────────────────────────────────────────────────────────────────

  @doc "A family colour token as ARGB (`color(:bg)`, `color(:fm)`, …)."
  def color(name), do: Map.fetch!(@argb, name)

  @doc "Every family colour token, as ARGB."
  def colors, do: @argb

  @doc "The pad colour names in palette order (`:coral` … `:cream`)."
  def pad_palette, do: Keyword.keys(@pad_palette)

  @doc "A pad colour at full strength, as ARGB."
  def pad_color(name), do: Map.fetch!(@pad_argb, name)

  @doc """
  A pad's fill for its state, opaque ARGB, over the `raised` pad base:
  `:idle` = the colour at 26 %, `:loop` = 55 %, `:playing` = 100 %.
  """
  def pad_fill(name, :idle), do: blend(pad_color(name), color(:raised), @pad.idle_tint)
  def pad_fill(name, :loop), do: blend(pad_color(name), color(:raised), @pad.loop_tint)
  def pad_fill(name, :playing), do: pad_color(name)

  @doc "The bird's colours (`creature.md`), as ARGB. `:asleep` for paused / no mic."
  def bird(:awake), do: @bird_argb
  def bird(:asleep), do: Map.merge(@bird_argb, @bird_asleep_argb)

  # ── Space, size, radius, motion ───────────────────────────────────────────

  def space(name), do: Map.fetch!(@space, name)
  @doc "Left/right gutter on every instrument screen (the back gesture)."
  def edge_gutter, do: @edge_gutter
  def top_bottom_inset, do: @top_bottom_inset
  @doc "Minimum touch target. The sequencer's step grid is a deliberate exception."
  def touch, do: @touch
  def grid, do: @grid
  @doc "Family radii. Magpie's pads use `pad().radius` (14), not `radius(:pad)` (12)."
  def radius(name), do: Map.fetch!(@radius, name)
  def screen_bezel, do: @screen_bezel
  def press_offset, do: @press_offset
  def type(name), do: Map.fetch!(@type_scale, name)
  def motion, do: @motion
  def knob, do: @knob

  @doc "Pad geometry and states (radius, gap, tints, grid per orientation, banks)."
  def pad, do: @pad
  @doc "Sequencer tokens (step counts, 96 PPQN, step look, tempo range, swing default)."
  def sequencer, do: @sequencer

  # ── Type ──────────────────────────────────────────────────────────────────

  @doc "Font tokens for `font:` props (`font: :display`)."
  def font_names, do: Keyword.keys(@font_files)

  @doc """
  The font family name behind a token, for `Mob.Canvas.text/4`'s `family:`.
  iOS draws canvas text in it; Android's canvas renderer uses the system face.
  """
  def font_family(token), do: Keyword.fetch!(@font_files, token)

  @doc "The app theme: the family palette and the bundled fonts."
  def theme do
    Mob.Theme.build(
      primary: color(:fm),
      on_primary: color(:ink),
      secondary: color(:raised_hi),
      on_secondary: color(:text),
      surface: color(:surface),
      surface_raised: color(:raised),
      on_surface: color(:text),
      muted: color(:muted),
      background: color(:bg),
      on_background: color(:text),
      error: color(:danger),
      on_error: color(:ink),
      border: color(:line),
      radius_sm: 8,
      radius_md: radius(:button),
      radius_lg: radius(:card),
      fonts:
        Map.new(@font_files, fn {token, name} ->
          {token, Mob.Theme.font(name, from_file: "priv/fonts/#{name}.ttf")}
        end)
    )
  end

  # ── Layout and velocity ───────────────────────────────────────────────────

  @doc """
  Grid for a usable instrument area of `w` × `h` pt (screen minus gutters and
  insets): columns, rows and the cell size that fills the area.
  """
  def grid_for(w, h) do
    %{min_cell: min, gap: gap} = @grid
    cols = max(1, div(trunc(w + gap), min + gap))
    rows = max(1, div(trunc(h + gap), min + gap))

    %{
      cols: cols,
      rows: rows,
      cell_w: (w - (cols - 1) * gap) / cols,
      cell_h: (h - (rows - 1) * gap) / rows,
      gap: gap
    }
  end

  @doc """
  Velocity from where a pad was hit: 127 at the top edge down to 19 at the
  bottom (`round(127 × (1 − 0.85 × y / height))`). `y` is measured from the
  pad's top and clamped to the pad.
  """
  def velocity(y, pad_height) when pad_height > 0 do
    frac = min(max(y / pad_height, 0.0), 1.0)
    round(@velocity.max * (1 - @velocity.floor_factor * frac))
  end

  @doc "The velocity of a pad set to \"Fixed\" when the kit doesn't say."
  def fixed_velocity, do: @velocity.fixed_default

  # ── Colour maths ──────────────────────────────────────────────────────────

  @doc """
  The 88-key colour of a MIDI note (21 = A0 … 108 = C8): hue 0° to 300°,
  saturation 72 %, as ARGB. Notes outside the piano clamp to its ends.
  (The family file returns `{h, s, l}`; Mob wants ARGB.)
  """
  def pitch_color(midi, lightness \\ 62) do
    midi = midi |> round() |> max(21) |> min(108)
    hsl((midi - 21) / 87 * 300, 0.72, lightness / 100)
  end

  @doc "An opaque ARGB colour from hue (degrees), saturation and lightness (0..1)."
  def hsl(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    hp = h / 60
    x = c * (1 - abs(fmod(hp, 2) - 1))

    {r, g, b} =
      cond do
        hp < 1 -> {c, x, 0}
        hp < 2 -> {x, c, 0}
        hp < 3 -> {0, c, x}
        hp < 4 -> {0, x, c}
        hp < 5 -> {x, 0, c}
        true -> {c, 0, x}
      end

    m = l - c / 2
    argb(255, channel(r + m), channel(g + m), channel(b + m))
  end

  @doc "Replace a colour's alpha (0..1)."
  def alpha(color, a), do: (color &&& 0x00FFFFFF) ||| round(a * 255) <<< 24

  @doc "`fg` at opacity `a` (0..1) over an opaque `bg`, as an opaque ARGB colour."
  def blend(fg, bg, a) do
    mix = fn shift -> round((fg >>> shift &&& 0xFF) * a + (bg >>> shift &&& 0xFF) * (1 - a)) end
    argb(255, mix.(16), mix.(8), mix.(0))
  end

  defp argb(a, r, g, b), do: a <<< 24 ||| r <<< 16 ||| g <<< 8 ||| b
  defp channel(v), do: v |> Kernel.*(255) |> round() |> max(0) |> min(255)
  defp fmod(a, b), do: a - b * Float.floor(a / b)
end
