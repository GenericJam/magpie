defmodule Magpie.HomeScreenTest do
  use Mob.ScreenCase, async: true

  import Magpie.Test.Screens, only: [assert_every_tap_held: 1]

  alias Magpie.HomeScreen

  test "mounts and renders a tree the native layer can draw" do
    view = mount_screen(HomeScreen)
    assert_renderable(view)
    assert text(view) =~ "Magpie"
    assert_every_tap_held(view)
  end

  test "Record a sample opens the record screen" do
    view = HomeScreen |> mount_screen() |> render_info({:tap, :record})
    assert navigated_to(view) == Magpie.RecordScreen
  end
end
