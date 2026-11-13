defmodule Magpie.HomeScreen do
  @moduledoc """
  Placeholder root until the pads screen exists (it needs Mob's per-node
  multi-pointer `on_touch`, MOB-518): the wordmark and the Identity board's
  line, in the family theme `App.on_start` sets.
  """

  use Mob.Screen

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(_assigns) do
    ~MOB"""
    <Column background={:background} padding={28} fill_width={true} fill_height={true}>
      <Text text="Magpie" font={:display} text_size={32} text_color={:primary} />
      <Spacer size={8} />
      <Text text="Collect sounds, play them back." text_size={15} text_color={:on_surface} />
    </Column>
    """
  end
end
