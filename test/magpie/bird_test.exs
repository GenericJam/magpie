defmodule Magpie.BirdTest do
  use ExUnit.Case, async: true

  alias Magpie.{Bird, Style}

  # The extent of one op: {min_x, min_y, max_x, max_y}.
  defp extent(%{op: :rect, x: x, y: y, w: w, h: h}), do: {x, y, x + w, y + h}
  defp extent(%{op: :circle, x: x, y: y, r: r}), do: {x - r, y - r, x + r, y + r}
  defp extent(%{op: :ellipse, x: x, y: y, rx: rx, ry: ry}), do: {x - rx, y - ry, x + rx, y + ry}

  defp extent(%{op: :path, points: points}) do
    xs = Enum.map(points, &hd/1)
    ys = Enum.map(points, &List.last/1)
    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  # Canvas text grows down from y; ≈ 0.6 em per character.
  defp extent(%{op: :text, x: x, y: y, size: size, text: text}),
    do: {x, y, x + String.length(text) * size * 0.6, y + size}

  for size <- [0.75, 1, 3.5] do
    test "every mood stays inside its 64 × 56 box at size #{size}" do
      size = unquote(size)
      {x0, y0} = {10, 20}

      for mood <- Bird.moods() do
        ops = Bird.ops(mood, x: x0, y: y0, size: size)
        assert ops != []

        for op <- ops do
          {a, b, c, d} = extent(op)
          slack = 0.05

          assert a >= x0 - slack and b >= y0 - slack and c <= x0 + 64 * size + slack and
                   d <= y0 + 56 * size + slack,
                 "#{mood} #{inspect(op)} leaves the box"
        end
      end
    end
  end

  test "grabbing holds a trinket in the chosen pad colour; no-mic is the asleep palette" do
    colors = fn ops -> MapSet.new(ops, & &1.color) end

    assert Style.pad_color(:sky) in colors.(Bird.ops(:grab, trinket: :sky))
    refute Style.pad_color(:sky) in colors.(Bird.ops(:idle))
    assert Style.pad_color(:coral) in colors.(Bird.ops(:grab))

    asleep = Style.bird(:asleep)
    nomic = colors.(Bird.ops(:nomic))
    assert asleep.body in nomic and asleep.wing in nomic
    refute Style.bird(:awake).wing in nomic
  end
end
