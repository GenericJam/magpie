defmodule Magpie.LibraryTest do
  # The sample directory is app config, shared by all tests: not async.
  use ExUnit.Case, async: false

  alias Magpie.{Kit, Library, Wav}
  alias Magpie.Library.Sample
  alias Magpie.Test.Repo, as: TestRepo

  @tmp_root Path.join(System.tmp_dir!(), "magpie_library_test")

  setup do
    TestRepo.start()

    dir = Path.join(@tmp_root, Integer.to_string(System.unique_integer([:positive])))
    Application.put_env(:magpie, :library_dir, dir)

    on_exit(fn ->
      Application.delete_env(:magpie, :library_dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp f32(values), do: for(v <- values, into: <<>>, do: <<v::float-32-little>>)

  defp meta(name, extra \\ %{}),
    do: Map.merge(%{name: name, rate: 48_000, channels: 1, source: :recorded}, extra)

  describe "put_pcm/2" do
    test "stores the audio under the SHA-256 of its PCM" do
      pcm = f32([0.1, 0.2, 0.3, 0.4])
      {:ok, sample} = Library.put_pcm(pcm, meta("Kick", %{tags: ["drums"], peaks: <<9, 200>>}))

      assert sample.id == Base.encode16(:crypto.hash(:sha256, pcm), case: :lower)

      assert %Sample{
               frames: 4,
               rate: 48_000,
               channels: 1,
               source: :recorded,
               tags: ["drums"],
               peaks: <<9, 200>>
             } = sample

      assert Sample.seconds(sample) == 4 / 48_000
      assert {:ok, ^pcm} = Library.pcm(sample.id)

      assert {:ok, %{rate: 48_000, channels: 1}, ^pcm} =
               sample.id |> Library.path() |> File.read!() |> Wav.decode()
    end

    test "the same sound added twice is one sample, keeping the first name" do
      pcm = f32([0.5, -0.5])
      {:ok, first} = Library.put_pcm(pcm, meta("First"))
      {:ok, again} = Library.put_pcm(pcm, meta("Second", %{source: :imported}))

      assert again.id == first.id
      assert again.name == "First"
      assert [_one] = Library.list()
    end

    test "stereo frames count both channels" do
      {:ok, s} = Library.put_pcm(f32([0.1, 0.2, 0.3, 0.4]), meta("St", %{channels: 2}))
      assert s.frames == 2
    end

    test "refuses empty audio, a partial frame and an unknown source" do
      assert {:error, :empty} = Library.put_pcm("", meta("x"))
      assert {:error, :partial_frame} = Library.put_pcm(f32([0.1]), meta("x", %{channels: 2}))
      assert {:error, :invalid_meta} = Library.put_pcm(f32([0.1]), meta("x", %{source: :stolen}))
      assert Library.list() == []
    end
  end

  test "put_wav/2 imports a 16-bit file as float PCM" do
    wav = Wav.encode_s16(f32([0.5, -0.5]), 44_100, 2)
    {:ok, s} = Library.put_wav(wav, %{name: "Imported", source: :imported})
    assert %Sample{rate: 44_100, channels: 2, frames: 1, source: :imported} = s
  end

  describe "list/1" do
    setup do
      {:ok, kick} = Library.put_pcm(f32([0.1]), meta("Kick 01", %{tags: ["Drums"]}))

      {:ok, pad} =
        Library.put_pcm(f32([0.2]), meta("Glass bell", %{source: :fmutate, tags: ["keys"]}))

      {:ok, brk} =
        Library.put_pcm(
          f32([0.3]),
          meta("Break 96", %{source: :imported, tags: ["drums", "loop"]})
        )

      %{kick: kick, pad: pad, brk: brk}
    end

    test "newest first", %{kick: kick, pad: pad, brk: brk} do
      assert Enum.map(Library.list(), & &1.id) == [brk.id, pad.id, kick.id]
    end

    test "by source", %{pad: pad} do
      assert [^pad] = Library.list(%{source: :fmutate})
      assert Library.list(%{source: :pack}) == []
    end

    test "text matches a name or a tag, ignoring case", %{kick: kick, brk: brk, pad: pad} do
      assert Enum.map(Library.list(%{q: "DRUM"}), & &1.id) == [brk.id, kick.id]
      assert [^pad] = Library.list(%{q: "bell"})
      assert [^brk] = Library.list(%{q: "drums", source: :imported})
    end
  end

  test "rename/2 and set_tags/2" do
    {:ok, s} = Library.put_pcm(f32([0.1]), meta("Old"))
    assert {:ok, %{name: "New"}} = Library.rename(s.id, "  New ")
    assert {:error, :blank} = Library.rename(s.id, "   ")
    assert {:ok, %{tags: ["a", "b"]}} = Library.set_tags(s.id, [" a", "", "b", "a"])
    assert {:error, :not_found} = Library.rename("nope", "x")
  end

  describe "kits" do
    setup do
      {:ok, kit} = Kit.load("design/kits/dusty-breaks.kit.json")
      %{kit: kit}
    end

    test "save and load round-trip; saving again replaces", %{kit: kit} do
      assert {:ok, ^kit} = Library.save_kit(kit)
      assert {:ok, ^kit} = Library.load_kit("dusty-breaks")

      renamed = %{kit | name: "Dustier", tempo: 100}
      {:ok, _} = Library.save_kit(renamed)
      assert {:ok, ^renamed} = Library.load_kit("dusty-breaks")
      assert [%{id: "dusty-breaks", name: "Dustier"}] = Library.list_kits()
    end

    test "a sample a saved kit uses can't be deleted until the kit is gone", %{kit: kit} do
      {:ok, s} = Library.put_pcm(f32([0.7]), meta("Kick"))
      pads = put_in(kit.banks["A"][0].sample.id, s.id)
      {:ok, _} = Library.save_kit(%{kit | banks: pads.banks})

      assert {:error, {:in_use, ["dusty-breaks"]}} = Library.delete(s.id)
      assert File.exists?(Library.path(s.id))

      :ok = Library.delete_kit("dusty-breaks")
      assert :ok = Library.delete(s.id)
      refute File.exists?(Library.path(s.id))
      assert Library.get(s.id) == nil
      assert {:error, :not_found} = Library.delete(s.id)
    end

    test "loading or deleting a kit that isn't there" do
      assert {:error, :not_found} = Library.load_kit("ghost")
      assert {:error, :not_found} = Library.delete_kit("ghost")
    end
  end
end
