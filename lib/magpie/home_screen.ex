defmodule Magpie.HomeScreen do
  @moduledoc """
  Placeholder root until the pads screen exists (it needs Mob's per-node
  multi-pointer `on_touch`, MOB-518): the wordmark and the Identity board's
  line, in the family theme `App.on_start` sets, and the way into
  `Magpie.RecordScreen`.
  """

  use Mob.Screen

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(_assigns) do
    record = {self(), :record}
    held = {self(), :held}

    ~MOB"""
    <Column background={:background} padding={28} fill_width={true} fill_height={true}>
      <Text text="Magpie" font={:display} text_size={32} text_color={:primary} />
      <Spacer size={8} />
      <Text text="Collect sounds, play them back." text_size={15} text_color={:on_surface} />
      <Spacer size={24} />
      <Button
        id="record"
        text="Record a sample"
        on_tap={record}
        on_press_out={held}
        fill_width={false}
      />
    </Column>
    """
  end

  def handle_info({:tap, :record}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, Magpie.RecordScreen)}

  def handle_info(_msg, socket), do: {:noreply, socket}
end
