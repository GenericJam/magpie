defmodule Magpie.Test.Kits do
  @moduledoc """
  Kits and library samples for tests of `Magpie.KitSession` and the pads
  screen: `setup_library/0` (the Repo, a fresh sample directory, the
  engine with the fake audio), `sample!/2` (a sound in the library),
  `kit/1`, `pad/3` and `await_loaded/0`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Magpie.Audio.Fake
  alias Magpie.{Engine, Kit, KitSession, Library}
  alias Magpie.Kit.{Pad, Region}
  alias Magpie.Test.Repo, as: TestRepo

  @tmp_root Path.join(System.tmp_dir!(), "magpie_kit_tests")

  @doc "Start the Repo and the Engine (fake audio) and point the library at a fresh directory."
  def setup_library do
    TestRepo.start()
    :ok = Fake.fail_open(nil)
    start_supervised!(Engine)

    dir = Path.join(@tmp_root, Integer.to_string(System.unique_integer([:positive])))
    Application.put_env(:magpie, :library_dir, dir)

    on_exit(fn ->
      Application.delete_env(:magpie, :library_dir)
      File.rm_rf!(dir)
    end)

    :ok
  end

  @doc """
  Put a mono 48 kHz sound in the library: `seconds` long, loud (0.8) in
  its first half and quiet (0.1) after, so its waveform has a shape.
  """
  def sample!(name, seconds \\ 1.0) do
    frames = round(seconds * 48_000)
    half = div(frames, 2)
    # Different lengths give different sounds (ids); the name keeps them apart too.
    salt = :erlang.phash2(name, 1000) / 1.0e6

    pcm =
      for i <- 0..(frames - 1)//1, into: <<>> do
        <<if(i < half, do: 0.8 + salt, else: 0.1)::float-32-little>>
      end

    {:ok, sample} =
      Library.put_pcm(pcm, %{name: name, rate: 48_000, channels: 1, source: :recorded})

    sample
  end

  @doc "A kit with `pads` (`{bank, %Pad{}}`) and nothing else."
  def kit(pads, opts \\ []) do
    banks =
      Enum.reduce(pads, %{}, fn {bank, pad}, acc ->
        Map.update(acc, bank, %{pad.slot => pad}, &Map.put(&1, pad.slot, pad))
      end)

    %Kit{
      id: Keyword.get(opts, :id, "test-kit"),
      name: Keyword.get(opts, :name, "Test Kit"),
      tempo: 120,
      snap: Keyword.get(opts, :snap, false),
      banks: banks
    }
  end

  @doc "A pad on `slot` playing the whole of `sample`; `opts` set Pad fields."
  def pad(slot, %Library.Sample{id: id, name: name}, opts \\ []),
    do: struct(%Pad{slot: slot, name: name, color: :coral, sample: %Region{id: id}}, opts)

  @doc "Start the session on `kit` and wait until every sample has loaded."
  def start_session!(kit, opts \\ []) do
    start_supervised!({KitSession, Keyword.merge([kit: kit, autosave_ms: 60_000], opts)})
    await_loaded()
  end

  @doc "Wait until no pad's sample is still loading; returns the snapshot."
  def await_loaded(tries \\ 200) do
    snapshot = KitSession.snapshot()

    cond do
      Enum.all?(snapshot.pads, fn {_, p} -> p.status != :loading end) ->
        snapshot

      tries == 0 ->
        flunk("samples still loading: #{inspect(snapshot.pads)}")

      true ->
        Process.sleep(5)
        await_loaded(tries - 1)
    end
  end
end
