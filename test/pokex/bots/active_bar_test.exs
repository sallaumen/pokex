defmodule Pokex.Bots.ActiveBarTest do
  @moduledoc """
  The bar belongs to the pokémon, not to the screen.

  "seria legal se pudéssemos calibrar uma barra de skills para cada pokémon"
  (Lucas, 2026-08-12) — and the reason it matters more than the layout is that
  the READY references are the skill ICONS. A set captured with one pokémon out
  scores every later cooldown against art that is not on the bar.
  """
  # async: false — scopes the global :home_dir env per test.
  use ExUnit.Case, async: false

  alias Pokex.Bots.ActiveBar
  alias Pokex.Calibration
  alias Pokex.Pokedex.Team

  @moduletag :tmp_dir

  @dataset %{
    "species" => [
      %{"name" => "Vespiquen", "number" => 416, "elements" => ["Bug"]},
      %{"name" => "Gardevoir", "number" => 282, "elements" => ["Psychic"]}
    ],
    "lures" => []
  }

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Pokex.TestHome.restore()
    end)

    %{
      calib: %Calibration{
        skill_bar_region: {10, 20, 300, 40},
        skill_bar_count: 6,
        skill_slot_refs: [[1, 2, 3]]
      }
    }
  end

  describe "with nobody calibrated" do
    # There is no shared bar to fall back to since 2026-08-24: a rectangle
    # nobody on the field owns is what let the screen ruler measure a doubled
    # slot and rescale 21 settings by it. Nothing to read is the honest answer,
    # and `Pokex.Preflight` is what keeps a bot from starting into it.
    test "there is no bar to read, and the screen calibration is not one" do
      bar = ActiveBar.current()

      assert bar.region == nil
      assert bar.count == nil
      assert bar.refs == nil
      assert bar.name == nil
      refute ActiveBar.own?()
    end
  end

  describe "with the pokémon on the field carrying its own" do
    setup do
      {:ok, _} = Team.add("Vespiquen")
      Team.set_bar("Vespiquen", %{region: {5, 5, 900, 50}, count: 9, refs: [{9, 9, 9}]})
      Team.set_active("Vespiquen")
      :ok
    end

    test "its bar wins, and says whose it is", %{calib: calib} do
      bar = ActiveBar.current()

      assert bar.region == {5, 5, 900, 50}
      assert bar.count == 9
      # {r,g,b}, the shape Vision.slot_distance/2 needs — a list would be
      # silently ignored and the slot judged by brightness alone
      assert bar.refs == [{9, 9, 9}]
      assert bar.name == "Vespiquen"
      assert ActiveBar.own?()
    end

    # Choosing someone else must move the bar with it — that is the swap this
    # exists for.
    test "choosing another pokémon reads NOTHING until THAT one is calibrated" do
      {:ok, _} = Team.add("Gardevoir")
      Team.set_active("Gardevoir")

      assert %{region: nil, count: nil, name: nil} = ActiveBar.current()

      Team.set_bar("Gardevoir", %{region: {1, 2, 400, 44}, count: 4, refs: nil})

      assert %{region: {1, 2, 400, 44}, count: 4, name: "Gardevoir"} = ActiveBar.current()
    end

    # The promise in his own words: "eu calibro uma vez a Vespiquen e uma vez a
    # Vileplume, e nunca mais vou precisar calibrar ela, só trocando" — with
    # Gardevoir standing in, because Team.add refuses a name the Pokédex does
    # not carry. Calibrating
    # the second one must not disturb the first, and swapping back must return it
    # whole — region, count and the READY references, which ARE the skill icons.
    test "two calibrated pokémon keep their own bars across every swap", %{calib: calib} do
      {:ok, _} = Team.add("Gardevoir")
      Team.set_bar("Gardevoir", %{region: {7, 8, 500, 60}, count: 6, refs: [{1, 2, 3}]})

      Team.set_active("Gardevoir")

      assert %{region: {7, 8, 500, 60}, count: 6, refs: [{1, 2, 3}], name: "Gardevoir"} =
               ActiveBar.current()

      Team.set_active("Vespiquen")

      assert %{region: {5, 5, 900, 50}, count: 9, refs: [{9, 9, 9}], name: "Vespiquen"} =
               ActiveBar.current()

      Team.set_active("Gardevoir")
      assert %{region: {7, 8, 500, 60}, count: 6, name: "Gardevoir"} = ActiveBar.current()
    end

    test "calibrating one pokémon never touches another's bar", %{calib: _calib} do
      {:ok, _} = Team.add("Gardevoir")
      Team.set_bar("Gardevoir", %{region: {7, 8, 500, 60}, count: 6, refs: [{1, 2, 3}]})

      assert Team.bar("Vespiquen").count == 9
      assert Team.bar("Vespiquen").region == {5, 5, 900, 50}
    end

    test "clearing a pokémon's bar leaves nothing to read" do
      Team.set_bar("Vespiquen", nil)

      assert %{region: nil, count: nil, name: nil} = ActiveBar.current()
    end
  end

  describe "storage" do
    test "the region survives the round trip as a TUPLE, not a JSON list" do
      {:ok, _} = Team.add("Vespiquen")
      Team.set_bar("Vespiquen", %{region: {7, 8, 500, 48}, count: 8, refs: nil})

      assert %{region: {7, 8, 500, 48}, count: 8} = Team.bar("Vespiquen")
    end

    # The refs the calibration page samples are {r,g,b} TUPLES — the first cut
    # only translated the region, so this raised inside JSON.encode! and took
    # the page down on the very first real save. And a ref that came back a
    # LIST would be worse than the crash: Vision.slot_distance/2 answers nil for
    # anything that is not {r,g,b}, so every reference would be silently
    # ignored and the reading would quietly fall back to the brightness rule —
    # the exact failure this whole feature exists to prevent.
    test "the READY references survive as {r,g,b} tuples, holes included" do
      {:ok, _} = Team.add("Vespiquen")

      Team.set_bar("Vespiquen", %{
        region: {10, 20, 300, 40},
        count: 3,
        refs: [{200, 30, 30}, nil, {40, 90, 220}]
      })

      assert %{refs: [{200, 30, 30}, nil, {40, 90, 220}]} = Team.bar("Vespiquen")
    end

    test "a pokémon nobody has, and one never calibrated, both answer nil" do
      {:ok, _} = Team.add("Gardevoir")

      assert Team.bar("Gardevoir") == nil
      assert Team.bar("Ninguém") == nil
    end
  end
end
