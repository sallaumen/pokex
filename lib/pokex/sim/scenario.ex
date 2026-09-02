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
            # O SÍMBOLO E A COR, pra achar um cenário sem ler treze nomes.
            #
            # O símbolo é a identidade (🥚 é o bicho de papel, 🛡️ é o couraçado)
            # e não sai do design system: o sistema tem três degraus de texto e
            # quatro cores semânticas, e nenhuma delas distingue treze coisas.
            # Um emoji distingue, e é o mesmo alfabeto que o feed da caçada já
            # usa.
            icon: "🎯",
            # …e a cor NÃO repete o grupo. O grupo diz do que o cenário trata; o
            # aperto diz o que esperar de uma corrida: `:rotina` é o que tem que
            # dar certo sempre (verde), `:aperto` é o bot sofrendo mas segurando
            # (âmbar), `:quebrado` é alguma coisa falhando DE PROPÓSITO (vermelho
            # — e aí morrer não é notícia ruim, é o cenário funcionando).
            aperto: :rotina,
            # A PROMESSA, cobrável. Ver `Pokex.Sim.Verdict`: uma lista de nomes
            # de propriedades que uma corrida deste cenário tem que cumprir. Sem
            # ela um cenário responde "rodou" e cabe a ele olhar seis números e
            # lembrar qual era a pergunta.
            espera: [],
            route: nil,
            seed: 42,
            knobs: %{},
            # OS AJUSTES QUE A PERGUNTA PRECISA, quando ela precisa de algum. Um
            # cenário é um experimento controlado, e um padrão novo pode apagar
            # a pergunta que ele existe pra fazer: quando o stun do resgate foi
            # ligado por padrão, "Ele cai" parou de derrubar o pokémon, porque
            # uma pilha dormindo não morde ninguém. O que o cenário fixa aqui
            # ainda pode ser sobrescrito por quem o roda.
            config: %{},
            # QUAL MODO DE COMBATE esta pergunta é sobre (`Pokex.Bots.HuntMode`).
            # `nil` é o bot como ele está — o que mantém todo cenário antigo
            # medindo exatamente o que media.
            mode: nil,
            script: [],
            # A FORMA DO CHÃO. `:liso` é o que todo cenário sempre foi: um plano
            # infinito onde só criatura atrapalha. `:anel` põe parede em volta do
            # circuito e pedras no caminho — "uns pontos de obstáculo pra ele
            # tropeçar e vermos como ele lida" (26/08).
            #
            # É a única coisa que pergunta sobre a ROTA. Chão liso responde sobre
            # a régua e sobre o dano, e não responde nada sobre andar — que é
            # onde a caçada de verdade trava.
            chao: :liso

  @type action :: {:fail, term} | {:recover, term}
  @type t :: %__MODULE__{}

  @groups %{
    hunt: "A caçada inteira",
    mundo: "O bicho e o bolo",
    chefe: "O chefe",
    ruler: "A régua e a pilha",
    health: "Vida, revive e morte",
    hands: "Mãos que falham",
    blind: "Rota e cegueira"
  }

  # A ORDEM DA TELA, e ela não é a do mapa (que não tem ordem). Começa pela
  # caçada inteira, passa pelo mundo — as condições que ele nomeou: muito bicho,
  # bicho duro, bicho de papel — e termina nas peças quebradas.
  @group_order [:hunt, :mundo, :chefe, :ruler, :health, :hands, :blind]

  @doc """
  The groups that are controlled EXPERIMENTS — one pile, one question.

  `:mundo` fica DE FORA, e a lista é o lugar onde a diferença vira contrato:
  aqueles são caçadas inteiras (circuito com ninho em cada canto, perdidos na
  estrada, renascimento) rodando com uma FÍSICA diferente — bicho duro, bicho
  de papel, pilha enorme. Num circuito assim, passar por um canto enquanto se
  luta em outro é o que uma caçada é, e o contrato "nada some sem luta" (que
  vale para um experimento de mapa parado) reprovaria a caçada por existir.
  """
  def experiment_groups, do: [:ruler, :health, :hands, :blind]

  @doc "Os grupos na ordem em que a tela os oferece."
  @spec group_order() :: [atom]
  def group_order, do: @group_order

  @doc "How the screen names each group."
  def group_label(group), do: Map.get(@groups, group, to_string(group))

  # A COR DO APERTO, com os nomes do design system. Ver o campo `aperto`: verde
  # é o que tem que dar certo sempre, âmbar é o bot sofrendo mas segurando,
  # vermelho é uma peça quebrada de propósito.
  @apertos %{
    rotina: {"rotina", :ok, "tem que dar certo sempre"},
    aperto: {"aperto", :warn, "o bot vai sofrer — a pergunta é se segura"},
    quebrado: {"quebrado de propósito", :danger, "uma peça está falhando aqui"}
  }

  @doc "O nome curto do aperto de um cenário."
  @spec aperto_label(atom) :: String.t()
  def aperto_label(aperto), do: @apertos |> entry(aperto) |> elem(0)

  @doc "O tom do design system que pinta este aperto (`:ok | :warn | :danger`)."
  @spec aperto_tone(atom) :: :ok | :warn | :danger
  def aperto_tone(aperto), do: @apertos |> entry(aperto) |> elem(1)

  @doc "O que este aperto quer dizer, em uma frase."
  @spec aperto_note(atom) :: String.t()
  def aperto_note(aperto), do: @apertos |> entry(aperto) |> elem(2)

  defp entry(apertos, aperto),
    do: Map.get(apertos, aperto, {to_string(aperto), :ok, ""})

  @doc "Every scenario, in the order the screen offers them."
  @spec all() :: [t]
  def all do
    [
      %__MODULE__{
        id: "cacada",
        group: :hunt,
        icon: "🌙",
        aperto: :rotina,
        espera: [:nao_cai, :mata, :anda, :revive_util],
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
        icon: "🐜",
        aperto: :aperto,
        espera: [:nao_cai, :mata, :anda, :revive_util],
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
        id: "lotavanon",
        group: :hunt,
        icon: "⚡",
        aperto: :rotina,
        espera: [:nao_cai, :mata, :anda, :revive_util],
        name: "Lotavanon (o anel de Electrode)",
        why:
          "O mapa REAL que ele está testando, com os números dele: “é uma área circular " <>
            "mesmo, cheia de bichinho. Toda hora aparece no monte, direto tem nove pokémon ao " <>
            "redor do meu” — e, o que muda tudo, “os electrodos mal me dão dano, tipo menos de " <>
            "1% da minha vida por ataque”. É o cenário onde a pergunta não é sobreviver, é " <>
            "quanta gente cada tiro pega: com a mordida quase de graça, o que sobra medindo é " <>
            "a economia de skill.",
        route: :lotavanon,
        chao: :anel,
        knobs: %{
          # nove ao redor, que é o que ele vê
          nest_sizes: %{7 => 2, 8 => 3, 9 => 4},
          nest_radius: 2,
          stray_chance_pct: 30,
          aggro_tiles: 9,
          leash_tiles: 14,
          respawn_ms: 15_000,
          # MEDIDO POR ELE: "menos de 1% da minha vida por ataque". A vida aqui é
          # 0-100, então a mordida é o menor número que ainda é uma mordida. É o
          # que faz este mapa uma questão de dano, não de sobrevivência.
          bite_dmg: 1,
          player_bite_dmg: 1
        }
      },
      %__MODULE__{
        id: "rota-barata",
        group: :hunt,
        icon: "🪙",
        aperto: :rotina,
        mode: :economy,
        espera: [:nao_cai, :mata, :anda],
        name: "Rota barata (Econômico)",
        why:
          "A caçada esparsa com o modo magro: sem mobada, sem régua, sem recuo e sem reset — " <>
            "Tab, a tecla mais barata, um respiro, e a área só se ainda precisar. A pergunta " <>
            "não é matar mais: é matar o suficiente gastando pouco, e sem deixar o pokémon cair.",
        route: :hunt_field,
        knobs: %{respawn_ms: 45_000, aggro_tiles: 8, leash_tiles: 12}
      },
      %__MODULE__{
        id: "corrente-do-cliente",
        group: :hunt,
        icon: "🔗",
        aperto: :rotina,
        mode: :auto_combo,
        espera: [:nao_cai, :mata],
        name: "Auto Combo (a corrente do cliente)",
        why:
          "O mesmo formigueiro, com o modo que ele caça de verdade contra bicho forte: o bot " <>
            "aperta UMA tecla, o jogo encadeia as skills e termina em stun, e o revive vem logo " <>
            "atrás pra devolver a barra. A pergunta é se o ciclo se sustenta sozinho — se a " <>
            "corrente sai, o revive cai depois dela (nunca no meio) e a próxima sai na sequência. " <>
            "A corrente aqui dura o que ele cronometrou: 3,5 segundos.",
        route: :anthill,
        knobs: %{
          nest_sizes: %{2 => 4, 3 => 4, 4 => 2, 5 => 1},
          nest_radius: 3,
          stray_chance_pct: 60,
          aggro_tiles: 8,
          leash_tiles: 12,
          respawn_ms: 20_000,
          # MEDIDO POR ELE (01/09): a corrente leva 3,5s pra sair inteira. O
          # ajuste do bot é 4s — a mesma medida com meia folga, porque a cerca
          # protege contra uma corrente que engasga. Aqui vale a FÍSICA, não a
          # crença: o mundo entrega no tempo que o jogo entrega.
          combo_chain_ms: 3_500
        },
        # A R3b é o que faz o ciclo repetir: barra gasta pela corrente, revive
        # devolve a barra, corrente de novo. Sem ela o modo aperta uma vez e
        # espera quarenta segundos de cooldown.
        config: %{reset_revive: true}
      },
      %__MODULE__{
        id: "modo-hard",
        group: :hunt,
        icon: "🧟",
        aperto: :aperto,
        mode: :auto_combo,
        espera: [:nao_morre, :mata],
        name: "Modo hard (ele com 1 de vida)",
        why:
          "A vida dele como ela é: \"no modo hard parece que tô jogando Dark Souls — se tem " <>
            "monstro ao meu redor e uso o revive, esse período de menos de 1s que o revive me " <>
            "deixa exposto eu já tomo um jato de água ou uma folha de navalha na cara e morro\". " <>
            "O mesmo formigueiro e a mesma corrente, com o personagem com 1 de vida: a PRIMEIRA " <>
            "mordida que chegar nele durante o campo vazio é a morte. Se o ciclo não for 100% " <>
            "seguro — revive só com todo mundo dormindo ou longe — ele morre aqui antes de " <>
            "morrer lá. Cada detalhe importa.",
        route: :anthill,
        knobs: %{
          nest_sizes: %{2 => 4, 3 => 4, 4 => 2, 5 => 1},
          nest_radius: 3,
          stray_chance_pct: 60,
          aggro_tiles: 8,
          leash_tiles: 12,
          respawn_ms: 20_000,
          combo_chain_ms: 3_500,
          player_hp: 1
        },
        config: %{reset_revive: true}
      },
      %__MODULE__{
        id: "chefe-brando",
        group: :chefe,
        icon: "👹",
        aperto: :rotina,
        espera: [:nao_cai, :aguenta, :stun_sempre, :mata],
        name: "Chefe brando (5×)",
        why:
          "O padrão MENOR do level mais alto: um chefe com 5× a vida e 5× o ataque de um " <>
            "bicho comum, nascendo de tempos em tempos numa estrada vazia. O combo dele é a " <>
            "única resposta — todas as skills, stun no fim, revive, e de novo — e a régua é " <>
            "a frase dele: \"ou otimizamos para realmente não termos abertura a falha, ou 1 " <>
            "segundo sem stun no campo quer dizer que eu morri\". As promessas cobram as " <>
            "duas metades: nem uma mordida, e nenhum chefe 1s acordado por perto.",
        route: :hunt_field,
        knobs: %{
          nest_size: 0,
          stray_chance_pct: 0,
          boss_every_ms: 45_000,
          boss_hp_mult: 5,
          boss_atk_mult: 5,
          # a mordida-base HERDADA da noite medida (0,41%/s por bicho): o
          # multiplicador do chefe multiplica ISTO — com o default de mesa
          # (4 por 900ms) o chefe mordia 10× mais forte que a régua real
          bite_dmg: 1,
          bite_every_ms: 1_000,
          # o relógio do combo: o sono segura 8s, o F4 volta em 5s — é o que
          # faz \"stun → revive → stun\" caber; os dois são dele pra cronometrar
          # MEDIDO POR ELE (30/08, segunda passada): "o stun dura 5s,
          # começando a contar depois dos 2s" — pegada 2s, sono 5s
          stun_ms: 5_000,
          stun_onset_ms: 2_000,
          # O F4 NÃO TEM COOLDOWN NO JOGO ("aquele era um cooldown de
          # segurança") — o piso de 5s é do CÉREBRO (rescue_floor_ms, contado
          # da ordem), e um mundo que recusa F4 por conta própria modela um
          # jogo que não existe: a recusa silenciosa trancava a corrente.
          revive_cooldown_ms: 0,
          presses_to_kill: 3
        },
        config: %{
          reset_revive: true,
          boss_names: "chefe",
          stun_hold_ms: 7_000,
          # o mesmo piso do knob revive_cooldown_ms do mundo: o cérebro segura
          # o stun até o F4 que vem atrás caber nele
          rescue_floor_ms: 5_000,
          # sem R11 aqui: o prepare re-baseava o piso do resgate na cara do
          # chefe seguinte, e o stun ficava 2s esperando o F4 caber. Contra
          # chefe o primeiro ciclo já chega resetando — preparar é pagar dobrado.
          prepare_revive: false
        }
      },
      %__MODULE__{
        id: "chefe-incognito",
        group: :chefe,
        icon: "🎭",
        aperto: :rotina,
        # `aguenta` fica FORA por decisão datada (01/09): a detecção incógnita
        # tem uma janela sem proteção que o grit não fecha — a mobada arrasta o
        # mordedor 5× ANTES de existir luta pra medir (o tanque mediu 15-60%
        # nas sementes). Fechar essa janela pede o segundo sinal, a MORDIDA
        # (vida caindo rápido demais pro tamanho da pilha) — follow-up. O
        # contrato promete o que o caminho entrega: o chefe morre e ninguém cai.
        espera: [:nao_cai, :mata],
        name: "Chefe incógnito (5×, sem nome)",
        why:
          "O chefe DELE de verdade: \"ele tem o mesmo nome que os outros pokémons\" " <>
            "(31/08). Nenhum nome declara nada — o chefe nasce no meio da caçada comum, o " <>
            "bolo abre a luta, os comuns caem, e quem NÃO cai depois de engolir a barra " <>
            "inteira é chefe (o grit). A promessa é a de quem caça sem crachá: o corpo do " <>
            "chefe no chão e o tanque de pé.",
        route: :hunt_field,
        knobs: %{
          # COMUNS EM VOLTA, de propósito: o grit precisa de luta aberta pra
          # contar entregas — o caminho real da dungeon dele, onde o chefe
          # aparece DENTRO do bolo (o chefe sozinho na estrada é buraco
          # conhecido: sem nome e sem luta não há o que medir; o gatilho pela
          # MORDIDA fica de fora desta rodada).
          nest_size: 3,
          stray_chance_pct: 0,
          boss_every_ms: 45_000,
          boss_hp_mult: 5,
          boss_atk_mult: 5,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          stun_ms: 5_000,
          stun_onset_ms: 2_000,
          revive_cooldown_ms: 0,
          presses_to_kill: 3
        },
        config: %{
          reset_revive: true,
          # SEM NOME — o teste é exatamente este: o grit declara sozinho.
          # 6 = 1,5× o máximo que a noite fraca real entregou por pilha (4):
          # margem de sobra contra falso chefe, e cada tique a menos de
          # latência é mordida 5× que o tanque não paga.
          boss_names: "",
          boss_grit: 6,
          stun_hold_ms: 7_000,
          rescue_floor_ms: 5_000,
          prepare_revive: false
        }
      },
      %__MODULE__{
        id: "chefe-pela-cor",
        group: :chefe,
        icon: "🎨",
        aperto: :rotina,
        # MEDIDO no A/B contra o incógnito (6 sementes, 3 min): a cor leva o
        # pior momento de 5% pra 27% e a mediana de 15% pra 34%, com o triplo
        # de chefes mortos. Ainda assim `aguenta` (≥50) fica FORA, e o motivo
        # está nos rastros: o tombo que sobra é sempre o PRIMEIRO bolo, aos
        # ~40s, antes de qualquer chefe aparecer — ninho de comuns com a barra
        # gasta. Não é falha de detecção, é o preço de mobar; prometer aqui
        # seria cobrar da cor uma dívida que não é dela. O ganho está travado
        # no teste comparativo dos invariantes.
        espera: [:nao_cai, :mata],
        name: "Chefe pela cor (5×, regra ensinada)",
        why:
          "O SHINY — que é o que ele chama de chefe neste jogo — com uma diferença pro " <>
            "incógnito: a regra de cor dele foi ensinada e " <>
            "provada na calibração, então o vigia o reconhece assim que ele aparece na tela — " <>
            "antes de qualquer luta. É o buraco que o grit não fecha (a mobada arrasta o " <>
            "mordedor 5× enquanto ainda não há entrega pra contar), e a promessa a mais é " <>
            "exatamente essa: aqui o tanque tem que AGUENTAR.",
        route: :hunt_field,
        knobs: %{
          nest_size: 3,
          stray_chance_pct: 0,
          boss_every_ms: 45_000,
          boss_hp_mult: 5,
          boss_atk_mult: 5,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          stun_ms: 5_000,
          stun_onset_ms: 2_000,
          revive_cooldown_ms: 0,
          presses_to_kill: 3,
          # A DIFERENÇA, e a única: a cor foi ensinada.
          boss_color: true
        },
        config: %{
          reset_revive: true,
          boss_names: "",
          boss_grit: 6,
          stun_hold_ms: 7_000,
          rescue_floor_ms: 5_000,
          prepare_revive: false
        }
      },
      %__MODULE__{
        id: "shinies-empilhados",
        group: :chefe,
        icon: "✨✨",
        aperto: :aperto,
        espera: [:nao_cai, :stun_sempre, :mata],
        name: "Shinies empilhados (mais de um por grupo)",
        why:
          "\"Às vezes tem até mais do que 1 por grupo\" (01/09). O caso que quebrou a " <>
            "postura: um shiny chega enquanto o outro dorme, e a BANDA DE VIDA tomava a " <>
            "frente — o cérebro revivia pra curar e não apertava o controle, caindo de 58% a " <>
            "10% com o bicho colado e acordado. A promessa `stun_sempre` é a régua dele " <>
            "virada contrato: nenhum especial acordado por perto mais que um ciclo.",
        route: :hunt_field,
        knobs: %{
          nest_size: 3,
          stray_chance_pct: 0,
          # curto de propósito: é o que faz dois se sobreporem
          boss_every_ms: 20_000,
          boss_hp_mult: 5,
          boss_atk_mult: 5,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          stun_ms: 5_000,
          stun_onset_ms: 2_000,
          revive_cooldown_ms: 0,
          presses_to_kill: 3,
          boss_color: true
        },
        config: %{
          reset_revive: true,
          boss_names: "",
          boss_grit: 6,
          stun_hold_ms: 7_000,
          rescue_floor_ms: 5_000,
          prepare_revive: false
        }
      },
      %__MODULE__{
        id: "chefe-cruel",
        group: :chefe,
        icon: "🐲",
        aperto: :aperto,
        espera: [:nao_cai, :aguenta, :stun_sempre, :mata],
        name: "Chefe cruel (10×)",
        why:
          "O padrão MAIOR: 10× a vida, 10× o ataque. A física é a mesma do brando — o que " <>
            "muda é o preço do erro: uma mordida deste tira um quinto da vida, então " <>
            "\"quase não tomou dano\" não existe aqui. Se o combo segura este, segura a " <>
            "hunt avançada que ele quer rodar de verdade.",
        route: :hunt_field,
        knobs: %{
          nest_size: 0,
          stray_chance_pct: 0,
          # mais cedo que o brando de propósito: um 10× leva ~70s de combo pra
          # cair, e a promessa `mata` precisa ver pelo menos um corpo dentro da
          # janela de 3 minutos dos invariantes
          boss_every_ms: 30_000,
          boss_hp_mult: 10,
          boss_atk_mult: 10,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          # MEDIDO POR ELE (30/08, segunda passada): "o stun dura 5s,
          # começando a contar depois dos 2s" — pegada 2s, sono 5s
          stun_ms: 5_000,
          stun_onset_ms: 2_000,
          # O F4 NÃO TEM COOLDOWN NO JOGO ("aquele era um cooldown de
          # segurança") — o piso de 5s é do CÉREBRO (rescue_floor_ms, contado
          # da ordem), e um mundo que recusa F4 por conta própria modela um
          # jogo que não existe: a recusa silenciosa trancava a corrente.
          revive_cooldown_ms: 0,
          presses_to_kill: 3
        },
        config: %{
          reset_revive: true,
          boss_names: "chefe",
          stun_hold_ms: 7_000,
          # o mesmo piso do knob revive_cooldown_ms do mundo: o cérebro segura
          # o stun até o F4 que vem atrás caber nele
          rescue_floor_ms: 5_000,
          # sem R11 aqui: o prepare re-baseava o piso do resgate na cara do
          # chefe seguinte, e o stun ficava 2s esperando o F4 caber. Contra
          # chefe o primeiro ciclo já chega resetando — preparar é pagar dobrado.
          prepare_revive: false
        }
      },
      %__MODULE__{
        id: "estrada-com-chefes",
        group: :chefe,
        icon: "🛤️",
        aperto: :aperto,
        # SÓ :mata, e é o diagnóstico DELE virado em contrato (30/08): "ainda
        # não confio nas de boss, a hunt ainda não tá tão bem organizada — 1
        # erro é morte na certa". Um chefe 10× no meio de pilha comum vive no
        # fio (vida mínima 3-20 nas sementes); prometer nao_cai aqui hoje
        # seria flake, não régua. A promessa volta quando a hunt mista fechar.
        espera: [:mata],
        name: "Estrada com chefes",
        why:
          "A hunt avançada inteira: os ninhos de sempre E um chefe 10× brotando no meio " <>
            "dela de tempos em tempos. É o teste de POSTURA — largar a pilha na hora, " <>
            "rodar o combo, e voltar pra caçada — e de bolso: cada chefe custa uma fila de " <>
            "revives. Sem promessa de dano zero nem de andar aqui, de propósito: com bicho " <>
            "comum na tela mordida faz parte, e o ciclo de chefe é parado por natureza. O " <>
            "que não pode é cair nem parar de matar.",
        route: :hunt_field,
        knobs: %{
          nest_sizes: %{2 => 3, 3 => 3, 4 => 2},
          nest_radius: 3,
          aggro_tiles: 8,
          leash_tiles: 12,
          respawn_ms: 30_000,
          boss_every_ms: 90_000,
          boss_hp_mult: 10,
          boss_atk_mult: 10,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          # MEDIDO POR ELE (30/08, segunda passada): "o stun dura 5s,
          # começando a contar depois dos 2s" — pegada 2s, sono 5s
          stun_ms: 5_000,
          stun_onset_ms: 2_000,
          # O F4 NÃO TEM COOLDOWN NO JOGO ("aquele era um cooldown de
          # segurança") — o piso de 5s é do CÉREBRO (rescue_floor_ms, contado
          # da ordem), e um mundo que recusa F4 por conta própria modela um
          # jogo que não existe: a recusa silenciosa trancava a corrente.
          revive_cooldown_ms: 0,
          presses_to_kill: 3
        },
        config: %{
          reset_revive: true,
          boss_names: "chefe",
          stun_hold_ms: 7_000,
          # o mesmo piso do knob revive_cooldown_ms do mundo: o cérebro segura
          # o stun até o F4 que vem atrás caber nele
          rescue_floor_ms: 5_000,
          # sem R11 aqui: o prepare re-baseava o piso do resgate na cara do
          # chefe seguinte, e o stun ficava 2s esperando o F4 caber. Contra
          # chefe o primeiro ciclo já chega resetando — preparar é pagar dobrado.
          prepare_revive: false
        }
      },
      %__MODULE__{
        id: "a-noite-medida",
        group: :mundo,
        icon: "📏",
        aperto: :rotina,
        espera: [:nao_cai, :mata, :anda, :revive_util],
        name: "A tua noite, medida",
        why:
          "O CENÁRIO DE REFERÊNCIA: nenhum número aqui foi escolhido por mim. Todos saem da " <>
            "noite de 28/08 lida por `Sim.Calibrate` — a mordida de 0,41% da vida por segundo " <>
            "por bicho (n=8.011), a pilha de mediana 6 na hora do engajamento (n=5.840), e as " <>
            "3,0 teclas por morto (n=4.867). Se o simulador estiver dizendo a verdade, esta " <>
            "corrida se parece com a tua noite; se não estiver, é AQUI que a diferença " <>
            "aparece, e não num cenário que eu inventei.",
        route: :hunt_field,
        knobs: %{
          # a distribuição com mediana 6 e teto 9, que é o que a noite mostrou
          nest_sizes: %{3 => 1, 4 => 2, 5 => 3, 6 => 4, 7 => 3, 8 => 2, 9 => 1},
          nest_radius: 3,
          stray_chance_pct: 30,
          aggro_tiles: 8,
          leash_tiles: 12,
          respawn_ms: 30_000,
          # MEDIDO: 0,41%/s por bicho. A cadência fica em 1s e a medição inteira
          # vai no tamanho — a mesma escolha que `Calibrate.bite_knobs/1` faz,
          # porque inventar o segundo número é como um knob medido volta a ser
          # chute. A mesa dele diz 4 a cada 900ms: dez vezes mais forte.
          bite_dmg: 1,
          bite_every_ms: 1_000,
          mob_hp: 100,
          presses_to_kill: 3
        }
      },
      %__MODULE__{
        id: "enxame",
        group: :mundo,
        icon: "🐝",
        aperto: :aperto,
        espera: [:nao_cai, :mata, :revive_no_prazo],
        name: "Enxame (muito bicho de uma vez)",
        why:
          "Pilhas de 10 a 14 — ACIMA do que a noite dele já mostrou (o teto medido foi 9). " <>
            "A pergunta não é se a área acerta todo mundo, é o que ele faz quando a pilha é " <>
            "maior que a barra: tem que juntar, gastar tudo, controlar e reviver pra voltar " <>
            "com a barra cheia, sem recuar. Se aparecer revive fora da janela do controle, é " <>
            "aqui que se vê.",
        route: :anthill,
        knobs: %{
          nest_sizes: %{10 => 3, 11 => 3, 12 => 2, 13 => 1, 14 => 1},
          nest_radius: 3,
          stray_chance_pct: 40,
          aggro_tiles: 9,
          leash_tiles: 14,
          respawn_ms: 25_000,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          presses_to_kill: 3
        }
      },
      %__MODULE__{
        id: "couracado",
        group: :mundo,
        icon: "🛡️",
        aperto: :aperto,
        espera: [:nao_cai, :mata, :revive_no_prazo, :revive_util],
        name: "Couraçado (morre em 8 teclas)",
        why:
          "O bicho duro que ele pediu: “pra testar como lidamos com monstros com mais ou " <>
            "menos vida — se sabemos usar corretamente a skill de controle antes de usar " <>
            "ressurect para resetar os cooldowns, e seguir esse loop até matar”. Oito teclas " <>
            "por monstro é mais barra do que existe, então o loop controle → gasta tudo → " <>
            "revive → gasta tudo é a ÚNICA forma de terminar.\n\n" <>
            "A pilha nasce ACIMA da régua dele de propósito. Com pilhas de 3 a 5 (a primeira " <>
            "versão deste cenário) a régua responde “não vale” antes de a dureza ter chance " <>
            "de perguntar alguma coisa: o bot usa a mão pequena, dá um tiro e segue — e a " <>
            "corrida mede zero mortos em dois minutos, dizendo sobre a régua o que o nome " <>
            "prometia dizer sobre a vida do bicho.",
        route: :anthill,
        knobs: %{
          nest_sizes: %{6 => 3, 7 => 3, 8 => 2, 9 => 1},
          nest_radius: 2,
          aggro_tiles: 10,
          leash_tiles: 16,
          respawn_ms: 40_000,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          # A DUREZA EM TECLAS, não em vida: subir `mob_hp` sozinho não deixaria
          # bicho nenhum mais duro (o dano é % da vida). Ver `World`.
          presses_to_kill: 8
        }
      },
      %__MODULE__{
        id: "casca-de-ovo",
        group: :mundo,
        icon: "🥚",
        aperto: :rotina,
        espera: [:nao_cai, :mata, :anda, :revive_util],
        name: "Casca de ovo (morre numa tecla)",
        why:
          "O oposto do couraçado: uma tecla mata. A pergunta é a ECONOMIA — com tudo " <>
            "morrendo no primeiro toque, cada tecla que sai a mais é uma tecla que ficou " <>
            "45 segundos em cooldown por nada, e cada revive é uma bola do bolso dele " <>
            "gasta numa luta que não precisava de nenhuma.\n\n" <>
            "Ele ainda gasta revives aqui, e isso NÃO é um defeito: com uma tecla por " <>
            "monstro a barra esvazia rápido, e a R3b troca o revive pela barra de volta. " <>
            "O que se cobra é que nenhum deles saia com tecla de dano ainda na mão.",
        route: :anthill,
        knobs: %{
          nest_sizes: %{2 => 3, 3 => 3, 4 => 2, 5 => 1},
          nest_radius: 2,
          aggro_tiles: 8,
          leash_tiles: 12,
          respawn_ms: 20_000,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          presses_to_kill: 1
        }
      },
      %__MODULE__{
        id: "mare",
        group: :mundo,
        icon: "🌊",
        aperto: :aperto,
        espera: [:nao_cai, :mata, :anda],
        name: "Maré (eles não param de nascer)",
        why:
          "O ninho renasce a cada 6 segundos: a pilha volta a crescer enquanto ele ainda " <>
            "está matando a anterior. É o “toda hora aparece no monte” dele levado ao " <>
            "extremo, e a pergunta é se a rodada CHEGA A FECHAR — um bot que só sai quando " <>
            "a tela limpa fica preso aqui pra sempre, e a promessa que cobra isso é “anda”.",
        route: :anthill,
        knobs: %{
          nest_sizes: %{4 => 3, 5 => 3, 6 => 2},
          nest_radius: 3,
          stray_chance_pct: 35,
          aggro_tiles: 9,
          leash_tiles: 14,
          respawn_ms: 6_000,
          bite_dmg: 1,
          bite_every_ms: 1_000,
          presses_to_kill: 3
        }
      },
      %__MODULE__{
        id: "pilha-pequena",
        group: :ruler,
        icon: "🔹",
        aperto: :rotina,
        espera: [],
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
        icon: "🎯",
        aperto: :rotina,
        espera: [],
        name: "Pilha que fecha",
        why:
          "Cinco chegam e param de chegar. É a janela que o desenho chama de sizing → " <>
            "engaged: veja quanto tempo ele espera antes de abrir.",
        knobs: %{nest_size: 5, nest_radius: 0, aggro_tiles: 20}
      },
      %__MODULE__{
        id: "pilha-que-pinga",
        group: :ruler,
        icon: "💧",
        aperto: :aperto,
        espera: [],
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
        icon: "🏃",
        aperto: :aperto,
        espera: [],
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
        icon: "🩸",
        aperto: :aperto,
        espera: [],
        name: "Vida caindo até o amarelo",
        why:
          "A mordida é forte. Acompanhe verde → amarelo: a rota deve travar (fecha a " <>
            "rodada) antes de qualquer revive.",
        knobs: %{nest_size: 4, nest_radius: 1, aggro_tiles: 20, bite_dmg: 14, bite_every_ms: 500}
      },
      %__MODULE__{
        id: "vermelho",
        group: :health,
        icon: "🚨",
        aperto: :aperto,
        espera: [],
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
        icon: "💀",
        aperto: :quebrado,
        espera: [],
        name: "Ele cai (e o revive não sai)",
        why:
          "A barra some junto com o pokémon: o fato vira readable?: false e fainted?: true. " <>
            "É assim que o suporte descobre a morte — não por vida zero. O revive é " <>
            "ORDENADO e não sai (a falha de 24/08), senão ele salva sempre e a queda " <>
            "nunca chega a acontecer.",
        knobs: %{nest_size: 3, nest_radius: 0, aggro_tiles: 20, bite_dmg: 20, bite_every_ms: 400},
        # SEM o stun do resgate: a pergunta aqui é o que a caçada faz quando o
        # revive não sai, e com a pilha dormindo ela não chega a precisar de um.
        config: %{rescue_stun_first: false},
        script: [{100, {:fail, :dead_revive}}]
      },
      %__MODULE__{
        id: "tecla-morta",
        group: :hands,
        icon: "🔇",
        aperto: :quebrado,
        espera: [],
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
        icon: "🌫️",
        aperto: :quebrado,
        espera: [],
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
  def route(%__MODULE__{route: :lotavanon}, _available), do: lotavanon()

  def route(%__MODULE__{route: name}, available),
    do: Enum.find(available, &(&1.name == name)) || ring()

  @doc """
  Os tiles que o personagem não atravessa neste cenário.

  Vazio no chão liso, que é o de sempre. No anel, uma parede externa e uma
  interna formam o corredor que ele anda, e algumas pedras ficam DENTRO do
  corredor — porque uma parede que só delimita não faz ninguém tropeçar.
  """
  @spec blocked(t) :: MapSet.t()
  def blocked(%__MODULE__{chao: :liso}), do: MapSet.new()

  def blocked(%__MODULE__{chao: :anel} = scenario) do
    %Route{waypoints: [%{z: z} | _]} = route(scenario, [])

    parede_externa = anel(14, z) |> MapSet.new()
    parede_interna = anel(6, z) |> MapSet.new()

    # As pedras ficam no raio do circuito (11), espalhadas de forma FIXA: um
    # obstáculo sorteado a cada corrida faria duas sementes medirem mapas
    # diferentes, e o cenário deixaria de ser um experimento.
    pedras =
      for passo <- [3, 17, 31, 44, 58, 71], into: MapSet.new() do
        a = 2 * :math.pi() * passo / 80
        {1_000 + round(11 * :math.cos(a)), 1_000 + round(11 * :math.sin(a)), z}
      end

    parede_externa |> MapSet.union(parede_interna) |> MapSet.union(pedras)
  end

  defp anel(raio, z) do
    for passo <- 0..(8 * raio) do
      a = 2 * :math.pi() * passo / (8 * raio)
      {1_000 + round(raio * :math.cos(a)), 1_000 + round(raio * :math.sin(a)), z}
    end
  end

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
  O anel de Lotavanon: doze cantos num CÍRCULO, cada um com ninho.

  Os outros circuitos são polígonos desenhados pra caber numa pergunta. Este é a
  forma do mapa dele — "uma área circular mesmo, cheia de bichinho" — e a forma
  importa: num anel ele nunca anda de volta pelo que já limpou, então o
  renascimento chega nele em vez de ele voltar buscar.
  """
  @spec lotavanon() :: Route.t()
  def lotavanon do
    %Route{
      name: "anel de lotavanon",
      waypoints:
        for {x, y} <- [
              {1011, 1000},
              {1010, 1005},
              {1006, 1010},
              {1000, 1011},
              {995, 1010},
              {990, 1005},
              {989, 1000},
              {990, 995},
              {994, 990},
              {1000, 989},
              {1006, 990},
              {1010, 994}
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
            # CADA CANTO é ninho: num anel cheio não existe trecho vazio, e um
            # waypoint sem `gather_ms`/`fight_ms` não é ninho nenhum — só tira
            # um dado de passante (`World.population_of/2`). A primeira versão
            # deste circuito não tinha nenhum dos dois, então o "mapa cheio de
            # bichinho" nascia praticamente vazio: 1,19 monstro por tiro contra
            # os 3,82 do formigueiro.
            fight_ms: nil,
            gather_ms: 2_000,
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
