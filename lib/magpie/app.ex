defmodule Magpie.App do
  @moduledoc "Application entry point for Magpie."

  use Mob.App

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: Magpie.PadsScreen)
  end

  @impl Mob.App
  def on_start do
    # Configure BEAM's DNS path so Req / Finch / Mint / `gen_tcp:connect/3`
    # with a hostname work on iOS without per-host setup. Flips the lookup
    # chain from the iOS-broken `:native` (inet_gethost port program) path
    # to `[:file, :dns]` and seeds Google + Cloudflare as fallback
    # nameservers. Override with `nameservers:` if you need to (corporate
    # resolver, Quad9, etc.) — see `Mob.DNS.configure_pure_beam/1`.
    #
    # For hosts that need Apple's resolver (VPN-pushed DNS, mDNS,
    # captive portals, search-domain expansion) call `Mob.DNS.resolve/1`
    # for those specific hostnames here too. Both paths compose.
    Mob.DNS.configure_pure_beam()

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Magpie.Repo.start_link()

    Ecto.Migrator.with_repo(Magpie.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    # The sampler: the audio stream and the sequencer live outside the
    # screens, so they keep time whichever screen is in front.
    {:ok, _} = Magpie.Engine.start_link()
    # The kit being played: loads its samples into the engine, autosaves.
    {:ok, _} = Magpie.KitSession.start_link()
    # MIDI devices: USB and Bluetooth open as they appear (notes and clock
    # themselves go between Kotlin and the engine, not through here).
    {:ok, _} = Magpie.Midi.start_link()

    Mob.Theme.set(Magpie.Style.theme())
    Mob.Screen.start_root(Magpie.PadsScreen)
    Mob.Dist.ensure_started(node: :"magpie_android@127.0.0.1", cookie: :mob_secret)
  end

  # Returns the path to the migrations directory for the current environment.
  #
  # WHY NOT Application.app_dir/2?
  #
  # Application.app_dir(app, "priv/repo/migrations") calls :code.priv_dir(app)
  # under the hood. That works in a normal `mix run` dev environment where the
  # app lives in $OTP_ROOT/lib/APP-VERSION/ebin/.
  #
  # On Android and iOS, Mob deploys .beam files to a flat -pa directory with no
  # versioned lib structure, so :code.priv_dir/1 returns {error, bad_name}.
  # Ecto.Migrator.run/3 silently finds zero migrations and logs "Migrations
  # already up" — tables are never created and any query against them crashes
  # the screen GenServer, making the screen appear frozen.
  #
  # The fix: mob_beam.c/mob_beam.m set MOB_BEAMS_DIR=beams_dir before erl_start.
  # The deployer pushes priv/ into beams_dir/priv/ and runs chmod -R 755 on it
  # (mkdir-as-root creates system:system drwxrwx--x dirs that the app process
  # can traverse but not list, breaking Path.wildcard). Here we read MOB_BEAMS_DIR
  # and pass the explicit path to Ecto.Migrator.run/4.
  defp migrations_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:magpie, "priv/repo/migrations")
      beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
    end
  end
end
