defmodule Pokex.Settings.Locked do
  @moduledoc """
  AS CONSTANTES: os ajustes que existem, aparecem no /config e NÃO se editam.

  "Se for algo que não faz sentido ser configurável dá pra usar constante no
  código e mostrar a constante ali só pra eu saber que existe, mas sem deixar
  configurar pra não bagunçar" (Lucas, 02/09).

  Uma chave travada continua sendo uma chave do `Settings` — todo mundo que a
  lê com `Settings.get/1` segue lendo — mas o ARQUIVO não manda nela: o
  `settings.json` não a carrega no boot nem a grava, e a página não tem campo.
  Um `put/2` em memória ainda funciona (testes, diagnósticos) e morre com o
  processo, que é o que "constante" quer dizer aqui: o número é o do código.

  O que trava, e o porquê de cada uma, mora aqui — a mesma lista que a página
  mostra, nunca uma cópia. Os grupos são os subsistemas que leem o número.
  """

  @locked %{
    # --- Barra de skills (visão) ---
    skill_ready_min_saturation:
      {"Barra de skills (visão)", "slot pronto = cor: saturação média acima disto"},
    skill_cooldown_min_white_pct:
      {"Barra de skills (visão)",
       "número branco do cooldown vence a cor: % de pixels brancos puros"},
    skill_ref_max_distance:
      {"Barra de skills (visão)", "distância de cor máxima até a referência 'pronta' calibrada"},
    skill_ready_min_vivid_pct:
      {"Barra de skills (visão)", "% de pixels bem coloridos que também vale como pronto"},
    skill_bar_fact_max_age_ms:
      {"Barra de skills (visão)",
       "leitura da barra mais velha que isto é desconhecida (rotação cega)"},
    # --- Cadência das leituras ---
    feed_battle_ms:
      {"Cadência das leituras", "a janela de batalha é lida a cada 120ms (a mais rápida)"},
    feed_skill_bar_ms:
      {"Cadência das leituras", "a barra muda a cada ~1s; ler mais rápido só gasta captura"},
    feed_failure_warn_streak:
      {"Cadência das leituras", "capturas falhadas seguidas antes de gritar no log"},
    feed_hud_ms: {"Cadência das leituras", "estoque e level mudam devagar: 1 leitura/s"},
    feed_team_ms: {"Cadência das leituras", "painel do time a cada 1,2s"},
    feed_minimap_ms:
      {"Cadência das leituras", "posição a cada 0,5s ainda guia a rota a 5 passos/s"},
    # --- Captura (visão) ---
    corpse_sprite_box_px: {"Captura (visão)", "lado do quadrado do corpo; derivado do tile"},
    capture_aim_settle_ms: {"Captura (visão)", "pausa entre mirar o cursor e apertar a bola"},
    capture_hold_ms: {"Captura (visão)", "quanto o cursor fica no alvo depois do arremesso"},
    corpse_scan_step_px:
      {"Captura (visão)", "passo grosso da varredura de corpos; derivado do tile"},
    corpse_scan_refine_px: {"Captura (visão)", "passo fino ao redor dos picos"},
    corpse_scan_refine_peaks: {"Captura (visão)", "quantos picos a varredura refina"},
    pokeball_min_red_px:
      {"Captura (visão)", "pixels vermelhos que marcam a bola do PRÓPRIO pokémon na lista"},
    feed_corpses_ms: {"Captura (visão)", "o chão é lido a cada 400ms no modo Parado"},
    corpse_warmup_frames: {"Captura (visão)", "quadros pra aprender o chão vazio"},
    corpse_cell_px: {"Captura (visão)", "célula da grade que detecta mudança no chão"},
    corpse_noise_threshold:
      {"Captura (visão)", "delta por canal pra um pixel contar como mudado (aprendendo)"},
    corpse_diff_threshold:
      {"Captura (visão)", "delta por canal pra um pixel contar como mudado (varrendo)"},
    corpse_cell_min_samples: {"Captura (visão)", "amostras mudadas pra uma célula esquentar"},
    corpse_min_cells: {"Captura (visão)", "células quentes vizinhas que formam um corpo (~2-3)"},
    corpse_stationary_frames: {"Captura (visão)", "quadros parado antes de valer como corpo"},
    corpse_stationary_tolerance_px:
      {"Captura (visão)", "quanto pode tremer e ainda ser o mesmo corpo"},
    corpse_match_tolerance_px: {"Captura (visão)", "distância pra casar um corpo com o acervo"},
    corpse_ignore_ttl_ms: {"Captura (visão)", "corpo desistido é ignorado por 45s"},
    corpse_confirm_after_ms: {"Captura (visão)", "espera antes de confirmar que a bola capturou"},
    # --- Cavebot (andar) ---
    cavebot_arrival_tolerance_tiles:
      {"Cavebot (andar)", "a 1 tile do waypoint conta como chegou"},
    cavebot_walk_timeout_ms: {"Cavebot (andar)", "3s sem chegar = tropeço"},
    cavebot_blind_kick_ms:
      {"Cavebot (andar)", "parado e cego, dá um passo pra tela desenhar a coordenada"},
    cavebot_minimap_fact_max_age_ms: {"Cavebot (andar)", "posição mais velha que 0,8s é cega"},
    cavebot_stuck_max_retries:
      {"Cavebot (andar)", "tentativas de desencalhar antes de pular o waypoint"},
    cavebot_post_kill_dwell_ms: {"Cavebot (andar)", "respiro depois de uma morte antes de andar"},
    cavebot_capture_wait_ms: {"Cavebot (andar)", "quanto a rota espera a captura pegar o corpo"},
    cavebot_pinned_probe_ms:
      {"Cavebot (andar)", "preso na mesma tile, 1s de andar responde se saiu"},
    cavebot_stop_wait_ms:
      {"Cavebot (andar)", "a parada 'esperar': 5s parado pros cooldowns voltarem"},
    cavebot_gather_wait_min_ms: {"Cavebot (andar)", "piso do respiro aprendido na gravação"},
    cavebot_gather_wait_max_ms: {"Cavebot (andar)", "teto do respiro aprendido na gravação"},
    cavebot_clear_debounce_ms: {"Cavebot (andar)", "tela limpa por 0,8s antes de a rota voltar"},
    cavebot_record_min_tiles: {"Cavebot (andar)", "gravando, um waypoint a cada 4 tiles andados"},
    cavebot_precise_tiles: {"Cavebot (andar)", "os últimos 2 tiles são tocados, não segurados"},
    cavebot_fight_only_at_stops:
      {"Cavebot (andar)", "só luta nas paradas, nunca no meio da escada"},
    cavebot_stair_probe_ms:
      {"Cavebot (andar)", "cada sonda da escada espera isto pela troca de andar"},
    cavebot_stair_max_probes: {"Cavebot (andar)", "32 sondas = duas voltas ao redor do canto"},
    cavebot_stair_step_ms: {"Cavebot (andar)", "um toque de escada anda dois tiles em 0,7s"},
    cavebot_stair_step_taps: {"Cavebot (andar)", "toques na escada antes da busca em anel"},
    cavebot_park_clicks: {"Cavebot (andar)", "cliques do estacionar"},
    cavebot_park_gap_ms: {"Cavebot (andar)", "intervalo entre os cliques do estacionar"},
    cavebot_record_dwell_ms: {"Cavebot (andar)", "parado 5s na gravação = parada 'esperar'"},
    cavebot_record_fight_dwell_ms: {"Cavebot (andar)", "parado 12s na gravação = ponto de luta"},
    cavebot_smart_recording: {"Cavebot (andar)", "a gravação lê o relógio pra adivinhar paradas"},
    cavebot_fight_timeout_ms: {"Cavebot (andar)", "20s de luta sem fim = a rota retoma"},
    # --- Combate (Tab) ---
    tab_key: {"Combate (Tab)", "a tecla do jogo que troca de alvo"},
    tab_confirm_ms: {"Combate (Tab)", "quanto esperar o alvo travar depois do Tab"},
    tab_confirm_frames:
      {"Combate (Tab)", "quadros sem trava vistos antes de apertar Tab de novo"},
    tab_max_attempts: {"Combate (Tab)", "Tabs por caçada antes de desistir da linha"},
    scenery_hunts_needed: {"Combate (Tab)", "caçadas sem trava que marcam a linha como cenário"},
    scenery_ttl_ms: {"Combate (Tab)", "linha cenário é tentada de novo depois de 5min"},
    # --- Combate (ritmo) ---
    skill_burst_every_ms: {"Combate (ritmo)", "respiro entre duas decisões de ataque"},
    combat_aoe_from_enemies: {"Combate (ritmo)", "só o plano padrão lê; nenhum modo vivo usa"},
    combat_skill_tap_count: {"Combate (ritmo)", "toques por tecla numa rajada"},
    combat_skill_jitter_ms:
      {"Combate (ritmo)", "tremor aleatório entre teclas; assume o SEU 100"},
    max_consecutive_failures: {"Combate (ritmo)", "falhas seguidas antes de o worker parar"},
    target_lost_streak:
      {"Combate (ritmo)", "leituras sem o alvo antes de dar a luta por fim; assume o SEU 1"},
    hunt_cooldown_ms: {"Combate (ritmo)", "respiro entre duas caçadas de alvo"},
    no_damage_ms:
      {"Combate (ritmo)", "8s batendo sem a vida do alvo cair = empate, troca de alvo"},
    hunt_probe_window_ms:
      {"Combate (ritmo)", "depois de matar, 8s de Tabs cegos procurando o próximo"},
    combat_world_max_age_ms:
      {"Combate (ritmo)", "leitura de batalha mais velha que 2,5s = nenhuma tecla"},
    combat_confirm_skills: {"Combate (ritmo)", "a rajada confere na barra que a tecla saiu"},
    combat_confirm_ms: {"Combate (ritmo)", "quanto esperar a barra confirmar a tecla"},
    posture_max_age_ms: {"Combate (ritmo)", "postura lembrada por 3s"},
    # --- Cérebro (prazos internos) ---
    engine_pile_settle_ms:
      {"Cérebro (prazos internos)", "contagem parada por 1,5s = pararam de chegar"},
    engine_size_ceiling_ms:
      {"Cérebro (prazos internos)", "teto da espera parado: 8s, aí abre se vale"},
    engine_reset_revive_cooldown_ms:
      {"Cérebro (prazos internos)", "piso entre dois revives de reset"},
    engine_reset_revive_min_hp:
      {"Cérebro (prazos internos)", "abaixo desta vida não gasta revive só pra zerar"},
    engine_recover_timeout_ms:
      {"Cérebro (prazos internos)", "revive que não pega: pede de novo a cada 30s"},
    engine_prepare_max_enemies:
      {"Cérebro (prazos internos)", "restos na tela que ainda contam como 'entre grupos'"},
    engine_closing_timeout_ms:
      {"Cérebro (prazos internos)", "fechar a rodada espera no máximo 8s"},
    engine_revive_confirm_ms: {"Cérebro (prazos internos)", "3s pro revive provar que pegou"},
    engine_kite_max_ms: {"Cérebro (prazos internos)", "uma retirada dura no máximo 20s"},
    engine_spent_keys_left:
      {"Cérebro (prazos internos)", "barra 'vazia' = zero teclas de dano prontas"},
    engine_crowd_from: {"Cérebro (prazos internos)", "o controle sai a partir de 1 bicho"},
    engine_stun_window_ms:
      {"Cérebro (prazos internos)", "a regra dos 5s: revive dentro da janela do stun"},
    engine_stun_reach_tiles: {"Cérebro (prazos internos)", "raio útil do controle: 3 tiles"},
    engine_reset_rearm_ms:
      {"Cérebro (prazos internos)", "reset desarmado volta a tentar em 10min"},
    engine_vitals_ms:
      {"Cérebro (prazos internos)", "leitura de vitais a cada 1s quando nada muda"},
    engine_hunt_max_age_ms:
      {"Cérebro (prazos internos)", "fato da caçada mais velho que 2s = sem caçada"},
    engine_orders_max_age_ms:
      {"Cérebro (prazos internos)", "ordens mais velhas que 1,5s = cada worker por si"},
    # --- Estoque ---
    stock_alerts_enabled:
      {"Estoque", "os alarmes de estoque existem; os limiares estão nos Editores"},
    # --- Foco e teclado ---
    key_modifier_settle_ms: {"Foco e teclado", "shift segurado 30ms antes da tecla (Wine)"},
    ensure_game_focus: {"Foco e teclado", "tecla só sai com o jogo na frente"},
    game_app_name: {"Foco e teclado", "o jogo roda sob Wine"},
    pause_when_unfocused: {"Foco e teclado", "tudo pausa com o jogo atrás"},
    focus_poll_ms: {"Foco e teclado", "quem está na frente é conferido a cada 250ms"},
    calibration_front_delay_ms:
      {"Foco e teclado", "a calibração espera 0,7s o jogo desenhar depois de trazê-lo"},
    restore_mouse_after_actions:
      {"Foco e teclado", "o cursor volta pra onde estava depois de cada ação"},
    hold_max_ms: {"Foco e teclado", "tecla segurada solta sozinha em 1,5s"},
    # --- Janela de batalha (visão) ---
    battle_first_row_y: {"Janela de batalha (visão)", "centro da linha 0 dentro da região"},
    battle_max_rows: {"Janela de batalha (visão)", "até 10 linhas lidas"},
    target_locked_min_pixels: {"Janela de batalha (visão)", "pixels vermelhos do anel de alvo"},
    # --- Logout (mecânica) ---
    logout_key: {"Logout (mecânica)", "Ctrl+Q é do jogo"},
    logout_confirm_key: {"Logout (mecânica)", "Enter confirma"},
    logout_confirm_delay_ms: {"Logout (mecânica)", "pausa antes do Enter"},
    logout_verify_delay_ms: {"Logout (mecânica)", "1,5s pra tela trocar antes de conferir"},
    logout_attempts: {"Logout (mecânica)", "tenta 3 vezes"},
    # --- Mini-game da pesca ---
    mini_game_manual_alert_ms:
      {"Mini-game da pesca", "o aviso 'resolve o minigame' repete a cada 5s"},
    mini_game_diag_samples_max: {"Mini-game da pesca", "amostras de diagnóstico por jogo"},
    mini_game_diag_frames_max: {"Mini-game da pesca", "quadros guardados por jogo"},
    mini_game_preview_ms: {"Mini-game da pesca", "a prévia da página atualiza a cada 0,5s"},
    mini_game_export_keep: {"Mini-game da pesca", "guarda até 20 exportações"},
    mini_game_export_max_mb: {"Mini-game da pesca", "e até 200MB delas"},
    mini_game_tick_ms: {"Mini-game da pesca", "o detector olha a cada 150ms"},
    mini_game_enter_streak:
      {"Mini-game da pesca", "2 quadros seguidos com o overlay antes de entrar"},
    mini_game_exit_streak: {"Mini-game da pesca", "2 quadros sem ele antes de sair"},
    mini_game_min_confidence: {"Mini-game da pesca", "confiança mínima da detecção"},
    mini_game_min_dark_ratio:
      {"Mini-game da pesca", "proporção de escuro que caracteriza a faixa"},
    mini_game_bar_offset_px: {"Mini-game da pesca", "deslocamento da faixa derivada"},
    mini_game_bar_width_px: {"Mini-game da pesca", "largura da faixa"},
    mini_game_above_px: {"Mini-game da pesca", "quanto acima do personagem"},
    mini_game_strip_height_px: {"Mini-game da pesca", "altura da faixa"},
    mini_game_anchor_tolerance:
      {"Mini-game da pesca", "meia-largura da janela onde a barra pode estar"},
    mini_game_play_tick_ms: {"Mini-game da pesca", "jogando, decide a cada 80ms"},
    mini_game_min_toggle_ms: {"Mini-game da pesca", "piso entre segurar e soltar o espaço"},
    mini_game_no_capsule_exit_ticks:
      {"Mini-game da pesca", "25 tiques sem cápsula = jogo acabou"},
    mini_game_max_game_ms: {"Mini-game da pesca", "jogo de 90s é leitura presa, não jogo"},
    mini_game_deadband_pct: {"Mini-game da pesca", "zona morta ao redor do peixe"},
    mini_game_fish_max_speed: {"Mini-game da pesca", "velocidade máxima plausível do peixe"},
    mini_game_fish_reacquire_ms:
      {"Mini-game da pesca", "leitura mais velha que 0,7s é abandonada"},
    mini_game_brake_up: {"Mini-game da pesca", "freio subindo"},
    mini_game_brake_down: {"Mini-game da pesca", "freio descendo (o jogo é assimétrico)"},
    mini_game_fact_max_age_ms:
      {"Mini-game da pesca", "fato do minigame mais velho que 2s = não está jogando"},
    # --- Minimapa (visão) ---
    minimap_px_per_tile: {"Minimapa (visão)", "medido: 2px por tile"},
    # --- O modo decide ---
    engine_gather_piles: {"O modo decide", "juntar bicho andando: nenhum modo faz"},
    engine_kite_when_spent: {"O modo decide", "recuar com a barra vazia"},
    # --- Onde estão os monstros (visão) ---
    crowd_scan_radius_tiles: {"Onde estão os monstros (visão)", "a foto ao redor cobre 6 tiles"},
    crowd_scan_evidence_shrink:
      {"Onde estão os monstros (visão)", "a evidência é desenhada 4× menor"},
    # --- Painel (canto de comando) ---
    command_corner:
      {"Painel (canto de comando)", "mouse no canto superior direito alterna o modo"},
    command_corner_dwell_ms: {"Painel (canto de comando)", "segurando 0,6s"},
    # --- Pesca (ritmo) ---
    pokemon_fact_max_age_ms:
      {"Pesca (ritmo)", "fato do pokémon mais velho que 3s é desconhecido"},
    hook_hold_max_ms: {"Pesca (ritmo)", "uma fisgada segurada no máximo 3min"},
    tick_ms_watching: {"Pesca (ritmo)", "vigiando a água, uma captura a cada 150ms"},
    tick_ms_default: {"Pesca (ritmo)", "fora da vigia, 80ms"},
    wait_focus_ms: {"Pesca (ritmo)", "pausa depois de focar"},
    wait_after_equip_ms: {"Pesca (ritmo)", "pausa depois de equipar"},
    wait_cast_settle_ms: {"Pesca (ritmo)", "0,8s pro respingo assentar antes de vigiar"},
    wait_assess_ms: {"Pesca (ritmo)", "0,7s entre puxar e o próximo arremesso"},
    watch_timeout_ms: {"Pesca (ritmo)", "30s vigiando sem mordida = arremessa de novo"},
    dry_casts_alarm: {"Pesca (ritmo)", "3 arremessos sem bolha = alarme"},
    watch_dead_streak_needed: {"Pesca (ritmo)", "5 quadros de água vazia = o arremesso falhou"},
    cast_grace_ms: {"Pesca (ritmo)", "a conta só começa 5s depois do arremesso"},
    calm_streak_needed: {"Pesca (ritmo)", "3 quadros calmos antes de um pico valer como mordida"},
    settle_max_ms: {"Pesca (ritmo)", "2,5s depois do arremesso a água assentou por física"},
    humanize_max_ms: {"Pesca (ritmo)", "tremor humano: desligado"},
    cast_delay_max_ms: {"Pesca (ritmo)", "até 250ms aleatórios antes de cada arremesso"},
    hook_delay_min_ms: {"Pesca (ritmo)", "mínimo aleatório antes de puxar"},
    hook_delay_max_ms: {"Pesca (ritmo)", "máximo aleatório antes de puxar"},
    # --- Pesca (visão) ---
    glow_search_margin: {"Pesca (visão)", "margem da busca pelo brilho"},
    fishing_lure_min_pixels: {"Pesca (visão)", "pixels da isca pra achá-la"},
    fishing_bubble_radius_px: {"Pesca (visão)", "raio ao redor da isca onde as bolhas contam"},
    line_present_min_px: {"Pesca (visão)", "pixels que provam a linha na água"},
    wild_min_red_pixels: {"Pesca (visão)", "pixels vermelhos que denunciam um selvagem"},
    glow_streak_needed: {"Pesca (visão)", "um quadro de brilho basta pra fisgar"},
    # --- Rastreio do pokémon (visão) ---
    pokemon_sprite_box_px: {"Rastreio do pokémon (visão)", "quadrado ensinado do pokémon"},
    pokemon_track_step_px: {"Rastreio do pokémon (visão)", "passo da busca"},
    pokemon_track_radius_px: {"Rastreio do pokémon (visão)", "raio ao redor do ponto esperado"},
    pokemon_track_min_similarity:
      {"Rastreio do pokémon (visão)", "similaridade mínima (ele vira, por isso baixa)"},
    pokemon_park_tolerance_px:
      {"Rastreio do pokémon (visão)", "a 90px do ponto conta como chegou"},
    # --- Revive (mecânica) ---
    rescue_step_ms: {"Revive (mecânica)", "40ms entre o controle e o revive"},
    rescue_confirm_ms: {"Revive (mecânica)", "quanto esperar a barra confirmar o controle"},
    rescue_stun_settle_ms:
      {"Revive (mecânica)", "medido: o sono leva ~2s pra pegar; o pokémon fica em campo isso"},
    rescue_blackout_ms:
      {"Revive (mecânica)",
       "medido: depois do revive o pokémon leva 2s pra voltar; nada é apertado"},
    fainted_revive_cooldown_ms: {"Revive (mecânica)", "piso entre dois revives de um caído"},
    heal_skill_cooldown_ms:
      {"Revive (mecânica)", "anti-spam da cura; se está pronta é a barra que diz"},
    support_tick_ms: {"Revive (mecânica)", "a vida do pokémon é lida a cada 120ms"},
    potion_cooldown_ms: {"Revive (mecânica)", "uma poção a cada 10s no máximo"},
    potion_battle_clear_ms:
      {"Revive (mecânica)", "2s fora de luta antes da poção (o canal cancela apanhando)"},
    reposition_battle_clear_ms: {"Revive (mecânica)", "2s fora de luta antes de reposicionar"},
    support_capture_wait_max_ms:
      {"Revive (mecânica)", "o suporte espera a captura no máximo 10s"},
    # --- Shiny (visão) ---
    shiny_always_ball: {"Shiny (visão)", "shiny sempre leva bola, mesmo com captura desligada"},
    special_color_scan_ms: {"Shiny (visão)", "varredura de cor a cada 0,7s"},
    special_color_confirm_frames: {"Shiny (visão)", "2 varreduras seguidas confirmam"},
    # --- Timers ---
    timers_tick_ms: {"Timers", "os timers conferem o relógio a cada 1s"},
    # --- Vida do pokémon (visão) ---
    pokemon_hp_min_brightness:
      {"Vida do pokémon (visão)", "coluna cheia = pixel colorido: brilho mínimo"},
    pokemon_hp_min_saturation: {"Vida do pokémon (visão)", "…e saturação mínima"},
    pokemon_hp_full_at_pct:
      {"Vida do pokémon (visão)", "as pontas são arredondadas: isto já é cheia"},
    pokemon_hp_min_known_pct:
      {"Vida do pokémon (visão)", "% da região que precisa ser barra pra leitura valer"},
    pokemon_hp_max_track_brightness:
      {"Vida do pokémon (visão)", "quão claro o trilho vazio pode ser"},
    pokemon_hp_min_bright_pct:
      {"Vida do pokémon (visão)", "faixa toda escura é janela coberta, não barra vazia"},
    # --- Vai sumir ---
    engine_spend_the_minimum: {"Vai sumir", "só a bancada lê; some no próximo PR"},
    sim_respawn_ms: {"Vai sumir", "é do simulador; vira knob do Sim no próximo PR"},
    after_kill_hold_ms: {"Vai sumir", "sempre 0; a regra some no próximo PR"},
    engine_gather_tiles: {"Vai sumir", "só valia juntando andando; some no próximo PR"},
    engine_bunch_walk_tiles: {"Vai sumir", "idem; some no próximo PR"},
    engine_skip_fire: {"Vai sumir", "medido: não muda nada; some no próximo PR"}
  }

  @doc "Toda chave travada, com o grupo e o porquê."
  @spec all() :: %{atom => {String.t(), String.t()}}
  def all, do: @locked

  @doc "As chaves travadas."
  @spec keys() :: [atom]
  def keys, do: Map.keys(@locked)

  @doc "Esta chave é uma constante?"
  @spec locked?(atom) :: boolean
  def locked?(key), do: Map.has_key?(@locked, key)

  @doc "As travadas por grupo, em ordem: `[{grupo, [{chave, porquê}]}]`."
  @spec groups() :: [{String.t(), [{atom, String.t()}]}]
  def groups do
    @locked
    |> Enum.group_by(fn {_key, {group, _why}} -> group end, fn {key, {_group, why}} ->
      {key, why}
    end)
    |> Enum.map(fn {group, rows} -> {group, Enum.sort(rows)} end)
    |> Enum.sort_by(fn {group, _rows} -> {group == "Vai sumir", group} end)
  end
end
