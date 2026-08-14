defmodule Pokex.Bots.Cavebot.HpGuardTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.{Logic, Route}

  @cfg %{
    arrival_tolerance: 1,
    walk_timeout_ms: 3000,
    stuck_max_retries: 4,
    clear_debounce_ms: 800,
    fight_timeout_ms: 20_000,
    post_kill_dwell_ms: 1200,
    blind_kick_ms: 1200,
    capture_wait_ms: 20_000,
    sweep_grace_ms: 1500,
    stop_wait_ms: 5_000,
    gather_wait_ms: 4_000,
    gather_wait_min_ms: 500,
    gather_wait_max_ms: 8_000,
    hp_abort_pct: 60,
    hp_resume_pct: 85
  }

  defp plain_route do
    {:ok, r} = Route.append(Route.new("reta"), {10, 10, 7})
    {:ok, r} = Route.append(r, {20, 10, 7})
    r
  end

  defp mob_route do
    plain_route()
    |> Route.set_action(0, :lure_start)
    |> Route.set_action(1, :lure_end)
    |> Route.set_timing(1, combo: ["3", "3", "4", "5"])
  end

  defp luring(route \\ mob_route(), cfg \\ @cfg) do
    %{Logic.new(route, cfg) | combat_running?: true, homed?: true, wp_index: 1}
  end

  defp world(pos, hp, enemies \\ 0),
    do: %{pos: pos, enemies: enemies, combat_state: :hunting, hp_pct: hp}

  test "one low reading does not abort the gather" do
    {l, action} = Logic.step(luring(), world({12, 10, 7}, 30, 3), 0)

    assert l.state == :walking
    assert match?({:walk, _, _}, action)
  end

  test "two low readings abort the gather into the fight" do
    {l, _} = Logic.step(luring(), world({12, 10, 7}, 55, 3), 0)
    {l, :none} = Logic.step(l, world({12, 10, 7}, 55, 3), 200)

    assert l.state == :fighting
    refute Logic.hold_fire?(l, 200)
  end

  test "the freed fire carries the destination kill spot's combo" do
    {l, _} = Logic.step(luring(), world({12, 10, 7}, 55, 3), 0)
    {l, _} = Logic.step(l, world({12, 10, 7}, 55, 3), 200)

    assert Logic.combo(l) == ["3", "4", "5"]
  end

  test "recovering releases the fire even inside the huddle wait" do
    l = %{luring() | state: :fighting, since: %{gather: 0}}

    assert Logic.hold_fire?(l, 100)
    refute Logic.hold_fire?(%{l | recovering?: true}, 100)
  end

  test "a plain leg stands still while recovering" do
    l = %{Logic.new(plain_route(), @cfg) | combat_running?: true, homed?: true, last_hp: 30}

    {l, :none} = Logic.step(l, world({5, 10, 7}, 30), 0)
    assert l.state == :walking
    assert Logic.recovery(l) == %{hp_pct: 30, resume_pct: 85}
  end

  test "an unreadable bar keeps the hold" do
    l = %{Logic.new(plain_route(), @cfg) | combat_running?: true, homed?: true, last_hp: 30}
    {l, :none} = Logic.step(l, world({5, 10, 7}, 30), 0)

    {l, :none} = Logic.step(l, world({5, 10, 7}, nil), 200)
    assert Logic.recovery(l) == %{hp_pct: nil, resume_pct: 85}
  end

  test "the route resumes after two readings at or above the resume threshold" do
    l = %{Logic.new(plain_route(), @cfg) | combat_running?: true, homed?: true, last_hp: 30}
    {l, :none} = Logic.step(l, world({5, 10, 7}, 30), 0)

    {l, :none} = Logic.step(l, world({5, 10, 7}, 100), 200)
    {l, action} = Logic.step(l, world({5, 10, 7}, 100), 400)

    assert Logic.recovery(l) == nil
    assert match?({:walk, _, _}, action)
  end

  test "post_fight does not resume while recovering" do
    l = %{
      Logic.new(plain_route(), @cfg)
      | combat_running?: true,
        homed?: true,
        state: :post_fight,
        since: %{dwell: 0},
        last_hp: 30
    }

    {l, :none} = Logic.step(l, world({10, 10, 7}, 30), 5_000)
    assert l.state == :post_fight

    {l, :none} = Logic.step(l, world({10, 10, 7}, 100), 5_200)
    {l, :none} = Logic.step(l, world({10, 10, 7}, 100), 5_400)
    assert l.state == :walking
  end

  test "enemies during a recovering walk are still a fight" do
    l = %{Logic.new(plain_route(), @cfg) | combat_running?: true, homed?: true, last_hp: 30}
    {l, :none} = Logic.step(l, world({5, 10, 7}, 30), 0)

    {l, :none} = Logic.step(l, world({5, 10, 7}, 30, 2), 200)
    assert l.state == :fighting
  end

  test "a config without the guard is inert" do
    cfg = Map.drop(@cfg, [:hp_abort_pct, :hp_resume_pct])
    l = %{luring(mob_route(), cfg) | last_hp: 5}

    {l, action} = Logic.step(l, world({12, 10, 7}, 5, 4), 0)

    assert l.state == :walking
    assert match?({:walk, _, _}, action)
    assert Logic.recovery(l) == nil
  end

  test "a world without a reading is inert" do
    l = luring()
    {l, action} = Logic.step(l, %{pos: {12, 10, 7}, enemies: 3, combat_state: :hunting}, 0)

    assert l.state == :walking
    assert match?({:walk, _, _}, action)
  end
end
