defmodule Magpie.HomeScreenTest do
  use Mob.ScreenCase, async: true

  alias Magpie.HomeScreen

  test "mounts and renders a tree the native layer can draw" do
    view = mount_screen(HomeScreen)
    assert_renderable(view)
    assert text(view) =~ "Magpie"
  end
end
