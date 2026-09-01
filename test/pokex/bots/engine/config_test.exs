defmodule Pokex.Bots.Engine.ConfigTest do
  @moduledoc """
  A lista de ajustes existia três vezes e as três discordaram. Este arquivo é o
  que impede a quarta cópia de nascer.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Config
  alias Pokex.Settings

  test "todo ajuste do cérebro existe no Settings" do
    seeds = Settings.defaults()

    for {knob, setting} <- Config.knobs() do
      assert Map.has_key?(seeds, setting),
             "#{knob} aponta pra #{setting}, que não é um ajuste que existe"
    end
  end

  test "as sementes e o que está em vigor têm exatamente as mesmas chaves" do
    assert Config.defaults() |> Map.keys() |> Enum.sort() ==
             Config.in_force() |> Map.keys() |> Enum.sort()
  end

  test "as sementes são as do Settings, não uma cópia com vida própria" do
    seeds = Settings.defaults()
    config = Config.defaults()

    for {knob, setting} <- Config.knobs() do
      assert config[knob] == seeds[setting], "#{knob} divergiu de #{setting}"
    end
  end

  test "merge devolve o mapa INTEIRO, não só o que foi pedido" do
    merged = Config.merge(%{engage_from: 9})

    assert merged.engage_from == 9
    assert Map.keys(merged) |> Enum.sort() == Config.defaults() |> Map.keys() |> Enum.sort()
  end

  # O piso entre dois resgates é do PlayerSupport, não do cérebro — ele só
  # precisa saber que existe, senão planeja em cima de uma prensa que a mão não
  # pode dar (R5).
  test "o piso do resgate vem do ajuste do suporte" do
    assert Config.knobs()[:rescue_cooldown_ms] == :rescue_cooldown_ms
  end

  # A SOBREPOSIÇÃO DO MODO. Ela existe pra que o Econômico desligue mobada,
  # kite e reset SEM uma linha nova dentro do `Logic` — e pra que ninguém
  # precise escrever no settings.json dele pra isso acontecer.
  test "o modo econômico desliga as regras caras sem tocar no Settings" do
    economico = Config.in_force(:economy)

    assert economico.gather_piles == false
    assert economico.kite_when_spent == false
    assert economico.reset_revive == false
    assert economico.prepare_revive == false
    assert economico.engage_from == 1

    assert Settings.get(:engine_gather_piles) == Settings.defaults()[:engine_gather_piles]
  end

  test "o auto combo é o bot como ele está — nenhuma sobreposição" do
    assert Config.in_force(:auto_combo) == Config.in_force(:auto_combo)

    for {knob, setting} <- Config.knobs() do
      assert Config.in_force(:auto_combo)[knob] == Settings.get(setting),
             "#{knob} foi sobreposto por um modo que não sobrepõe nada"
    end
  end

  test "a sobreposição não muda o CONJUNTO de knobs, só valores" do
    assert Config.in_force(:economy) |> Map.keys() |> Enum.sort() ==
             Config.in_force(:auto_combo) |> Map.keys() |> Enum.sort()
  end

  # UM KNOB QUE SÓ A BANCADA LÊ É UMA REGRA QUE O BOT NÃO TEM — e como este mapa
  # é a linha de base de `Bench.default_config/0` E de `Bench.config_in_force/0`
  # (que se documenta como "os knobs como o bot está rodando agora"), a bancada
  # passa a medir um bot que obedece uma regra que o de verdade nunca viu. É a
  # mesma família de #358 e #367: a bancada media um parecido.
  #
  # No molde do guarda que `display_feeds_test.exs` já tem: uma varredura de
  # texto, porque a pergunta é justamente "alguém lê isto?".
  test "todo knob da decisão é lido pelo cérebro, não só pela bancada" do
    # A FOTO É PARTE DO CÉREBRO: `Situation.build/3` recebe a config e é o que
    # a `Logic` decide em cima. Um knob lido só ali estava sendo acusado de
    # órfão (o `spent_keys_left`, 27/08), que é o oposto do que este guarda
    # existe pra achar.
    # …E O PLANO DE COMBATE ENTRA NA LISTA (01/09): a composição da mão saiu do
    # `Inputs` e da rotação e passou a morar num lugar só, que o modo escolhe.
    # `single_target` e `shield_from` são lidos lá — e são regras que o bot TEM,
    # não regras que só a bancada obedece, que é a pergunta deste guarda.
    fontes =
      [
        "lib/pokex/bots/engine/logic.ex",
        "lib/pokex/bots/engine/worker.ex",
        "lib/pokex/bots/engine/situation.ex",
        "lib/pokex/bots/engine/inputs.ex",
        "lib/pokex/bots/combat/plan.ex",
        "lib/pokex/bots/combat/plan/standard.ex"
      ]
      |> Enum.map_join("\n", &File.read!/1)

    orfaos =
      Config.knobs()
      |> Map.keys()
      |> Enum.reject(
        &(String.contains?(fontes, "#{&1}") or Map.has_key?(Config.bench_only(), &1))
      )
      |> Enum.sort()

    assert orfaos == [],
           "knobs que só a bancada lê (o bot não tem essa regra): #{inspect(orfaos)}"
  end

  # E o que é declarado como só-da-bancada nasce DESLIGADO: ligado por semente,
  # a linha de base de todo sweep mede um bot que obedece uma regra que o de
  # verdade não tem.
  test "o que só a bancada obedece vem desligado por semente" do
    ligados =
      Config.bench_only()
      |> Map.keys()
      |> Enum.filter(fn knob -> Settings.get(Map.fetch!(Config.knobs(), knob)) end)

    assert ligados == [], "semeados ligados sem o cérebro obedecer: #{inspect(ligados)}"
  end
end
