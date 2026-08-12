defmodule Pokex.Bots.Catcher.CorpseLibraryTest do
  # async: false — home_dir and the :persistent_term cache are global
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Vision.Frame

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  # solid one-color "sprite" — an unmistakable palette for the histogram
  defp solid(r, g, b, px \\ 16) do
    %Frame{width: px, height: px, rgba: :binary.copy(<<r, g, b, 255>>, px * px)}
  end

  # half sprite color, half "ground" — simulates a corpse composited over background
  defp half(r, g, b, ground, px \\ 16) do
    {gr, gg, gb} = ground
    metade = div(px * px, 2)

    %Frame{
      width: px,
      height: px,
      rgba: :binary.copy(<<r, g, b, 255>>, metade) <> :binary.copy(<<gr, gg, gb, 255>>, metade)
    }
  end

  # A shiny is a recolor of a body he has never killed. Until one drops he teaches
  # the ordinary corpse with its hue turned toward the shiny — a stand-in that
  # aims like any other sample, and says so, so he knows which to replace.
  @tag :tmp_dir
  test "a hand-painted sample says it is one; an ordinary one says it is not" do
    {:ok, 1} = CorpseLibrary.add("Tentacool shiny", solid(40, 200, 190), painted?: true)
    {:ok, 1} = CorpseLibrary.add("Tentacool", solid(180, 120, 200))

    by_name = Map.new(CorpseLibrary.list(), &{&1["name"], &1})

    assert [%{"painted" => true}] = by_name["Tentacool shiny"]["samples"]
    assert [%{"painted" => false}] = by_name["Tentacool"]["samples"]
  end

  @tag :tmp_dir
  test "a painted corpse aims exactly like a photographed one" do
    {:ok, 1} = CorpseLibrary.add("Krabby shiny", solid(40, 200, 190), painted?: true)

    assert {:ok, %{name: "Krabby shiny"}} = CorpseLibrary.match(solid(40, 200, 190), 0.72)
  end

  @tag :tmp_dir
  test "teaching accumulates samples per corpse, capped, dropping the oldest" do
    assert CorpseLibrary.empty?()

    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    {:ok, 1} = CorpseLibrary.add("Zubat", solid(60, 60, 220))
    assert [%{"name" => "Zubat"}, %{"name" => "Rattata"}] = CorpseLibrary.list()

    {:ok, 2} = CorpseLibrary.add("rattata", solid(181, 121, 201))
    {:ok, 3} = CorpseLibrary.add("rattata", solid(182, 122, 202))
    assert length(CorpseLibrary.list()) == 2

    {:ok, n} = CorpseLibrary.add("rattata", solid(183, 123, 203))
    assert n == CorpseLibrary.max_samples()

    :ok = CorpseLibrary.delete("zubat")
    assert [%{"name" => "rattata", "samples" => samples}] = CorpseLibrary.list()
    assert length(samples) == CorpseLibrary.max_samples()

    :ok = CorpseLibrary.delete_sample("rattata", 0)
    assert [%{"samples" => rest}] = CorpseLibrary.list()
    assert length(rest) == CorpseLibrary.max_samples() - 1

    :ok = CorpseLibrary.delete_sample("rattata", 0)
    :ok = CorpseLibrary.delete_sample("rattata", 0)
    assert CorpseLibrary.empty?()
  end

  @tag :tmp_dir
  test "a sample from a different ground improves the match — the max across samples wins" do
    {:ok, 1} = CorpseLibrary.add("Rattata", half(180, 120, 200, {90, 70, 40}))
    candidato = half(180, 120, 200, {30, 30, 120})
    {:ok, %{score: fraco}} = CorpseLibrary.match(candidato, 0.3)

    {:ok, 2} = CorpseLibrary.add("Rattata", half(180, 120, 200, {30, 30, 120}))
    {:ok, %{name: "Rattata", score: forte}} = CorpseLibrary.match(candidato, 0.3)

    assert forte > fraco
    assert forte > 0.95
  end

  @tag :tmp_dir
  test "the legacy #101 format (one flattened sample) is still readable" do
    antigo = [
      %{
        "name" => "Zubat",
        "slug" => "zubat",
        "w" => 4,
        "h" => 4,
        "rgba" => Base.encode64(:binary.copy(<<60, 60, 220, 255>>, 16)),
        "added_at" => "2026-07-30T00:00:00Z"
      }
    ]

    File.mkdir_p!(Path.dirname(CorpseLibrary.file()))
    File.write!(CorpseLibrary.file(), Jason.encode!(antigo))

    assert [%{"name" => "Zubat", "samples" => [_uma]}] = CorpseLibrary.list()
    assert {:ok, %{name: "Zubat"}} = CorpseLibrary.match(solid(60, 60, 220, 4), 0.7)
  end

  @tag :tmp_dir
  test "the thumbnail is a valid BMP data URL" do
    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200, 4))
    [%{"samples" => [sample]}] = CorpseLibrary.list()

    url = CorpseLibrary.thumb(sample)
    assert String.starts_with?(url, "data:image/bmp;base64,")

    <<"BM", _resto::binary>> =
      url |> String.replace_prefix("data:image/bmp;base64,", "") |> Base.decode64!()
  end

  @tag :tmp_dir
  test "an empty name is rejected" do
    assert {:error, :empty_name} = CorpseLibrary.add("   ", solid(1, 2, 3))
  end

  @tag :tmp_dir
  test "matches the right corpse even when half the crop is ground" do
    {:ok, 1} = CorpseLibrary.add("Rattata", half(180, 120, 200, {90, 70, 40}))
    {:ok, 1} = CorpseLibrary.add("Zubat", half(60, 60, 220, {90, 70, 40}))

    candidato = half(180, 120, 200, {50, 110, 60})

    assert {:ok, %{name: "Rattata", score: score}} = CorpseLibrary.match(candidato, 0.4)
    assert score >= 0.4
  end

  @tag :tmp_dir
  test "an unknown palette does not match; an empty library never matches" do
    assert :nomatch = CorpseLibrary.match(solid(9, 9, 9), 0.4)

    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    assert :nomatch = CorpseLibrary.match(solid(9, 200, 9), 0.7)
  end

  @tag :tmp_dir
  test "the cache respects mtime: an add is visible on the next read" do
    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    assert [_] = CorpseLibrary.list()
    {:ok, 1} = CorpseLibrary.add("Zubat", solid(60, 60, 220))
    assert length(CorpseLibrary.list()) == 2
  end

  describe "per-corpse enable/disable" do
    @tag :tmp_dir
    test "a disabled corpse leaves the aim but stays in the library" do
      {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
      {:ok, 1} = CorpseLibrary.add("Zubat", solid(60, 60, 220))

      assert {:ok, %{name: "Rattata"}} = CorpseLibrary.match(solid(180, 120, 200), 0.7)

      :ok = CorpseLibrary.set_enabled("rattata", false)

      assert :nomatch = CorpseLibrary.match(solid(180, 120, 200), 0.7)
      assert length(CorpseLibrary.list()) == 2

      assert Enum.any?(
               CorpseLibrary.list(),
               &(&1["slug"] == "rattata" and not CorpseLibrary.enabled?(&1))
             )

      assert {:ok, %{name: "Zubat"}} = CorpseLibrary.match(solid(60, 60, 220), 0.7)

      :ok = CorpseLibrary.set_enabled("rattata", true)
      assert {:ok, %{name: "Rattata"}} = CorpseLibrary.match(solid(180, 120, 200), 0.7)
    end

    @tag :tmp_dir
    test "a legacy library without the enabled field still participates in the aim" do
      {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))

      antigo =
        CorpseLibrary.file()
        |> File.read!()
        |> Jason.decode!()
        |> Enum.map(&Map.delete(&1, "enabled"))

      File.write!(CorpseLibrary.file(), Jason.encode!(antigo))

      assert {:ok, %{name: "Rattata"}} = CorpseLibrary.match(solid(180, 120, 200), 0.7)
    end

    @tag :tmp_dir
    test "re-teaching does not re-enable a deliberately disabled corpse" do
      {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
      :ok = CorpseLibrary.set_enabled("rattata", false)

      {:ok, 2} = CorpseLibrary.add("Rattata", solid(181, 121, 201))

      assert :nomatch = CorpseLibrary.match(solid(180, 120, 200), 0.7)
    end
  end
end
