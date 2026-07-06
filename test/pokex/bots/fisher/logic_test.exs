defmodule Pokex.Bots.Fisher.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fisher.Logic

  def config do
    %{
      water_point: {800, 400},
      neutral_point: {860, 470},
      battle_first_row: {1466, 138},
      fallback_points: [{800, 400}, {768, 400}, {832, 400}, {800, 368}, {800, 432}],
      skill_keys: ["1", "2"],
      tile_size: 32,
      tick_ms_watching: 200,
      tick_ms_fighting: 1000,
      tick_ms_default: 300,
      wait_focus_ms: 150,
      wait_after_equip_ms: 300,
      wait_assess_ms: 1500,
      wait_loot_ms: 400,
      wait_after_capture_ms: 2000,
      watch_timeout_ms: 30_000,
      fight_timeout_ms: 90_000,
      max_consecutive_failures: 3,
      hostile_scan_every: 2
    }
  end

  def cursor_obs, do: %{cursor: {500, 500}}

  def advance_to(:focusing), do: elem(Logic.start(Logic.new(config()), 0), 0)

  def advance_to(:equipping) do
    {l, _} = Logic.step(advance_to(:focusing), cursor_obs(), 0)
    l
  end

  def advance_to(:casting) do
    {l, _} = Logic.step(advance_to(:equipping), cursor_obs(), 200)
    l
  end

  def advance_to(:watching) do
    {l, _} = Logic.step(advance_to(:casting), cursor_obs(), 600)
    l
  end

  test "start only from idle or error" do
    {l, []} = Logic.start(Logic.new(config()), 0)
    assert l.state == :focusing
    # começar de novo não muda nada
    assert {^l, []} = Logic.start(l, 10)
  end

  test "focusing clicks neutral point and waits" do
    {l, actions} = Logic.step(advance_to(:focusing), cursor_obs(), 0)
    assert l.state == :equipping
    assert actions == [{:click, :left, {860, 470}}]
    assert l.waiting_until == 150
    # tick dentro da espera: nada acontece
    assert {^l, []} = Logic.step(l, cursor_obs(), 100)
  end

  test "equipping presses shift+z then casting clicks water" do
    {l, actions} = Logic.step(advance_to(:equipping), cursor_obs(), 200)
    assert l.state == :casting
    assert actions == [{:press, "shift+z"}]

    {l, actions} = Logic.step(l, cursor_obs(), 600)
    assert l.state == :watching
    assert actions == [{:click, :left, {800, 400}}]
    assert l.counters.cycles == 1
  end

  test "watching: no glow keeps watching, glow hooks and assesses" do
    watching = advance_to(:watching)
    assert {^watching, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 700)

    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 900)
    assert l.state == :assessing
    assert actions == [{:press, "shift+z"}]
    assert l.counters.hooked == 1
    assert l.waiting_until == 900 + 1500
  end

  test "watching times out back to casting" do
    watching = advance_to(:watching)
    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 600 + 30_001)
    assert l.state == :casting
    assert [{:log, _}] = actions
  end

  test "assessing: wild goes to fighting, nothing goes back to equipping" do
    watching = advance_to(:watching)
    {assessing, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 900)

    {fighting, []} = Logic.step(assessing, Map.put(cursor_obs(), :wild, true), 3000)
    assert fighting.state == :fighting
    refute fighting.targeted?

    {recast, [{:log, _}]} = Logic.step(assessing, Map.put(cursor_obs(), :wild, false), 3000)
    assert recast.state == :equipping
  end

  test "kill corner stops from any active state" do
    {l, actions} = Logic.step(advance_to(:watching), %{cursor: {5, 5}, glow: true}, 700)
    assert l.state == :idle
    assert [{:log, _}] = actions
  end

  test "needs per state" do
    assert Logic.needs(advance_to(:focusing)) == [:cursor]
    assert Logic.needs(advance_to(:watching)) == [:cursor, :glow]
    assert Logic.needs(%Logic{state: :idle}) == []
  end

  test "tick_interval per state" do
    assert Logic.tick_interval(advance_to(:watching)) == 200
    assert Logic.tick_interval(advance_to(:focusing)) == 300
  end

  test "io_failed counts and eventually errors" do
    l = advance_to(:watching)
    {l, _} = Logic.io_failed(l, "boom", 700)
    assert l.state == :equipping
    assert l.failures == 1
    assert l.counters.failures == 1

    {l, _} = Logic.io_failed(l, "boom", 800)
    {l, _} = Logic.io_failed(l, "boom", 900)
    assert l.state == :error
    assert l.error =~ "boom"
  end
end
