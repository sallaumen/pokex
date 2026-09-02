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

    # A ordem `:prepare` é o revive de tela limpa (R11): gastar o controle ali
    # é o que o deixava gelado pro revive PERIGOSO — a cadeia da morte de 28/08.
    test ":prepare revive na hora, sem gastar o controle" do
      world = mundo(@com_controle)

      {depois, hands} = Hands.obey(world, ordens(%{revive: :prepare}), Hands.new(), @stun)

      assert hands.revive_at == nil, "preparo não espera settle nenhum"
      assert depois.revive_at != nil
      refute depois.own.out?
      refute Enum.any?(depois.mobs, &World.asleep?(&1, depois)), "o controle ficou guardado"
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

    test "só as teclas PRONTAS saem, e só elas custam" do
      # O bot de verdade faz isso desde sempre: `Combat.Logic.ready_in_priority/2`
      # filtra a ordem pela leitura da barra ("only READY skills fire"). Estas
      # mãos foram escritas sem esse passo, e o resultado foi um bot paralisado:
      # com a barra gasta ele pedia quatro teclas, pagava os intervalos por
      # todas, nenhuma saía, e no tique seguinte pedia de novo.
      #
      # MEDIDO no traço de 40s: ocupado em 79% dos tiques, e em 77% ocupado SEM
      # ter apertado nada — parado no meio de 21 monstros com a vida caindo.
      # Depois do conserto: 9% e 8%.
      mundo = mundo(@barra)
      gasta = %{mundo | keys: Map.put(mundo.keys, "4", %{mundo.keys["4"] | ready_at: 99_999})}

      {_world, hands} =
        Hands.obey(
          gasta,
          rajada(["3", "4", "5"]),
          Hands.new(),
          Map.merge(@stun, %{skill_gap_ms: 500})
        )

      # Duas prontas de três: um intervalo, não dois.
      assert Hands.busy_until(hands) == 500
    end

    test "com a barra INTEIRA em cooldown, a rajada não custa nada" do
      # É este o caso que paralisava: pagar por uma rajada que não sai deixa o
      # corpo ocupado pra sempre, porque no tique seguinte ele pede de novo.
      mundo = mundo(@barra)

      gasta = %{
        mundo
        | keys: Map.new(mundo.keys, fn {k, v} -> {k, %{v | ready_at: 99_999}} end)
      }

      {_world, hands} =
        Hands.obey(
          gasta,
          rajada(["3", "4", "5"]),
          Hands.new(),
          Map.merge(@stun, %{skill_gap_ms: 500})
        )

      assert Hands.busy_until(hands) == 0
    end

    test "N teclas ocupam o corpo por (N-1) intervalos" do
      {_world, hands} = soltando(["3", "4", "5"], %{skill_gap_ms: 500})

      assert Hands.busy_until(hands) == 1_000
    end

    test "uma tecla só não custa intervalo nenhum" do
      {_world, hands} = soltando(["3"], %{skill_gap_ms: 500})

      assert Hands.busy_until(hands) == 0
    end

    test "sem intervalo configurado, a rajada segue de graça" do
      {_world, hands} = soltando(["3", "4", "5"], %{})

      assert Hands.busy_until(hands) == 0
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

    # E o preço tem uma segunda metade que o `busy_until` sozinho não cobrava:
    # a tecla não sai AGORA, ela sai quando chega a vez dela. Uma rajada de sete
    # teclas com o intervalo dele em 300ms tem a última saindo 1,8s depois da
    # primeira — e nesse intervalo o bicho pode já ter morrido. Cobrar o tempo e
    # entregar o dano todo no instante zero mede um bot que acerta o passado.
    defp gastas(world) do
      for {key, %{ready_at: at}} <- world.keys, at > world.clock, do: key
    end

    test "as teclas saem uma a cada intervalo, não todas no primeiro instante" do
      {world, _hands} = soltando(["3", "4", "5"], %{skill_gap_ms: 500})

      assert gastas(world) == ["3"]
    end

    test "a segunda tecla sai quando chega a vez dela, sem ordem nova" do
      config = Map.merge(@stun, %{skill_gap_ms: 500})
      {world, hands} = soltando(["3", "4", "5"], %{skill_gap_ms: 500})

      {no_meio, hands} = Hands.obey(%{world | clock: world.clock + 500}, ordens(), hands, config)
      assert Enum.sort(gastas(no_meio)) == ["3", "4"]

      {no_fim, _hands} =
        Hands.obey(%{no_meio | clock: no_meio.clock + 500}, ordens(), hands, config)

      assert Enum.sort(gastas(no_fim)) == ["3", "4", "5"]
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

  # O CAMINHANTE ENCOSTA NA PEDRA E FICA LÁ. `Sim.Hands` reimplementa o andar e
  # não tem nada equivalente ao `unstick/3` do cavebot: quando todo candidato do
  # escorregão está bloqueado, `World.step/4` devolve a mesma posição, e não há
  # mais nada no mundo que mexa o personagem. Uma corrida de bancada parada num
  # canto ainda reporta mortos/min — só que de uma caçada que nunca andou.
  # A TECLA QUE NÃO ANDA JUNTO, espelhada: no bot a corrente solta as setas
  # antes de sair (`Combat.Worker` → `Body.release/0`) e o revive nasce com
  # `:still`. O mundo tem o sensor (`chain_while_walking`) e a bancada a
  # invariante — "sinto que essas coisas deveríamos pegar no simulador e não
  # deixar ir pra gameplay real" (02/09).
  describe "a tecla que não anda junto" do
    @corrente %{combo_key: "r", combo_chain_ms: 3_500}

    test "a corrente solta as setas antes de sair, e o sensor fica em zero" do
      world = mundo(@barra, @corrente) |> World.press({:key_down, "up"})
      config = Map.put(@stun, :combo_window_ms, 4_000)

      {world, _hands} =
        Hands.obey(world, ordens(%{fire: :free, opening: ["r"]}), Hands.new(), config)

      assert world.chain != [], "a corrente não saiu"
      assert world.held == []
      assert world.stats.chain_while_walking == 0
    end

    test "o sensor do mundo acusa a corrente com seta segurada" do
      world = mundo(@barra, @corrente) |> World.press({:key_down, "up"})

      assert World.press(world, {:press, "r"}).stats.chain_while_walking == 1
      assert World.press(mundo(@barra, @corrente), {:press, "r"}).stats.chain_while_walking == 0
    end

    test "o revive solta as setas antes de sair" do
      world = mundo(@barra) |> World.press({:key_down, "left"})
      config = %{@stun | rescue_stun_first: false}

      {world, _hands} = Hands.obey(world, ordens(%{revive: :now}), Hands.new(), config)

      assert world.held == []
    end
  end

  describe "andando" do
    defp rota_reta do
      %Pokex.Bots.Cavebot.Route{
        name: "reta",
        dungeon: nil,
        waypoints: [
          %{x: 1000, y: 1000, z: 7, action: :walk, note: nil},
          %{x: 1010, y: 1000, z: 7, action: :walk, note: nil}
        ]
      }
    end

    defp encostado_na_pedra do
      # UMA pedra, e o alvo alinhado no outro eixo: `wanted` tem uma direção só,
      # então o escorregão do mundo não tem candidato nenhum pra oferecer. É o
      # caso mínimo, e é o comum numa caverna.
      pedra = MapSet.new([{1001, 1000, 7}])

      world =
        World.new(rota_reta(),
          seed: 1,
          loadout: @barra,
          blocked: pedra,
          knobs: %{nest_size: 0, stray_chance_pct: 0}
        )

      %{world | pos: {1000, 1000, 7}}
    end

    defp andando(world, hands, config, ate) do
      if world.clock >= ate do
        {world, hands}
      else
        {world, hands} = Hands.obey(world, ordens(%{route: :go}), hands, config)
        andando(World.step(world, 100), hands, config, ate)
      end
    end

    # PARADO PORQUE MANDARAM PARAR NÃO É TRAVADO. `advance/3` rodava no fim de
    # `obeying/4` sem NUNCA ver as ordens, então um `route: :hold` — que é o que
    # o cérebro faz em toda luta — contava como travamento. Quando a rota
    # voltava, o primeiro passo saía perpendicular, fora da rota: exatamente o
    # instante pós-luta em que o Catcher está mirando a bola, que é o dano que o
    # #383 foi consertar.
    test "a estrada segura pelo cérebro não conta como travamento" do
      world = %{encostado_na_pedra() | blocked: MapSet.new()}
      config = Map.merge(@stun, %{walk_timeout_ms: 3_000})

      {_world, hands} = parado(world, Hands.new(), config, 5_000)

      assert hands.sidestep == nil, "uma luta longa armou um desvio"
    end

    defp parado(world, hands, config, ate) do
      if world.clock >= ate do
        {world, hands}
      else
        {world, hands} = Hands.obey(world, ordens(%{route: :hold}), hands, config)
        parado(World.step(world, 100), hands, config, ate)
      end
    end

    # E O DESVIO ALTERNA. Uma direção só nunca contorna nada: se o perpendicular
    # também está bloqueado, ele empurra a parede pro resto da corrida.
    test "com o desvio também bloqueado, ele tenta o outro lado" do
      pedra = MapSet.new([{1001, 1000, 7}, {1000, 1001, 7}])

      world = %{encostado_na_pedra() | blocked: pedra}
      config = Map.merge(@stun, %{walk_timeout_ms: 3_000})

      {depois, _hands} = andando(world, Hands.new(), config, 30_000)

      refute depois.pos == world.pos, "só tentou um lado e ficou empurrando a pedra"
    end

    test "uma parede inteira no caminho não deixa a caçada parada a noite toda" do
      world = encostado_na_pedra()
      config = Map.merge(@stun, %{walk_timeout_ms: 3_000})

      {depois, _hands} = andando(world, Hands.new(), config, 30_000)

      refute depois.pos == world.pos, "ficou encostado na pedra a corrida inteira"
    end
  end
end
