defmodule Magpie.Test.Screens do
  @moduledoc """
  Helpers for screen tests (`import Magpie.Test.Screens`).

  A screen mounted with `Mob.ScreenCase.mount_screen/2` runs in the test
  process, so what `Magpie.Engine` forwards to it lands in the test's
  mailbox: `pump/1` hands those messages to the screen. Queries:
  `canvas_ops/2`, `canvas_texts/2`, `texts/1`, and
  `assert_every_tap_held/1` (MOB-509, AGENTS.md).
  """

  import ExUnit.Assertions
  import Mob.ScreenCase, only: [flatten: 1, render_info: 2]

  @doc """
  Deliver every engine message waiting for the screen. `Magpie.Engine.state/0`
  first, so the Engine has forwarded what the Fake sent it.
  """
  def pump(view) do
    Magpie.Engine.state()
    drain(view)
  end

  defp drain(view) do
    receive do
      {:magpie_audio, _, _, _} = message -> view |> render_info(message) |> drain()
    after
      0 -> view
    end
  end

  @doc "Every Text string on screen, in order."
  def texts(view), do: for(%{type: :text, props: %{text: t}} <- flatten(view), do: t)

  @doc "The draw ops of the `<Canvas>` with `id`."
  def canvas_ops(view, id) do
    node = Enum.find(flatten(view), &(&1.type == :canvas and &1.props[:id] == id))
    assert node, "no canvas #{inspect(id)}"
    node.props.draw
  end

  @doc "The text ops' strings of the `<Canvas>` with `id`."
  def canvas_texts(view, id), do: for(%{op: :text, text: t} <- canvas_ops(view, id), do: t)

  @doc """
  Every tap target also has `on_press_out={held()}` (MOB-509: the screen
  re-renders on meters and timers, and Android drops a plain tap from an
  older render). Returns how many there are.
  """
  def assert_every_tap_held(view) do
    taps = for node <- flatten(view), node.props[:on_tap] != nil, do: node
    assert taps != [], "no tap targets rendered"

    for node <- taps do
      assert node.props[:on_press_out] == {self(), :held},
             "#{node.type} with on_tap #{inspect(node.props.on_tap)} has no on_press_out={held()}"
    end

    length(taps)
  end
end
