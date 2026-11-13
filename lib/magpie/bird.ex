defmodule Magpie.Bird do
  @moduledoc """
  The magpie as `Mob.Canvas` ops: a port of `design/boards/Bird.dc.html`
  (geometry in `design/creature.md`). The board's 64 × 56 box, scaled by
  `size:` (1 = 64 × 56) with its top-left at `x:`, `y:`.

  Back to front: the pile of trinkets (proud), tail, legs, body and its
  outline, belly, wing, shoulder patch, head and its outline, beak (two
  jaws when grabbing), the trinket in the beak, eyes and pupils (closed:
  a stroke), the marks beside it (sound arcs listening, ticks playing),
  and "zZ" asleep. No gradients, no rotation.

  | mood      | pose                                                  |
  |-----------|-------------------------------------------------------|
  | `:idle`   | looking ahead                                         |
  | `:listen` | eyes bigger, pupils up-right, sound arcs by the head  |
  | `:grab`   | beak open on a pad-coloured trinket (`trinket:`)      |
  | `:play`   | bobbed up 2, wing raised, ticks either side           |
  | `:proud`  | head up, pupils down at a pile of trinkets            |
  | `:sleep`  | grey, eyes closed, "zZ"                               |
  | `:nomic`  | grey, eyes closed                                     |
  """

  import Mob.Canvas

  alias Magpie.Style

  @type mood :: :idle | :listen | :grab | :play | :proud | :sleep | :nomic

  @moods [:idle, :listen, :grab, :play, :proud, :sleep, :nomic]

  @eye_white 0xFFFFFFFF
  @pupil 0xFF17141F
  @lid 0xFFF3EFF8
  @glint 0xFFFFFFFF

  @doc "Every mood, in the board's order."
  @spec moods() :: [mood()]
  def moods, do: @moods

  @doc """
  The magpie in `mood`. Options: `x:`, `y:` (top-left, default 0),
  `size:` (scale, default 1: 64 × 56), `trinket:` (a pad colour name,
  `Magpie.Style.pad_palette/0`, for `:grab`; default `:coral`).
  """
  @spec ops(mood(), keyword()) :: [map()]
  def ops(mood, opts \\ []) when mood in @moods do
    s = Keyword.get(opts, :size, 1)
    ox = Keyword.get(opts, :x, 0)
    oy = Keyword.get(opts, :y, 0)
    c = palette(mood)
    g = geometry(mood)

    pt = fn {u, v} -> {r(ox + u * s), r(oy + v * s)} end
    len = fn v -> r(v * s) end

    fill = fn
      {:ellipse, {u, v}, rx, ry, color} ->
        {x, y} = pt.({u, v})
        ellipse(x, y, len.(rx), len.(ry), color: color, fill: true)

      {:rect, {u, v}, w, h, radius, color} ->
        {x, y} = pt.({u, v})
        rect(x, y, len.(w), len.(h), color: color, fill: true, radius: len.(radius))

      {:poly, points, color} ->
        path(Enum.map(points, pt), color: color, fill: true)
    end

    body = g.body_y
    head = g.head_y
    by = head + 2
    {hx, hy} = pt.({41, head})
    {bx, bcy} = pt.({30, body})

    List.flatten([
      Enum.map(pile(mood), fill),
      fill.({:poly, [{17, body + 4}, {1, 53}, {5, 56}, {22, body + 10}], c.wing}),
      fill.({:rect, {27, 43}, 2, 8, 1, c.legs}),
      fill.({:rect, {34, 43}, 2, 8, 1, c.legs}),
      fill.({:ellipse, {30, body}, 17, 14.5, c.body}),
      ellipse(bx, bcy, len.(17), len.(14.5), color: c.outline, width: len.(1.2)),
      fill.({:ellipse, {33, body + 7}, 11, 8.5, c.belly}),
      fill.({:ellipse, {22, body + 1}, 10, g.wing_ry, c.wing}),
      fill.({:ellipse, {24, body - 3}, 5.5, 2.4, c.belly}),
      circle(hx, hy, len.(10), color: c.body, fill: true),
      circle(hx, hy, len.(10), color: c.outline, width: len.(1.2)),
      Enum.map(beak(mood, by), &fill.({:poly, &1, c.beak})),
      trinket(mood, by, Keyword.get(opts, :trinket, :coral), fill),
      Enum.map([37, 45.5], &eye(mood, &1, head - 2, pt, len)),
      Enum.map(marks(mood), &path(Enum.map(&1, pt), mark_style(len))),
      zz(mood, pt, len)
    ])
  end

  # ── Pose ────────────────────────────────────────────────────────────────

  defp palette(mood) when mood in [:sleep, :nomic], do: Style.bird(:asleep)
  defp palette(_mood), do: Style.bird(:awake)

  defp geometry(mood) do
    bob = if mood == :play, do: -2, else: 0
    lift = if mood == :proud, do: -2, else: 0

    %{
      body_y: 30 + bob + lift,
      head_y: 18 + bob + lift * 1.5,
      wing_ry: if(mood == :play, do: 7.5, else: 6)
    }
  end

  defp look(:listen), do: {0.6, -1}
  defp look(:grab), do: {1, 0.2}
  defp look(:proud), do: {0, 1}
  defp look(_mood), do: {0, 0}

  defp beak(:grab, by) do
    [
      [{49, by - 1.5}, {57, by - 1}, {49, by + 0.5}],
      [{49, by + 1.5}, {56, by + 4}, {49, by + 3}]
    ]
  end

  defp beak(_mood, by), do: [[{49, by - 1.5}, {60, by}, {49, by + 2}]]

  defp trinket(:grab, by, color, fill) do
    [
      fill.({:rect, {56, by - 3}, 8, 8, 2, Style.pad_color(color)}),
      fill.({:rect, {58, by - 1.5}, 2.5, 2, 1, Style.alpha(@glint, 0.7)})
    ]
  end

  defp trinket(_mood, _by, _color, _fill), do: []

  defp pile(:proud) do
    for {u, v, color} <- [
          {8, 46, :coral},
          {40, 46, :lime},
          {48, 46, :sky},
          {44, 38, :amber},
          {14, 40, :violet}
        ],
        do: {:rect, {u, v}, 8, 8, 2, Style.pad_color(color)}
  end

  defp pile(_mood), do: []

  defp eye(mood, cx, cy, pt, len) when mood in [:sleep, :nomic] do
    path([pt.({cx - 3.5, cy}), pt.({cx + 3.5, cy})], color: @lid, width: len.(1.6), cap: :round)
  end

  defp eye(mood, cx, cy, pt, len) do
    {lx, ly} = look(mood)
    eye_r = if mood == :listen, do: 5.2, else: 4.5
    {ex, ey} = pt.({cx, cy})
    {px, py} = pt.({cx + lx * 2, cy + ly * 2})

    [
      circle(ex, ey, len.(eye_r), color: @eye_white, fill: true),
      circle(px, py, len.(2.2), color: @pupil, fill: true)
    ]
  end

  # The board's `M56 6 q3 4 0 8 M60 3 q5 7 0 14` (quadratic arcs as short
  # open paths) and `M8 14 v6 M12 12 v8`, `M54 34 v6 M58 32 v8`.
  defp marks(:listen), do: [quad({56, 6}, {59, 10}, {56, 14}), quad({60, 3}, {65, 10}, {60, 17})]

  defp marks(:play),
    do: [[{8, 14}, {8, 20}], [{12, 12}, {12, 20}], [{54, 34}, {54, 40}], [{58, 32}, {58, 40}]]

  defp marks(_mood), do: []

  defp quad({x0, y0}, {x1, y1}, {x2, y2}) do
    for i <- 0..6 do
      t = i / 6
      a = (1 - t) * (1 - t)
      b = 2 * (1 - t) * t
      c = t * t
      {a * x0 + b * x1 + c * x2, a * y0 + b * y1 + c * y2}
    end
  end

  defp mark_style(len),
    do: [color: Style.color(:muted), width: len.(1.6), cap: :round, join: :round]

  # "z" 7 units and "Z" 10 units tall, from x 50 at the top of the box.
  defp zz(:sleep, pt, len) do
    {x, y} = pt.({50, 0})
    {x2, _} = pt.({54.5, 0})
    muted = Style.color(:muted)

    [
      text(x, r(y + len.(3)), "z", color: muted, size: len.(7), weight: :bold),
      text(x2, y, "Z", color: muted, size: len.(10), weight: :bold)
    ]
  end

  defp zz(_mood, _pt, _len), do: []

  defp r(v), do: Float.round(v * 1.0, 2)
end
