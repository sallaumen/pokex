defmodule Pokex.Bots.Cavebot.HpGuardTest do
  @moduledoc """
  O que sobrou da guarda de HP: o CHÃO. A metade percentual (abandonar a
  mobada abaixo de X% e voltar em Y%) morreu em 28/08 — ela prendia a rota num
  limbo sem caminho de recuperação ("ele fica lá parado que nem um idiota, até
  a vida cair o suficiente pra ele usar o ressurect"). Vida é assunto das
  faixas do cérebro; o cavebot só espera quando NÃO HÁ pokémon em pé.
  """
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
    stop_wait_ms: 5_000,
    gather_wait_ms: 4_000,
    gather_wait_min_ms: 500,
    gather_wait_max_ms: 8_000
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

  defp walking(route \\ plain_route()) do
    %{Logic.new(route, @cfg) | combat_running?: true, homed?: true}
  end

  defp world(pos, hp, enemies \\ 0),
    do: %{pos: pos, enemies: enemies, combat_state: :hunting, hp_pct: hp}

  defp down(pos \\ {5, 10, 7}),
    do: %{pos: pos, enemies: 0, combat_state: :hunting, hp_pct: nil, fainted?: true}

  defp back(pos \\ {5, 10, 7}),
    do: %{pos: pos, enemies: 0, combat_state: :hunting, hp_pct: 100, fainted?: false}

  # A REGRESSÃO DA RECLAMAÇÃO DELE: vida baixa com pokémon EM PÉ não segura
  # mais nada — nem a rota, nem a mobada. O amarelo do cérebro é quem fecha a
  # rodada e revive; parado esperando 85% era só apanhar de graça.
  test "vida baixa com pokémon em pé NÃO segura a rota" do
    l = %{walking(mob_route()) | wp_index: 1, last_hp: 30}

    {l, action} = Logic.step(l, world({12, 10, 7}, 30, 3), 0)

    assert l.state == :walking
    assert match?({:walk, _, _}, action)
    assert Logic.recovery(l) == nil
  end

  test "the route holds while the pokémon is on the floor" do
    l = walking()

    {l, :none} = Logic.step(l, down(), 0)

    assert l.state == :walking
    assert Logic.recovery(l) == %{hp_pct: nil}
  end

  # Standing still is the ORDER here, so it must not read as "não saiu do
  # lugar": every floor revive outlasts walk_timeout_ms.
  test "a long floor hold does not come back as :stuck" do
    l = walking()

    {l, {:walk, _, _}} = Logic.step(l, world({5, 10, 7}, 100), 0)
    {l, :none} = Logic.step(l, down(), 200)
    assert Logic.recovery(l)

    {l, :none} = Logic.step(l, down(), 30_000)
    {l, action} = Logic.step(l, back(), 30_200)

    assert l.state == :walking
    assert match?({:walk, _, _}, action)
  end

  test "enemies during a floor hold are still a fight" do
    l = walking()
    {l, :none} = Logic.step(l, down(), 0)

    {l, :none} = Logic.step(l, %{down() | enemies: 2}, 200)
    assert l.state == :fighting
  end

  test "the freed fire carries the destination kill spot's combo" do
    l = %{walking(mob_route()) | wp_index: 1}
    {l, _} = Logic.step(l, Map.put(down({12, 10, 7}), :enemies, 3), 0)
    {l, _} = Logic.step(l, Map.put(down({12, 10, 7}), :enemies, 3), 200)

    assert Logic.combo(l) == ["3", "4", "5"]
  end

  test "a floor hold releases the fire even inside the huddle wait" do
    l = %{walking(mob_route()) | wp_index: 1, state: :fighting, since: %{gather: 0}}

    assert Logic.hold_fire?(l, 100)
    refute Logic.hold_fire?(%{l | recovering?: true}, 100)
  end

  test "post_fight does not resume while the pokémon is down" do
    l = %{walking() | state: :post_fight, since: %{dwell: 0}}

    {l, :none} = Logic.step(l, Map.put(down({10, 10, 7}), :enemies, 0), 5_000)
    assert l.state == :post_fight

    {l, :none} = Logic.step(l, back({10, 10, 7}), 5_200)
    assert l.state == :walking
  end

  test "he comes back and the route walks on the same tick" do
    l = walking()

    {l, :none} = Logic.step(l, down(), 0)
    {l, action} = Logic.step(l, back(), 200)

    assert Logic.recovery(l) == nil
    assert match?({:walk, _, _}, action)
  end
end
