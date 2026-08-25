defmodule Pokex.Pokedex.TypeChartTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.TypeChart

  describe "elements/0" do
    test "lists the eighteen canonical types and none of PokeXGames' own" do
      elements = TypeChart.elements()

      assert length(elements) == 18
      assert "Fairy" in elements
      refute "Crystal" in elements
      assert elements == Enum.sort(elements)
    end
  end

  describe "multiplier/2 — a single defending element" do
    test "a super-effective attack doubles" do
      assert TypeChart.multiplier("Fire", ["Grass"]) == 2.0
    end

    test "a resisted attack halves" do
      assert TypeChart.multiplier("Fire", ["Water"]) == 0.5
    end

    test "an immunity zeroes" do
      assert TypeChart.multiplier("Electric", ["Ground"]) == 0.0
      assert TypeChart.multiplier("Ghost", ["Normal"]) == 0.0
    end

    test "an unrelated pairing is neutral" do
      assert TypeChart.multiplier("Normal", ["Water"]) == 1.0
    end
  end

  describe "multiplier/2 — a dual type multiplies both columns" do
    test "two resistances stack to a quarter" do
      assert TypeChart.multiplier("Grass", ["Grass", "Poison"]) == 0.25
    end

    test "two weaknesses stack to quadruple" do
      assert TypeChart.multiplier("Rock", ["Fire", "Flying"]) == 4.0
    end

    test "a weakness cancelled by a resistance lands back on neutral" do
      assert TypeChart.multiplier("Water", ["Water", "Ground"]) == 1.0
    end

    test "one immune half zeroes the whole pairing" do
      assert TypeChart.multiplier("Ground", ["Ground", "Flying"]) == 0.0
    end
  end

  describe "weak_to/1, resists/1, immune/1, neutral/1" do
    test "Bulbasaur's Grass and Poison answer the four buckets" do
      elements = ["Grass", "Poison"]

      assert TypeChart.weak_to(elements) == ["Fire", "Flying", "Ice", "Psychic"]
      assert "Water" in TypeChart.resists(elements)
      assert "Grass" in TypeChart.resists(elements)
      assert TypeChart.immune(elements) == []
      assert "Normal" in TypeChart.neutral(elements)
    end

    test "a Ground type is immune to Electric and nothing else" do
      assert TypeChart.immune(["Ground"]) == ["Electric"]
    end

    test "the four buckets partition the eighteen elements with no overlap" do
      elements = ["Ghost", "Dark"]

      buckets =
        TypeChart.weak_to(elements) ++
          TypeChart.resists(elements) ++
          TypeChart.immune(elements) ++ TypeChart.neutral(elements)

      assert Enum.sort(buckets) == TypeChart.elements()
    end

    test "an empty or unknown element list leaves everything neutral" do
      assert TypeChart.weak_to([]) == []
      assert TypeChart.neutral([]) == TypeChart.elements()
      assert TypeChart.weak_to(["Bogus"]) == []
    end
  end

  describe "effectiveness/1 — the tiers the detail page shows" do
    test "a quadruple weakness gets its own tier above the double one" do
      tiers = TypeChart.effectiveness(["Fire", "Flying"])

      assert %{label: "Muito Efetivo", kind: "weak", elements: ["Rock"]} = hd(tiers)
      assert Enum.any?(tiers, &(&1.label == "Efetivo" and "Water" in &1.elements))
    end

    test "empty tiers are dropped, so a type with no immunity shows no immunity row" do
      labels = ["Grass", "Poison"] |> TypeChart.effectiveness() |> Enum.map(& &1.label)

      refute "Imune" in labels
    end
  end
end
