defmodule Pokex.Bots.Cavebot.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.{Logic, Route}

  @cfg %{
    arrival_tolerance: 1,
    walk_timeout_ms: 3000,
    stuck_max_retries: 4,
    clear_debounce_ms: 800,
    fight_timeout_ms: 20000,
    post_kill_dwell_ms: 1200
  }

  defp route do
    {:ok, r} = Route.append(elem(Route.append(Route.new("r"), {10, 10, 7}), 1), {20, 10, 7})
    r
  end

  defp world(pos, enemies \\ 0, combat \\ :hunting),
    do: %{pos: pos, enemies: enemies, combat_state: combat}

  test "no arranque liga o combate" do
    l = Logic.new(route(), @cfg)
    assert {l, :run_combat} = Logic.step(l, world({0, 0, 7}), 0)
    assert l.combat_running?
  end

  test "anda em direção ao waypoint e avança quando chega" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    assert {l, {:walk, dx, dy}} = Logic.step(l, world({5, 10, 7}), 10)
    assert {dx, dy} == {5, 0}
    assert {l, _} = Logic.step(l, world({10, 10, 7}), 20)
    assert l.wp_index == 1
  end

  test "inimigo aparece → estado fighting, sem novo comando" do
    {l, _} = Logic.step(Logic.new(route(), @cfg), world({10, 10, 7}, 2), 0)
    assert {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 10)
    assert l.state == :fighting
  end

  test "luta limpa sustentada por debounce volta a andar após o dwell" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 0)
    {l, _} = Logic.step(l, world({10, 10, 7}, 0), 900)
    assert l.state == :post_fight
    {l, _} = Logic.step(l, world({10, 10, 7}, 0), 900 + 1300)
    assert l.state == :walking
  end

  test "z mudou → block" do
    l = Logic.new(route(), @cfg)
    assert {_l, {:block, :floor_changed}} = Logic.step(l, world({10, 10, 6}), 0)
  end

  # --- casos extra: ramos :stuck / :fight_stalled / :blocked ---

  test "parado no lugar vira stuck e, esgotados os retries, bloqueia" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 10)

    # mesma posição antes do timeout: continua walking
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 2000)
    assert l.state == :walking

    # mesma posição por >= walk_timeout_ms (desde now=10) → stuck
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3010)
    assert l.state == :stuck
    assert l.retries == 0

    # stuck re-emite {:walk, dx, dy} incrementando retries até o gate
    l =
      Enum.reduce(1..4, l, fn i, acc ->
        {acc, {:walk, 5, 0}} = Logic.step(acc, world({5, 10, 7}), 3010 + i * 100)
        assert acc.retries == i
        acc
      end)

    assert {l, {:block, :stuck}} = Logic.step(l, world({5, 10, 7}), 4000)
    assert l.state == :blocked

    # blocked é terminal
    assert {_l, :none} = Logic.step(l, world({5, 10, 7}), 4100)
  end

  test "stuck: posição voltando a mudar retoma walking e zera retries" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 10)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3010)
    assert l.state == :stuck

    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3100)
    assert l.retries == 1

    # andou um tile → volta a walking, retries zerados
    {l, {:walk, 4, 0}} = Logic.step(l, world({6, 10, 7}), 3200)
    assert l.state == :walking
    assert l.retries == 0
  end

  test "fighting além do fight_timeout vira fight_stalled e depois bloqueia" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}

    # primeiro tick com inimigos marca o início da luta
    {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 0)
    assert l.state == :fighting

    # antes do timeout continua fighting
    {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 19_000)
    assert l.state == :fighting

    # timeout cumprido → fight_stalled
    {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 20_000)
    assert l.state == :fight_stalled
    assert l.retries == 0

    # fight_stalled emite nudges incrementando retries até o gate
    l =
      Enum.reduce(1..4, l, fn i, acc ->
        {acc, {:nudge, 0, 0}} = Logic.step(acc, world({10, 10, 7}, 2), 20_000 + i * 100)
        assert acc.retries == i
        acc
      end)

    assert {l, {:block, :fight_stalled}} = Logic.step(l, world({10, 10, 7}, 2), 21_000)
    assert l.state == :blocked
  end

  test "z mudou durante a luta também bloqueia (qualquer estado)" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    assert {l, {:block, :floor_changed}} = Logic.step(l, world({10, 10, 5}, 3), 0)
    assert l.state == :blocked

    # terminal: nem um novo desvio de z gera outra ação
    assert {_l, :none} = Logic.step(l, world({10, 10, 4}, 3), 10)
  end

  test "walking com pos desconhecida segura sem andar às cegas" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    assert {l, :none} = Logic.step(l, world(nil), 10)
    assert l.state == :walking
  end

  test "clear interrompido por inimigo novo zera o debounce" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 0)
    # inimigo voltou antes do debounce → clear zera
    {l, :none} = Logic.step(l, world({10, 10, 7}, 1), 400)
    assert l.state == :fighting
    # limpa de novo: precisa sustentar o debounce inteiro outra vez
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 500)
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 1200)
    assert l.state == :fighting
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 1400)
    assert l.state == :post_fight
  end

  test "wp_index dá a volta no fim da rota" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({0, 0, 7}), 0)
    {l, _} = Logic.step(l, world({10, 10, 7}), 10)
    assert l.wp_index == 1
    {l, _} = Logic.step(l, world({20, 10, 7}), 20)
    assert l.wp_index == 0
  end
end
