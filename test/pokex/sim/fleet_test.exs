defmodule Pokex.Sim.FleetTest do
  @moduledoc """
  The proof the whole undertaking exists for: the REAL engine, with not one line
  changed, deciding over a world that is not the game.

  It starts its OWN `Engine.Worker` rather than the app-global one — an isolated
  supervisor in a test must never arm the fleet the machine is running.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Bots.Engine
  alias Pokex.Perception.WorldState
  alias Pokex.Sim.Runner
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  @facts [:battle, :pokemon, :skill_bar, :minimap, :situation, :orders, :hunt]

  defp route do
    %Route{
      name: "sim",
      waypoints:
        for {x, y, z, gather} <- [{100, 200, 5, nil}, {110, 200, 5, 2_000}] do
          %{
            x: x,
            y: y,
            z: z,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: nil,
            gather_ms: gather,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end

  setup do
    # The fence puts a bar here while armed (`Sim.Fence`'s @swaps). These tests
    # boot the pieces by hand, so they do the same by hand — without it the
    # engine has no keys and every assertion would be measuring an empty room.
    Application.put_env(:pokex, :simulated_loadout, Pokex.Sim.Loadout.fallback())
    on_exit(fn -> Application.delete_env(:pokex, :simulated_loadout) end)

    for key <- @facts, do: WorldState.forget(key)
    on_exit(fn -> for key <- @facts, do: WorldState.forget(key) end)

    counter = :counters.new(1, [])
    :counters.put(counter, 1, System.monotonic_time(:millisecond))

    runner =
      start_supervised!(
        {Runner,
         name: nil,
         tick_ms: 10,
         clock: fn -> :counters.get(counter, 1) end,
         route: route(),
         knobs: %{nest_size: 5, nest_radius: 1, screen_w: 199, screen_h: 199, ms_per_tile: 100}}
      )

    Runner.play(runner)
    Runner.tick_now(runner)

    engine = start_supervised!({Engine.Worker, name: nil, active: true}, id: :sim_engine)
    :ok = Engine.Worker.run(engine)

    %{runner: runner, engine: engine, advance: fn ms -> :counters.add(counter, 1, ms) end}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp wait_for_fact(key, tries \\ 200) do
    case WorldState.get(key, 10_000, now()) do
      {:ok, obs} ->
        obs

      _missing when tries > 0 ->
        Process.sleep(10)
        wait_for_fact(key, tries - 1)

      _missing ->
        flunk("the real engine never published #{key} from the fake world")
    end
  end

  @tag :tmp_dir
  @tag :capture_log
  test "the real engine counts the fake world's monsters" do
    picture = wait_for_fact(:situation)

    assert picture.enemies == 5
    refute picture.blind?
  end

  @tag :tmp_dir
  @tag :capture_log
  test "the real engine publishes orders carrying a reason in his own words" do
    orders = wait_for_fact(:orders)

    assert orders.route in [:go, :hold]
    assert orders.fire in [:free, :hold]
    assert is_binary(orders.why)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a pile the ruler rejects reads as not worth fighting", %{runner: runner} do
    Runner.load(runner, route(),
      knobs: %{nest_size: 1, nest_radius: 0, screen_w: 199, screen_h: 199}
    )

    Runner.tick_now(runner)

    picture = wait_for_worth(false)

    assert picture.enemies == 1
    refute picture.worth_fighting?
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a pile above the ruler reads as worth fighting" do
    picture = wait_for_worth(true)

    assert picture.enemies >= 3
    assert picture.worth_fighting?
  end

  # THE TEST THAT WAS MISSING, and he found the hole by playing: "rodei uma
  # simulação e aparentemente ele não usou nenhuma skill nem andou" (Lucas,
  # 2026-08-25). Every test above proves the engine THINKS. None proved that
  # anything HAPPENS — and a simulator nobody acts in is a screen, not a
  # simulator.
  #
  # Its own runner, on the REAL clock and a REAL screen (15x11), because both
  # shortcuts the tests above take would hide the bug: a fake clock that runs
  # ahead makes every `:orders` fact read as stale and nothing is ever obeyed,
  # and a 199-tile screen makes the engine hold the route ten tiles from a pile
  # its area can never reach.
  describe "com o cérebro no comando, o mundo se mexe" do
    setup do
      Application.put_env(:pokex, :simulated_loadout, Pokex.Sim.Loadout.fallback())
      on_exit(fn -> Application.delete_env(:pokex, :simulated_loadout) end)

      runner =
        start_supervised!(
          {Runner,
           name: nil,
           tick_ms: 20,
           route: route(),
           knobs: %{
             nest_size: 4,
             nest_radius: 1,
             screen_w: 15,
             screen_h: 11,
             ms_per_tile: 60,
             mob_ms_per_tile: 80,
             skill_cooldown_ms: 400
           }},
          id: :acting_runner
        )

      Runner.play(runner)
      Runner.auto(runner, true)

      engine = start_supervised!({Engine.Worker, name: nil, active: true}, id: :acting_engine)
      :ok = Engine.Worker.run(engine)

      %{runner: runner}
    end

    test "as teclas saem — a barra é uma consequência, não um enfeite", %{runner: runner} do
      world = play(runner, &(World.observe(&1, :skill_bar).ready_keys != todas(&1)))

      refute World.observe(world, :skill_bar).ready_keys == todas(world),
             "nenhuma tecla entrou em cooldown: nada foi apertado"
    end

    test "e os monstros morrem", %{runner: runner} do
      world = play(runner, &(&1.stats.killed > 0))

      assert world.stats.killed > 0, "o cérebro mandou atacar e ninguém morreu"
    end

    test "o personagem anda a rota quando não há o que lutar", %{runner: runner} do
      Runner.load(runner, route(),
        knobs: %{nest_size: 0, stray_chance_pct: 0, ms_per_tile: 60, screen_w: 15, screen_h: 11}
      )

      inicio = Runner.world(runner).pos
      world = play(runner, &(&1.pos != inicio))

      assert world.pos != inicio, "o cérebro mandou andar e o personagem ficou parado"
    end

    test "sem entregar o comando, nada acontece — e é assim de propósito", %{runner: runner} do
      Runner.auto(runner, false)
      Runner.load(runner, route(), knobs: %{nest_size: 4, screen_w: 15, screen_h: 11})

      inicio = Runner.world(runner)
      world = play(runner, fn _nunca -> false end, 60)

      assert world.pos == inicio.pos
      assert world.stats.killed == 0
    end
  end

  defp todas(world), do: world.keys |> Map.keys() |> Enum.sort()

  # O runner tem relógio próprio de verdade aqui: basta deixar o tempo passar.
  # O ORÇAMENTO tem que caber o RELÓGIO DO CÉREBRO, não a impressão de quem
  # escreveu o teste. Eram 4s, e o teto de `size_ceiling_ms` virou 8: numa
  # máquina de 2 núcleos (o CI) a pilha assenta depois do orçamento e o teste
  # falha por pressa, não por bug (25/08). Só se paga na falha — o laço volta no
  # instante em que a condição vale.
  # A CORRIDA DELE, 25/08: "a vida dele foi descendo, e ele não tentou usar
  # revive. Quando ele notou que a vida estava baixa, ele caiu porque morreu, e
  # os pokémons inimigos mataram o meu personagem."
  #
  # O cérebro MANDAVA reviver; a aba não tinha mãos pra isso — nem pra curar,
  # nem pra beber poção — porque a obediência estava escrita duas vezes e a
  # metade viva não tinha a escada do suporte nem os pisos do `Settings`.
  #
  # A queda vem do ROTEIRO do cenário, no relógio do MUNDO: esperar a física
  # derrubar a barra é esperar o relógio da máquina, e numa máquina carregada
  # isso é uma corrida contra o timeout em vez de um teste.
  describe "com o cérebro no comando, a vida é defendida" do
    setup do
      Application.put_env(:pokex, :simulated_loadout, Pokex.Sim.Loadout.fallback())
      on_exit(fn -> Application.delete_env(:pokex, :simulated_loadout) end)

      runner = start_supervised!({Runner, name: nil, tick_ms: 20}, id: :defended_runner)

      Runner.load_scenario(runner, Scenario.get("vermelho"), [], %{
        ms_per_tile: 60,
        mob_ms_per_tile: 80,
        skill_cooldown_ms: 400
      })

      Runner.play(runner)
      Runner.auto(runner, true)

      engine = start_supervised!({Engine.Worker, name: nil, active: true}, id: :defended_engine)
      :ok = Engine.Worker.run(engine)

      %{runner: runner}
    end

    # A PROVA de que a ordem foi obedecida é o corpo SAIR de campo: é o que um
    # revive aceito faz, e é a coisa mais cedo que dá pra observar.
    test "a barra cai no vermelho e o revive é OBEDECIDO", %{runner: runner} do
      ferido = play(runner, &(&1.own.hp_pct < 30))
      assert ferido.own.hp_pct < 30, "o roteiro não chegou a derrubar a barra"

      revivendo = play(runner, &(&1.own.out? == false or &1.own.hp_pct == 100))

      assert revivendo.own.out? == false or revivendo.own.hp_pct == 100,
             "o revive foi ordenado e ninguém obedeceu"
    end

    # O personagem paga UM POUCO por revive — o corpo sai de campo pelo settle e
    # as mordidas passam a ser dele — e é esse o preço que a R3 cobra. O que ele
    # não pode é MORRER, que foi o fim da corrida dele.
    test "e o personagem sobrevive ao preço", %{runner: runner} do
      play(runner, &(&1.own.hp_pct < 30))
      world = play(runner, &(&1.own.out? == false or &1.own.hp_pct == 100))

      assert world.player.alive?
    end
  end

  # "os monstros não renascem" — a aba viva rodava com `respawn_ms: nil`, o
  # padrão que existe pros EXPERIMENTOS, onde um bicho chegando de fora do palco
  # estragaria a pergunta.
  describe "o ninho volta" do
    test "o mundo vivo herda o respawn dos ajustes, não o nil do experimento" do
      runner = start_supervised!({Runner, name: nil, route: route()}, id: :respawn_runner)

      assert Runner.world(runner).knobs.respawn_ms == Pokex.Settings.get(:sim_respawn_ms)
    end

    test "e os pisos entre dois revives vêm dos ajustes dele" do
      runner = start_supervised!({Runner, name: nil, route: route()}, id: :floors_runner)
      knobs = Runner.world(runner).knobs

      assert knobs.revive_cooldown_ms == Pokex.Settings.get(:rescue_cooldown_ms)
      assert knobs.fainted_revive_cooldown_ms == Pokex.Settings.get(:fainted_revive_cooldown_ms)
    end
  end

  defp play(runner, until?, tries \\ 1_500) do
    world = Runner.world(runner)

    cond do
      until?.(world) -> world
      tries > 0 -> Process.sleep(10) && play(runner, until?, tries - 1)
      true -> world
    end
  end

  defp wait_for_worth(want, tries \\ 200) do
    picture = wait_for_fact(:situation)

    cond do
      picture.worth_fighting? == want -> picture
      tries > 0 -> Process.sleep(10) && wait_for_worth(want, tries - 1)
      true -> flunk("worth_fighting? never became #{want}")
    end
  end
end
