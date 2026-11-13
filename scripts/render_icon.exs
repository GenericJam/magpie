# Regenerates every launcher icon from the two masters in assets/icon/.
#
#     mise exec -- mix run --no-start scripts/render_icon.exs
#
# magpie-icon-1024.png is the design board's app icon ("Magpie over its
# nest", Magpie.html → Identity → App icon), full bleed on the tile colour
# #1C1925. iOS and pre-26 Android icons come from it.
#
# magpie-icon-foreground-1024.png is the same art at 60 % of the canvas,
# centred on #1C1925. `mix mob.icon --adaptive` scales the whole source to
# the 108 dp adaptive canvas, so a full-bleed master loses the outer pads
# to round launcher masks; this foreground keeps the whole nest inside the
# 72 dp a round mask shows. Its background is the adaptive background
# colour, so no transparency is needed.

master = "assets/icon/magpie-icon-1024.png"
foreground = "assets/icon/magpie-icon-foreground-1024.png"

Mix.Task.run("mob.icon", ["--source", master, "--adaptive", "--adaptive-bg", "#1C1925"])

fg = Image.open!(foreground)

for {bucket, px} <- MobDev.IconGenerator.adaptive_sizes() do
  dest = Path.join(["android/app/src/main/res", bucket, "ic_launcher_foreground.png"])
  fg |> Image.thumbnail!(px) |> Image.write!(dest)
end

IO.puts("Adaptive foregrounds replaced with #{foreground}")
