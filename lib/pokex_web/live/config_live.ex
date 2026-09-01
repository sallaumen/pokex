defmodule PokexWeb.ConfigLive do
  @moduledoc """
  O /config como uma PÁGINA: todo ajuste simples do bot, num lugar só, com busca.

  O que existia era um overlay em cima do dashboard — denso, em fonte de 11px,
  com os ajustes na ordem em que foram nascendo e SEM os mais novos (28/08: o
  `revive_stock` não tinha campo nenhum; ele soube dele por uma mensagem minha
  e não achou onde digitar). "Eu que uso óculos consigo entender nada direito,
  preciso de menos texto, mais ícones, algo BEM mais simples."

  Três decisões respondem isso:

    * **Schema, não formulários à mão.** Cada ajuste é uma linha declarada
      (chave, tipo, rótulo, dica) e o salvar é genérico via `Settings.put/2`,
      que já valida tipo, faixa e enum. Um ajuste novo no `Settings` vira uma
      linha aqui — não um formulário, um evento e um teste novos.
    * **Busca em primeiro lugar.** A pergunta dele era "onde está o
      revive_stock?" — a resposta certa é uma caixa de busca que filtra as
      linhas por rótulo, dica e nome da chave, não uma ordem melhor de seções.
    * **Menos texto na tela.** O rótulo é curto, o número é grande
      (`text-pk-title`, tabular), e a explicação inteira mora no `?` de cada
      linha (tooltip nativo) — visível quando perguntada, invisível no resto.

  Os editores COMPOSTOS (bolas por espécie, presets, shiny) continuam
  no overlay do painel, agora em `/config/editores` — eles são formulários de
  verdade, com estado próprio, e não cabem num schema de linhas.

  Salvar é imediato (phx-change com debounce): não há botão "aplicar", e o ✓
  verde na linha diz que o número em vigor é o que está na tela.
  """
  use PokexWeb, :live_view

  alias Pokex.Bots.AlarmCategories
  alias Pokex.Bots.HuntMode
  alias Pokex.Settings

  # ---------------------------------------------------------------------------
  # O SCHEMA. `kind` decide o controle e a conversão:
  #   :bool — linha inteira é o botão
  #   :int  — número cru        :pct — número com "%"
  #   :sec  — guardado em ms, editado em segundos
  #   :min  — guardado em ms, editado em minutos
  #   :ms   — guardado e editado em ms, para tempos curtos que não cabem
  #           redondos em segundos (o :sec é inteiro: 1500 viraria 1000)
  #   :key  — texto mono curto (tecla)
  #   :select — enum fechado do Settings
  # `hint` vira o tooltip do ?; `keywords` só alimenta a busca.
  # ---------------------------------------------------------------------------

  @groups [
    %{
      id: "estoque",
      icon: "hero-archive-box",
      tint: :ok,
      title: "Estoque de revives",
      rows: [
        %{
          key: :revive_stock,
          kind: :int,
          label: "Revives no bolso",
          hint:
            "Quantos revives você tem AGORA. Digitar aqui É o botão de repor: a conta de gastos " <>
              "zera quando o número muda. 0 = não contei (orçamento desligado).",
          keywords: "revive stock estoque bolso orçamento repor caderninho"
        },
        %{
          key: :engine_revive_reserve,
          kind: :int,
          label: "Reserva de emergência",
          hint:
            "Quando a conta chega aqui, o cérebro para de gastar revive com conveniência " <>
              "(preparo, reset). Vermelho, amarelo e caído gastam até o fim.",
          keywords: "reserva emergência orçamento"
        }
      ]
    },
    %{
      id: "voce",
      icon: "hero-user",
      tint: :danger,
      title: "Você, o personagem",
      note: {"marque a barra vermelha na", "Calibração → Vida do PERSONAGEM", "/calibration"},
      rows: [
        %{
          key: :player_hp_floor_pct,
          kind: :pct,
          label: "Alarme abaixo de",
          hint:
            "Duas leituras seguidas da SUA vida (a barra vermelha do painel 'Pokémon') abaixo " <>
              "disto disparam o alarme. 0 desliga o grito; a leitura continua.",
          keywords: "vida personagem player você piso alarme"
        },
        %{
          key: :player_hp_logout,
          kind: :bool,
          label: "Logout automático",
          hint:
            "Sangrando abaixo do piso, sair do jogo (Ctrl+Q com conferência de tela) — a única " <>
              "fuga que existe pra quem está sem pokémon em pé.",
          keywords: "logout automático sair personagem auto"
        }
      ]
    },
    %{
      id: "sobrevivencia",
      icon: "hero-heart",
      tint: :warn,
      title: "Revive e cura do pokémon",
      rows: [
        %{
          key: :rescue_enabled,
          kind: :bool,
          label: "Revive automático",
          hint: "O socorro caro: recolhe e devolve o pokémon, zerando os cooldowns.",
          keywords: "revive resgate rescue automático"
        },
        %{
          key: :pokemon_hp_rescue_pct,
          kind: :pct,
          label: "Revive abaixo de",
          hint:
            "Deixe BEM abaixo da poção: a vida passa pelo número maior primeiro, e um revive " <>
              "acima dela recolhe o pokémon em toda luta.",
          keywords: "revive vida limiar pct"
        },
        %{
          key: :rescue_cooldown_ms,
          kind: :sec,
          label: "Um revive a cada",
          hint: "O piso entre dois revives de um pokémon vivo.",
          keywords: "revive intervalo cooldown"
        },
        %{
          key: :revive_dry_action,
          kind: :select,
          label: "Bag sem revive: fazer o quê",
          hint:
            "Três revives pagos sem a vida voltar = a bag secou (ou o jogo ficou surdo ao F4). " <>
              "logout SAI do jogo (para a frota antes); stop só para a caçada; alarm só grita — " <>
              "e gritar foi o que não bastou nas duas mortes de 01/09.",
          keywords: "revive bag vazia estoque seca logout parar emergência"
        },
        %{
          key: :rescue_key,
          kind: :key,
          label: "Tecla do revive",
          hint: "A tecla que o jogo entende como revive (ex.: f4).",
          keywords: "revive tecla key f4"
        },
        %{
          key: :rescue_stun_first,
          kind: :bool,
          label: "Dormir a pilha antes",
          hint:
            "Usa o controle do /time antes de reviver — reviver exposto no meio do bolo é como " <>
              "o personagem apanha (medido: sem ele, 45 quedas por hora no circuito denso). " <>
              "No Auto Combo ele NÃO sai: a corrente do jogo já termina em stun, e o revive cai " <>
              "dentro desse sono.",
          keywords: "stun controle dormir antes revive"
        },
        %{
          key: :rescue_stun_settle_ms,
          kind: :ms,
          label: "…e espera dormirem",
          hint:
            "Quanto o pokémon FICA EM CAMPO depois do controle, tanqueando, antes de sair. " <>
              "A tecla sair não é a pilha dormir: o recibo prova que o cooldown começou, e o " <>
              "sono do jogo leva mais um tanto. Curto demais e o campo esvazia com o bolo " <>
              "ainda acordado.",
          keywords: "stun settle espera dormir sono revive controle"
        },
        %{
          key: :rescue_blackout_ms,
          kind: :ms,
          label: "…e volta a atacar em",
          hint:
            "O pokémon SAI de campo no revive e volta. Enquanto está fora, a barra mostra tudo " <>
              "pronto e nenhuma skill sai. Medido em 29/08: 91% das teclas ignoradas pelo jogo " <>
              "estavam no primeiro segundo depois de um revive.",
          keywords: "revive janela cega blackout volta atacar campo"
        },
        %{
          key: :pokemon_hp_fainted_below_pct,
          kind: :pct,
          label: "Caído abaixo de",
          hint:
            "Abaixo disto a barra lida conta como pokémon no chão, e o revive entra no lugar da " <>
              "cura. Acima, uma leitura ruim é só uma leitura ruim.",
          keywords: "caído fainted desmaiou chão vida limiar"
        },
        %{
          key: :fainted_revive_cooldown_ms,
          kind: :sec,
          label: "Caído: pedir a cada",
          hint: "O piso entre dois revives de um pokémon JÁ no chão.",
          keywords: "caído fainted revive chão"
        },
        %{
          key: :heal_skill_enabled,
          kind: :bool,
          label: "Skill de cura",
          hint: "A tecla :heal do /time — o único socorro que funciona apanhando.",
          keywords: "cura heal skill"
        },
        %{
          key: :pokemon_hp_heal_pct,
          kind: :pct,
          label: "Cura abaixo de",
          hint: "Vida do pokémon abaixo disto aperta a skill de cura.",
          keywords: "cura heal vida limiar"
        },
        %{
          key: :potion_enabled,
          kind: :bool,
          label: "Poção automática",
          hint: "Canal que o jogo cancela apanhando — só sai fora de luta.",
          keywords: "poção potion automática"
        },
        %{
          key: :pokemon_hp_potion_pct,
          kind: :pct,
          label: "Poção abaixo de",
          hint: "Vida do pokémon abaixo disto usa a poção (fora de luta).",
          keywords: "poção vida limiar"
        },
        %{
          key: :potion_key,
          kind: :key,
          label: "Tecla da poção",
          hint: "Onde a poção está no atalho (ex.: e).",
          keywords: "poção tecla key"
        }
      ]
    },
    %{
      id: "modo",
      icon: "hero-adjustments-horizontal",
      tint: :info,
      title: "Modo de caça",
      note: {"cada rota pode escolher o dela em", "Cavebot → rota ativa", "/cavebot"},
      rows: [
        %{
          key: :hunt_mode,
          kind: :select,
          label: "Modo padrão das rotas",
          hint:
            "Auto Combo: o jogo encadeia as skills atrás de UMA tecla — o bot aperta uma vez e " <>
              "cuida só do revive. Econômico: Tab, alvo único e área só se precisar, pra rota " <>
              "barata. A rota que escolher um modo manda mais que isto.",
          keywords: "modo caça auto combo econômico estratégia combate"
        },
        %{
          key: :auto_combo_key,
          kind: :key,
          label: "Tecla do combo",
          hint:
            "A tecla que o JOGO usa pra encadear as skills ofensivas (ex.: r). É um atalho do " <>
              "cliente, como as posturas — não um slot de pokémon. Em branco, o Auto Combo não " <>
              "tem o que apertar.",
          keywords: "combo tecla r auto atalho"
        },
        %{
          key: :auto_combo_window_ms,
          kind: :ms,
          label: "O combo ocupa por",
          hint:
            "Quanto tempo a corrente do jogo leva pra sair. Nada ofensivo é apertado nessa " <>
              "janela, e o revive do ciclo espera ela acabar — cortar a corrente joga fora o " <>
              "dano que faltava. Cronometrado em 3,5s; o padrão de 4s é ele com meia folga.",
          keywords: "combo janela tempo ms corrente"
        }
      ]
    },
    %{
      id: "cerebro",
      icon: "hero-cpu-chip",
      tint: :info,
      title: "Cérebro da caçada",
      rows: [
        %{
          key: :engine_boss_grit,
          kind: :int,
          label: "Chefe pelo tempo de matar",
          hint:
            "Quantas skills de dano o bicho engole (cooldown andou) sem NENHUM corpo cair " <>
              "antes do cérebro declarar chefe e rodar o combo skills → stun → revive. " <>
              "Uma pilha comum nunca passa de ~4; um chefe 10× engole 10 em dois giros da " <>
              "barra. 0 desliga (só o nome declara). Vale pra chefe com o MESMO nome dos " <>
              "outros pokémons.",
          keywords: "chefe boss tempo grit postura combo stun revive dano"
        },
        %{
          key: :engine_boss_names,
          kind: :key,
          label: "Nomes dos chefes",
          hint:
            "Separados por vírgula (ex.: chefe, boss x) — o jeito ANTIGO, pra chefe com " <>
              "nome próprio na janela de batalha. Com um destes nomes na tela o cérebro " <>
              "entra na postura de chefe na hora, sem esperar o tempo de matar. Vazio " <>
              "desliga (o \"chefe pelo tempo de matar\" acima segue valendo).",
          keywords: "chefe boss nome postura combo stun revive"
        },
        %{
          key: :engine_stun_hold_ms,
          kind: :sec,
          label: "…quanto o teu stun segura",
          hint:
            "Do APERTO até o sono acabar: a pegada (~2s até o efeito cair — o mesmo tempo " <>
              "do settle) + a duração do sono (~5s) = 7. O combo de chefe emenda o próximo " <>
              "stun quando a cobertura restante chega na pegada.",
          keywords: "stun sono duração segura chefe cronometro pegada"
        },
        %{
          key: :engine_stun_reach_tiles,
          kind: :int,
          label: "…e até quantos tiles alcança",
          hint:
            "O raio útil do teu controle, em tiles (um a menos que o real, de folga). O stun " <>
              "de chefe só sai com o alvo dentro disto — apertar com ele longe é dormir o " <>
              "vento e chegar acordado.",
          keywords: "stun raio alcance tiles chefe vento"
        },
        %{
          key: :engine_engage_from,
          kind: :int,
          label: "Encara a partir de (bichos)",
          hint:
            "Menos que isto na tela e o cérebro segue andando em vez de parar pra lutar. Num " <>
              "mapa que lota, subir este número é o que impede a caçada de parar a cada bicho " <>
              "solto; 1 é lutar com tudo.",
          keywords: "encarar engajar engage lutar a partir bichos mínimo"
        },
        %{
          key: :engine_gather_target,
          kind: :int,
          label: "Juntar até (bichos)",
          hint: "A janela de mob fecha quando o bolo chega neste tamanho.",
          keywords: "juntar mobar gather alvo pilha bolo"
        },
        %{
          key: :engine_bunch_walk_tiles,
          kind: :int,
          label: "Puxar mais (passos)",
          hint: "Fechada a janela, anda isto pra colar a pilha antes de parar.",
          keywords: "puxar passos bunch andar"
        },
        %{
          key: :engine_bunch_ms,
          kind: :sec,
          label: "Esperar a pilha fechar",
          hint: "Parado, quanto esperar os bichos chegarem em cima antes de estourar a área.",
          keywords: "esperar espera bunch janela fechar"
        },
        %{
          key: :engine_prepare_revive,
          kind: :bool,
          label: "Chegar preparado (R11)",
          hint:
            "Entre grupos, com a barra pela metade, gasta um revive pra chegar inteiro no próximo.",
          keywords: "preparado prepare revive entre grupos r11"
        },
        %{
          key: :engine_prepare_max_enemies,
          kind: :int,
          label: "…mesmo com até (restos)",
          hint:
            "Na estrada, quantos restos na tela ainda contam como 'entre grupos'. A tela dessa " <>
              "rota nunca zera — com isto em 0 o preparo nunca dispara.",
          keywords: "preparo restos teto estrada"
        },
        %{
          key: :engine_reset_revive,
          kind: :bool,
          label: "Revive como reset (R3b)",
          hint: "Barra vazia na frente da pilha: compra a barra de volta com um revive.",
          keywords: "reset revive barra r3b"
        },
        %{
          key: :engine_downed_give_up_ms,
          kind: :min,
          label: "Desistir do chão após",
          hint:
            "Pokémon caído e o revive sem devolver ninguém por isto → a caçada PARA de vez " <>
              "(estoque acabou). A noite de 27→28/08 moeu 4,9h sem este freio. 0 desliga.",
          keywords: "freio chão desistir stranded caído give up"
        },
        %{
          key: :engine_band_yellow_pct,
          kind: :pct,
          label: "Faixa amarela abaixo de",
          hint: "Vida do pokémon abaixo disto: para de mobar, gasta os cooldowns.",
          keywords: "faixa amarela banda vida"
        },
        %{
          key: :engine_band_red_pct,
          kind: :pct,
          label: "Faixa vermelha abaixo de",
          hint: "Abaixo disto é emergência: revive agora, no meio da luta.",
          keywords: "faixa vermelha banda vida emergência"
        },
        %{
          key: :engine_resume_pct,
          kind: :pct,
          label: "Rota volta acima de",
          hint: "Depois de um revive, a rota só anda com a vida acima disto.",
          keywords: "voltar rota recuperar resume"
        },
        %{
          key: :fight_timeout_ms,
          kind: :sec,
          label: "Luta parada vira tropeço em",
          hint:
            "Tela idêntica em luta por isto = tropeço. Esperar cooldown com a barra gasta NÃO " <>
              "conta — o cérebro avisa a caçada.",
          keywords: "luta timeout tropeço stalled"
        }
      ]
    },
    %{
      id: "rajada",
      icon: "hero-bolt",
      tint: :warn,
      title: "Rajada e teclas",
      rows: [
        %{
          key: :combat_skill_burst_size,
          kind: :int,
          label: "Teclas por rajada",
          hint: "Quantas teclas saem numa rajada de ataque.",
          keywords: "rajada burst teclas"
        },
        %{
          key: :skill_burst_every_ms,
          kind: :ms,
          label: "Intervalo entre rajadas",
          hint:
            "O respiro entre duas decisões de ataque. No Econômico é ele que separa a tecla de " <>
              "alvo único da de área: uma sai, ele espera, e a outra só sai se ainda precisar.",
          keywords: "intervalo rajada respiro econômico cadência"
        },
        %{
          key: :combat_skill_gap_ms,
          kind: :int,
          unit: "ms",
          label: "Intervalo entre teclas",
          hint:
            "O teto de dano da caçada inteira: 500ms com rajada de 2 é 1s por rajada. O padrão " <>
              "é 300.",
          keywords: "intervalo gap rajada ms dano"
        },
        %{
          key: :combat_single_target,
          kind: :bool,
          label: "Usar alvo único na rotação",
          hint:
            "Desligado (o padrão desde 27/08): as de alvo único mal arranham e atrasam a área.",
          keywords: "alvo único single target rotação"
        },
        %{
          key: :combat_shield_from_enemies,
          kind: :int,
          label: "Escudo a partir de",
          hint: "Com este tanto de bicho em cima, a aura de defesa sai junto.",
          keywords: "escudo shield defesa aura"
        },
        %{
          key: :attack_mode_key,
          kind: :key,
          label: "Postura de ataque",
          hint: "A tecla da postura ofensiva — vai na frente de toda rajada.",
          keywords: "postura ataque shift modo"
        },
        %{
          key: :defense_mode_key,
          kind: :key,
          label: "Postura de defesa",
          hint: "A tecla da postura defensiva — usada segurando o fogo.",
          keywords: "postura defesa shift modo"
        }
      ]
    },
    %{
      id: "sessao",
      icon: "hero-power",
      tint: :danger,
      title: "Fuga e fim de sessão",
      rows: [
        %{
          key: :escape_direction,
          kind: :select,
          label: "Fuga: direção",
          hint: "Pra onde o pânico anda antes de entrar na escada calibrada.",
          keywords: "fuga escape direção pânico"
        },
        %{
          key: :escape_steps,
          kind: :int,
          label: "Fuga: passos",
          hint: "Quantos tiles a fuga anda na direção escolhida.",
          keywords: "fuga passos escape"
        },
        %{
          key: :stagnation_minutes,
          kind: :int,
          unit: "min",
          label: "Estagnação após",
          hint: "Sem kill e sem peixe por isto, age. 0 desliga.",
          keywords: "estagnação parado minutos"
        },
        %{
          key: :stagnation_action,
          kind: :select,
          label: "Estagnado: fazer o quê",
          hint: "alarm só grita; stop para os bots; logout sai do jogo.",
          keywords: "estagnação ação logout stop"
        },
        %{
          key: :stop_after_minutes,
          kind: :int,
          unit: "min",
          label: "Meta: parar após",
          hint: "Sessão com hora pra acabar. 0 desliga.",
          keywords: "meta parar minutos sessão"
        },
        %{
          key: :stop_after_kills,
          kind: :int,
          label: "Meta: parar após (kills)",
          hint: "Sessão com contagem pra acabar. 0 desliga.",
          keywords: "meta parar kills sessão"
        },
        %{
          key: :stop_after_action,
          kind: :select,
          label: "Meta batida: fazer o quê",
          hint: "stop para os bots; logout também sai do jogo.",
          keywords: "meta ação stop logout"
        }
      ]
    },
    %{
      id: "pesca",
      icon: "hero-lifebuoy",
      tint: :info,
      title: "Pesca",
      rows: [
        %{
          key: :rod_key,
          kind: :key,
          label: "Tecla da vara",
          hint: "O atalho que arremessa.",
          keywords: "vara rod pesca tecla"
        },
        %{
          key: :require_cooldowns,
          kind: :bool,
          label: "Só fisgar podendo matar",
          hint: "Segura a fisga até uma skill de matar estar pronta. (do personagem ativo)",
          keywords: "pesca fisga cooldown gate"
        },
        %{
          key: :require_pokemon_hp,
          kind: :bool,
          label: "Só fisgar com vida",
          hint: "Segura a fisga com o pokémon fraco ou na bola. (do personagem ativo)",
          keywords: "pesca fisga vida gate"
        },
        %{
          key: :pokemon_hp_fishing_pct,
          kind: :pct,
          label: "Vida mínima pra puxar",
          hint: "Abaixo disto a vara espera.",
          keywords: "pesca vida mínima puxar"
        }
      ]
    },
    %{
      id: "captura",
      icon: "hero-cube",
      tint: :ok,
      title: "Captura e loot",
      rows: [
        %{
          key: :capture_enabled,
          kind: :bool,
          label: "Jogar bola nos corpos",
          hint: "O catcher olha os corpos e joga a bola configurada.",
          keywords: "captura bola corpos catcher"
        },
        %{
          key: :ball_key,
          kind: :key,
          label: "Tecla da bola",
          hint: "Onde a bola padrão está (regras por espécie: Editores).",
          keywords: "bola tecla ball"
        },
        %{
          key: :corpse_max_balls,
          kind: :int,
          label: "Bolas por corpo",
          hint: "Quantas tentativas o mesmo corpo merece.",
          keywords: "bolas corpo tentativas"
        },
        %{
          key: :corpse_scan_radius_tiles,
          kind: :int,
          unit: "tiles",
          label: "Raio de procura",
          hint: "Até onde procurar corpos ao redor do personagem.",
          keywords: "raio corpos procurar tiles"
        },
        %{
          key: :dry_balls_alarm,
          kind: :int,
          label: "Alarme de bola seca após",
          hint: "Bolas seguidas sem capturar nada disparam o alarme de estoque. 0 desliga.",
          keywords: "bola seca alarme estoque"
        },
        %{
          key: :sweep_enabled,
          kind: :bool,
          label: "Varredura de loot",
          hint: "De tempos em tempos, varre o chão ao redor por loot esquecido.",
          keywords: "varredura loot sweep"
        },
        %{
          key: :sweep_interval_ms,
          kind: :sec,
          label: "Varrer a cada",
          hint: "O intervalo entre duas varreduras.",
          keywords: "varredura intervalo sweep"
        }
      ]
    },
    %{
      id: "alarmes",
      icon: "hero-bell-alert",
      tint: :warn,
      title: "Alarmes",
      rows: [
        %{
          key: :alarm_sound,
          kind: :bool,
          label: "Som ligado",
          hint: "O apito dos alarmes. Desligado, só o painel mostra.",
          keywords: "som alarme apito áudio"
        },
        %{
          key: :alarm_min_gap_ms,
          kind: :sec,
          label: "Um apito a cada",
          hint: "O mesmo setor não apita de novo antes disto.",
          keywords: "apito intervalo gap alarme"
        }
      ]
    }
  ]

  # A busca compara neste formato: rótulo + dica + palavras + a própria chave.
  @haystacks Map.new(
               Enum.flat_map(@groups, & &1.rows),
               fn row ->
                 {row.key,
                  String.downcase(
                    "#{row.label} #{row.hint} #{Map.get(row, :keywords, "")} #{row.key}"
                  )}
               end
             )

  @key_index Map.new(Enum.flat_map(@groups, & &1.rows), &{to_string(&1.key), &1.key})
  @kinds Map.new(Enum.flat_map(@groups, & &1.rows), &{&1.key, &1.kind})

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Config",
       query: "",
       saved: nil,
       errors: %{}
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: String.downcase(String.trim(q)), saved: nil)}

  def handle_event("toggle", %{"key" => raw}, socket) do
    case known_key(raw) do
      {:ok, key} ->
        Settings.put(key, not Settings.get(key))
        {:noreply, assign(socket, saved: key, errors: Map.delete(socket.assigns.errors, key))}

      _unknown ->
        {:noreply, socket}
    end
  end

  def handle_event("save", params, socket) do
    # O form manda {"chave" => valor}; a primeira chave conhecida é a linha.
    Enum.find_value(params, {:noreply, socket}, fn {raw, value} ->
      case known_key(raw) do
        {:ok, key} -> {:noreply, save(socket, key, value)}
        _meta_field -> nil
      end
    end)
  end

  # O formato do disco é STRING (a mesma convenção do sino do cabeçalho —
  # `HeaderState.toggle_alarm_category`); escrever átomo aqui criaria duas
  # grafias do mesmo setor no mesmo arquivo.
  def handle_event("toggle_alarm_cat", %{"cat" => raw}, socket) do
    if AlarmCategories.from_string(raw) do
      muted = Settings.get(:alarm_muted_categories) || []

      updated = if raw in muted, do: List.delete(muted, raw), else: [raw | muted]
      Settings.put(:alarm_muted_categories, updated)
    end

    {:noreply, assign(socket, saved: :alarm_muted_categories)}
  end

  defp save(socket, key, value) do
    case parse(kind_of(key), value) do
      {:ok, parsed} ->
        case Settings.put(key, parsed) do
          {:error, text} ->
            assign(socket, errors: Map.put(socket.assigns.errors, key, text), saved: nil)

          _ok ->
            assign(socket, saved: key, errors: Map.delete(socket.assigns.errors, key))
        end

      :error ->
        assign(socket,
          errors: Map.put(socket.assigns.errors, key, "não entendi esse número"),
          saved: nil
        )
    end
  end

  defp parse(:sec, value), do: value |> to_int() |> scale(1_000)
  defp parse(:min, value), do: value |> to_int() |> scale(60_000)
  defp parse(kind, value) when kind in [:int, :pct, :ms], do: to_int(value)

  defp parse(kind, value) when kind in [:key, :select, :text],
    do: {:ok, value |> to_string() |> String.trim() |> String.downcase()}

  # O valor guardado é código (inglês); o que ele lê é produto. Só onde as duas
  # coisas divergem — os outros enums já guardam a palavra que a tela mostra.
  defp option_text(:hunt_mode, value), do: HuntMode.label(HuntMode.parse(value))
  defp option_text(_key, value), do: value

  defp to_int(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {n, ""} -> {:ok, n}
      _not_a_number -> :error
    end
  end

  defp scale({:ok, n}, by), do: {:ok, n * by}
  defp scale(:error, _by), do: :error

  defp known_key(raw), do: Map.fetch(@key_index, raw)

  defp kind_of(key), do: Map.fetch!(@kinds, key)

  # --- a busca ----------------------------------------------------------------

  defp visible_rows(group, ""), do: group.rows

  defp visible_rows(group, query),
    do: Enum.filter(group.rows, &String.contains?(Map.fetch!(@haystacks, &1.key), query))

  # --- valores na tela --------------------------------------------------------

  defp shown(key, :sec), do: div(Settings.get(key) || 0, 1_000)
  defp shown(key, :min), do: div(Settings.get(key) || 0, 60_000)
  defp shown(key, _kind), do: Settings.get(key)

  defp unit(%{unit: unit}, _kind), do: unit
  defp unit(_row, :sec), do: "s"
  defp unit(_row, :min), do: "min"
  defp unit(_row, :ms), do: "ms"
  defp unit(_row, :pct), do: "%"
  defp unit(_row, _kind), do: nil

  defp options(key), do: Settings.enum_values(key)

  defp tint_bg(:ok), do: "bg-pk-ok-dim text-pk-ok"
  defp tint_bg(:warn), do: "bg-pk-warn-dim text-pk-warn"
  defp tint_bg(:danger), do: "bg-pk-danger-dim text-pk-danger"
  defp tint_bg(:info), do: "bg-pk-info-dim text-pk-info"

  defp muted?(cat), do: to_string(cat) in (Settings.get(:alarm_muted_categories) || [])

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :groups, @groups)

    ~H"""
    <Layouts.app flash={@flash} current_page={:config} max_width="max-w-[1200px]">
      <div class="space-y-4">
        <header class="space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h1 class="flex items-center gap-2 text-pk-title font-bold text-pk-text">
              <.icon name="hero-adjustments-horizontal" class="size-5" /> Configurações
            </h1>
            <p class="font-mono text-pk-meta text-pk-text-3">
              muda → salva na hora · <span class="text-pk-ok">✓</span> = em vigor
            </p>
          </div>

          <%!-- A BUSCA É A PORTA. "Não achei o revive_stock" nunca mais: digitar
                qualquer pedaço do nome, do rótulo ou da dica acha a linha. --%>
          <form id="config-search-form" phx-change="search" class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-pk-text-3"
            />
            <input
              id="config-search"
              type="search"
              name="q"
              value={@query}
              placeholder="buscar um ajuste… (ex.: revive, logout, rajada)"
              autocomplete="off"
              phx-debounce="150"
              class="h-11 w-full rounded-xl border border-pk-line-strong bg-pk-surface pl-10 pr-3 text-pk-title text-pk-text placeholder:text-pk-text-3 focus:border-pk-ok/60 focus:outline-none"
            />
          </form>
        </header>

        <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          <section
            :for={group <- @groups}
            :if={visible_rows(group, @query) != []}
            id={"cfg-#{group.id}"}
            class="self-start overflow-hidden rounded-xl border border-pk-line bg-pk-surface"
          >
            <header class="flex items-center gap-2.5 border-b border-pk-line px-3 py-2.5">
              <span class={[
                "grid size-8 shrink-0 place-items-center rounded-lg",
                tint_bg(group.tint)
              ]}>
                <.icon name={group.icon} class="size-4" />
              </span>
              <h2 class="text-pk-body font-bold text-pk-text">{group.title}</h2>
            </header>

            <p
              :if={group[:note]}
              class="border-b border-pk-line bg-pk-sunken px-3 py-2 text-pk-meta text-pk-text-3"
            >
              {elem(group.note, 0)}
              <.link navigate={elem(group.note, 2)} class="text-pk-info hover:underline">
                {elem(group.note, 1)}
              </.link>
            </p>

            <ul class="divide-y divide-pk-line">
              <li :for={row <- visible_rows(group, @query)} id={"cfg-row-#{row.key}"}>
                <%!-- BOOL: a linha INTEIRA é o botão — alvo grande, estado óbvio. --%>
                <button
                  :if={row.kind == :bool}
                  type="button"
                  phx-click="toggle"
                  phx-value-key={row.key}
                  class="flex w-full items-center gap-2.5 px-3 py-2.5 text-left transition hover:bg-pk-raised"
                >
                  <span class={[
                    "relative h-5 w-9 shrink-0 rounded-full transition-colors",
                    if(Settings.get(row.key), do: "bg-pk-ok", else: "bg-pk-line-strong")
                  ]}>
                    <span class={[
                      "absolute top-0.5 size-4 rounded-full bg-pk-bg transition-all",
                      if(Settings.get(row.key), do: "left-4", else: "left-0.5")
                    ]}></span>
                  </span>
                  <span class="min-w-0 flex-1 truncate text-pk-body text-pk-text">
                    {row.label}
                  </span>
                  <.hint text={row.hint} />
                  <.saved_tick saved={@saved} key={row.key} />
                </button>

                <%!-- NÚMEROS e TEXTOS: rótulo à esquerda, valor GRANDE à direita. --%>
                <form
                  :if={row.kind != :bool}
                  id={"cfg-form-#{row.key}"}
                  phx-change="save"
                  class="flex items-center gap-2.5 px-3 py-2"
                >
                  <label
                    for={"cfg-input-#{row.key}"}
                    class="min-w-0 flex-1 truncate text-pk-body text-pk-text"
                  >
                    {row.label}
                  </label>
                  <.hint text={row.hint} />
                  <.saved_tick saved={@saved} key={row.key} />

                  <select
                    :if={row.kind == :select}
                    id={"cfg-input-#{row.key}"}
                    name={row.key}
                    class="h-9 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-body text-pk-text focus:border-pk-ok/60 focus:outline-none"
                  >
                    <option
                      :for={opt <- options(row.key)}
                      value={opt}
                      selected={opt == Settings.get(row.key)}
                    >
                      {option_text(row.key, opt)}
                    </option>
                  </select>

                  <input
                    :if={row.kind in [:int, :pct, :sec, :min, :ms]}
                    id={"cfg-input-#{row.key}"}
                    name={row.key}
                    type="number"
                    inputmode="numeric"
                    value={shown(row.key, row.kind)}
                    phx-debounce="500"
                    class="pk-num h-9 w-20 rounded-lg border border-pk-line-strong bg-pk-raised px-2 text-right font-mono text-pk-title font-bold tabular-nums text-pk-text focus:border-pk-ok/60 focus:outline-none"
                  />

                  <input
                    :if={row.kind == :key}
                    id={"cfg-input-#{row.key}"}
                    name={row.key}
                    type="text"
                    value={Settings.get(row.key)}
                    phx-debounce="600"
                    class="h-9 w-20 rounded-lg border border-pk-line-strong bg-pk-raised px-2 text-center font-mono text-pk-title font-bold text-pk-text focus:border-pk-ok/60 focus:outline-none"
                  />

                  <span
                    :if={unit(row, row.kind)}
                    class="w-7 shrink-0 font-mono text-pk-meta text-pk-text-3"
                  >
                    {unit(row, row.kind)}
                  </span>
                </form>

                <p
                  :if={@errors[row.key]}
                  class="px-3 pb-2 text-pk-meta text-pk-danger"
                  id={"cfg-error-#{row.key}"}
                >
                  {@errors[row.key]}
                </p>
              </li>
            </ul>

            <%!-- Os setores do alarme, como fichas: aceso = apita. --%>
            <div
              :if={
                group.id == "alarmes" and
                  (@query == "" or String.contains?("alarme setores mudo categorias", @query))
              }
              class="border-t border-pk-line px-3 py-2.5"
            >
              <p class="mb-1.5 font-mono text-pk-meta uppercase tracking-[0.12em] text-pk-text-3">
                setores — aceso apita
              </p>
              <div class="flex flex-wrap gap-1.5">
                <button
                  :for={{cat, label} <- AlarmCategories.all()}
                  type="button"
                  phx-click="toggle_alarm_cat"
                  phx-value-cat={cat}
                  title={label}
                  class={[
                    "rounded-lg border px-2.5 py-1.5 font-mono text-pk-meta font-semibold transition",
                    if(muted?(cat),
                      do: "border-pk-line text-pk-text-3 line-through",
                      else: "border-pk-ok-line bg-pk-ok-dim text-pk-ok"
                    )
                  ]}
                >
                  {cat}
                </button>
              </div>
            </div>
          </section>

          <%!-- O que NÃO cabe em linhas: os editores compostos, cada um na
                página que já sabe editá-lo. --%>
          <section
            :if={
              @query == "" or
                String.contains?("editores combos presets bolas shiny time calibração rotas", @query)
            }
            id="cfg-editores"
            class="self-start overflow-hidden rounded-xl border border-pk-line bg-pk-surface"
          >
            <header class="flex items-center gap-2.5 border-b border-pk-line px-3 py-2.5">
              <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-pk-raised text-pk-text-2">
                <.icon name="hero-wrench-screwdriver" class="size-4" />
              </span>
              <h2 class="text-pk-body font-bold text-pk-text">Editores</h2>
            </header>
            <ul class="divide-y divide-pk-line">
              <li :for={
                {href, icon, label, sub} <- [
                  {"/config/editores", "hero-squares-plus", "Presets, bolas e shiny",
                   "os formulários compostos, no painel"},
                  {"/time", "hero-users", "Time: skills e cooldowns", "o que cada tecla faz"},
                  {"/calibration", "hero-viewfinder-circle", "Calibração",
                   "regiões e pontos da tela"},
                  {"/cavebot", "hero-map", "Rotas da caçada", "waypoints e cantos"}
                ]
              }>
                <.link
                  navigate={href}
                  class="flex items-center gap-2.5 px-3 py-2.5 transition hover:bg-pk-raised"
                >
                  <.icon name={icon} class="size-4 shrink-0 text-pk-text-3" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-pk-body text-pk-text">{label}</span>
                    <span class="block truncate text-pk-meta text-pk-text-3">{sub}</span>
                  </span>
                  <.icon name="hero-chevron-right" class="size-4 shrink-0 text-pk-text-3" />
                </.link>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # O ? de cada linha: a explicação inteira, só quando perguntada.
  defp hint(assigns) do
    ~H"""
    <span
      title={@text}
      class="grid size-6 shrink-0 cursor-help place-items-center rounded-full text-pk-text-3 transition hover:bg-pk-raised hover:text-pk-text"
    >
      <.icon name="hero-question-mark-circle" class="size-4" />
    </span>
    """
  end

  defp saved_tick(assigns) do
    ~H"""
    <span :if={@saved == @key} class="shrink-0 text-pk-ok" aria-label="salvo">
      <.icon name="hero-check-circle" class="size-4" />
    </span>
    """
  end
end
