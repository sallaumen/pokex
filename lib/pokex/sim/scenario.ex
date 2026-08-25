defmodule Pokex.Sim.Scenario do
  @moduledoc """
  The problems he named, as data instead of as code.

  A scenario is a route, a seed, a set of knobs and a **script**: a list of
  `{at_ms, action}` fired against the WORLD's clock, never the machine's. That
  is what makes a scenario reproducible — the same scenario replays the same
  way on a busy laptop and on a quiet one, which a wall-clock script could not
  promise.

  Each one carries a `why` in his own language saying what to watch for. A
  scenario without a question is just an animation.

  ## The four groups are his

  He marked them on 2026-08-17: the ruler and the pile · health, revive and
  death · hands that fail · route and blindness. The library below covers all
  four, and `tecla-morta` is not a hypothetical: it is the failure sitting in
  his journal right now, with six openings, six `🔁 não saiu` and zero
  `alvo morto`.
  """

  alias Pokex.Bots.Cavebot.Route

  defstruct id: nil,
            name: nil,
            why: nil,
            group: nil,
            route: nil,
            seed: 42,
            knobs: %{},
            script: []

  @type action :: {:fail, term} | {:recover, term}
  @type t :: %__MODULE__{}

  @groups %{
    hunt: "A caçada inteira",
    ruler: "A régua e a pilha",
    health: "Vida, revive e morte",
    hands: "Mãos que falham",
    blind: "Rota e cegueira"
  }

  @doc "The groups that are controlled EXPERIMENTS — one pile, one question."
  def experiment_groups, do: [:ruler, :health, :hands, :blind]

  @doc "How the screen names each group."
  def group_label(group), do: Map.get(@groups, group, to_string(group))

  @doc "Every scenario, in the order the screen offers them."
  @spec all() :: [t]
  def all do
    [
      %__MODULE__{
        id: "cacada",
        group: :hunt,
        name: "A caçada inteira",
        why:
          "Não é uma pergunta, é a NOITE: quatro cantos que renascem, pilhas do tamanho " <>
            "que a distribuição dele dá (1 ou 2 na maioria, 3 e 4 de vez em quando), " <>
            "perdidos no caminho entre elas. É o único cenário em que “monstros por " <>
            "minuto” quer dizer o que ele quer dizer — os outros medem uma luta, este " <>
            "mede uma caçada.",
        route: :hunt_field,
        knobs: %{respawn_ms: 45_000, aggro_tiles: 8, leash_tiles: 12}
      },
      %__MODULE__{
        id: "formigueiro",
        group: :hunt,
        name: "Formigueiro (cheio de bicho)",
        why:
          "A caçada dele, na densidade que ele descreveu: “esse jogo geralmente se dá uma " <>
            "andada: aparece mais três inimigos de uma vez, mais dois inimigos de uma vez”. " <>
            "Doze cantos, quase todos com ninho, pilhas de 2 a 5, perdidos em mais da metade " <>
            "do caminho e um renascimento de 20s. É aqui que a régua de passos tem o que " <>
            "medir — no anel esparso todas as respostas empatam.",
        route: :anthill,
        knobs: %{
          nest_sizes: %{2 => 4, 3 => 4, 4 => 2, 5 => 1},
          nest_radius: 3,
          stray_chance_pct: 60,
          aggro_tiles: 8,
          leash_tiles: 12,
          respawn_ms: 20_000
        }
      },
      %__MODULE__{
        id: "pilha-pequena",
        group: :ruler,
        name: "Pilha pequena",
        why:
          "UM monstro só — que é o que “abaixo da régua” quer dizer desde que ela virou " <>
            "dois (25/08). A régua não o ignora, ela ADIA: ele é carregado junto enquanto " <>
            "a caçada anda, e vira luta quando a paciência acaba. Com a paciência " <>
            "desligada, é ele sendo deixado pra trás.",
        knobs: %{nest_size: 1, nest_radius: 1, aggro_tiles: 8, leash_tiles: 20}
      },
      %__MODULE__{
        id: "pilha-que-fecha",
        group: :ruler,
        name: "Pilha que fecha",
        why:
          "Cinco chegam e param de chegar. É a janela que o desenho chama de sizing → " <>
            "engaged: veja quanto tempo ele espera antes de abrir.",
        knobs: %{nest_size: 5, nest_radius: 0, aggro_tiles: 20}
      },
      %__MODULE__{
        id: "pilha-que-pinga",
        group: :ruler,
        name: "Pilha que pinga (ela PULA)",
        why:
          "Cinco monstros espalhados, chegando um de cada vez. A contagem nunca fica " <>
            "pile_settle_ms parada, o teto de size_ceiling_ms estoura, e o cérebro PULA " <>
            "uma pilha de cinco que valia. Não é bug do simulador: é o que os dois " <>
            "números fazem juntos quando a pilha pinga em vez de chegar.",
        knobs: %{nest_size: 5, nest_radius: 4, aggro_tiles: 16, mob_ms_per_tile: 700}
      },
      %__MODULE__{
        id: "ganancia",
        group: :ruler,
        name: "Ganância: eles somem",
        why:
          "Um monstro e uma corda curta. Com a régua acima dele E a paciência desligada a " <>
            "pilha é ABANDONADA, a caçada segue andando, e quem já tinha acordado " <>
            "desaparece — R2 acontecendo, não uma regra escrita em lugar nenhum. Com a " <>
            "régua em 1 (a sua) ele morre: é o preço da régua, medido.",
        knobs: %{nest_size: 1, nest_radius: 1, aggro_tiles: 8, leash_tiles: 8}
      },
      %__MODULE__{
        id: "vida-caindo",
        group: :health,
        name: "Vida caindo até o amarelo",
        why:
          "A mordida é forte. Acompanhe verde → amarelo: a rota deve travar (fecha a " <>
            "rodada) antes de qualquer revive.",
        knobs: %{nest_size: 4, nest_radius: 1, aggro_tiles: 20, bite_dmg: 14, bite_every_ms: 500}
      },
      %__MODULE__{
        id: "vermelho",
        group: :health,
        name: "Vermelho no meio da pilha",
        why:
          "A vida cai para 25% de uma vez, com a pilha em cima. O revive deve sair AGORA, " <>
            "sem esperar rodada nenhuma.",
        knobs: %{nest_size: 4, nest_radius: 1, aggro_tiles: 20},
        script: [{3_000, {:fail, {:hp, 25}}}]
      },
      %__MODULE__{
        id: "morte",
        group: :health,
        name: "Ele cai (e o revive não sai)",
        why:
          "A barra some junto com o pokémon: o fato vira readable?: false e fainted?: true. " <>
            "É assim que o suporte descobre a morte — não por vida zero. O revive é " <>
            "ORDENADO e não sai (a falha de 24/08), senão ele salva sempre e a queda " <>
            "nunca chega a acontecer.",
        knobs: %{nest_size: 3, nest_radius: 0, aggro_tiles: 20, bite_dmg: 20, bite_every_ms: 400},
        script: [{100, {:fail, :dead_revive}}]
      },
      %__MODULE__{
        id: "tecla-morta",
        group: :hands,
        name: "A tecla não sai (o bug de hoje)",
        why:
          "A tecla 3 sai da mão, o cooldown corre e o recibo confirma — e o monstro não " <>
            "perde vida. É o padrão do seu journal de 17/08: 6 aberturas, 6 “não saiu”, " <>
            "zero “alvo morto”. Compare com a tecla 4, que funciona.",
        knobs: %{nest_size: 4, nest_radius: 1, aggro_tiles: 14},
        script: [{2_000, {:fail, {:dead_key, "3"}}}]
      },
      %__MODULE__{
        id: "tela-ilegivel",
        group: :blind,
        name: "Tela ilegível",
        why:
          "A lista de batalha para de ser lida: enemies vira nil, não zero. O cérebro deve " <>
            "dizer que não está vendo e SEGURAR, em vez de concluir que a tela esvaziou.",
        knobs: %{nest_size: 4, nest_radius: 1},
        script: [{3_000, {:fail, :blind}}, {9_000, {:recover, :blind}}]
      }
    ]
  end

  @spec get(String.t()) :: t | nil
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc """
  The route a scenario plays on: the one it names, or the small built-in ring.

  The built-in exists so a scenario never depends on which routes happen to be
  in his `routes.json` today — a library that breaks when he renames a hunt is a
  library he stops trusting.
  """
  @spec route(t, [Route.t()]) :: Route.t()
  def route(%__MODULE__{route: nil}, _available), do: ring()
  def route(%__MODULE__{route: :hunt_field}, _available), do: hunt_field()
  def route(%__MODULE__{route: :anthill}, _available), do: anthill()

  def route(%__MODULE__{route: name}, available),
    do: Enum.find(available, &(&1.name == name)) || ring()

  @doc "A small square with one nest — enough to see a decision, small enough to read."
  @spec ring() :: Route.t()
  def ring do
    %Route{
      name: "campo de testes",
      waypoints:
        for {x, y, gather} <- [
              {1_000, 1_000, nil},
              {1_020, 1_000, 4_000},
              {1_020, 1_020, nil},
              {1_000, 1_020, nil}
            ] do
          %{
            x: x,
            y: y,
            z: 7,
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

  @doc """
  A LAP, not an experiment: four corners his hand would have marked, far enough
  apart that walking between them is most of the minute.

  The ring is deliberately too small to measure a hunt on — one nest, twenty
  tiles, and the character is back before anything respawned. A rate per minute
  taken there is a rate per fight wearing a minute's clothes.
  """
  @spec hunt_field() :: Route.t()
  def hunt_field do
    %Route{
      name: "caçada de teste",
      # …and one MOBBING stretch, marked the way his own routes are: the leg
      # leaving `:lure_start` is walked gathering instead of fighting, and
      # arriving at `:lure_end` ends it. Without a marked stretch the whole
      # `:gathering` branch of the decision is unreachable, which is how a
      # sweep of `engine_gather_piles` came to be a sweep of nothing.
      waypoints:
        for {x, y, gather, fight, action} <- [
              {1_000, 1_000, nil, nil, :walk},
              {1_012, 1_000, 4_000, nil, :walk},
              {1_012, 1_010, nil, nil, :lure_start},
              {1_024, 1_010, nil, 3_000, :lure_end},
              {1_024, 1_020, nil, nil, :walk},
              {1_012, 1_020, 4_000, nil, :walk},
              {1_000, 1_020, nil, nil, :walk},
              {1_000, 1_010, nil, 3_000, :walk}
            ] do
          %{
            x: x,
            y: y,
            z: 7,
            action: action,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: fight,
            gather_ms: gather,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end

  @doc """
  A LONG lap, thick with monsters: twelve corners, a nest on almost every one,
  and strays on more than half the road between them.

  The sparse ring cannot tell two rulers apart — every answer lands inside the
  noise, because there is rarely more than one pile in play. This is where a
  ruler measured in STEPS has something to measure, and it is the density he
  described: "aparece mais três inimigos de uma vez, mais dois inimigos de uma
  vez" (2026-08-25).
  """
  @spec anthill() :: Route.t()
  def anthill do
    %Route{
      name: "formigueiro de teste",
      waypoints:
        for {x, y, gather, fight} <- [
              {1_000, 1_000, nil, nil},
              {1_010, 1_000, 3_000, nil},
              {1_020, 1_000, nil, 3_000},
              {1_030, 1_004, 3_000, nil},
              {1_034, 1_012, nil, 3_000},
              {1_030, 1_020, 3_000, nil},
              {1_020, 1_024, nil, 3_000},
              {1_010, 1_024, 3_000, nil},
              {1_000, 1_020, nil, 3_000},
              {996, 1_012, 3_000, nil},
              {998, 1_006, nil, 3_000},
              {1_000, 1_002, nil, nil}
            ] do
          %{
            x: x,
            y: y,
            z: 7,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: fight,
            gather_ms: gather,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end

  @doc """
  The script entries that fall in `(from_ms, up_to_ms]`.

  A half-open window on purpose: a tick that lands exactly on a beat must fire
  it once, and the next tick must not fire it again.
  """
  @spec due(t, non_neg_integer, non_neg_integer) :: [action]
  def due(%__MODULE__{script: script}, from_ms, up_to_ms) do
    script
    |> Enum.filter(fn {at, _action} -> at > from_ms and at <= up_to_ms end)
    |> Enum.map(&elem(&1, 1))
  end
end
