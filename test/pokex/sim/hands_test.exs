defmodule Pokex.Sim.HandsTest do
  @moduledoc """
  O RESGATE É UM COMBO, não uma tecla — e modelar só a tecla fazia todo revive
  parecer um convite pra morrer.

  "Com o revive e stun em área antes de usar o revive tudo se resolve" (Lucas,
  2026-08-25). O preço de um revive é o campo vazio, e uma pilha dormindo não
  cobra esse preço.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Sim.Hands
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  @com_controle %Loadout{name: "Controlador", aoe: ["3"], single: ["4"], crowd: ["1"]}
  @sem_controle %Loadout{name: "Sem controle", aoe: ["3"], single: ["4"], crowd: []}
  @barra %Loadout{name: "Barra", aoe: ["3", "4", "5"], single: [], crowd: []}

  @stun %{
    rescue_stun_first: true,
    rescue_stun_settle_ms: 800,
    heal_skill_enabled: false,
    potion_enabled: false,
    heal_pct: 0,
    heal_skill_cooldown_ms: 0,
    potion_pct: 0,
    potion_cooldown_ms: 0
  }

  # O ninho do anel fica no canto SEGUINTE, a vinte tiles. Pra perguntar
  # qualquer coisa sobre stun é preciso estar em cima dele — então o personagem
  # e o pokémon nascem ao lado da pilha.
  defp mundo(loadout, knobs \\ %{}) do
    world =
      World.new(Scenario.ring(),
        seed: 7,
        loadout: loadout,
        knobs: Map.merge(%{nest_size: 3, nest_radius: 0, aggro_tiles: 12}, knobs)
      )

    %{x: x, y: y, z: z} = Enum.at(Scenario.ring().waypoints, 1)

    %{world | pos: {x, y, z}, own: %{world.own | pos: {x + 1, y, z}}}
  end

  defp ordens(overrides \\ %{}) do
    Map.merge(
      %{route: :hold, fire: :hold, opening: [], revive: :hold, potion: :hold},
      overrides
    )
  end

  describe "o prefixo do resgate" do
    test "o stun sai primeiro e o revive espera o settle" do
      world = mundo(@com_controle)

      {depois, hands} = Hands.obey(world, ordens(%{revive: :now}), Hands.new(), @stun)

      assert depois.revive_at == nil, "o corpo não pode sair de campo antes de a pilha dormir"
      assert hands.revive_at == world.clock + 800
      assert Enum.all?(depois.mobs, &World.asleep?(&1, depois)), "a pilha tem que estar dormindo"
    end

    test "e sai sozinho quando o settle passa, sem precisar da ordem de novo" do
      {world, hands} =
        Hands.obey(mundo(@com_controle), ordens(%{revive: :now}), Hands.new(), @stun)

      # a ordem já sumiu: o cérebro entra em :recovering no tique seguinte
      andado = World.step(world, 900)
      {depois, hands} = Hands.obey(andado, ordens(), hands, @stun)

      assert depois.revive_at != nil, "o resgate tem que terminar sozinho"
      assert hands.revive_at == nil
      refute depois.own.out?
    end

    test "sem controle pronto, revive direto — a falha cai pro lado de SALVAR" do
      world = mundo(@sem_controle)

      {depois, _hands} = Hands.obey(world, ordens(%{revive: :now}), Hands.new(), @stun)

      assert depois.revive_at != nil
      refute depois.own.out?
    end

    test "e com o pokémon já no chão não há stun: não sobrou ninguém pra apertar" do
      world = mundo(@com_controle)
      caido = %{world | own: %{world.own | out?: false, hp_pct: 0, alive?: false}}

      {depois, hands} = Hands.obey(caido, ordens(%{revive: :now}), Hands.new(), @stun)

      assert hands.revive_at == nil, "nada de esperar settle com o campo já vazio"
      assert depois.revive_at != nil
    end

    test "desligado, o revive é a tecla nua de antes" do
      world = mundo(@com_controle)
      sem_stun = %{@stun | rescue_stun_first: false}

      {depois, hands} = Hands.obey(world, ordens(%{revive: :now}), Hands.new(), sem_stun)

      assert hands.revive_at == nil
      assert depois.revive_at != nil
      refute Enum.any?(depois.mobs, &World.asleep?(&1, depois))
    end
  end

  describe "uma pilha dormindo" do
    defp dormindo(world) do
      {depois, _hands} = Hands.obey(world, ordens(%{revive: :now}), Hands.new(), @stun)
      depois
    end

    test "não anda" do
      world = dormindo(mundo(@com_controle, %{mob_ms_per_tile: 50}))
      antes = Enum.map(world.mobs, & &1.pos)

      depois = World.step(world, 500)

      assert Enum.map(depois.mobs, & &1.pos) == antes
    end

    test "e não morde — que é o preço do campo vazio, não cobrado" do
      world = dormindo(mundo(@com_controle, %{bite_every_ms: 100, bite_dmg: 20}))

      depois = World.step(world, 1_000)

      assert depois.own.hp_pct == world.own.hp_pct
      assert depois.player.hp_pct == 100
    end

    test "e acorda quando o sono acaba" do
      world = dormindo(mundo(@com_controle, %{stun_ms: 1_000}))

      depois = World.step(world, 1_100)

      refute Enum.any?(depois.mobs, &World.asleep?(&1, depois))
    end
  end

  describe "o preço da rajada" do
    # Este mundo tratava seis teclas como um evento instantâneo. No jogo dele
    # elas saem uma a cada `combat_skill_gap_ms`, e com o intervalo em 500ms uma
    # rajada de seis são dois segundos e meio em que o corpo não faz mais nada.
    # A própria Central já avisa que "é isso que limita o dano da caçada", e a
    # bancada media isso como zero.
    defp rajada(keys), do: ordens(%{fire: :free, opening: keys})

    defp soltando(keys, config) do
      Hands.obey(mundo(@barra), rajada(keys), Hands.new(), Map.merge(@stun, config))
    end

    test "N teclas ocupam o corpo por (N-1) intervalos" do
      {_world, hands} = soltando(["3", "4", "5"], %{skill_gap_ms: 500})

      assert hands.busy_until == 1_000
    end

    test "uma tecla só não custa intervalo nenhum" do
      {_world, hands} = soltando(["3"], %{skill_gap_ms: 500})

      assert hands.busy_until == 0
    end

    test "sem intervalo configurado, a rajada segue de graça" do
      {_world, hands} = soltando(["3", "4", "5"], %{})

      assert hands.busy_until == 0
    end

    test "enquanto a rajada sai, o corpo não anda nem aperta" do
      # É isto que faz uma tecla a mais custar alguma coisa: o corpo é um só.
      {world, hands} = soltando(["3", "4", "5"], %{skill_gap_ms: 500})

      antes = hd(world.mobs).hp
      ocupado = %{world | clock: world.clock + 200}

      {depois, _hands} =
        Hands.obey(
          ocupado,
          rajada(["3", "4", "5"]),
          hands,
          Map.merge(@stun, %{skill_gap_ms: 500})
        )

      assert hd(depois.mobs).hp == antes, "nenhuma tecla saiu enquanto a anterior ainda saía"
      assert depois.held == [], "as teclas de andar são soltas"
    end

    test "passada a rajada, o corpo volta a andar" do
      # Depois da janela ele obedece de novo. A prova é o ANDAR, não outra
      # rajada: as teclas da primeira ainda estão em cooldown, e um teste que
      # esperasse dano estaria medindo o cooldown, não a ocupação.
      {world, hands} = soltando(["3", "4", "5"], %{skill_gap_ms: 500})

      livre = %{world | clock: world.clock + 1_500}
      andando = ordens(%{route: :go})

      {depois, _hands} = Hands.obey(livre, andando, hands, Map.merge(@stun, %{skill_gap_ms: 500}))

      assert depois.held != [], "com o corpo livre, as teclas de andar voltam a ser seguradas"
    end
  end
end
