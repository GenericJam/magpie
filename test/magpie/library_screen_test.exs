defmodule Magpie.LibraryScreenTest do
  # Uses the shared Engine / Fake audio and app config (:library_dir): not async.
  use Mob.ScreenCase, async: false

  import Magpie.Test.Kits
  import Magpie.Test.Screens

  alias Magpie.{KitSession, Library, LibraryScreen, PadsScreen, StarterPack, Style, Wav}

  setup do
    setup_library()
    :ok
  end

  defp f32(values), do: for(v <- values, into: <<>>, do: <<v::float-32-little>>)

  defp put_sample!(name, source, opts \\ []) do
    amp = Keyword.get(opts, :amp, 0.5)
    tags = Keyword.get(opts, :tags, [])
    frames = Keyword.get(opts, :frames, 512)
    peaks = Keyword.get(opts, :peaks, <<200, 80>>)
    salt = :erlang.phash2({name, source, tags}, 1000) / 1.0e6
    pcm = f32(List.duplicate(amp + salt, frames))

    {:ok, sample} =
      Library.put_pcm(pcm, %{
        name: name,
        rate: 48_000,
        channels: 1,
        source: source,
        tags: tags,
        peaks: peaks
      })

    sample
  end

  defp press(view, tag), do: render_info(view, {:tap, tag})

  describe "rendering, filters, and search" do
    test "renders rows with mini waveforms and every tap target is held" do
      mic = put_sample!("Mic 17:22", :recorded, tags: ["vox"])
      pack = put_sample!("snare Snare1_Hit", :pack, tags: ["snare"])

      view = mount_screen(LibraryScreen)
      assert_renderable(view)
      assert assert_every_tap_held(view) >= 9
      assert "The stash" in texts(view)
      assert "Samples · 2" in texts(view)
      assert mic.name in texts(view)
      assert pack.name in texts(view)
    end

    test "scales each row's waveform to its own peak while keeping silence flat" do
      quiet = put_sample!("guiro short", :pack, peaks: <<8, 4, 2, 0>>)
      silent = put_sample!("digital silence", :recorded, peaks: <<0, 0, 0, 0>>)

      view = mount_screen(LibraryScreen)

      quiet_heights =
        for bar <- find(view, :row, id: "wave_#{quiet.id}").children, do: bar.props.height

      silent_heights =
        for bar <- find(view, :row, id: "wave_#{silent.id}").children, do: bar.props.height

      assert Enum.max(quiet_heights) == 22
      assert Enum.min(quiet_heights) == 2
      assert Enum.uniq(quiet_heights) == [22, 11, 6, 2]
      assert silent_heights == List.duplicate(2, 16)
    end

    test "source filter chips and search narrow visible rows" do
      mic = put_sample!("Mic 17:22", :recorded, tags: ["vox"])
      fm = put_sample!("FM Bell C4", :fmutate, tags: ["keys"])
      pack = put_sample!("bass-drum BDrum_v1", :pack, tags: ["bass-drum"])
      imp = put_sample!("Field Rain", :imported, tags: ["ambient"])

      view = mount_screen(LibraryScreen)
      for s <- [mic, fm, pack, imp], do: assert(s.name in texts(view))

      view = press(view, {:filter, :recorded})
      assert mic.name in texts(view)
      refute pack.name in texts(view)
      refute imp.name in texts(view)

      view = press(view, {:filter, :fmutate})
      assert fm.name in texts(view)
      refute mic.name in texts(view)

      view = press(view, {:filter, :pack})
      assert pack.name in texts(view)
      refute mic.name in texts(view)

      view = press(view, {:filter, :imported})
      assert imp.name in texts(view)
      refute pack.name in texts(view)

      view = press(view, {:filter, :all})
      view = render_info(view, {:change, :search, "bass-drum"})
      assert pack.name in texts(view)
      refute mic.name in texts(view)
      refute imp.name in texts(view)

      view = render_info(view, {:change, :search, "no-such-sound"})
      assert "No samples in the stash match." in texts(view)
    end
  end

  describe "pick mode vs browse mode" do
    test "pick mode assigns the tapped sample to the target pad through KitSession and leaves other pads untouched" do
      existing = put_sample!("Mic 17:22", :recorded)
      chosen = put_sample!("snare Snare1_Hit", :pack, tags: ["snare"])

      kit = kit([{"A", pad(0, existing)}])
      start_session!(kit)

      view = mount_screen(LibraryScreen, %{pad: 1, reply_to: KitSession.whereis()})
      assert "Load into pad A2" in texts(view)

      # Start audition first, then pick the row: audition stops and the pad loads.
      view = press(view, {:audition, chosen.id})
      assert assigns(view).playing_id == chosen.id

      view = press(view, {:sample, chosen.id})
      assert assigns(view).playing_id == nil
      assert navigated_to(view) == PadsScreen

      snapshot = await_loaded()
      assert snapshot.kit.banks["A"][0].sample.id == existing.id
      assert snapshot.kit.banks["A"][1].sample.id == chosen.id
      assert snapshot.kit.banks["A"][1].name == String.slice(chosen.name, 0, 12)
    end

    test "browse mode tapping a row body toggles audition without changing the kit" do
      existing = put_sample!("Mic 17:22", :recorded)
      pack = put_sample!("clap SoloClap_vl1", :pack, tags: ["clap"])

      kit = kit([{"A", pad(0, existing)}])
      start_session!(kit)

      view = mount_screen(LibraryScreen)
      assert "The stash" in texts(view)

      view = press(view, {:sample, pack.id})
      assert assigns(view).playing_id == pack.id
      assert navigated_to(view) == nil

      view = press(view, {:sample, pack.id})
      assert assigns(view).playing_id == nil

      snapshot = KitSession.snapshot()
      assert map_size(snapshot.kit.banks["A"]) == 1
      assert snapshot.kit.banks["A"][0].sample.id == existing.id
    end
  end

  describe "audition" do
    test "toggles one sample at a time, clears on playback completion/error, and stops on back" do
      s1 = put_sample!("Kick 1", :pack, tags: ["bass-drum"])
      s2 = put_sample!("Snare 1", :pack, tags: ["snare"])

      view = mount_screen(LibraryScreen)
      assert assigns(view).playing_id == nil

      view = press(view, {:audition, s1.id})
      assert assigns(view).playing_id == s1.id
      row1 = find(view, :box, id: "row_#{s1.id}")
      assert row1.props.border_color == Style.color(:fm)

      # Auditioning another sample switches immediately to it.
      view = press(view, {:audition, s2.id})
      assert assigns(view).playing_id == s2.id

      # Tapping the playing sample's button stops it.
      view = press(view, {:audition, s2.id})
      assert assigns(view).playing_id == nil

      # Native playback completion clears the active audition.
      view = press(view, {:audition, s1.id})
      path1 = Library.path(s1.id)
      view = render_info(view, {:audio, :playback_finished, %{path: path1}})
      assert assigns(view).playing_id == nil

      # Native playback error clears the active audition and surfaces a notice.
      view = press(view, {:audition, s1.id})
      view = render_info(view, {:audio, :playback_error, %{reason: :decode_failed}})
      assert assigns(view).playing_id == nil
      assert "Couldn't play sample: decode_failed" in texts(view)

      # Back stops any playing sample and pops the screen.
      view = press(view, {:audition, s2.id})
      view = press(view, :back)
      assert assigns(view).playing_id == nil
      assert navigated_to(view) == {:pop}
    end
  end

  describe "starter pack progress, credit, and file import" do
    test "shows starter pack progress from {:starter_pack, status} and credit when pack samples exist" do
      view = mount_screen(LibraryScreen)
      refute Enum.any?(texts(view), &String.contains?(&1, "Versilian"))

      _pack = put_sample!("tom HighTom_v1", :pack, tags: ["tom"])

      view =
        render_info(
          view,
          {:starter_pack, %{state: :importing, done: 14, total: 100, failed: 0}}
        )

      # Progress on every file; the list only every 10 files and at the end.
      assert "Adding starter drums 14/100" in texts(view)
      refute "tom HighTom_v1" in texts(view)

      view =
        render_info(
          view,
          {:starter_pack, %{state: :importing, done: 20, total: 100, failed: 0}}
        )

      assert "tom HighTom_v1" in texts(view)
      _snare = put_sample!("snare Snare_v1", :pack, tags: ["snare"])

      view =
        render_info(
          view,
          {:starter_pack, %{state: :ready, done: 100, total: 100, failed: 0}}
        )

      refute Enum.any?(texts(view), &String.starts_with?(&1, "Adding starter drums"))
      assert "snare Snare_v1" in texts(view)
      assert "Starter Drums: #{StarterPack.credit()}" in texts(view)
    end

    test "+ Import adds a picked file to the stash without auto-assigning in pick mode" do
      existing = put_sample!("Mic 17:22", :recorded)
      kit = kit([{"A", pad(0, existing)}])
      start_session!(kit)

      wav_path = Path.join(Library.dir(), "Bell.wav")
      File.mkdir_p!(Library.dir())
      File.write!(wav_path, Wav.encode_s16(f32(List.duplicate(0.4, 1024)), 48_000, 1))

      view =
        LibraryScreen
        |> mount_screen(%{pad: 1, reply_to: KitSession.whereis()})
        |> press(:import)
        |> render_info(
          {:files, :picked, [%{path: wav_path, name: "Bell.wav", mime: "audio/x-wav"}]}
        )
        |> render_async()

      assert "Bell" in texts(view)
      assert navigated_to(view) == nil
      assert KitSession.snapshot().kit.banks["A"][1] == nil
    end
  end
end
