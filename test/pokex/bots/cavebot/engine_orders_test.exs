defmodule Pokex.Bots.Cavebot.EngineOrdersTest do
  @moduledoc """
  The road obeying the engine — and, more importantly, what happens when the
  engine goes quiet.

  Two rules of his are decided here. R2, the ceiling on greed: the engine can
  ask the route to stop extending a gathering, because dragging a pile far from
  where it spawned makes it vanish. And the corner mark that stopped being an
  order: "às vezes você reseta os cooldowns quando não precisa, que o meu
  pokémon tá cheio de vida lá e cheio de cooldown também. Você reseta só porque
  é um local da rota que parece que faz sentido" (2026-08-17).
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.{Logic, Route}

  defp route do
    {:ok, route} = Route.append(Route.new("cavena"), {10, 10, 7})
    {:ok, route} = Route.append(route, {20, 10, 7})
    route
  end

  defp logic, do: Logic.new(route(), config())

  defp config do
    %{
      arrival_tolerance: 1,
      blind_kick_ms: 100_000,
      walk_timeout_ms: 100_000,
      stuck_max_retries: 3,
      clear_debounce_ms: 0,
      fight_timeout_ms: 100_000,
      post_kill_dwell_ms: 0,
      capture_wait_ms: 0,
      sweep_grace_ms: 0,
      stop_wait_ms: 0,
      gather_wait_ms: 0,
      fight_only_at_stops: true,
      stair_probe_ms: 100_000,
      stair_max_probes: 3,
      stair_step_ms: 100,
      stair_step_taps: 1,
      hp_abort_pct: 0,
      hp_resume_pct: 80,
      park_tiles: nil
    }
  end

  defp world(overrides \\ %{}) do
    Map.merge(
      # deliberately NOT standing on a corner: an arrival tick has nothing to
      # hold, and "held the road" only means something while there is a step to
      # take
      %{pos: {5, 10, 7}, enemies: 0, combat_state: :hunting, hp_pct: 90, fainted?: false},
      overrides
    )
  end

  # QUEM DECLARA O FIM DA LUTA É A TELA, NUNCA A ORDEM. Com `engine_active`
  # (true em produção, false em `config/test.exs` — por isso a suíte inteira
  # não enxergava isto) toda tela limpa responde `route: :go`, e a luta ia pro
  # `follow_route` em vez de passar pelo `fight_clear/2` — a ÚNICA porta do
  # `:post_fight`. A caçada latchava em `:fighting` para sempre: some a rodada
  # da esquina (varredura, revive de cooldown) e, caro, o `post_kill_dwell_ms`
  # nunca segura o pé — o personagem anda debaixo da bola enquanto o Catcher
  # mira num ponto de TELA.
  describe "com o cérebro ligado" do
    defp lutando(logic) do
      {logic, :run_combat} = Logic.step(logic, world(), 0)
      {logic, _} = Logic.step(logic, world(%{engine?: true, enemies: 1}), 50)
      assert logic.state == :fighting
      logic
    end

    test "a tela limpa encerra a luta mesmo com ordem de andar" do
      limpo = world(%{engine?: true, enemies: 0})

      # dois tiques porque a tela limpa é carimbada e só então debatida
      # (`clear_debounce_ms`), como em toda outra luta
      {logic, _} = Logic.step(lutando(logic()), limpo, 100)
      {logic, _} = Logic.step(logic, limpo, 200)

      assert logic.state == :post_fight
    end

    test "mas com bicho na tela a ordem manda: anda pra juntar, sem encerrar" do
      {logic, _} = Logic.step(lutando(logic()), world(%{engine?: true, enemies: 3}), 100)

      assert logic.state == :fighting
    end

    test "e cego não é limpo: sem leitura, a luta continua" do
      {logic, _} = Logic.step(lutando(logic()), world(%{engine?: true, enemies: nil}), 100)

      assert logic.state == :fighting
    end

    test "travado no alvo também não é limpo, mesmo com a lista vazia" do
      {logic, _} =
        Logic.step(
          lutando(logic()),
          world(%{engine?: true, enemies: 0, combat_state: :fighting}),
          100
        )

      assert logic.state == :fighting
    end
  end

  # The machine has to be walking before "hold the road" means anything.
  defp walking(logic) do
    {logic, :run_combat} = Logic.step(logic, world(), 0)
    logic
  end

  describe "the engine asking the road to wait (R2)" do
    test "a hold stops the step" do
      logic = walking(logic())

      {_logic, action} = Logic.step(logic, world(%{route_hold?: true}), 100)

      assert action == :none
    end

    test "without the ask, the route walks" do
      logic = walking(logic())

      {_logic, action} = Logic.step(logic, world(), 100)

      refute action == :none
    end

    # A deliberate stop must not spend the walk's patience — otherwise the wait
    # itself is what declares the hunt stuck, which is the bug the recovery hold
    # already had to fix once.
    test "waiting on the engine never reads as stuck" do
      logic = walking(logic())

      logic =
        Enum.reduce(1..40, logic, fn tick, acc ->
          {acc, :none} = Logic.step(acc, world(%{route_hold?: true}), tick * 1_000)
          acc
        end)

      assert logic.state == :walking
    end
  end

  describe "the cooldown_revive mark is a hint now" do
    defp at_kill_spot do
      {:ok, route} = Route.append(Route.new("cavena"), {10, 10, 7})
      route = Route.set_stop(route, 0, :cooldown_revive, true)

      %{Logic.new(route, config()) | state: :post_fight, wp_index: 1, combat_running?: true}
    end

    test "a hurt pokémon still gets the reset the corner asks for" do
      {_logic, action} =
        Logic.step(at_kill_spot(), world(%{reset_worth?: true, reset_note: "vida 40%"}), 100)

      assert action == :cooldown_revive
    end

    test "a full bar and full health skips it, saying which reading decided" do
      {_logic, action} =
        Logic.step(
          at_kill_spot(),
          world(%{reset_worth?: false, reset_note: "vida 92%, cooldowns prontos"}),
          100
        )

      assert action == {:skip_reset, "vida 92%, cooldowns prontos"}
    end

    # An engine that is not running, or a reading that could not be taken, must
    # never be the reason a corner he marked stops working.
    test "with no engine speaking, the mark runs exactly as it always did" do
      {_logic, action} = Logic.step(at_kill_spot(), world(), 100)

      assert action == :cooldown_revive
    end

    test "an unknown reading is not a refusal" do
      {_logic, action} = Logic.step(at_kill_spot(), world(%{reset_worth?: :unknown}), 100)

      assert action == :cooldown_revive
    end
  end
end
