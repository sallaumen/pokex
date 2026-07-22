defmodule Pokex.Perception.BattleEnemiesTest do
  @moduledoc """
  The battle list, read as what it is: WHO is there and how hurt they are.

  Two things this pins beyond the readings themselves. The row geometry comes
  from the profile (rows repeat every 46px) rather than from
  `battle_row_height`, which still says 52 — tuned when the panel sat 173px
  higher. And the region comes from the layout, because Lucas's hand-marked
  one now covers the minimap: against the same capture it finds ONE enemy
  where there are six.
  """
  use ExUnit.Case, async: false

  alias Pokex.{Calibration, Layout, ScreenFixtures, Settings}
  alias Pokex.Perception.Interpret
  alias Pokex.Vision.Frame

  defp battle(fixture) do
    frame = ScreenFixtures.frame!(fixture)
    {:ok, fix} = Layout.locate(frame)
    region = Layout.region(:battle_list, fix)
    {x, y, w, h} = region
    calib = %Calibration{scale: 1.0, battle_region: region, layout: fix}

    Interpret.battle(Frame.crop(frame, {x, y, w, h}), calib, Settings.all())
  end

  test "reads every enemy in a full list, by name and by health" do
    obs = battle("ultrawide_3440x1440_outro_mapa")

    assert Enum.map(obs.enemies_detail, & &1.name) == [
             "Sceptile",
             "Magikarp",
             "Magikarp",
             "Smeargle",
             "Magikarp",
             "Magikarp"
           ]

    assert Enum.all?(obs.enemies_detail, &(&1.hp_pct > 0.9))
    refute Enum.any?(obs.enemies_detail, & &1.shiny?)
  end

  test "a single-enemy list reads that one enemy" do
    obs = battle("ultrawide_3440x1440_full")

    assert [%{row: 0, name: "Pidgeot", shiny?: false, hp_pct: hp}] = obs.enemies_detail
    assert_in_delta hp, 0.86, 0.03
  end

  test "the hand-marked region loses five of the six enemies" do
    # Not a hypothetical: this is what combat has been seeing.
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_outro_mapa")
    {:ok, fix} = Layout.locate(frame)
    stale = {3178, 287, 250, 347}
    {x, y, w, h} = stale

    obs =
      Interpret.battle(
        Frame.crop(frame, {x, y, w, h}),
        %Calibration{scale: 1.0, battle_region: stale, layout: nil},
        Settings.all()
      )

    assert length(obs.enemies) < 3
    assert obs.enemies_detail == []

    derived = battle("ultrawide_3440x1440_outro_mapa")
    assert length(derived.enemies) == 6
  end

  test "an empty list describes nobody rather than guessing" do
    obs = battle("ultrawide_3440x1440_terceiro")

    assert [%{name: "Sceptile"}] = obs.enemies_detail
  end
end
