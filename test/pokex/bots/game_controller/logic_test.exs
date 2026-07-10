defmodule Pokex.Bots.GameController.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.GameController.Logic

  defp input(overrides) do
    %{
      hp_pct: 100,
      threshold_pct: 50,
      enabled?: true,
      cooldown_ms: 60_000,
      last_rescue_at: nil,
      now: 10_000
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "decide/1" do
    test "holds while HP is at or above the rescue threshold" do
      assert Logic.decide(input(hp_pct: 100)) == :hold
      assert Logic.decide(input(hp_pct: 50)) == :hold
    end

    test "rescues the first time HP drops below the threshold" do
      assert Logic.decide(input(hp_pct: 49)) == :rescue
      assert Logic.decide(input(hp_pct: 10)) == :rescue
    end

    test "an unknown HP reading never rescues (fail-safe: don't burn a revive on nil)" do
      assert Logic.decide(input(hp_pct: nil)) == :hold
    end

    test "the toggle disables the rescue entirely" do
      assert Logic.decide(input(hp_pct: 5, enabled?: false)) == :hold
    end

    test "the protection cooldown blocks a second combo within the window" do
      # last combo at 10_000; now 40_000 → only 30s elapsed of a 60s cooldown
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 40_000)) == :hold
    end

    test "the combo fires again once the cooldown has fully elapsed" do
      # exactly 60s later → allowed
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 70_000)) == :rescue
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 200_000)) == :rescue
    end
  end

  describe "combo/1" do
    test "builds the recall → max-revive-on-photo → release → recentre sequence" do
      config = %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {70, 934},
        neutral_point: {1457, 666},
        step_ms: 40
      }

      assert Logic.combo(config) == [
               {:press, "q"},
               {:wait, 40},
               {:move, {70, 934}},
               {:wait, 40},
               {:press, "shift+q"},
               {:wait, 40},
               {:press, "q"},
               {:wait, 40},
               {:move, {1457, 666}}
             ]
    end
  end
end
