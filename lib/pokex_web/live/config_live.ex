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

  ## Três destinos, e nenhuma chave escondida (02/09)

  "Tudo muito grande, descrições não claras e desatualizadas." A auditoria
  contou 290 chaves no `Settings`, 74 com campo, 216 escondidas. Cada chave
  tem agora UM destino, e `known_keys/0` cobra em teste que nenhuma fique fora:

    * **linha** — o que depende dele, do pokémon ou da hunt: editável aqui;
    * **constante** (`Pokex.Settings.Locked`) — medido no jogo ou na máquina:
      aparece travada, com o porquê, sem campo;
    * **outra página** (`@elsewhere`) — já tem dono melhor (Editores,
      Calibração, Cavebot, /time, cabeçalho): daqui só se aponta, nunca se
      duplica.

  O que o modo de caça força sai do campo e vira uma linha "o modo decide".

  Salvar é imediato (phx-change com debounce): não há botão "aplicar", e o ✓
  verde na linha diz que o número em vigor é o que está na tela.
  """
  use PokexWeb, :live_view

  alias Pokex.Bots.AlarmCategories
  alias Pokex.Bots.Engine.Config
  alias Pokex.Bots.HuntMode
  alias Pokex.Settings
  alias Pokex.Settings.Locked

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
      id: "voce",
      icon: "hero-user",
      tint: :danger,
      title: "Você e o estoque",
      note: {"a barra vermelha se marca em", "Calibração → Vida do personagem", "/calibration"},
      rows: [
        %{
          key: :player_hp_floor_pct,
          kind: :pct,
          label: "Alarme da sua vida abaixo de",
          hint:
            "Duas leituras seguidas da SUA vida abaixo disto tocam o alarme. E o cérebro trata " <>
              "como emergência: com a barra gasta, revive na hora. 0 desliga o alarme; a leitura continua.",
          keywords: "vida personagem player você piso alarme"
        },
        %{
          key: :player_hp_logout,
          kind: :bool,
          label: "Sair do jogo se a sua vida cair",
          hint:
            "Sangrando abaixo do alarme acima, sai do jogo (Ctrl+Q, conferido na tela). É a única fuga que existe quando não há pokémon em pé.",
          keywords: "logout automático sair personagem auto"
        },
        %{
          key: :revive_stock,
          kind: :int,
          label: "Revives na bag",
          hint:
            "Quantos revives você tem AGORA. Digitar aqui é repor: a conta de gastos zera quando o número muda. 0 = não contei, orçamento desligado.",
          keywords: "revive stock estoque bolso orçamento repor"
        },
        %{
          key: :engine_revive_reserve,
          kind: :int,
          label: "Reserva de emergência",
          hint:
            "Com a conta neste número, o bot para de gastar revive por conveniência (zerar cooldown, chegar preparado). Emergência e pokémon caído gastam até o fim.",
          keywords: "reserva emergência orçamento"
        }
      ]
    },
    %{
      id: "revive",
      icon: "hero-heart",
      tint: :warn,
      title: "Revive do pokémon",
      rows: [
        %{
          key: :rescue_enabled,
          kind: :bool,
          label: "Revive automático",
          hint: "Recolhe e devolve o pokémon, zerando os cooldowns dele.",
          keywords: "revive resgate rescue automático"
        },
        %{
          key: :rescue_key,
          kind: :key,
          label: "Tecla do revive",
          hint: "A tecla que o jogo entende como revive (ex.: f4).",
          keywords: "revive tecla key f4"
        },
        %{
          key: :pokemon_hp_rescue_pct,
          kind: :pct,
          label: "Revive abaixo de",
          hint:
            "Vida do pokémon abaixo disto pede revive. Deixe bem abaixo da poção: a vida passa pelo número maior primeiro.",
          keywords: "revive vida limiar pct"
        },
        %{
          key: :rescue_cooldown_ms,
          kind: :sec,
          label: "Um revive a cada",
          hint: "O mínimo entre dois revives de um pokémon vivo.",
          keywords: "revive intervalo cooldown"
        },
        %{
          key: :pokemon_hp_fainted_below_pct,
          kind: :pct,
          label: "Caído abaixo de",
          hint:
            "Abaixo disto a barra lida conta como pokémon no chão, e o revive entra no lugar da cura. Acima, uma leitura ruim é só uma leitura ruim.",
          keywords: "caído fainted desmaiou chão vida limiar"
        },
        %{
          key: :revive_dry_action,
          kind: :select,
          label: "Bag sem revive: fazer o quê",
          hint:
            "Três revives pagos sem a vida voltar = a bag secou. logout sai do jogo; stop só para a caçada; alarm só toca.",
          keywords: "revive bag vazia estoque seca logout parar emergência"
        },
        %{
          key: :rescue_stun_first,
          kind: :bool,
          label: "Dormir a pilha antes do revive",
          hint:
            "Usa o controle do /time antes de reviver, pra não reviver exposto no meio do bolo. Só vale no Econômico: no Auto Combo a corrente já termina em stun.",
          keywords: "stun controle dormir antes revive econômico"
        },
        %{
          key: :engine_band_yellow_pct,
          kind: :pct,
          label: "Vida amarela abaixo de",
          hint: "Vida do pokémon abaixo disto: para de juntar bicho e gasta o que tem pronto.",
          keywords: "faixa amarela banda vida"
        },
        %{
          key: :engine_band_red_pct,
          kind: :pct,
          label: "Vida vermelha abaixo de",
          hint: "Abaixo disto é emergência: revive agora, no meio da luta.",
          keywords: "faixa vermelha banda vida emergência"
        },
        %{
          key: :engine_resume_pct,
          kind: :pct,
          label: "Rota volta acima de",
          hint: "Depois de um revive, a rota só anda com a vida do pokémon acima disto.",
          keywords: "voltar rota recuperar resume"
        },
        %{
          key: :engine_downed_give_up_ms,
          kind: :min,
          label: "Desistir do chão após",
          hint:
            "Pokémon caído e o revive sem devolver ninguém por isto: a caçada para de vez, porque o estoque acabou. 0 desliga.",
          keywords: "freio chão desistir caído give up"
        }
      ]
    },
    %{
      id: "cura",
      icon: "hero-beaker",
      tint: :ok,
      title: "Cura, defesa e poção",
      rows: [
        %{
          key: :shield_skill_enabled,
          kind: :bool,
          label: "Aura de defesa automática",
          hint:
            "Vida do pokémon abaixo do número de baixo: aperta a aura de defesa do /time, se a " <>
              "barra disser que está pronta. Não sai durante a corrente do combo nem enquanto o " <>
              "pokémon volta do revive.",
          keywords: "defesa escudo aura buff shield automática"
        },
        %{
          key: :pokemon_hp_shield_pct,
          kind: :pct,
          label: "Defesa abaixo de",
          hint:
            "Abaixo disto já tem gente batendo nele o suficiente pra valer o buff. Deixe acima da cura.",
          keywords: "defesa escudo vida limiar"
        },
        %{
          key: :heal_skill_enabled,
          kind: :bool,
          label: "Skill de cura",
          hint: "A tecla de cura do /time. É o único socorro que funciona apanhando.",
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
          hint: "A poção é um canal que o jogo cancela apanhando, então só sai fora de luta.",
          keywords: "poção potion automática"
        },
        %{
          key: :potion_key,
          kind: :key,
          label: "Tecla da poção",
          hint: "Onde a poção está no atalho (ex.: e).",
          keywords: "poção tecla key"
        },
        %{
          key: :pokemon_hp_potion_pct,
          kind: :pct,
          label: "Poção abaixo de",
          hint: "Vida do pokémon abaixo disto usa a poção, fora de luta.",
          keywords: "poção vida limiar"
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
            "Auto Combo: o jogo encadeia as skills atrás de UMA tecla; o bot aperta uma vez e cuida do revive. Econômico: Tab, alvo único e área só se precisar, pra rota barata.",
          keywords: "modo caça auto combo econômico estratégia combate"
        },
        %{
          key: :auto_combo_key,
          kind: :key,
          label: "Tecla do combo",
          hint:
            "A tecla que o JOGO usa pra encadear as skills ofensivas (ex.: r). Em branco, o Auto Combo não tem o que apertar.",
          keywords: "combo tecla r auto atalho"
        },
        %{
          key: :auto_combo_window_ms,
          kind: :ms,
          label: "O combo ocupa por",
          hint:
            "Quanto a corrente do jogo leva pra sair. Nada é apertado nesse tempo, e o revive espera ela acabar. Cronometrado em 3,5s; 4s é isso com folga.",
          keywords: "combo janela tempo ms corrente"
        }
      ]
    },
    %{
      id: "cerebro",
      icon: "hero-cpu-chip",
      tint: :info,
      title: "Cérebro: parar e abrir",
      rows: [
        %{
          key: :engine_engage_from,
          kind: :int,
          label: "Encara a partir de (bichos)",
          hint:
            "Menos que isto na tela e o bot segue andando em vez de parar. 1 é lutar com tudo.",
          keywords: "encarar engajar engage lutar a partir bichos mínimo"
        },
        %{
          key: :engine_gather_target,
          kind: :int,
          label: "O bolo está cheio com (bichos)",
          hint:
            "Parado, contando quem chega: com este tanto na tela abre o fogo sem esperar mais. " <>
              "No máximo 8: só 8 cabem ao redor do pokémon; o resto fica longe e bate em você.",
          keywords: "juntar mobar gather alvo pilha bolo cheio"
        },
        %{
          key: :engine_patience_tiles,
          kind: :int,
          label: "Paciência (passos)",
          hint:
            "Com bicho na tela mas o bolo sem encher, depois deste tanto de passos mata o que tem.",
          keywords: "paciência passos não veio mais ninguém"
        },
        %{
          key: :engine_bunch_ms,
          kind: :sec,
          label: "Esperar chegarem em cima",
          hint: "Parado, quanto esperar os bichos colarem antes de estourar a área.",
          keywords: "esperar espera bunch colar fechar"
        },
        %{
          key: :engine_reset_revive,
          kind: :bool,
          label: "Revive pra zerar os cooldowns",
          hint:
            "Com todas as skills de dano gastas e bicho na tela, usa um revive pra ter a barra cheia de novo. É o ciclo do Auto Combo: combo, revive, combo.",
          keywords: "reset revive barra cooldown zerar"
        },
        %{
          key: :engine_prepare_revive,
          kind: :bool,
          label: "Chegar inteiro no próximo grupo",
          hint:
            "Entre um grupo e outro, se metade da barra está em cooldown, gasta um revive antes de encontrar a próxima pilha.",
          keywords: "preparado prepare revive entre grupos"
        },
        %{
          key: :crowd_watch_enabled,
          kind: :bool,
          label: "Olhar a pilha enquanto espera (só mede)",
          hint:
            "Esperando o bolo, fotografa ao redor do pokémon a cada meio segundo e escreve no feed " <>
              "quantos estão a 1 tile. Ainda não decide nada por isso. Desligue se a batalha atrasar.",
          keywords: "olho perto pilha foto medir crowd alcance tile"
        }
      ]
    },
    %{
      id: "chefe",
      icon: "hero-shield-exclamation",
      tint: :danger,
      title: "Chefe",
      rows: [
        %{
          key: :engine_boss_grit,
          kind: :int,
          label: "Chefe pelo tempo de matar",
          hint:
            "Quantas skills de dano o bicho engole sem nenhum corpo cair antes de o bot declarar chefe e rodar skills, stun e revive em ciclo. Uma pilha comum não passa de 4. 0 desliga.",
          keywords: "chefe boss tempo grit stun revive dano"
        },
        %{
          key: :engine_boss_names,
          kind: :key,
          label: "Nomes dos chefes",
          hint:
            "Separados por vírgula. Com um destes nomes na janela de batalha o bot entra na postura de chefe na hora. Vazio desliga.",
          keywords: "chefe boss nome postura"
        },
        %{
          key: :engine_stun_hold_ms,
          kind: :sec,
          label: "Quanto o seu stun segura",
          hint:
            "Do aperto até o sono acabar. O ciclo de chefe emenda o próximo stun antes de este acabar.",
          keywords: "stun sono duração segura chefe"
        }
      ]
    },
    %{
      id: "teclas",
      icon: "hero-bolt",
      tint: :warn,
      title: "Teclas e rajada",
      rows: [
        %{
          key: :attack_mode_key,
          kind: :key,
          label: "Postura de ataque",
          hint: "A tecla da postura ofensiva. Vai na frente de toda rajada.",
          keywords: "postura ataque shift modo"
        },
        %{
          key: :defense_mode_key,
          kind: :key,
          label: "Postura de defesa",
          hint: "A tecla da postura defensiva, usada quando o fogo segura.",
          keywords: "postura defesa shift modo"
        },
        %{
          key: :combat_skill_burst_size,
          kind: :int,
          label: "Teclas por rajada",
          hint: "Quantas teclas saem numa rajada de ataque.",
          keywords: "rajada burst teclas"
        },
        %{
          key: :combat_skill_gap_ms,
          kind: :int,
          unit: "ms",
          label: "Intervalo entre teclas",
          hint:
            "O intervalo entre duas teclas da mesma rajada. É o teto de dano da caçada: 500ms com rajada de 2 é 1s por rajada.",
          keywords: "intervalo gap rajada ms dano"
        },
        %{
          key: :combat_single_target,
          kind: :bool,
          label: "Usar as skills de alvo único",
          hint: "Só vale no Econômico. O Auto Combo ignora: a corrente do jogo decide o que sai.",
          keywords: "alvo único single target rotação econômico"
        },
        %{
          key: :fight_timeout_ms,
          kind: :sec,
          label: "Luta parada vira tropeço em",
          hint:
            "Tela idêntica em luta por isto conta como tropeço. Esperar cooldown com a barra gasta não conta.",
          keywords: "luta timeout tropeço parada"
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
          key: :escape_walk_wait_ms,
          kind: :sec,
          label: "Fuga: esperar depois de andar",
          hint: "Quanto esperar parado depois dos passos da fuga, antes de conferir a tela.",
          keywords: "fuga espera andar escape"
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
          hint: "alarm só toca; stop para os bots; logout sai do jogo.",
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
          hint: "Segura a fisga até uma skill de matar estar pronta. Do personagem ativo.",
          keywords: "pesca fisga cooldown"
        },
        %{
          key: :require_pokemon_hp,
          kind: :bool,
          label: "Só fisgar com vida",
          hint: "Segura a fisga com o pokémon fraco ou na bola. Do personagem ativo.",
          keywords: "pesca fisga vida"
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
      title: "Captura",
      note:
        {"bolas, regras por espécie, varredura e estoque ficam nos", "Editores",
         "/config/editores"},
      rows: [
        %{
          key: :capture_enabled,
          kind: :bool,
          label: "Jogar bola nos corpos",
          hint:
            "O interruptor da captura. Qual bola, em quem e quantas vezes se ajusta nos Editores.",
          keywords: "captura bola corpos catcher"
        }
      ]
    },
    %{
      id: "alarmes",
      icon: "hero-bell-alert",
      tint: :warn,
      title: "Alarmes",
      note: {"o som liga e desliga no", "sino do cabeçalho", "/"},
      rows: [
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

  # O QUE MORA EM OUTRA PÁGINA. Cada chave do `Settings` que não é linha aqui
  # nem constante tem um dono melhor — e a lista existe pra um teste cobrar que
  # nenhuma chave fique escondida de novo.
  @elsewhere [
    %{
      href: "/config/editores",
      icon: "hero-squares-plus",
      label: "Editores",
      sub: "bolas, regras por espécie, varredura, estoque, reposição",
      keys: [
        :ball_key,
        :ball_needs_click,
        :ball_types,
        :ball_rules,
        :corpse_max_balls,
        :corpse_scan_radius_tiles,
        :corpse_match_min_similarity,
        :dry_balls_alarm,
        :sweep_enabled,
        :sweep_interval_ms,
        :sweep_radius_tiles,
        :sweep_side,
        :stock_alert_f1,
        :stock_alert_f2,
        :stock_alert_e,
        :stock_alert_s_q,
        :reposition_enabled,
        :support_waits_capture
      ]
    },
    %{
      href: "/time",
      icon: "hero-users",
      label: "Time",
      sub: "as skills do pokémon e os cooldowns",
      keys: [:skill_keys]
    },
    %{
      href: "/calibration",
      icon: "hero-viewfinder-circle",
      label: "Calibração",
      sub: "barra de skills, janela de batalha, minimapa",
      keys: [:skill_bar_count, :battle_row_height, :minimap_coord_ink]
    },
    %{
      href: "/cavebot",
      icon: "hero-map",
      label: "Cavebot",
      sub: "rotas, respiro das paradas, tropeço, estacionar",
      keys: [
        :cavebot_gather_wait_ms,
        :cavebot_block_retries,
        :cavebot_block_retry_ms,
        :cavebot_park_tiles_x,
        :cavebot_park_tiles_y,
        :tile_px,
        :area_probe_enabled,
        :skill_meter_enabled
      ]
    },
    %{
      href: "/",
      icon: "hero-home",
      label: "Painel e cabeçalho",
      sub: "personagem, modo de jogo, sino, shiny, pesca",
      keys: [
        :active_character,
        :player_mode,
        :alarm_sound,
        :alarm_muted_categories,
        :shiny_guard_enabled,
        :mini_game_sound,
        :cavebot_measure_walk,
        :hook_skill_keys,
        :glow_threshold,
        :after_kill_hold_ms
      ]
    },
    %{
      href: "/mini-game",
      icon: "hero-play",
      label: "Mini-game",
      sub: "o que o bot faz quando o minigame da pesca abre",
      keys: [:mini_game_mode]
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

  # A busca também acha as constantes: chave, grupo e porquê.
  @const_haystacks Map.new(Locked.all(), fn {key, {group, why}} ->
                     {key, String.downcase("#{key} #{group} #{why}")}
                   end)

  @doc "Toda chave que esta página conhece: linha, constante ou de outra página."
  def known_keys do
    Enum.map(Enum.flat_map(@groups, & &1.rows), & &1.key) ++
      Locked.keys() ++ Enum.flat_map(@elsewhere, & &1.keys)
  end

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
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-pk-body text-pk-text">{row.label}</span>
                    <.mode_line key={row.key} />
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
                  <label for={"cfg-input-#{row.key}"} class="min-w-0 flex-1">
                    <span class="block truncate text-pk-body text-pk-text">{row.label}</span>
                    <.mode_line key={row.key} />
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

            <%!-- O QUE O MODO DECIDE: sem campo, com o valor em cada modo. --%>
            <div
              :if={group.id == "modo" and mode_decided(@query) != []}
              class="border-t border-pk-line px-3 py-2.5"
            >
              <p class="mb-1.5 font-mono text-pk-meta uppercase tracking-[0.12em] text-pk-text-3">
                o modo decide
              </p>
              <ul class="space-y-1.5">
                <li :for={{key, why} <- mode_decided(@query)} id={"cfg-mode-#{key}"}>
                  <span class="block truncate text-pk-body text-pk-text">{why}</span>
                  <span class="block font-mono text-pk-meta text-pk-text-3">
                    {mode_values(key)}
                  </span>
                </li>
              </ul>
            </div>

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

          <%!-- O QUE MORA EM OUTRA PÁGINA: um ponteiro por dono, nunca uma cópia. --%>
          <section
            :if={elsewhere(@query) != []}
            id="cfg-editores"
            class="self-start overflow-hidden rounded-xl border border-pk-line bg-pk-surface"
          >
            <header class="flex items-center gap-2.5 border-b border-pk-line px-3 py-2.5">
              <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-pk-raised text-pk-text-2">
                <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              </span>
              <h2 class="text-pk-body font-bold text-pk-text">Em outra página</h2>
            </header>
            <ul class="divide-y divide-pk-line">
              <li :for={place <- elsewhere(@query)}>
                <.link
                  navigate={place.href}
                  class="flex items-center gap-2.5 px-3 py-2.5 transition hover:bg-pk-raised"
                >
                  <.icon name={place.icon} class="size-4 shrink-0 text-pk-text-3" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-pk-body text-pk-text">{place.label}</span>
                    <span class="block truncate text-pk-meta text-pk-text-3">{place.sub}</span>
                  </span>
                  <.icon name="hero-chevron-right" class="size-4 shrink-0 text-pk-text-3" />
                </.link>
              </li>
            </ul>
          </section>

          <%!-- AS CONSTANTES: existem, aparecem, não se editam. Fechadas por
                padrão; a busca abre o grupo que casou. --%>
          <section
            :if={constants(@query) != []}
            id="cfg-constantes"
            class="self-start overflow-hidden rounded-xl border border-pk-line bg-pk-surface md:col-span-2 xl:col-span-3"
          >
            <header class="flex items-center gap-2.5 border-b border-pk-line px-3 py-2.5">
              <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-pk-raised text-pk-text-2">
                <.icon name="hero-lock-closed" class="size-4" />
              </span>
              <span class="min-w-0 flex-1">
                <h2 class="text-pk-body font-bold text-pk-text">Constantes</h2>
                <p class="truncate text-pk-meta text-pk-text-3">
                  medidas no jogo ou na máquina; vivem no código e não têm campo
                </p>
              </span>
            </header>
            <div class="grid gap-x-4 md:grid-cols-2 xl:grid-cols-3">
              <details
                :for={{group, rows} <- constants(@query)}
                open={@query != ""}
                class="border-b border-pk-line px-3 py-2"
              >
                <summary class="flex cursor-pointer items-center gap-2 text-pk-body text-pk-text">
                  <span class="min-w-0 flex-1 truncate">{group}</span>
                  <span class="font-mono text-pk-meta text-pk-text-3">{length(rows)}</span>
                </summary>
                <ul class="mt-1.5 space-y-1.5">
                  <li :for={{key, why} <- rows} id={"cfg-const-#{key}"} class="min-w-0">
                    <span class="flex items-baseline gap-2">
                      <code class="min-w-0 flex-1 truncate font-mono text-pk-meta text-pk-text-2">
                        {key}
                      </code>
                      <span class="shrink-0 font-mono text-pk-meta font-semibold tabular-nums text-pk-text">
                        {const_shown(key)}
                      </span>
                    </span>
                    <span class="block text-pk-meta text-pk-text-3">{why}</span>
                  </li>
                </ul>
              </details>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # O MODO SOBREPÕE EM MEMÓRIA e a página mostra o global — então a linha diz,
  # embaixo do rótulo, o que vale no modo que a força. Lido de
  # `HuntMode.engine_overrides/1`, a mesma lista que o cérebro obedece.
  attr :key, :atom, required: true

  defp mode_line(assigns) do
    assigns = assign(assigns, :forced, forced_by_modes(assigns.key))

    ~H"""
    <span :if={@forced != []} class="block truncate font-mono text-pk-meta text-pk-text-3">
      {Enum.map_join(@forced, " · ", fn {modo, valor} -> "no #{modo}: #{valor}" end)}
    </span>
    """
  end

  defp forced_by_modes(key) do
    case knob_of(key) do
      nil ->
        []

      knob ->
        for mode <- HuntMode.all(),
            {:ok, value} <- [Map.fetch(HuntMode.engine_overrides(mode), knob)],
            do: {HuntMode.label(mode), forced_text(value)}
    end
  end

  # As travadas do grupo "O modo decide", com o valor em CADA modo: o que o
  # modo força, ou, quando não força, o número do código.
  defp mode_decided(query) do
    Locked.groups()
    |> Enum.filter(fn {group, _rows} -> group == "O modo decide" end)
    |> Enum.flat_map(fn {_group, rows} -> rows end)
    |> Enum.filter(fn {key, _why} -> matches?(@const_haystacks, key, query) end)
  end

  defp mode_values(key) do
    knob = knob_of(key)

    Enum.map_join(HuntMode.all(), " · ", fn mode ->
      value = Map.get(HuntMode.engine_overrides(mode), knob, Settings.get(key))
      "#{HuntMode.label(mode)}: #{forced_text(value)}"
    end)
  end

  defp knob_of(key) do
    case Enum.find(Config.knobs(), fn {_knob, setting} -> setting == key end) do
      {knob, _setting} -> knob
      nil -> nil
    end
  end

  defp forced_text(true), do: "ligado"
  defp forced_text(false), do: "desligado"
  defp forced_text(value), do: to_string(value)

  # --- as constantes -----------------------------------------------------------

  defp constants(query) do
    Locked.groups()
    |> Enum.reject(fn {group, _rows} -> group == "O modo decide" end)
    |> Enum.map(fn {group, rows} ->
      {group, Enum.filter(rows, fn {key, _why} -> matches?(@const_haystacks, key, query) end)}
    end)
    |> Enum.reject(fn {_group, rows} -> rows == [] end)
  end

  defp const_shown(key) do
    case Settings.get(key) do
      true -> "ligado"
      false -> "desligado"
      value when is_list(value) -> Enum.join(value, ", ")
      value -> "#{value}#{const_unit(key)}"
    end
  end

  defp const_unit(key) do
    name = Atom.to_string(key)

    cond do
      String.ends_with?(name, "_ms") -> " ms"
      String.ends_with?(name, "_pct") -> "%"
      String.ends_with?(name, "_px") -> " px"
      String.ends_with?(name, "_tiles") -> " tiles"
      String.ends_with?(name, "_mb") -> " MB"
      true -> ""
    end
  end

  defp elsewhere(""), do: @elsewhere

  defp elsewhere(query) do
    Enum.filter(@elsewhere, fn place ->
      haystack = String.downcase("#{place.label} #{place.sub} #{Enum.join(place.keys, " ")}")
      String.contains?(haystack, query)
    end)
  end

  defp matches?(_haystacks, _key, ""), do: true
  defp matches?(haystacks, key, query), do: String.contains?(Map.fetch!(haystacks, key), query)

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
