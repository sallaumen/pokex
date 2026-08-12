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

  # MEASURED on his real library (2026-08-11, 24 taught bodies): a corpse against
  # its own entry scores 1.0, and against the nearest DIFFERENT creature 0.78
  # (Shiny Magikarp vs Shiny Giant Magikarp — same family). That margin is what
  # makes the veto work: with only the shiny taught, a normal Krabby corpse had
  # nowhere else to land and matched it at 0.8+, and he woke up to a bank full
  # of ordinary Krabby. Teaching the ordinary body and switching it OFF is how
  # he says "I know this one and I do NOT want it".
  describe "a corpse switched off is a veto, not an absence" do
    @tag :tmp_dir
    test "the closest taught body wins, and winning while off means no ball" do
      {:ok, 1} = CorpseLibrary.add("Krabby shiny", solid(40, 200, 190))
      {:ok, 1} = CorpseLibrary.add("Krabby", solid(200, 120, 40))
      :ok = CorpseLibrary.set_enabled("krabby", false)

      # the ordinary body: closest to the entry he switched off
      assert :nomatch = CorpseLibrary.match(solid(200, 120, 40), 0.72)

      # the shiny: still a target
      assert {:ok, %{name: "Krabby shiny"}} = CorpseLibrary.match(solid(40, 200, 190), 0.72)
    end

    @tag :tmp_dir
    test "best/1 still reports the vetoed winner — a refusal has to be explainable" do
      {:ok, 1} = CorpseLibrary.add("Krabby", solid(200, 120, 40))
      :ok = CorpseLibrary.set_enabled("krabby", false)

      assert %{name: "Krabby", score: score, aimed?: false} =
               CorpseLibrary.best(solid(200, 120, 40))

      assert score > 0.9
    end

    @tag :tmp_dir
    test "with nothing switched off, the aim is exactly what it was" do
      {:ok, 1} = CorpseLibrary.add("Corsola", solid(180, 120, 200))

      assert {:ok, %{name: "Corsola", aimed?: true}} =
               CorpseLibrary.match(solid(180, 120, 200), 0.72)
    end
  end

  # A name typed wrong is not cosmetic: the ball rules match on it, so
  # "Shiny Craby" answers to no rule written for Krabby.
  describe "fixing a name without losing the photographs" do
    @tag :tmp_dir
    test "renaming keeps the samples and the switch" do
      {:ok, 1} = CorpseLibrary.add("Shiny Craby", solid(40, 200, 190))
      :ok = CorpseLibrary.set_enabled("shiny-craby", false)

      assert {:ok, "shiny-krabby"} = CorpseLibrary.rename("shiny-craby", "Shiny Krabby")

      assert [entry] = CorpseLibrary.list()
      assert entry["name"] == "Shiny Krabby"
      assert entry["slug"] == "shiny-krabby"
      assert length(entry["samples"]) == 1
      refute CorpseLibrary.enabled?(entry)
    end

    @tag :tmp_dir
    test "an empty name and a name already taken are refused" do
      {:ok, 1} = CorpseLibrary.add("Shiny Craby", solid(40, 200, 190))
      {:ok, 1} = CorpseLibrary.add("Kingler", solid(200, 120, 40))

      assert {:error, :empty_name} = CorpseLibrary.rename("shiny-craby", "   ")
      assert {:error, :taken} = CorpseLibrary.rename("shiny-craby", "Kingler")
      assert length(CorpseLibrary.list()) == 2
    end

    @tag :tmp_dir
    test "re-typing the same name is not a collision with itself" do
      {:ok, 1} = CorpseLibrary.add("Kingler", solid(200, 120, 40))

      assert {:ok, "kingler"} = CorpseLibrary.rename("kingler", "Kingler")
    end
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
