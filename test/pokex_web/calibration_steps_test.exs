defmodule PokexWeb.CalibrationStepsTest do
  use ExUnit.Case, async: true

  alias PokexWeb.CalibrationSteps

  # THE 2026-07-20 BUG: the mini-game quick-fix steps had instructions but were
  # missing from `marking?/1`, so the page showed the instruction over NO
  # screenshot — a black page you cannot click. The two lists have to agree,
  # and now a new step that forgets one side fails here instead of in his face.
  test "every step with an instruction expects a click, and vice versa" do
    with_copy = CalibrationSteps.all() |> Map.keys() |> MapSet.new()
    marking = with_copy |> Enum.filter(&CalibrationSteps.marking?/1) |> MapSet.new()
    screenless = MapSet.new(CalibrationSteps.screenless())

    assert MapSet.difference(with_copy, MapSet.union(marking, screenless))
           |> MapSet.to_list() == [],
           "estes passos têm instrução mas não desenham a foto (página preta)"

    # a screenless step must never ALSO claim a click — that is the black page again
    assert MapSet.intersection(marking, screenless) |> MapSet.to_list() == []
  end

  test "the numbered run is 1..total with no gaps and no repeats" do
    numbered =
      CalibrationSteps.all()
      |> Map.keys()
      |> Enum.map(&CalibrationSteps.index/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    assert numbered == Enum.to_list(1..CalibrationSteps.total())
  end

  test "quick-fix steps are unnumbered but still mark" do
    # they belong to no numbered run, yet each must draw the screenshot
    for step <- [:mini_game_a, :mini_game_b, :minimap_cross, :pokemon_spot, :escape_point] do
      assert CalibrationSteps.index(step) == nil
      assert CalibrationSteps.marking?(step)
      assert CalibrationSteps.instruction(step)
    end
  end

  test "an unknown step marks nothing and says nothing" do
    refute CalibrationSteps.marking?(:nope)
    assert CalibrationSteps.instruction(:nope) == nil
    assert CalibrationSteps.index(:nope) == nil
  end
end
