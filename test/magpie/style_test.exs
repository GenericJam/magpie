defmodule Magpie.StyleTest do
  use ExUnit.Case, async: true

  alias Magpie.Style

  # name: "#RRGGBB" pairs from one of the designer's token files.
  defp design_tokens(file, block) do
    text = File.read!(Path.join("design", file))
    [_, body] = Regex.run(~r/#{block}\s*(?:=|%\{|\[)(.*?)(?:\n\s*\}|\n\s*\])\n/s, text)

    for [_, name, hex] <- Regex.scan(~r/(\w+):\s*"#([0-9A-Fa-f]{6})"/, body),
        into: %{},
        do: {String.to_atom(name), 0xFF000000 + String.to_integer(hex, 16)}
  end

  describe "tokens match the designer's files" do
    test "every family colour, and no extras" do
      assert Style.colors() == design_tokens("family_style.ex", "@colors")
    end

    test "every pad colour, in palette order" do
      expected = design_tokens("magpie_style.ex", "@pad_palette")
      assert Style.pad_palette() == ~w(coral amber lime teal sky violet pink cream)a
      assert Map.new(Style.pad_palette(), &{&1, Style.pad_color(&1)}) == expected
    end

    test "the bird's colours" do
      assert Style.bird(:awake) == design_tokens("magpie_style.ex", "@bird")
    end
  end

  describe "velocity/2 (where the pad was hit)" do
    test "127 at the top edge, 19 at the bottom" do
      assert Style.velocity(0, 155) == 127
      assert Style.velocity(155, 155) == 19
    end

    test "falls linearly in between" do
      assert Style.velocity(77.5, 155) == round(127 * (1 - 0.85 * 0.5))
      assert Style.velocity(10, 100) > Style.velocity(90, 100)
    end

    test "a finger landing just outside the pad clamps to the edge" do
      assert Style.velocity(-4, 155) == 127
      assert Style.velocity(170, 155) == 19
    end
  end

  test "an idle pad is its colour at 26 % over the raised base, opaque" do
    # coral #FF9A7A over raised #221F2B at 0.26
    assert Style.pad_fill(:coral, :idle) == 0xFF5B3F40
    assert Style.pad_fill(:coral, :playing) == Style.pad_color(:coral)
  end

  test "the asleep bird is greyed but keeps its outline and legs" do
    asleep = Style.bird(:asleep)
    awake = Style.bird(:awake)
    assert asleep.body == 0xFF4A4560
    assert asleep.wing == 0xFF5A5470
    assert asleep.outline == awake.outline
  end
end
