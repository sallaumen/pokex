defmodule Pokex.Bots.CooldownsTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Cooldowns
  alias Pokex.Calibration

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    # 7 slots × 2px wide: slots 1-6 bright/colourful (ready), slot 7 dark (cooldown).
    row = List.duplicate({200, 200, 0, 255}, 12) ++ List.duplicate({20, 20, 20, 255}, 2)
    bar = Pokex.PngFixtures.write!(Path.join(tmp, "bar.png"), [row])

    # single-element script = sticky: the Fake returns this PNG on every poll capture.
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, bar}]})

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 100,
      water_point: {0, 0},
      glow_region: {0, 0, 1, 1},
      battle_region: {0, 0, 1, 1},
      arena_region: {0, 0, 1, 1},
      neutral_point: {0, 0},
      skill_bar_region: {0, 0, 14, 1}
    })

    :ok
  end

  @tag :tmp_dir
  test "polls the skill bar, broadcasts readiness, and answers queries", %{} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Cooldowns.topic())
    {:ok, cd} = Cooldowns.start_link(name: nil)

    assert :ok = Cooldowns.run(cd)
    assert_receive {:cooldowns, %{states: states}}, 1_000
    assert states == [:ready, :ready, :ready, :ready, :ready, :ready, :cooldown]

    assert Cooldowns.ready_keys(cd) == ["1", "2", "3", "4", "5", "6"]
    assert Cooldowns.all_ready?(["4", "5", "6"], cd) == true
    # skill 7 is on cooldown → not all ready
    assert Cooldowns.all_ready?(["4", "5", "6", "7"], cd) == false

    assert :ok = Cooldowns.halt(cd)
    assert Cooldowns.snapshot(cd).states == nil
  end

  @tag :tmp_dir
  test "fails OPEN before any reading (never softlocks fishing)", %{} do
    {:ok, cd} = Cooldowns.start_link(name: nil)

    # not run yet → no reading
    assert Cooldowns.snapshot(cd).states == nil
    assert Cooldowns.all_ready?(["4", "5"], cd) == true
    assert Cooldowns.ready_keys(cd) == []
  end

  @tag :tmp_dir
  test "a query against a dead poller returns the fail-open default, no crash" do
    assert Cooldowns.all_ready?(["1"], :nonexistent_cooldowns) == true
    assert Cooldowns.ready_keys(:nonexistent_cooldowns) == []
  end
end
