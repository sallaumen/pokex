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
    # The whole point of the fallback: this arrives without a flag day.
    test "it answers the screen calibration, exactly as before", %{calib: calib} do
      bar = ActiveBar.current(calib)

      assert bar.region == {10, 20, 300, 40}
      assert bar.count == 6
      assert bar.refs == [[1, 2, 3]]
      assert bar.name == nil
      refute ActiveBar.own?()
    end

    test "no calibration at all is not a crash" do
      assert %{region: nil, count: nil, name: nil} = ActiveBar.current(nil)
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
      bar = ActiveBar.current(calib)

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
    test "choosing another pokémon falls back until THAT one is calibrated", %{calib: calib} do
      {:ok, _} = Team.add("Gardevoir")
      Team.set_active("Gardevoir")

      assert %{region: {10, 20, 300, 40}, count: 6, name: nil} = ActiveBar.current(calib)

      Team.set_bar("Gardevoir", %{region: {1, 2, 400, 44}, count: 4, refs: nil})

      assert %{region: {1, 2, 400, 44}, count: 4, name: "Gardevoir"} = ActiveBar.current(calib)
    end

    test "clearing a pokémon's bar drops it back to the calibration", %{calib: calib} do
      Team.set_bar("Vespiquen", nil)

      assert %{region: {10, 20, 300, 40}, name: nil} = ActiveBar.current(calib)
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
