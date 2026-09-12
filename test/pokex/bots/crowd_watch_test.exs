defmodule Pokex.Bots.CrowdWatchTest do
  @moduledoc """
  The eye: looks on a fight clock, publishes the whole reading, tells the
  page, and keeps a photo of every revive decision. Decides nothing.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.CrowdWatch
  alias Pokex.Perception.WorldState
  alias Pokex.SettingsStash

  @moduletag :tmp_dir

  @bmp "data:image/bmp;base64," <> Base.encode64("bmp-de-mentira")

  setup %{tmp_dir: tmp} do
    WorldState.clear()
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    SettingsStash.stash!(crowd_watch_enabled: true)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "engine")

    test = self()

    look = fn opts ->
      send(test, {:looked, opts})

      %{
        read?: true,
        at: now(),
        took_ms: 12,
        me: {800, 800},
        box: {200, 200, 1200, 1200},
        pet: %{point: {800, 1000}, dx: 0, dy: 2, tiles: 2, hp_pct: 96},
        hostiles: [
          %{point: {900, 1000}, dx: 1, dy: 2, from_me: 2, from_pet: 1, hp_pct: 100, skull?: true},
          %{point: {1300, 500}, dx: 5, dy: -3, from_me: 5, from_pet: 5, hp_pct: 100, skull?: true}
        ],
        listed: opts[:listed],
        evidence: if(opts[:evidence], do: @bmp)
      }
    end

    pid = start_supervised!({CrowdWatch, name: nil, active: true, look: look})
    %{watch: pid}
  end

  defp orders!(phase, opts \\ []) do
    WorldState.put(
      :orders,
      %{
        phase: phase,
        why: Keyword.get(opts, :why, "teste"),
        revive: Keyword.get(opts, :revive, :hold)
      },
      now()
    )
  end

  # O QUADRO-NEGRO VELHO PELO CARIMBO, não pelo relógio: `WorldState.put/3` leva a
  # hora do fato, então "velho" é um número — não 1,6 s de espera que numa
  # máquina carregada vira outra coisa.
  defp stale_orders!(phase) do
    at = now() - 10 * Pokex.Settings.get(:engine_orders_max_age_ms)
    WorldState.put(:orders, %{phase: phase, why: "teste", revive: :hold}, at)
  end

  defp battle!(n),
    do: WorldState.put(:battle, %{enemies: Enum.to_list(1..n//1), captured_at: now()}, now())

  # A pasta só nasce quando a primeira foto é gravada: "não existe" e "vazia"
  # são a mesma resposta aqui.
  defp photos do
    case Pokex.Home.captures_dir() |> Path.join("crowd") |> File.ls() do
      {:ok, files} -> files
      {:error, :enoent} -> []
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  test "in a fight it looks, publishes the whole reading without the picture, and tells the page",
       %{watch: watch} do
    orders!(:engaged)
    battle!(3)

    reading = CrowdWatch.look_now(watch)

    assert_receive {:looked, opts}
    assert opts[:listed] == 3
    assert reading.evidence == @bmp
    assert {:ok, crowd} = WorldState.get(:crowd, 5_000, now())
    assert crowd.listed == 3
    assert length(crowd.hostiles) == 2
    assert crowd.pet.tiles == 2
    refute Map.has_key?(crowd, :evidence)
    assert_receive {:crowd, %{hostiles: [_, _]}}
  end

  test "the feed line says what it saw, once per change", %{watch: watch} do
    orders!(:engaged)
    battle!(3)

    CrowdWatch.look_now(watch)
    CrowdWatch.look_now(watch)

    # `:debug` since 11/09: the Central draws the eye in bars, and the line was
    # 65% of his diary
    assert_receive {:engine_log, :debug,
                    "olho: 👀 vi 2 (lista 3) · pokémon a 2 tiles · mais perto a 2 tiles · caveira · 12ms"}

    refute_receive {:engine_log, _level, "olho: 👀" <> _}, 100
  end

  test "the clock is a fight clock: 250ms with enemies or a revive pending, 1s walking clear, idle without a hunt",
       %{watch: watch} do
    battle!(0)
    orders!(:travelling)
    assert CrowdWatch.next_look_ms(watch) == 1_000

    battle!(2)
    assert CrowdWatch.next_look_ms(watch) == 250

    battle!(0)
    orders!(:travelling, revive: :prepare)
    assert CrowdWatch.next_look_ms(watch) == 250

    orders!(:engaged)
    assert CrowdWatch.next_look_ms(watch) == 250

    WorldState.forget(:orders)
    assert CrowdWatch.next_look_ms(watch) == :idle
  end

  test "without a hunt or switched off it does not look", %{watch: watch} do
    battle!(3)
    assert CrowdWatch.look_now(watch) == %{read?: false, reason: :no_hunt}
    refute_receive {:looked, _}, 50

    orders!(:engaged)
    SettingsStash.stash!(crowd_watch_enabled: false)
    assert CrowdWatch.look_now(watch) == %{read?: false, reason: :disabled}
    refute_receive {:looked, _}, 50
  end

  test "the fight opening keeps a photo", %{watch: watch} do
    orders!(:bunching)
    battle!(3)
    CrowdWatch.look_now(watch)

    send(watch, {:engine, %{}, %{phase: :engaged, why: "matando", revive: :hold}})
    :sys.get_state(watch)

    assert [photo] = photos()
    assert photo =~ "-open.png"
    assert File.read!(Path.join([Pokex.Home.captures_dir(), "crowd", photo])) == "bmp-de-mentira"
  end

  # DESLIGADO É DESLIGADO. A foto da abertura chamava o olho direto, sem passar
  # pela porta: com o interruptor no não ele continuava capturando a tela e
  # reescrevendo o fato `:crowd` a cada abertura de luta, pra sempre — e cada
  # uma dessas fotos deixava o `last` fresco pra próxima.
  test "switched off, the fight opening captures nothing", %{watch: watch} do
    orders!(:bunching)
    battle!(3)
    CrowdWatch.look_now(watch)
    assert_receive {:looked, _}

    SettingsStash.stash!(crowd_watch_enabled: false)
    WorldState.forget(:crowd)

    send(watch, {:engine, %{}, %{phase: :engaged, why: "matando", revive: :hold}})
    :sys.get_state(watch)

    refute_receive {:looked, _}, 50
    assert photos() == []
    assert WorldState.get(:crowd, 5_000, now()) == :missing
  end

  test "every revive decision keeps a photo named by the verdict, once per sentence",
       %{watch: watch} do
    orders!(:engaged)
    battle!(3)

    send(watch, {:engine, %{}, %{phase: :engaged, why: "revive agora", revive: :now}})
    send(watch, {:engine, %{}, %{phase: :engaged, why: "revive agora", revive: :now}})

    send(
      watch,
      {:engine, %{},
       %{phase: :engaged, why: "parado — segurando o revive: 2 na tela", revive: :hold}}
    )

    send(watch, {:engine, %{}, %{phase: :travelling, why: "andando", revive: :prepare}})
    :sys.get_state(watch)

    tags = photos() |> Enum.map(&(&1 |> String.split("-") |> List.last())) |> Enum.sort()
    assert tags == ["held.png", "revive.png", "revive.png"]
  end

  # ESTE TESTE É DO RODÍZIO, E O RODÍZIO NÃO TEM RELÓGIO. Ele escrevia `:orders`
  # uma vez e mandava as 33 frases de uma vez: `send/2` é assíncrono, então as 33
  # escritas caíam primeiro e o olho drenava a fila inteira contra o ÚNICO
  # `:orders` que sobrou, envelhecendo a cada mensagem. Como toda foto passa por
  # `allowed/2` → `cadence/1` → `orders/1` (`engine_orders_max_age_ms`, 1,5 s), o
  # que o teste media era quantas das 33 cabiam em 1,5 s DE MÁQUINA: 33 numa
  # ociosa (30 depois do rodízio, verde), 14 ou 25 numa carregada, 7 numa suíte
  # de 854 s.
  #
  # Duas saídas que NÃO servem: renovar `:orders` dentro do laço só muda o
  # relógio de lugar (continua sendo o tempo de drenar 33 mensagens de fila); e
  # afrouxar `engine_orders_max_age_ms` tira o olho de `:idle` e o põe a olhar
  # sozinho no próprio tique — o arquivo foi de 2,6 s pra 15 s e o
  # `:sys.get_state` estourou os 5 s dele.
  #
  # O que serve é não ter fila: uma frase por vez, drenada antes da próxima. Cada
  # mensagem é tratada a microssegundos do seu `orders!`, e nada se acumula.
  test "only thirty photos stay", %{watch: watch} do
    battle!(3)

    for i <- 1..33 do
      orders!(:engaged)
      send(watch, {:engine, %{}, %{phase: :engaged, why: "revive #{i}", revive: :now}})
      :sys.get_state(watch)
    end

    assert length(photos()) == 30
  end

  # SEM FOTO, A FRASE NÃO SE GASTA. O olho guarda uma foto POR FRASE de revive, e
  # o cérebro repete a mesma frase a cada tique — a trava `last_why` existe pra
  # não virar uma foto por tique. Mas ela era carimbada ANTES de perguntar se a
  # olhada estava autorizada, então um tique que chegasse com o quadro-negro
  # velho (`:orders` além de `engine_orders_max_age_ms`) gastava a frase sem
  # tirar foto: o quadro voltava a ficar fresco, o cérebro repetia a MESMA
  # frase, e aquela decisão de revive ficava PRA SEMPRE sem foto — justo a
  # decisão que a foto existe pra explicar.
  test "a decision refused for a stale blackboard is photographed when the eye is allowed again",
       %{watch: watch} do
    battle!(3)
    stale = %{phase: :engaged, why: "revive agora", revive: :now}

    # o quadro-negro chega velho: o olho recusa a olhada, e nenhuma foto sai
    stale_orders!(:engaged)
    send(watch, {:engine, %{}, stale})
    :sys.get_state(watch)
    assert photos() == []

    # o cérebro repete a MESMA frase com o quadro-negro fresco de novo
    orders!(:engaged)
    send(watch, {:engine, %{}, stale})
    :sys.get_state(watch)
    assert length(photos()) == 1

    # …e segue sendo UMA: com o quadro-negro FRESCO (a única recusa possível
    # agora é a trava), a mesma frase não tira foto de novo
    orders!(:engaged)
    send(watch, {:engine, %{}, stale})
    :sys.get_state(watch)
    assert length(photos()) == 1
  end

  describe "the eye's keys" do
    test "the box covers the game viewport and the clock is a fight clock" do
      assert Pokex.Settings.defaults()[:crowd_scan_radius_tiles] == 8
      assert Pokex.Settings.defaults()[:crowd_scan_every_ms] == 250
      assert Pokex.Settings.defaults()[:crowd_fact_max_age_ms] == 600
    end
  end
end
