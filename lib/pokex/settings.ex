defmodule Pokex.Settings do
  @moduledoc """
  Runtime-tunable bot settings, persisted as JSON.

  The checked-in @seed_settings map is the source of truth for defaults. The file at
  `~/.pokex/settings.json` stores ONLY the keys the user has explicitly changed, so a default
  that isn't overridden always comes from code — changing a seed default in a new build takes
  effect for everyone who hasn't overridden that key. (Persisting a full snapshot instead would
  freeze every default at its first-boot value and silently shadow later code changes.)

  ## Three layers: character ⊕ base ⊕ seed

  The keys in `character_keys/0` belong to the CHARACTER and live in
  `chars/<slug>/settings.json`. The rest — vision thresholds, timings,
  calibration, sounds — describe the Mac and the game, not who is playing, and
  stay single in `settings.json`.

  Reading walks down the layers: what the character overrode, else the global
  (the BASE), else the seed. Writing follows the same ruler — with a character
  active, one of their keys lands in their file; with no character, you are
  editing the base, which is what every new character inherits.

  No consumer needs to know any of this: `get/2` and `put/3` are the same.
  """
  use GenServer
  require Logger

  alias Pokex.Settings.Legacy

  @seed_settings %{
    # Active character slug (see Pokex.Characters). "" = no character selected —
    # per-character files (chars/<slug>/…) fall back to the legacy shared ones.
    active_character: "",
    rod_key: "shift+v",
    skill_keys: ["1", "2", "3"],
    # Combat does not need the mouse once a target is locked. Fire a short keyboard-only burst
    # per battle read, then re-check the ring/list. This keeps the mouse free for fishing and
    # reduces capture pressure during fights.
    combat_skill_burst_size: 3,
    # From how many enemies on the battle list the fight leads with AREA damage
    # instead of single-target. Below it the single-target skills go first: "ir
    # usando as skills single target primeiro com poucos inimigos e guardar
    # para mobar em inimigos maiores" (Lucas, 2026-08-11). Only consulted when
    # the pokémon on the field has its keys classified (/time); the opening of
    # a gathered pile is always area, whatever this says.
    combat_aoe_from_enemies: 3,
    # SE A CAÇADA USA AS TECLAS DE ALVO ÚNICO.
    #
    # Desligado, e por medição dele em campo (27/08): "o que dá dano é a skill
    # em área, praticamente exclusivamente — a gente nem precisa usar as de alvo
    # único". Ele viu o defeito de dentro: entrou numa luta com DOIS bichos, o
    # `combat_aoe_from_enemies: 3` pôs o alvo único na frente e a luta virou uma
    # sequência de teclas que não matam.
    #
    # Um pokémon SEM área classificada continua usando as de alvo único: ficar
    # mudo é pior que bater fraco. E `combat_aoe_from_enemies` só volta a
    # significar alguma coisa com esta ligada.
    combat_single_target: false,
    # A PARTIR DE QUANTOS INIMIGOS a aura de DEFESA vale a pena.
    #
    # "A de defesa vale sempre que tem já uns 2 pokémons atacando ele pelo menos,
    # e ele tá pretendendo entrar em luta muito em breve (…) ou no pior dos
    # casos, que nem a aura de ataque: quando entrar em luta, sempre garantir
    # usar se estiver disponível" (27/08). Em 1 ela vira a regra da aura de
    # ataque — sai em toda luta com a tecla pronta.
    #
    # Ela só faz alguma coisa para um pokémon com tecla classificada como
    # `:shield` no /time; em 27/08 nenhum dos seis do time dele tinha uma, e é
    # por isso que a aura de defesa nunca saiu.
    combat_shield_from_enemies: 2,
    # --- Tracking HIS OWN pokémon on screen (Pokex.Bots.PokemonTracker) ---
    # The teach-sized square, and the coarse stride the finder slides it by. The
    # box is a tile and a bit: a pokémon is bigger than a corpse and the taught
    # framing is what the search has to reproduce.
    pokemon_sprite_box_px: 96,
    pokemon_track_step_px: 8,
    # How far around the expected point to look. Small on purpose — asking "is
    # it here?" costs a fraction of asking "where is it?", and the callers all
    # know roughly where to look.
    pokemon_track_radius_px: 160,
    # Above this the sighting counts. Lower than the corpse threshold because a
    # pokémon TURNS: the sample that matches is rarely the exact angle.
    pokemon_track_min_similarity: 0.55,
    # How far from the park point still counts as "it got there".
    pokemon_park_tolerance_px: 90,
    # How often the scheduled actions (`Pokex.Timers`) check their clocks. One
    # second is far finer than anything he schedules — the shortest is eight
    # seconds into a mob stretch — and costs nothing: a tick reads one fact and
    # compares integers.
    timers_tick_ms: 1_000,
    combat_skill_tap_count: 1,
    # ESCOLHA DELE (26/08): "usa um gap universal de uns 300ms acho que é
    # suficiente". Os 35 anteriores eram uma semente que ninguém tinha medido
    # contra o cliente — eu já recomendei esse número por ele ser a semente, e
    # não por alguém ter provado que o jogo aceita. Trezentos é o palpite DELE,
    # que joga, e vale mais que o meu.
    #
    # O que custa, medido em 26/08 (16 sementes × 180s, vida 300, três áreas
    # fortes): a rajada ocupa o corpo por (N-1) intervalos, e nesse tempo não se
    # anda nem se foge. Aos 500ms que ele rodava, o preço era ~20% dos mortos e
    # o DOBRO das quedas. O recibo (`SkillReceipt`) é quem pode confirmar se 300
    # sai inteiro no cliente — ele mede, isto só assume.
    combat_skill_gap_ms: 300,
    combat_skill_jitter_ms: 20,
    # --- Skill-bar cooldown tracking (SkillBar reads the hotbar per-process) ---
    # Legacy fallback when an old calibration has no explicit count. New calibrations
    # ask for 1..10 and persist that fixed geometry; cooldown frames never change it.
    skill_bar_count: 6,
    # A slot reads :ready when its average SATURATION clears this (or the vivid floor
    # below) — readiness is COLOUR, never brightness alone. Under ~20s the game renders
    # the countdown BIG with decimals ("17.6"); that white number lifted average
    # brightness enough that the old brightness-only branch read every long cooldown as
    # falsely ready for its final stretch (Lucas, 2026-07-10) — pulling fish with nothing
    # to kill them. White/grey have zero saturation, so the colour tests are immune.
    # MEASURED on Lucas's real bar (2026-07-08 diagnostic): ready icons sit at saturation
    # 27-68 (every one clears the colour tests alone), cooldown slots at 19/19.
    skill_ready_min_saturation: 25,
    # The countdown NUMBER wins over everything: a slot with at least this % of PURE-white
    # pixels (the glyph body) reads :cooldown regardless of colour — the number's
    # anti-aliasing over a COLOURED icon mints saturated edge pixels that fool the colour
    # tests (the slot-6 "16" false ready, 2026-07-10). Erring toward :cooldown is the cheap
    # direction (hook_hold_max_ms bounds a false hold). RAISE this if a ready icon with real
    # white art ever reads :cooldown — white_pct is exported per slot in the diagnostics.
    skill_cooldown_min_white_pct: 4,
    # Reference match (preferred, when the calibration carries per-slot references captured
    # with every skill READY): a slot is :ready while its live non-white colour signature
    # stays within this euclidean RGB distance of its own reference. TIGHT by measurement
    # (2026-07-20): a true ready match is 0-1 (static art, deterministic capture), while the
    # dark cooldown panel that REPLACES the icon lands at ~44-60 from dark-averaging refs —
    # the old ceiling of 60 read slots 3/6/8 as :ready mid-cooldown. 25 splits ~1 from ~44
    # with margin on both sides. The per-slot `distance` is exported in the diagnostics —
    # tune from there if an icon flickers between states.
    skill_ref_max_distance: 25,
    # A slot also reads :ready when at least this % of its pixels are strongly COLOURED
    # (the coloured glyph of a usable icon). This is what saves a dark-but-colourful ready
    # icon — e.g. skill 3's green symbol on black — whose AVERAGE brightness/saturation are
    # both low (so it was misread as cooldown forever). The cooldown overlay greys the icon
    # and the white countdown number is colourless, so a real cooldown reads ~0% vivid. RAISE
    # it if a greyed cooldown ever reads ready; LOWER it if a small coloured icon reads cooldown.
    skill_ready_min_vivid_pct: 7,
    # Fishing gate (toggle in the panel): when true, a bite is HELD (line stays in
    # the water, bubbles keep flashing) and the rod is only pulled once AT LEAST ONE
    # skill in hook_skill_keys is ready — so you don't reel in a fish with nothing to
    # kill it. (Loosened from ALL-ready, which held ~54% of bites while the ~40s
    # kill-skills cycled — the "sees bubbles but won't pull" bug.)
    require_cooldowns: false,
    # Fishing HP gate (toggle in the panel), the cooldown gate's sibling: when true, a
    # bite is HELD unless the :pokemon blackboard fact says the active Pokémon can take
    # the fight — HP at least pokemon_hp_fishing_pct AND the HP bar readable (unreadable
    # = no Pokémon out of the ball / party window minimized). Casting is never gated —
    # only the pull. Fact missing/stale (support monitor off, no HP calibration) = no
    # opinion, the gate stays open.
    require_pokemon_hp: false,
    pokemon_hp_fishing_pct: 40,
    # Max age of the :pokemon fact before the fishing gate treats it as unknown. The
    # support monitor republishes every support_tick_ms, so 3s only trips when the
    # monitor is halted or wedged — fail open, never hold fishing on a dead monitor.
    pokemon_fact_max_age_ms: 3_000,
    # Which skills the gate watches — it pulls as soon as ANY of them is ready. Lucas
    # uses 4-7 (~40s each) to kill; edit in the panel. These are hotbar keys ("1".."N").
    hook_skill_keys: ["4", "5", "6", "7"],
    # Ceiling on ONE held bite: if no watched skill reads ready for this long, pull anyway
    # (logged loudly). This is the ONLY "don't hold forever" protection — an unreadable or
    # misread skill bar HOLDS (unknown ≠ ready) and this timer is what unblocks it, so it
    # must exceed the longest watched-skill cooldown (Lucas's slot 6 is ~2min).
    hook_hold_max_ms: 180_000,
    # 100 → 150: each watcher tick is ONE capture on the serialized queue, and
    # at 100ms fishing alone asked for ~10 captures/s — drowning the battle
    # feed (2026-07-29 logs: combat with no post-Tab frame for 3s straight,
    # fishing ticking at 2-6s). The bubble oscillates continuously; 150ms still
    # catches the bite on the next frame.
    tick_ms_watching: 150,
    tick_ms_default: 80,
    wait_focus_ms: 20,
    wait_after_equip_ms: 30,
    # Let the cast SPLASH settle before watching, so the line landing isn't read
    # as a bite; then give the game time to finish the hook/reel animation before
    # the next cast. Too short here makes the next Shift+V land while the rod is
    # still being recovered, so the cast fails and fishing relies on the dead-frame
    # fallback to recover.
    # Widened to fully outlast the ~1-1.5s splash so most ambiguous frames never
    # even enter the sample stream (an independent second layer of defense).
    # Post-cast wait before watching the water. Was 1600 — but settle ALREADY
    # requires calm_streak_needed consecutive calm frames after this, so the
    # long wait was belt AND suspenders paid twice, every cycle (it also
    # delayed failed-cast detection, which only counts from here). 800 skips
    # the bulk of the splash; the calm frames prove the rest.
    wait_cast_settle_ms: 800,
    # Pause between pulling the fish and the next cast. Was 1500 — half a
    # second covers the catch animation; the rest was fish/minute thrown away.
    wait_assess_ms: 700,
    watch_timeout_ms: 30_000,
    # N CONSECUTIVE casts with NO bubbles at all = the rod key is probably not
    # reaching the game (swallowed key, focus, helper) — the screen is the only
    # witness that a cast happened. On trip: alarm and restart the count.
    # 0 = off.
    dry_casts_alarm: 3,
    # MAPPED corpses (the glyph approach applied to capture): the library
    # taught in calibration IS the aim — only a candidate whose palette matches
    # a known corpse gets a Pokéball. The guess-without-library mode was
    # retired (2026-07-30); an empty library = no targets, and the Catcher
    # warns loudly on start.
    corpse_match_min_similarity: 0.72,
    # side of the square crop (RAW frame px) when photographing/validating a corpse
    # Derived, not measured: this and the corpse lengths below follow the tile,
    # which was re-measured on the new client (see tile_px) — 151/131 bigger
    # than the old one's. What the ground is made of did not change; how many
    # points a step of it takes did.
    corpse_sprite_box_px: 65,
    # The capture SCAN SQUARE: radius in tiles of the square swept around the
    # character when a kill happens. 3 = 7×7 tiles ≈ 616pt on Lucas's screen —
    # covers the fallen corpse in any plausible neighborhood without sweeping
    # the whole screen. Was 1 (only the 8 neighbors) and, with the arena crop,
    # only 11 of the 16 windows survived (measured live 2026-07-30).
    corpse_scan_radius_tiles: 3,
    # DENSE two-phase sweep: coarse step across the whole region, fine
    # refinement around the N best peaks. The score drops ~0.05 per 7px of
    # offset (measured on Lucas's samples), so refinement is where the gap
    # between 0.63 and 0.95 is recovered. Coarse step = half a tile.
    # The Pokéball HOTKEY. Was "f1" hardcoded in Rig.Mac — the only bot key
    # that wasn't a setting, and it already changed hands once without the
    # code following. `ball_needs_click` covers the doubt only the game can
    # answer: whether the hotkey uses the ball directly or arms an aim that
    # waits for a click.
    ball_key: "f1",
    ball_needs_click: false,
    # The balls on his hotbar. `ball_key` above is the DEFAULT — what an
    # unrecognised corpse, or one no rule mentions, gets thrown at it.
    ball_types: [
      %{"key" => "f1", "name" => "Poké Ball"},
      %{"key" => "f2", "name" => "Bola de aquáticos"}
    ],
    # WHICH ball for WHICH corpse, read like the combo triggers: naming the
    # creature beats naming what it is made of, and both beat the default.
    # Seeded with the two he hunts (2026-08-11) — the rules stand ready and
    # start working the moment their corpses are in the library, painted by
    # hand or photographed for real.
    ball_rules: [
      %{"trigger" => %{"kind" => "species", "value" => "Tentacool"}, "key" => "f2"},
      %{"trigger" => %{"kind" => "species", "value" => "Krabby"}, "key" => "f2"}
    ],
    # The beat between positioning the cursor and firing the hotkey. The rod
    # has the SAME shape and uses 30ms (wait_after_equip_ms) — the ball had no
    # beat at all.
    capture_aim_settle_ms: 30,
    # How long the cursor stays parked on the target after the throw, before
    # the Body returns it to Lucas's spot (restore_mouse_after_actions).
    # Without it the cursor was yanked ~2ms after the key.
    capture_hold_ms: 120,
    corpse_scan_step_px: 51,
    corpse_scan_refine_px: 8,
    corpse_scan_refine_peaks: 4,
    # Auto-recovery: consecutive NEAR-EMPTY-water frames (bubble px below
    # line_present_min_px — no line in the water) before we assume the cast FAILED
    # (a dropped rod press, or the game itself just not casting, which happens even
    # when Lucas fishes by hand) and re-throw. Lowered 20→4 (Lucas): a resting line
    # pulses 108-759px, ALWAYS above the 100 floor, so a real line reads `line?` and
    # resets this every frame — only genuinely empty water climbs it. At
    # tick_ms_watching (100ms) 4 frames is ~0.4s: catch a failed cast almost
    # immediately instead of waiting ~2s. A REAL/building bite also resets it (see
    # the glow clauses), so a live line is never cut short. Raise it if good lines
    # get recast mid-wait — watch the "N/M sem bolha" counter in the feed.
    watch_dead_streak_needed: 5,
    # ...but the streak only starts counting THIS long after the cast. The rod key
    # does not put the lure in the water: the throw arcs and the lure appears
    # seconds later — MEASURED on the 3440×1440 (journal 2026-08-10): 2-5s from the
    # key to the first frame with any lure pixel, on every cast. Without this the
    # verdict "o cast falhou" was reached while the bait was still in the air (5
    # frames ≈ 0.75s at tick_ms_watching) and the re-throw's key press yanked the
    # bait that had just landed back OUT — "joga a vara, acha que não lançou nada e
    # re-lança". 5s covers the slowest measured throw; raise it if the water is
    # still empty when the streak starts, lower it to catch a swallowed key sooner.
    cast_grace_ms: 5_000,
    # A locked target that hasn't died in this long isn't a real hostile (our own
    # pokemon) or is hopelessly tanky → drop it and try the next battle row.
    fight_timeout_ms: 6000,
    # Min cyan pixels for a BITE. The bite bubbles flash ON/OFF frame-to-frame
    # (measured 2..1513 during one bite) but their PEAKS hit 1100-1500, while the
    # resting bait ring pulses higher than first thought — 800 still let resting
    # frames through as false bites. 1100 clears the resting ceiling with margin;
    # only a real bubble burst reaches it. Tunable via /diagnostics "Bolhas (ciano)".
    #
    # The live reader samples `glow_region` plus this margin on every side. Quick-cast
    # throws toward the cursor but the lure lands on the nearest valid water tile, which
    # can be ~100-180px away from the cursor on diagonal shorelines. 192 covers that
    # landing drift; Vision then selects the local lure-like red component near the
    # expected point so character sprites in the larger crop do not become the target.
    glow_search_margin: 192,
    # Inside the expanded region, find the red/orange lure first, then count cyan
    # only near it. This keeps random water sparkles from looking like a live line.
    fishing_lure_min_pixels: 20,
    fishing_bubble_radius_px: 64,
    glow_threshold: 1100,
    # Legacy/raw fallback for line presence when a sensor only returns an integer.
    # The real sensor now prefers the lure-focused `line_present?` flag so random
    # water sparkles do not keep a failed cast alive forever.
    line_present_min_px: 100,
    max_consecutive_failures: 5,
    wild_min_red_pixels: 12,
    # A SINGLE bite-magnitude frame (> glow_threshold) hooks. The bite oscillates
    # hard (2..1513), so requiring CONSECUTIVE frames never confirms — but one frame
    # over 800 is unambiguous (nothing else reaches it) and the post-hook anti-bot
    # delay covers the "too instant" concern, so first detection = caught.
    glow_streak_needed: 1,
    # Consecutive below-threshold (resting/splash level) frames before a cyan spike
    # counts as a bite. Guards against a splash that briefly clears glow_threshold.
    calm_streak_needed: 3,
    # TIME ceiling on settling: past this since the cast, the water has settled
    # BY PHYSICS (the splash lasts ~1-1.5s) even if the calm frames never
    # accumulated. Counting only frames assumes ~150ms ticks — with capture
    # starved (frames seconds apart) the fish bites before 3 calm frames,
    # every spike RESETS the calm streak and the rod never pulls (2026-07-30
    # logs: bubbles 2843/1150 for 16s without hooking, timeout, fish burned).
    settle_max_ms: 2_500,
    # Height (points) of ONE battle-list row = the vertical spacing between rows.
    # MEASURED live via hp_bar_rows: HP bars at frame-y 42 and 95 → ~53px apart
    # (matches the documented 52-53px rows). The old 30 compressed the click grid
    # (config.battle_rows = first_row + i*row_height) to ~half the real spacing, so
    # row-N clicks landed BETWEEN real rows / on row N-1 — the bot clicked, missed
    # the creature, and "kept searching". Drives BOTH the row click points and the
    # per-row lock read bands, so they now line up with the real rows.
    battle_row_height: 30,
    # Where row 0's band is CENTERED inside the battle region, in points. It was
    # a constant (18) measured on the old client; the new one stacks icon, name
    # and bar so the row's middle sits at 31 with a pitch of 30 (measured on his
    # own list, 2026-08-24: bars at 41, 71, 101, 131, 161). A band centered on
    # the wrong number straddles two rows, which costs BOTH the row a creature
    # is bucketed into and the red the lock sensor is looking for.
    battle_first_row_y: 31,
    battle_max_rows: 6,
    # Min bright-red (r>=200,g<=60,b<=60) px on a scanline of the rightmost strip for it to count
    # as the OWN-pokemon pokeball (so that row is EXCLUDED from attack candidates). MEASURED on
    # Lucas's real Mareep (2026-07-09): the icon is a small ~7-px red blob per scanline, so the
    # old 12 never matched and his own pokemon got clicked as an enemy. 5 catches it with margin;
    # RAISE it if a red enemy element in the strip ever gets mistaken for a pokeball.
    pokeball_min_red_px: 5,
    # Screen points per game tile — the ruler for everything measured FROM THE
    # CHARACTER. RE-MEASURED 2026-08-24 on the client he plays; 131 was the old
    # one's, and before that 88 was two thirds of a tile.
    #
    # The method assumes nothing: two full-screen photos whose minimap
    # coordinates differ by a known number of tiles, matched against each other.
    # Walking 4 tiles west moved the terrain 604 points across (604/4 = 151.00,
    # the same answer from three different patches of ground); walking 3 south
    # moved it 452 up (452/3 = 150.67). Two axes agreeing to 0.2%.
    #
    # Both wrong answers this number has had came from trusting a texture
    # instead of a walk: 88 was the floor pattern repeating every 44 points read
    # as two rows per tile, and one patch of THIS measurement locked onto 302 —
    # exactly two tiles — with an error ten times the true match's. A ruler off
    # by a third is why the blind sweep threw several balls at one square and
    # none at the ring around it.
    tile_px: 151,
    # /diagnostics still shows the per-row red target-ring read for manual inspection; this
    # is the threshold it uses (a real ring is 600-900 red px, the unlocked baseline ~40-150).
    # Combat itself no longer reads the ring — it targets by HP bar + pokeball (enemy_rows).
    target_locked_min_pixels: 120,
    # Consecutive ticks the enemy must be GONE from the Battle list before the fight is
    # declared over — filters a 1-frame HP-bar blink on a hit/death animation.
    target_lost_streak: 2,
    # What the bot DOES when the overlay opens (see Pokex.Bots.MiniGame.Mode):
    # "manual_assist" (default, safe: detect + hold the other workers + alert, Lucas plays),
    # "diagnostic" (same, silent) or "auto" (the Pilot plays). A STRING because settings.json
    # round-trips through JSON — an atom seed would never match the persisted string.
    mini_game_mode: "manual_assist",
    # How often the "resolve o minigame" alert repeats while a manual game waits. It is easy to
    # miss one chirp with the game window unfocused, and a mini-game left unplayed stalls the
    # whole session (every worker is held by the :mini_game fact). 0 = only the entry alert.
    mini_game_manual_alert_ms: 5_000,
    # Per-game diagnostics (always collected, in every mode — a game Lucas played by hand is the
    # most informative recording there is). Caps are memory guards: at the 80ms play tick 3000
    # samples is ~4min, well past the hard duration cap.
    mini_game_diag_samples_max: 3_000,
    # Frames kept per game beyond the fixed first/last/worst-error slots (source flips, rejected
    # readings, :no_track, :no_fish). Ring buffer: newest wins, oldest is dropped.
    mini_game_diag_frames_max: 8,
    # How often the /mini-game page's preview image is refreshed from the frame that was
    # ACTUALLY analysed (a file copy of the captured PNG — never a second capture). 0 = off.
    mini_game_preview_ms: 500,
    # Export bundle retention, applied after each game, oldest first: at most this many bundles
    # and at most this many MB total under ~/.pokex/exports.
    mini_game_export_keep: 20,
    mini_game_export_max_mb: 200,
    # Fishing mini-game monitor. It only detects the overlay and coordinates worker pause/resume.
    mini_game_tick_ms: 150,
    # 2 consecutive present frames (~300ms) before entering: the overlay lasts many seconds,
    # and one dark thing crossing the anchor for a single frame must not pause every worker.
    mini_game_enter_streak: 2,
    mini_game_exit_streak: 2,
    mini_game_min_confidence: 0.62,
    mini_game_min_dark_ratio: 0.34,
    # Meia-largura da faixa DERIVADA do minigame (o resto vem das âncoras: o
    # personagem em cima, a barra de skills embaixo). A barra tem ~17px e é
    # desenhada em cima do personagem; 50 cobre o desenho + o erro humano de
    # clicar o player_point, sem virar a caixa larga que leu tronco escuro +
    # flores azuis como minigame (2026-08-05). Estreite se voltar a ver
    # minigame onde não tem.
    # A faixa do minigame DERIVADA, medida na marca do próprio Lucas
    # (2026-08-10, 3440×1440): região {1707, 673, 24, 474} contra um
    # player_point de {1707, 689}. O centro da barra fica 12pt à DIREITA dele,
    # a barra tem 24 de largura, começa 16 acima e desce 474.
    mini_game_bar_offset_px: 12,
    mini_game_bar_width_px: 24,
    mini_game_above_px: 16,
    mini_game_strip_height_px: 474,
    # Half-width (screen points) of the window around the player point where the bar may sit.
    # Measured 2026-07-10: the game draws the bar ~40px to the RIGHT of the character sprite,
    # so this must cover sprite-center error + that offset (the old 4%-of-width default = ~26px
    # rejected every real mini-game).
    mini_game_anchor_tolerance: 70,
    # Playing the mini-game (hold/release Space chasing the fish). Tick = capture+decide
    # cadence while in-game; deadband validated by Lucas in the lab 2026-07-10 (6px of the
    # lab's 548px track); min-toggle mirrors the lab's 50ms input floor. 80ms tick: while
    # playing the worker captures only the narrow bar STRIP (no Detector pass), so each
    # decision is cheap — the fish reverses every 0.5-1.5s and 150ms reacted too late.
    mini_game_play_tick_ms: 80,
    mini_game_min_toggle_ms: 50,
    # End-of-game detection is DEFENSE IN DEPTH — the "track gone" exit streak alone hung
    # the whole bot (2026-07-20): after a WIN the world behind the strip held a ≥60-row dark
    # column, Track kept reading a "track" + clutter-fish, and every tick came back present.
    # The capsule's blue is the player's OWN presence (measured live: visible on 86/86 play
    # frames), so present readings with NO blue for this many consecutive ticks mean the
    # overlay is functionally gone (~2s at the 80ms tick).
    mini_game_no_capsule_exit_ticks: 25,
    # Hard duration cap per game — the backstop for ANY unseen wedge (same philosophy as
    # hook_hold_max_ms): no real game lasts minutes; a "game" that does is a stuck reading.
    mini_game_max_game_ms: 90_000,
    mini_game_deadband_pct: 0.011,
    # Stopping-distance braking (track/s²), per direction — the REAL game is
    # asymmetric: thrust arrests a fall almost instantly (brake late: sink to
    # the fish before pressing), gravity barely arrests a rise (release early
    # or it coasts far past — "sobe demais"). RAISE brake_down to press even
    # later on the way down; LOWER brake_up to release even earlier going up.
    # brake_up MEASURED from live game traces (2026-07-11, 4 games): falling
    # acceleration ≈ 0.7-0.95 track/s² — and Lucas's independent "press 0.7x
    # as long" intuition lands on the same number (1.2 * 0.7 ≈ 0.84).
    # Fish readings implying a faster-than-possible jump are MISREADS (the fish tops out
    # ~1.3 track/s, measured 2026-07-20; the phantom teleports implied 3-5): the pilot holds
    # its last plausible aim instead of chasing them...
    mini_game_fish_max_speed: 2.0,
    # ...unless the last plausible reading is older than this — then the new reading is
    # adopted and the history restarts (bounded blindness beats chasing ghosts, and a fresh
    # start beats blending a velocity across the warp).
    mini_game_fish_reacquire_ms: 700,
    mini_game_brake_up: 0.8,
    mini_game_brake_down: 3.0,
    # Browser alert on enter/leave (panel mute button). Muting stops the panel
    # from pushing the sound event at all.
    mini_game_sound: true,
    # Session ALARMS (panel): sound on a worker error edge or the Pokémon's HP
    # crossing below the rescue threshold. Deduplicated per alarm type by
    # alarm_min_gap_ms (KizuBot's antiSpamInterval) — a flapping error can't
    # turn the panel into a siren. Muting stops the push entirely.
    alarm_sound: true,
    alarm_min_gap_ms: 30_000,
    # Per-SECTOR mute (Lucas, 2026-07-30: too noisy, asked for per-sector
    # alert config). List of muted categories (strings, see
    # Pokex.Bots.AlarmCategories) — empty by default (nothing changes for
    # existing users: the master sound stays the only switch). The header
    # button toggles each sector WITHOUT touching the master sound — the two
    # multiply (muted = master off OR sector in the list).
    alarm_muted_categories: [],
    # Stop conditions (hunt goals): the Guardian halts the WHOLE fleet — with
    # the same latch as the panic corner, so nothing auto-resumes until Iniciar
    # — when the running session crosses a limit. 0 = condition off.
    stop_after_minutes: 0,
    stop_after_kills: 0,
    # What to do when a goal is hit: "stop" latches everything like Stop;
    # "logout" logs the account out — which is what actually saves stamina.
    stop_after_action: "stop",
    # The COMMAND corner (top right): holding the mouse there for
    # command_corner_dwell_ms toggles the last used mode — from INSIDE the
    # game, without clicking the browser (clicking steals focus and closes the
    # input gate at the exact instant of startup; real regression 2026-07-29).
    # The dwell is the anti-accident: sweeping the mouse through the corner
    # fires nothing, and you must LEAVE the corner before a second command.
    command_corner: true,
    command_corner_dwell_ms: 600,
    # Shiny guard (Lucas's anti-shiny protocol): watch the arena feed for the
    # COLOR signature of the watched Shinies (built from the wiki sprites — a
    # PokeTibia shiny is a full recolor, so no in-game photo is needed). Action on a
    # confirmed sighting: "escape" = the emergency-escape protocol (staircase);
    # "alarm" = keep fighting, just scream (his "lutar se quiser").
    shiny_guard_enabled: false,
    # The battle-list STAR detector (the reliable path — PokeTibia marks a shiny with
    # a gold ★ before its name). A row is shiny when its densest 3-column gold
    # window reaches this many pixels; MEASURED on Lucas's real capture
    # (2026-07-21): the star reads 15+ in that window, a non-shiny row 0, and a
    # shiny's own sprite icon at most 2. Raise it if a golden sprite ever trips.
    # A star is a compact glyph: MEASURED, five consecutive columns carry 4-7
    # gold pixels each. A yellow POKÉMON never stacks like that — a Magikarp's
    # fins peak at ONE dense column. 3 sits between the two.
    shiny_star_min_columns: 3,
    # A shiny ALWAYS deserves a pokéball, even with capture_enabled off.
    shiny_always_ball: true,
    shiny_action: "alarm",
    # A sighting must survive this long without a clean frame refuting it.
    # The feed captures every ~120ms, so a one-frame glitch dies in ~120-240ms.
    shiny_confirm_ms: 400,
    # Anti-stagnation: an ACTIVE session with no sign of life for this window
    # is a stuck bot (empty water, wedged detector, dead spot). Sign of life =
    # kill + MINIGAME WON — not a hook: with the minigame stuck the rod hooks
    # all night without landing a single fish, which is how one overnight of
    # stamina was lost. Hooks only count again with the minigame watcher off.
    # 0 = off. "alarm" re-rings every silence window (the rule's own
    # cooldown); "stop" latches everything via the goals latch; "logout"
    # logs the account out.
    stagnation_minutes: 0,
    stagnation_action: "alarm",
    # Escape WALK (the flee protocol): clicking ON a ladder tries to USE it,
    # which only works when adjacent (Lucas, live 2026-07-20) — so escape_point
    # is a WALKABLE tile beside the staircase; after click-walking there the
    # flee presses the escape_direction arrow key escape_steps times to
    # actually step INTO the stairs. The wait covers the click-walk itself.
    escape_direction: "right",
    escape_steps: 2,
    escape_walk_wait_ms: 2_000,
    # Auto-logout: actually end the session — STOPPING the bot saves no
    # stamina, which burns while the character is online. The key is a setting
    # (not a constant) for the same reason defense_mode_key is: Lucas remaps
    # keys in game. The default is NEVER cmd+q, which on macOS would close the
    # whole client.
    logout_key: "ctrl+q",
    logout_confirm_key: "enter",
    logout_confirm_delay_ms: 300,
    # Time given to the screen to switch before the first check. If Lucas's
    # screen takes longer, one attempt is wasted — it still converges.
    logout_verify_delay_ms: 1_500,
    logout_attempts: 3,
    # Max age of the :mini_game WorldState fact before readers treat it as unknown
    # (= not playing, fail-open). The worker republishes every tick (80-150ms), so
    # 2s only trips when the worker is dead or a capture is badly stuck — exactly
    # when peers must NOT stay frozen.
    mini_game_fact_max_age_ms: 2_000,
    humanize_max_ms: 0,
    # Anti-bot: a RANDOM 0..this ms jitter before each CAST (the rod throw), so the
    # bot doesn't fish on a perfectly fixed cadence. Was 450; 250 still breaks
    # the metronome without costing a quarter second per cycle.
    cast_delay_max_ms: 250,
    # Anti-bot: once a bite is confirmed, wait a RANDOM hook_delay_min..max ms
    # before pulling. The bubbles keep flashing until we pull — the bite window
    # NEVER closes — so a human-like reaction is safe AND avoids a robotic
    # instant yank. Was 500..1000 — slower than Lucas himself fishing by hand
    # (~250-400ms real reaction). 250..550 stays within human range and gives
    # back ~350ms per fish; raise it back in the panel if anti-ban paranoia
    # tightens.
    hook_delay_min_ms: 250,
    hook_delay_max_ms: 550,
    # --- PlayerSupport: keep the main Pokémon alive ------------------------------------------
    # When its HP bar drops below pokemon_hp_rescue_pct, press rescue_key at :critical — one key
    # is the whole revive in this client (it recalls, revives and returns the pokémon by itself).
    # Toggle + a cooldown so a detection glitch can't burn the (expensive) revives. Ships OFF: the
    # HP region starts from a measured ESTIMATE, so verify the panel HP bar tracks your real HP
    # before enabling — a miscalibrated region reading a false "low" would waste a revive.
    rescue_enabled: false,
    rescue_key: "q",
    pokemon_hp_rescue_pct: 50,
    # O PISO ENTRE DOIS RESGATES, e a curva dele foi medida em 25/08 no circuito
    # denso, 60 minutos por linha, com o stun na frente do revive:
    #
    #   piso  2s → 0 quedas · 139 revives/h · ele termina com 88%
    #   piso 15s → 2 quedas · 137 revives/h · ele termina com 82%
    #   piso 60s → 45 quedas · 86 revives/h · ele termina MORTO
    #
    # Sessenta segundos economizava 51 revives por hora e pagava por eles com
    # quarenta e cinco quedas — e uma queda custa o campo vazio, que é quando as
    # mordidas passam a ser DELE.
    #
    # TRÊS SEGUNDOS, escolha dele (26/08): "parece um bom tempo pra usarmos todas
    # skills e usar o ress de acordo ainda". Medido com a bancada já destravada
    # (24 sementes × 180s, vida 300, três áreas fortes):
    #
    #     piso  lotavanon  quedas  vida mín
    #      15s       46,0     3,0        1%
    #       4s       85,3       0       27%
    #       3s       85,2       0       25%
    #       2s       99,2       0       25%
    #
    # Quase o DOBRO dos mortos e zero quedas. Três e quatro dão o mesmo número —
    # a escolha entre eles é livre, e é dele. Dois mede mais alto ainda e fica
    # registrado, mas o raciocínio dele é sobre caber a barra inteira entre dois
    # revives, e isso é uma leitura do jogo que a bancada não tem.
    rescue_cooldown_ms: 3_000,
    # ms between the stun prefix and the revive so the game registers each.
    rescue_step_ms: 40,
    # How long to wait for a skill-bar reading NEWER than the crowd-control
    # press, before giving up on confirming it. The receipt is the cooldown:
    # a skill that fired is no longer ready. Costs one feed cycle, and buys
    # knowing whether it is safe to take the pokémon off the field.
    rescue_confirm_ms: 900,
    # …and the receipt is NOT the sleep. It proves the KEY fired (the cooldown
    # started), which happens instantly; the monsters take about eight tenths
    # of a second to actually fall asleep. On 2026-08-14 Lucas watched the
    # recall follow the confirmation by ~100ms — with the game's sleep still
    # in flight, the field went empty and the jungle turned on HIM ("quase me
    # fez morrer"). The pokémon stays out, tanking, for this long AFTER the
    # stun key so the pile is really down before it leaves. Counted from the
    # press, so the confirmation's own wait is part of it. 0 disables.
    rescue_stun_settle_ms: 800,
    # MORREU. A janela do pokémon muda de forma quando ele cai, então a barra
    # some do lugar calibrado e a leitura vira "não reconheço" — igualzinho a
    # uma janela coberta. O que separa os dois é a TRAJETÓRIA: uma barra que
    # sumiu vindo DAQUI pra baixo é morte; vinda de 100% é alguém que mexeu na
    # janela. Acima disto, a barra some sem revive nenhum.
    pokemon_hp_fainted_below_pct: 35,
    # Cinto de segurança depois de reviver um caído. A regra que de verdade
    # impede o loop é outra: exigir ver o pokémon VIVO de novo antes de gastar
    # o próximo revive. Acompanha o piso de cima — um caído nunca deve esperar
    # MAIS que um em pé.
    fainted_revive_cooldown_ms: 3_000,
    # Stun BEFORE reviving (2026-07-30): hunting strong mobs, the pokémon's own
    # area-control keys are reserved for this moment and become the PREFIX of
    # the same atomic sequence, so the pile is asleep while the field is empty.
    #
    # LIGADO desde 25/08, e o motivo do "desligado" anterior era o que estava
    # errado: "o revive deste cliente é uma tecla só e esvazia o campo por um
    # instante, então a espera do prefixo é uma espera que o pokémon pode não
    # ter". O instante de campo vazio é EXATAMENTE o que mata — as mordidas
    # passam a ser dele — e o prefixo é o que impede isso. Medido no circuito
    # denso, 60 minutos: sem o stun, 45 quedas e o personagem morto; com o stun
    # e o piso curto dele, ZERO quedas em toda faixa de banda testada. É a
    # frase dele de volta: "com o revive e stun em área antes de usar o revive
    # tudo se resolve".
    #
    # Uma tecla em cooldown é PULADA, e sem controle pronto simplesmente não há
    # prefixo — sempre falhando na direção de SALVAR.
    rescue_stun_first: true,
    # The main Pokémon's own HEALING SKILL — the rung above the potion. A skill is
    # an instant press, not a channel, so unlike the potion it works MID-FIGHT,
    # which is the case that actually kills a pokémon. Higher than the potion
    # threshold on purpose: free and always available goes first.
    # Which key it is comes from /time (the `:heal` job of whoever is on the
    # field), so a pokémon with none simply never triggers this.
    heal_skill_enabled: true,
    pokemon_hp_heal_pct: 70,
    # Anti-spam only: whether the skill is UP is the skill bar's answer, not a
    # guess kept here.
    heal_skill_cooldown_ms: 3_000,
    # How often the PlayerSupport samples the main Pokémon's HP bar.
    support_tick_ms: 120,
    # HP-bar fill detection is COLOUR-AGNOSTIC: a column counts as filled when it holds a COLOURED
    # pixel (bright enough to not be black, saturated enough to not be the white number). The fill
    # changes hue as HP drops (green → olive → brown → red) — all are coloured, so all count; the
    # black background/track and the white "N/max" number are colourless and ignored. Low, permissive
    # floors so even a washed/dark fill tone still registers. See Vision.hp_fill_pct/2.
    pokemon_hp_min_brightness: 45,
    pokemon_hp_min_saturation: 30,
    # The HP bar's tips are ROUNDED: the last few columns of the calibrated box never hold a
    # coloured pixel even at genuinely full health, so the raw column-fill can top out below
    # 100 and the raw reading is rescaled so this value gates as 100%. The old client's bar
    # plateaued at 95; Poké Alliance's pokebar track reads a true 100 (measured on both full
    # rows, 2026-08-26), and correcting a bar that does not need it inflated every reading by
    # ~5pp — the wrong direction for a rescue. 100 disables the correction.
    pokemon_hp_full_at_pct: 100,
    # Sanity floor on the HP read: at least this % of the region's pixels must be the bar's own
    # two populations (warm fill + near-black track). Below it the frame is NOT the bar — e.g.
    # the party window is MINIMIZED and the region shows game world — and the read is UNKNOWN
    # (never acted on), instead of a garbage "low HP" that fired the combo in a loop.
    pokemon_hp_min_known_pct: 55,
    # How bright the bar's EMPTY track is allowed to be, and the reason the floor above is
    # survivable. Poké Alliance's pokebar track is (45,69,69) — measured 2026-08-26 — so the
    # old ceiling of 60 filed every emptying column under "unknown": the known share fell WITH
    # the HP and crossed the floor at ~65%, which reads as "bar não reconhecida" and acts on
    # nothing. Blind below 65% is blind exactly where the potion and the rescue live.
    pokemon_hp_max_track_brightness: 75,
    # A uniformly DARK strip is a covered window, not an empty bar: every dark
    # pixel used to count as the bar's empty track, so the browser in front of
    # the game read as a recognised bar at 0% and fired the survival combo on a
    # healthy Pokémon. Measured: the real bar is 68% bright, a covered frame 0.1%.
    pokemon_hp_min_bright_pct: 10,
    # --- Potion: cheap top-up so the expensive revive rarely fires ------------------------------
    # Below pokemon_hp_potion_pct AND out of combat (the heal channel is interrupted by entering a
    # fight, so an in-combat potion is a wasted potion), press potion_key — the game applies it to
    # the active Pokémon by itself, no mouse needed. The cooldown covers the heal channel: firing
    # again mid-channel wastes a potion, so wait it out before another sip.
    potion_enabled: false,
    potion_key: "e",
    pokemon_hp_potion_pct: 70,
    potion_cooldown_ms: 10_000,
    # One out-of-combat read is NOT "battle over": fished enemies re-aggress in the
    # post-kill gap and the game cancels the heal channel, wasting the potion. The
    # potion only fires after the battle has read CLEAR continuously for this long.
    potion_battle_clear_ms: 2_000,
    # After every battle, middle-click the calibrated pokemon_spot_point to send the
    # Pokémon back to its strategic tile (toggle in the panel). Same battle-clear
    # caution as the potion, on its own window. Needs the native key-event helper
    # (cliclick has no middle button).
    reposition_enabled: false,
    reposition_battle_clear_ms: 2_000,
    # A pokébola só é arremessada com isto ligado — a captura é o único uso de item que
    # sobrou no jogo novo (F1/F2), já que ele recolhe o loot sozinho.
    capture_enabled: true,
    # Post-fight ORDER policy (ball → support): with this on, a due
    # potion/reposition ALSO waits for the catcher to resolve its pending
    # corpses (queued + ball in flight) before acting. The cap below bails the
    # wait so a stuck detector can never starve the heal — fail-open, loudly.
    support_waits_capture: false,
    support_capture_wait_max_ms: 10_000,
    # --- Perception feeds -----------------------------------------------------------------------
    # Capture cadence per feed. A feed only captures while a consumer is attached, so these are
    # upper bounds on broker demand, not constant costs. battle is the combat hot path; arena has
    # no consumer today (the Loot walk that read it is gone) — kept registered for a future
    # feature that wants `arena_region` again, at effectively zero cost while unattached.
    feed_battle_ms: 120,
    feed_arena_ms: 300,
    # The skill hotbar changes at ~1s granularity (countdown numbers), so its feed runs far
    # slower than battle; it only captures while combat is attached anyway.
    # 250 → 400: cooldown tracking stays live; the capture queue breathes easier
    feed_skill_bar_ms: 400,
    # How old the :skill_bar fact may be before combat treats it as UNKNOWN (→ blind
    # rotation). Generous vs the 250ms cadence so one slow/failed capture doesn't flap the
    # rotation between filtered and blind.
    skill_bar_fact_max_age_ms: 1_500,
    # Consecutive failed captures (bad region, or the OS revoked Screen Recording mid-run) a
    # feed tolerates at :debug before it escalates to a loud Logger.warning. Resets to 0 on
    # the next successful observe, so a warning fires again if failures resume.
    feed_failure_warn_streak: 10,
    # HUD numbers change slowly (stocks, level); position changes as fast as
    # Lucas walks, so the minimap is read more often than the rest.
    # The four slots that keep him alive and hunting: alarm ONCE when a stock
    # crosses below its threshold, re-arm when it climbs back. 0 = off.
    # Combos: a named sequence the bot plays against a specific enemy. The waits
    # are what make it a combo instead of a key mash — the game needs a beat to
    # bring a pokémon out, and the sing needs time to land before the counter
    # comes in.
    combos_enabled: false,
    combo_swap_wait_ms: 900,
    # a beat between the combo's key presses, so the client registers them as
    # separate actions rather than one blur
    combo_press_gap_ms: 120,
    combo_sing_wait_ms: 2_500,
    stock_alerts_enabled: true,
    stock_alert_f1: 30,
    stock_alert_f2: 10,
    stock_alert_e: 5,
    stock_alert_s_q: 10,
    # 500 → 1000: stock alerts don't need 2 reads/s — the queue needs slack
    feed_hud_ms: 1000,
    # 500 → 1200: team display and combo swaps stay fresh; battle gets the slack
    feed_team_ms: 1200,
    # 250 → 500: at 5 steps/s a position every half second still guides the route
    feed_minimap_ms: 500,
    # MEASURED, not guessed: between two captures the coordinate moved (-5,-11)
    # tiles while the map image shifted (+10,+22) pixels — 2px per tile on both
    # axes, at 98.5% correlation.
    minimap_px_per_tile: 2,
    # Ink floor of the minimap COORDINATE strip. MEASURED (2026-07-30): digit
    # cores are 240+ but anti-aliasing spreads over 160-239, and the glyph
    # atlas was taught with floor-120 shapes — raising the floor THINS the
    # shapes and the atlas stops recognizing them (tested: 165 blinds all four
    # real captures). 120 = current behavior, which the fixtures prove works
    # with drop_background. Only change it together with re-teaching the new
    # shapes by hand on the "Ensinar glifos" screen.
    minimap_coord_ink: 120,
    # --- Combat: Tab targeting ------------------------------------------------------------------
    # Tab selects the first attackable enemy; pressing again CYCLES to the next. The confirm
    # window counts from the Tab press against frames captured AFTER it, so capture latency can't
    # eat the window (the old click flow's 500ms expired before its first read). Exhausting
    # tab_max_attempts hunt-holds for hunt_cooldown_ms so a visible-but-unattackable row can't
    # cause a Tab storm. skill_burst_every_ms throttles bursts below the feed cadence.
    tab_key: "tab",
    tab_confirm_ms: 700,
    # How many POST-Tab frames without lock must be SEEN before re-Tab.
    # Re-Tab cycles targets (each Tab jumps to the next enemy): doing it on
    # the clock, with no frame evidence, was the "keeps tabbing without ever
    # focusing the first" bug when capture lagged. 1 = require at least one
    # real frame; raise to 2 if the lock ring paints slowly on your machine.
    tab_confirm_frames: 1,
    tab_max_attempts: 3,
    hunt_cooldown_ms: 1_500,
    # SCENERY (unattackable) pokémon parked in the list: N complete
    # consecutive hunts — each with tab_max_attempts Tabs WITH frame evidence
    # and no lock — promote those targets to "presumed scenery": they stop
    # motivating Tab, like the position itself. One EXTRA target hunts
    # immediately; a shrinking list forgets; the presumption expires after
    # scenery_ttl_ms and re-probes (self-correcting). 3 hunts × 3 Tabs ≈ the
    # ~10 attempts Lucas asked for (2026-07-30). 0 = off.
    scenery_hunts_needed: 3,
    # A row Combat gave up on is re-probed when this expires (3 Tabs, ~8s). His
    # own pokémon lives in the battle list permanently, so a 60s TTL meant a
    # stutter every minute of every hunt; 5 minutes keeps the re-probe (a mob
    # CAN become reachable) without making it the loudest thing on screen.
    scenery_ttl_ms: 300_000,
    # THE STALEMATE. A locked target whose HP bar does not move a single pixel
    # for this long, while skills go out, is not being fought — it is out of
    # reach ("bugou com um pokemon do outro lado da parede que ele nao consegue
    # atacar", 2026-08-11). Combat then gives up on it exactly as it gives up
    # on a row that never locks, which is what frees the hunt to WALK — and
    # walking is what solves a wall. Long enough that a burst on cooldown
    # cannot look like one: 0 turns it off.
    no_damage_ms: 8_000,
    # ONE fight at a time, when he wants it: how long combat waits after a kill
    # before hunting anything else. 0 = chain, which is what it has always
    # done. Raise it to walk past a crowd killing only what actually engages —
    # "só matar aquele lá e não dar mais tab depois" (2026-08-11).
    after_kill_hold_ms: 0,
    skill_burst_every_ms: 300,
    # After every kill/timeout rehunt (and on a fish hook), hunting keeps PROBING with blind
    # Tabs for this long even when the HP-bar detector reports no enemy — "idle while fished
    # enemies wait in the list" is the one state combat must never rest in. Tab on an empty
    # list is a no-op; the lock ring is what confirms a real target.
    hunt_probe_window_ms: 8_000,
    # Battle observations older than this are treated as unknown by combat (fail-safe: no keys).
    # MUST outlast the broker's worst case, not just the feed cadence: when SCK is down the
    # screencapture fallback runs ~450-580ms per capture PLUS ~500ms of broker queueing (measured
    # on Lucas's perf dump, 2026-07-10), so battle entries routinely age past the old 600 under
    # load. That starved post-kill hunting — a static battle list never broadcasts, the poll was
    # the only driver, and every poll read "stale" → nil → combat never Tabbed the next fished
    # enemy. 2.5s still bounds how old a picture may act (enemy rows linger for many seconds),
    # while surviving a fully queued fallback pipeline.
    combat_world_max_age_ms: 2_500,
    # Hunting is not fishing: a skill that silently never left is damage he is
    # not doing while a pile eats him. After a burst, the bar is read again and
    # a key that is STILL ready never fired — press it once more. Off, combat
    # presses and hopes, exactly as it did before.
    combat_confirm_skills: true,
    combat_confirm_ms: 900,
    # How long the hunt's `:posture` fact stays believable. The cavebot
    # republishes it every tick, so this only has to survive a few missed
    # ticks — and it must stay SHORT, because EXPIRING is what frees combat
    # when the hunt dies in the middle of a mob stretch. Fail-open by ageing,
    # never by someone remembering to say "you may fight again".
    posture_max_age_ms: 3_000,
    # --- Keyboard focus guard --------------------------------------------------------------------
    # System Events keystrokes land in the FRONTMOST app: with the panel focused (watching the
    # activity feed in the browser), every bot key typed into Chrome and the game never saw it —
    # fishing recast forever into the void (2026-07-10). The guard re-fronts the game inside the
    # same keystroke script whenever something else is focused. The game runs under Wine, so
    # System Events knows its process as "wine"; update game_app_name if it ever changes client.
    ensure_game_focus: true,
    game_app_name: "wine",
    # SAFETY: pause everything while the game window isn't frontmost. The Focus poller closes the
    # InputGate (no key/click reaches the OS) and halts the workers the instant focus leaves the
    # game, and reopens + resumes when it returns. This is the fail-safe answer to a stray menu
    # stealing focus overnight and the bot typing into random windows. Off → never pause on focus
    # (the old "re-front then fire" behaviour via ensure_game_focus still applies).
    pause_when_unfocused: true,
    # How often the Focus poller checks the frontmost app. 250ms bounds the reaction to a focus
    # change while keeping the osascript overhead low (the InputGate makes the actual safety
    # independent of this cadence for anything routed through the gate).
    focus_poll_ms: 250,
    # Calibration on ONE monitor: "Capturar tela" fronts the GAME, waits this long for it to
    # render (fullscreen games need a beat after the focus switch), screenshots, and hands focus
    # back to the browser — so the game never has to be shrunk to calibrate. Raise it if the
    # screenshot catches the browser/game mid-transition.
    calibration_front_delay_ms: 700,
    # Cursor setup/teardown: every Body sequence that USES the mouse (cast, ball throw, revive
    # combo) captures the pointer position first and restores it after, so the bot stops
    # teleporting the cursor around while you share the computer with it. ~65ms per mouse
    # sequence (one read + one move); key-only sequences skip it entirely.
    restore_mouse_after_actions: true,
    # A held key dies on its own after this long without a refresh. The cavebot
    # refreshes every tick (200ms), so this is purely the watchdog for a caller
    # that crashed or was halted mid-stride — the one failure that would walk
    # the character away with nobody holding the reins.
    hold_max_ms: 1_500,
    # --- Corpse capture ("still" mode) -------------------------------------------------------------
    # The :corpses feed learns the EMPTY ground at attach: the first warmup frame is the baseline
    # and any 16px cell that deviates during the remaining warmup frames (animated water, sparkles,
    # the character) is masked out forever. After warmup, a masked-diff blob that holds still for
    # corpse_stationary_frames consecutive frames is a corpse (a wandering pet never qualifies).
    # Start the bot with the ground CLEAN — a corpse present at attach becomes part of the baseline.
    feed_corpses_ms: 400,
    corpse_warmup_frames: 20,
    corpse_cell_px: 18,
    # per-channel delta for a sample to count as changed (warmup: mask a cell; scanning: heat it)
    corpse_noise_threshold: 40,
    corpse_diff_threshold: 40,
    # samples per 16px cell = 16 (stride 4); a cell is HOT when this many changed
    corpse_cell_min_samples: 8,
    # a blob needs this many connected hot cells (a corpse sprite spans ~2-3 cells)
    corpse_min_cells: 2,
    corpse_stationary_frames: 2,
    corpse_stationary_tolerance_px: 28,
    # Catcher: one ball in flight at a time, confirmed against the next observations. A hit
    # consumes the corpse instantly (game rule), so a blob that SURVIVES corpse_max_balls
    # throws is not a corpse (a parked pet) → ignored for corpse_ignore_ttl_ms. Confirmation
    # only counts observations captured at least corpse_confirm_after_ms after the throw (the
    # ball needs flight time — an instant re-read would read the pre-hit frame).
    # The GLOBAL player mode: "still" (standing still — automations that need the fixed
    # viewport may act) or "moving" (Lucas is walking around — capture is his).
    player_mode: "still",
    # Independent switches, both only meaningful while parado:
    corpse_match_tolerance_px: 37,
    corpse_max_balls: 2,
    corpse_ignore_ttl_ms: 45_000,
    corpse_confirm_after_ms: 800,
    # N consecutive balls resolved WITHOUT a confirmed capture → :capture
    # alarm (the mirror of fishing's dry_casts_alarm). 0 = off.
    dry_balls_alarm: 4,
    catcher_world_max_age_ms: 1_200,
    # --- Varredura cega (the blind sweep) ---------------------------------------------------------
    # The safety net UNDER the aimed capture: on a slow cadence, a ball at every
    # tile around the character, with no detector involved. Asked for after
    # watching bodies go unclaimed (Lucas, 2026-08-05: "não precisa ser o mais
    # eficiente, mas não perde os pokémon"). Independent of `capture_enabled` on
    # purpose — this is the guarantee you switch on when you stopped trusting
    # the aim, so it must not hang off the aim's own switch.
    sweep_enabled: false,
    sweep_interval_ms: 30_000,
    # 4 = a 9×9 tile square, ~80 balls per pass. `sweep_side` halves it because
    # his fishing spot has the SEA to the left — see Catcher.Sweep.
    sweep_radius_tiles: 4,
    sweep_side: "square",
    # --- Cavebot (waypoint-route hunting) --------------------------------------------------------
    hunt_style: "steady",
    defense_mode_key: "shift+3",
    attack_mode_key: "shift+1",
    cavebot_arrival_tolerance_tiles: 1,
    cavebot_walk_timeout_ms: 3000,
    # Standing still and blind, the client renders no coordinate (it only
    # draws the label while the position CHANGES, or under a hovering mouse) —
    # so a blind cavebot kicks ONE step toward the waypoint at this cadence:
    # movement is what restores sight (Lucas's arrow-walking direction,
    # 2026-08-10).
    cavebot_blind_kick_ms: 1200,
    cavebot_minimap_fact_max_age_ms: 800,
    # MEASURING THE WALK — off, and off means SILENT. On, the hunt emits one
    # `:macro` line per walking decision (`Cavebot.Worker`'s
    # `log_walk_decision/4`) carrying where he was, how far the target was, how
    # old the reading was and what actually went out — the four together answer
    # tiles/s, tiles covered per decision, and "was this decided on a stale
    # reading". `:macro` is the lowest level `Journal` persists, so a whole hunt
    # survives in `~/.pokex/journal/*.jsonl` to be read afterwards.
    #
    # The price is that the line lands in the narrative he reads five times a
    # second, and /cavebot's log box keeps EIGHT lines: measuring on, that box
    # is a rolling 1.6-second window and the waypoints, the 🪜 lines and the
    # blocks scroll away before they can be read. So OFF emits nothing at all —
    # measuring is opt-in and costs exactly zero lines until he asks for it.
    cavebot_measure_walk: false,
    cavebot_stuck_max_retries: 4,
    # A NOITE é o produto: "ele vai estar lá a madrugada inteira farmando"
    # (Lucas). Um bloqueio local — travado, escada não achada, luta que não
    # termina — matava as horas seguintes esperando um humano. Agora a caçada
    # espera e REENTRA na rota (pelo canto mais perto, que é o que destrava um
    # empurrão ou um player que saiu do caminho). Nunca vale para os bloqueios
    # perigosos (mudou de andar, combate recusado): esses travam o pânico e
    # retomar sozinho seria desfazer uma parada de segurança. 0 desliga.
    cavebot_block_retries: 3,
    # Tempo parado antes de tentar de novo — longo o bastante para o obstáculo
    # que se resolve sozinho (um player passando) ter passado.
    cavebot_block_retry_ms: 30_000,
    cavebot_group_min_enemies: 3,
    cavebot_group_max_wait_ms: 4000,
    cavebot_stance_settle_ms: 400,
    cavebot_post_kill_dwell_ms: 1200,
    # After a kill the CAPTURE needs the floor: a sweep is seconds of Body time,
    # while the old fixed dwell was 1.2s — the hunt walked away mid-catch and
    # both workers fought over the hands. The route waits while the Catcher's
    # corpse queue is still MOVING; this is how long a frozen queue holds it
    # before the hunt goes on without it.
    cavebot_capture_wait_ms: 8_000,
    # A sweep asked for by the hunt needs a beat before its queue exists: the
    # Catcher builds the tile list on ITS next cycle, and an empty queue read
    # in between is not a finished sweep. Only this first window is a clock;
    # after it the wait follows the queue's own progress.
    cavebot_sweep_grace_ms: 1_500,
    # The plain "esperar" stop: seconds standing still so cooldowns come back
    # on their own. The revive stop short-circuits this entirely (reviving
    # resets the bar), so this is the fallback for a pokémon with no revive to
    # spend.
    cavebot_stop_wait_ms: 5_000,
    # "quando termino de mobar, eu geralmente dá quatro segundos até todos os
    # bichos se agruparem ao redor do meu" (Lucas, 2026-08-11). Arriving at
    # "até aqui" the pile is still strung out behind him; the fire stays held
    # this long so the area damage lands on a crowd, not on a straggler.
    cavebot_gather_wait_ms: 4_000,
    # The recorder learns this pause from his own hands, and a learned number
    # is only trusted inside a plausible band: his real route came back with
    # 2.0s, 3.3s and 3.6s at three kill spots — and 12.0s at a fourth, which
    # is the recorder having timed something other than a pile closing in.
    # The hunt no longer clamps anything with this band: what it obeys is the
    # ruler he typed (waypoint > route > `cavebot_gather_wait_ms`). This is now
    # only the plausibility filter for what the editor OFFERS on screen — a
    # measurement outside the band is not shown as a suggestion at all.
    cavebot_gather_wait_min_ms: 500,
    cavebot_gather_wait_max_ms: 8_000,
    cavebot_clear_debounce_ms: 800,
    # Recording the route WHILE WALKING: a new waypoint only lands after
    # walking this far since the last one. Without it the route would become
    # one waypoint per tile — the client already pathfinds between points, so
    # what matters is marking the path's corners, not every step.
    cavebot_record_min_tiles: 4,
    # The last tiles are TAPPED, not held. A held arrow keeps walking between
    # readings, so the character always overshoots the final tile — fine on a
    # wide corner, fatal on a staircase one tile wide ("ela é fininha, e ele
    # nao conseguiu achar o spot exato", 2026-08-11). Inside this range the
    # hunt spends one tap per tick instead, trading speed for landing exactly
    # where the waypoint is. 0 turns it off.
    cavebot_precise_tiles: 2,
    # THE STAIRCASE. A recording keeps the tile he LANDED on, and a staircase
    # is taken by STEPPING on it — so from the floor above, the step may be
    # that tile, or beside it, or one past it. Standing on the recorded tile
    # asks for nothing (dx and dy are both zero), which used to time out into a
    # SKIP: on 2026-08-11 the hunt "advanced" waypoints 15 and 16 (floor 2)
    # while he was still on floor 1, walking into the scenery beside the
    # stairs. Now it walks the ring around that tile — one probe this far
    # apart — and gives up with a name instead of walking the wrong floor.
    # "se não tá lutando, ele tá no modo mobado, onde ele não deveria atacar
    # nunca usando a tecla tab — só quando parar de andar e realmente entrar no
    # modo de luta" (2026-08-11). Every fight is a stop on the route: while the
    # hunt walks, the fire is held whether the leg is marked as a gathering or
    # not, and Combat only opens up once the hunt has stopped to fight. false
    # goes back to holding only on marked mob stretches.
    cavebot_fight_only_at_stops: true,
    cavebot_stair_probe_ms: 450,
    # STEPS, not ring entries: 16 is one full lap around the corner (each side
    # and each diagonal, with a step back to the middle between them), 32 is
    # two — about 14 seconds of looking before the hunt stops with a name.
    cavebot_stair_max_probes: 32,
    # ONE KEY, TWO TILES. A staircase is taken with a single arrow press that
    # moves the step AND the tile past it, changing floor on the way — which is
    # why he marks the corner right before and the corner right after. Holding
    # the key instead takes the stair on the first press and then keeps walking
    # on the floor above until the next tick ("a movimentação tá muito ruim
    # ainda", 2026-08-12), so a stair leg TAPS. This is how long to give the
    # client to answer that tap before repeating it: a second key on top of the
    # first is a second staircase.
    cavebot_stair_step_ms: 700,
    # How many taps a staircase gets before the ring search above takes over.
    # The ring is the NET, for the legs whose marking has extra walking folded
    # in — not the road.
    cavebot_stair_step_taps: 3,
    # How many times the park click goes out. One was not enough in the field:
    # "as vezes buga mesmo, nao vai, tem que mandar algumas vezes, umas 4x, pra
    # ter certeza" (2026-08-11). The click is idempotent — the pokémon walks to
    # the same tile — so repeating costs nothing but a few ms.
    cavebot_park_clicks: 4,
    cavebot_park_gap_ms: 120,
    # WHERE the pokémon is sent at a kill spot that has no spot of its own —
    # a distance from the character in TILES, right and down positive. Two of
    # his five kill spots (2026-08-11) carry no recorded click at all, so the
    # pile closed in around HIM. {0, 0} is "on top of me": no click at all,
    # which is what this is until he picks a direction.
    cavebot_park_tiles_x: 0,
    cavebot_park_tiles_y: 0,
    # Recording reads the CLOCK too. Standing still this long lays a waypoint
    # right there even without walking the min tiles: a spot he stopped on is
    # a spot that matters, and it is usually not a corner.
    cavebot_record_dwell_ms: 5_000,
    # …and standing still THIS long is a kill spot: he gathered a pile, killed
    # it and picked it up. The recorder marks it "até aqui" + varrer, and the
    # stretch back to the previous kill spot as the gathering
    # (Pokex.Bots.Cavebot.Recording).
    cavebot_record_fight_dwell_ms: 12_000,
    # Reading intentions off the clock is a big assist and a big assumption:
    # off, the recording is the plain list of places it always was.
    cavebot_smart_recording: true,
    cavebot_fight_timeout_ms: 20_000,
    cavebot_combo_timeout_ms: 6000,
    cavebot_cleanup_timeout_ms: 8000,
    # THE SAFETY LINE. Below this HP the hunt stops gathering, fights what
    # already came (fire freed, kill spot combo out) and holds the route until
    # the pokémon recovers — "não podemos morrer. Estar vivo nesse jogo é
    # muito importante" (2026-08-14). 0 turns the guard off. 60 sits ABOVE the
    # 50% revive threshold on purpose: killing the pile is the first answer,
    # the rescue combo is the second.
    cavebot_hp_abort_pct: 60,
    # …and the route only resumes here: the gap between the two is what stops
    # a heal to 70% from walking straight into the next pile at 55%.
    cavebot_hp_resume_pct: 85,
    # --- Engine ---------------------------------------------------------------------------------
    # HIS RULER. Era três (2026-08-17: "eu realmente mato quando tem uns três") e
    # ele o corrigiu vendo a simulação rodar (2026-08-25): "a gente quer matar
    # quando tem mais do que dois inimigos, dois ou mais". O número sozinho
    # nunca foi a regra inteira — a outra metade é `engine_gather_tiles`.
    engine_engage_from: 2,
    # Whether the hunt GATHERS a pile before hitting it. Gathering is what makes
    # the sizing wait worth paying: drag the mob together, then open with area.
    # Hunting weak creatures that wander in one at a time — and never mob back —
    # the wait is pure loss: the pile never stops growing, the ceiling runs out,
    # and the fight is skipped ("caçar em pokémons mais fracos que não mobam",
    # Lucas 2026-08-24, watching Rattata be walked past). With this off, worth
    # fighting means fight NOW, and a stretch recorded for mobbing is walked
    # with the fire free instead of held.
    #
    # MEDIDO em 25/08, e antes disso não podia ser: o bench respondia
    # `luring?: false` sempre, então o ramo `:gathering` era inalcançável e uma
    # varredura deste botão foi uma varredura de nada. Com um trecho de mobada
    # no cenário da caçada, 5 min × 12 sementes: juntando 7,13 mortos/min contra
    # 6,35 solto, com 0,08 quedas contra 0,25 e menos da metade do tempo no
    # chão. Na régua dele (1) o placar quase empata — o que faz sentido: quem
    # luta tudo não precisa que a pilha se forme.
    engine_gather_piles: true,
    # R6, A SEGUNDA DIMENSÃO DA RÉGUA, e a que faltava: quantos PASSOS vale a
    # pena andar puxando uma pilha que já vale a pena, antes de abrir. Dele,
    # 25/08: "andei dois passos e achei três inimigos, só que eu só andei dois
    # passos. Que que custa eu andar mais 5 passos, fechar mais um, juntar mais
    # monstros e aí matar todo mundo já ao redor". Bem abaixo do `leash_tiles`
    # (12), porque R2 diz que arrastar longe demais faz a pilha SUMIR.
    engine_gather_tiles: 6,
    # …e a paciência do outro lado: andados estes passos sem ninguém novo
    # chegando, vale mais matar o que tem do que continuar procurando. "Ou
    # quando a gente já andou demais e não achou mais ninguém."
    engine_patience_tiles: 10,
    # "Pararam de chegar" needs a floor: how long the count must hold still
    # before the pile counts as closed. A MEASUREMENT, not a preference — his
    # own recording shows 1264, 2543, 3248 and 4806ms of real gathering.
    engine_pile_settle_ms: 1_500,
    # R12 — QUANTO ESPERAR, DEPOIS DE FECHAR A JANELA, pros bichos chegarem
    # perto do pokémon antes de estourar a área.
    #
    # "Fecho essa janela de mob (…) só que, quando fecho, eu tenho que aguardar,
    # por exemplo, cinco segundos, pros bichos se aproximarem do meu pokémon"
    # (27/08). A régua sabia quando PARAR DE JUNTAR e disparava no mesmo tique —
    # e três bichos recém-chegados à lista estão longe, não em cima. Uma área
    # ali pega um e gasta o cooldown dos três.
    #
    # 3s por escolha dele (27/08), depois de corrigir a velocidade dos bichos no
    # simulador — com eles no passo antigo (420ms/tile) a curva pedia 2s, e com
    # o passo de verdade (900ms) ela virou:
    #
    #   espera   lotavanon        formigueiro
    #      0ms   96,3 mortos/min  18,6
    #   2000ms   90,4             21,2
    #   3000ms   92,8             21,9   <- aqui
    #   5000ms   82,7             19,9
    #
    # Ou seja: no anel esparso esperar CUSTA (o valor lá é cobrir chão), e no
    # formigueiro paga +18%. 3s é o meio que ele escolheu, e o knob existe pra
    # quando ele medir o passo de verdade no jogo.
    engine_bunch_ms: 6_000,
    # …e os PASSOS que ela anda antes de parar. "Ele não precisa parar na hora
    # que identificou isso. Ele pode andar um pouquinho até na rota, mais uns 5
    # passos, e parar, porque aí os monstros que ele encontrou lá na frente já
    # vão ter se enfiado um pouco mais no meio deles" (27/08).
    engine_bunch_walk_tiles: 5,
    # QUANTOS BICHOS FAZEM UM BOLO — o alvo que a régua persegue antes de fechar
    # a janela. "Quando encontra dois monstros, pode andar bastante até ter seis
    # monstros; se tiver cinco monstros na tela, pode andar um pouquinho e
    # depois parar" (27/08).
    #
    # Sem isso a janela fechava assim que o bolo valia a pena (`engage_from`, 2)
    # e os passos tinham sido dados — e a caçada abria fogo em dois. A paciência
    # (`engine_patience_tiles`) segue sendo o teto: um bolo que nunca chega no
    # alvo não segura a caçada pra sempre.
    engine_gather_target: 6,
    # …and a ceiling, because R2 says greed makes the pile VANISH: past this,
    # the hunt decides with whatever showed up instead of waiting more.
    #
    # It was 4s — "his longest recorded gather (4806) rounded down", which is a
    # sentence that names its own bug: a ceiling BELOW the slowest pile he ever
    # recorded cuts that pile off every time it happens. It is his complaint of
    # 2026-08-24 in one number ("o cérebro PULA uma pilha de cinco que valia"),
    # and `pilha-que-pinga` reproduces it: at 4s two of five are abandoned, at
    # 8s all five die. Over a whole hunt at his ruler of three, 5,42 → 6,88
    # mortos/min with FEWER falls and less time on the floor. Above his slowest
    # gather now, and still bounded.
    engine_size_ceiling_ms: 8_000,
    # THE BANDS (2026-08-17). Yellow is where the round starts being CLOSED —
    # stop gathering, let the pile arrive, spend everything on it, then revive
    # so the next leg starts full. Red is where nothing is worth waiting for.
    # Both inherit the numbers he had already chosen for the old thresholds.
    engine_band_yellow_pct: 60,
    engine_band_red_pct: 30,
    # R3b — THE REVIVE AS A COOLDOWN RESET, mid-round. Standing in front of a
    # pile still worth fighting with every damage key on cooldown is a round
    # that has already ended: waiting out eight seconds of cooldown buys
    # nothing that one press would not buy at once ("0 cooldowns livres, muitos
    # inimigos ainda na tela… vale a pena usar o revive no F4 rapidinho pra luta
    # seguir firme e forte", Lucas 2026-08-25). The simulator measured the hunt
    # spending 12-23% of every run in exactly that state.
    #
    # OFF by default on purpose. Whether the pokemon comes back with its
    # cooldowns cleared is a fact about the GAME, and it has to be MEASURED
    # before the bot spends presses on it — `/sim`'s "As quatro medições do
    # jogo" reads it off a real hunt.
    #
    # WHICH KEY, settled by him (2026-08-25): **F4 is the whole choreography** —
    # it recalls, uses the revive and puts the pokemon back on the field, all
    # from one press. The hotkey file calls it `ACTION_BAR_4` because it lives
    # in the item bar (the skills are `ACTION_1..12` on 1..9), and that is what
    # `rescue_key: "f4"` presses. Poké Alliance has no "Q recall" any more —
    # `POKEBAR_CYCLE: Q` is still bound in the file and is not one — so the only
    # other way off the field is a real SWAP on `Ctrl+1..6`, which brings out a
    # DIFFERENT pokemon and is a different decision entirely.
    #
    # THE COST THIS MODEL DOES NOT CARRY: if F4 spends a revive item, every
    # proactive press has a price in inventory, not only in the seconds the
    # pokemon is off the field. `Score`'s `revives.accepted` IS that bill.
    #
    # STILL OFF after being measured properly (2026-08-25): with the real floor
    # between two presses in the model, the rule reallocates rescues into resets
    # rather than adding presses, buys 5–9% more monsters, and costs the
    # character health in every run. The lever that actually moves the hunt is
    # `rescue_cooldown_ms` itself — 60s → 30s was +21% monsters in the bench,
    # paid in revive items.
    #
    # LIGADA em 26/08, e o que a ligou foi um vídeo de 53 segundos da caçada
    # dele. Até então este simulador supunha cooldown de 8s; a barra do jogo
    # desenha os segundos que faltam, e eles são **40 a 50**. Com o número certo
    # a caçada fica presa em "sem cooldown" 85% do tempo, e o revive deixa de
    # ser um luxo pra ser o ÚNICO jeito de ter barra.
    #
    # Medido com a barra dele (1 controle, 3–6 área), no circuito denso, 5 min ×
    # 12 sementes:
    #
    #   controle guardado pro resgate   17,97 mortos/min · 2,8 revives/min · ele com 40%
    #   R10, piso de 15s                20,00 mortos/min · 4,3 revives/min · ele com 40%
    #   R10, piso de 5s                 26,72 mortos/min · 9,2 revives/min · ele com 82%
    #
    # O piso é a carteira: 15s é o padrão porque quadruplicar a conta de revives
    # é decisão dele, não minha. Em 5s a regra rende +49% e ele ainda termina
    # mais inteiro — a pilha dorme, então o campo vazio sai de graça.
    engine_reset_revive: true,
    # The floor between two of them, so a fight whose bar stays empty does not
    # become a key held down. It WAS six seconds — comfortably above the game's
    # own rescue cooldown and below a full skill cooldown, and measured on his
    # own settings a faucet: 3,78 revives por minuto e o PERSONAGEM terminando a
    # caçada com 0% de vida, porque cada prensa tira o pokémon de campo e as
    # mordidas passam a ser dele. A curva inteira, 5 min x 12 sementes:
    #
    #   desligada      8,10 mortos/min · 0,38 revives/min · ele com 88%
    #   piso 6s        9,17 mortos/min · 3,78 revives/min · ele com 0%
    #   piso 30s       8,87 mortos/min · 1,85 revives/min · ele com 52%
    #   piso 60s       8,68 mortos/min · 1,43 revives/min · ele com 64%
    #   piso 120s      8,45 mortos/min · 0,98 revives/min · ele com 76%
    # O MESMO PISO, e é aqui que ele estava descompassado: o `settings.json` dele
    # já tinha o resgate em 2s desde agosto, e o reset de cooldown seguia na
    # semente de 15 — a mão andava rápido e o cérebro só pedia de quinze em
    # quinze. Os dois pisos falam do mesmo botão e agora dizem o mesmo número.
    engine_reset_revive_cooldown_ms: 3_000,
    # …e a vida abaixo da qual ele recusa gastar um revive só pra zerar
    # cooldowns. ZERO: ele não recusa por vida.
    #
    # Era 100 — vida CHEIA — por uma varredura de 25/08 que hoje não vale: até
    # 27/08 a janela do controle (`stun_window?`) não passava por
    # `reset_revive?`, então ela ignorava este piso, e a varredura mediu um
    # caminho que quase nunca era tomado. Com a janela obedecendo a regra, o
    # piso passou a MANDAR, e vida cheia virou "quase nunca reseta".
    #
    # Medido em 27/08, 12 sementes × 120s, com a janela exigindo barra gasta:
    #
    #   piso   lotavanon              formigueiro
    #   100%   67,1 mortos/min        22,9
    #    90%   72,5                   23,1
    #
    # 90 era o melhor NAQUELA barra. Com o Golem dele — o primeiro pokémon com
    # aura de defesa classificada, 12 sementes × 120s — a resposta virou:
    #
    #   piso   lotavanon                    formigueiro
    #    90%   93,0 mortos/min · hp mín 35%  25,7 · hp mín 72%
    #    60%   95,7            · hp mín 58%  25,2 · hp mín 72%
    #     0%   95,7            · hp mín 58%  25,2 · hp mín 72%
    #
    # E o rastro DELE decidiu: com a barra gasta e o pokémon em campo, a vida
    # estava abaixo de 90 em UM TERÇO dos tiques (1180 de 3638, 27/08). O piso
    # recusava o revive exatamente quando o pokémon estava machucado — e o
    # revive CURA. Gastar um revive num pokémon ferido é a melhor hora de
    # gastar, não a pior.
    #
    # Segue knob porque a pergunta é legítima e varre; o que era arbitrário era
    # o número.
    engine_reset_revive_min_hp: 0,
    # …and the route only walks again above this.
    engine_resume_pct: 80,
    # A revive that never lands must not end the night standing still.
    engine_recover_timeout_ms: 30_000,
    # Nor may closing a round wait forever for a pile that stopped coming — the
    # ceiling this same number doubles as, for when to give up and revive.
    engine_closing_timeout_ms: 8_000,
    # R5: how long a revive has to prove it landed before the engine calls it a
    # refusal and walks again. Its only job is to be longer than the game takes
    # to put the body back and much shorter than the recovery ceiling — the
    # ceiling spent 47.5% of a bench hunt standing in front of a bar that
    # standing still does not raise.
    engine_revive_confirm_ms: 3_000,
    # Quanto tempo um ninho limpo leva pra voltar, no mundo simulado. Um mapa
    # que esvazia uma vez e fica vazio é uma luta só vestida de noite — foi o
    # que a aba do simulador mostrou até 25/08. Chute dele pra começar ("a cada
    # 20 segundos, por exemplo"), e um dos números mais dignos de medir na
    # caçada de verdade.
    sim_respawn_ms: 20_000,
    # R1 diz pra IGNORAR um ou dois e seguir a vida, e é isso que o padrão faz.
    # A chave existe porque o bench achou o contrário digno de medida: a fase que
    # anda BATENDO mata mais por minuto do que a que anda de mãos baixas, e quem
    # vem atrás de uma pilha abandonada morde o caminho inteiro. Ligada, só as
    # teclas de alvo único — a área é o que a régua está guardando.
    engine_skip_fire: false,
    # R7: com TODAS as teclas de dano em cooldown e bicho em cima, ficar parado
    # é uma troca em que só um lado bate. Andando, eles seguem sem morder, e o
    # fogo segue livre — a primeira tecla que volta sai na hora.
    #
    # LIGADO, mas o veredito MUDOU DE NATUREZA quando o personagem ganhou corpo
    # no mundo simulado (26/08): até então ele atravessava a pilha, e fugir era
    # sempre possível. Com colisão, no formigueiro, 5 min × 12 sementes:
    #
    #   parado    23,92 mortos/min · 0,45 quedas/min · ele termina MORTO
    #   andando   24,27 mortos/min · 0,05 quedas/min · ele termina com 22%
    #
    # Ou seja: o ganho em DANO era artefato de uma fuga sem atrito (era +17%, é
    # +2%). O que sobra é o que importa — SEIS VEZES menos quedas — e o preço
    # aparece: três vezes mais monstros perdidos pra corda. É uma regra de
    # sobrevivência, não de dano.
    engine_kite_when_spent: true,
    # QUANTAS TECLAS DE DANO AINDA PRONTAS ainda contam como "acabou a barra" —
    # a condição que autoriza gastar um revive só pra zerar cooldowns.
    #
    # Era METADE, cravado no código: com sete teclas de dano o revive saía com
    # TRÊS na mão. Ele viu isso na caçada e disse o que quer (27/08): "ele usa
    # muito ressurect à toa (…) a gente tem que usar todas as skills, para
    # depois usar um ressurect, porque ele tem um certo custo que não é de
    # graça". Zero é isso: acabou é acabou.
    #
    # Vira knob e não constante porque a folga de uma tecla pode se pagar quando
    # a que sobrou é a mais fraca da barra — e isso se mede, agora que cada
    # skill tem o próprio cooldown pra medir com.
    engine_spent_keys_left: 0,
    # CHEGAR PREPARADO NO PRÓXIMO GRUPO — a regra dele, dita em 27/08:
    #
    #   "é raro quando uso todas minhas skills realmente esperar cooldown, eu
    #   sempre uso um revive antes de matar o próximo grupo de monstros,
    #   normalmente dá bem certinho depois de matar um grupo usar um revive,
    #   mesmo que nem tenha acabado todos os cooldowns, pra já deixar preparado
    #   pro próximo grupo que logo vai aparecer na tela conforme andarmos"
    #
    # É uma regra de PREPARO, não de emergência: com a tela limpa não há pilha
    # acordada pra machucar ninguém, então ela não precisa do prefixo de
    # controle que a R10 exige — o controle existe pra proteger um revive dado
    # NO MEIO da luta.
    #
    # Ela se limita sozinha: o revive devolve a barra inteira, e a condição é
    # justamente a barra não estar inteira. Um revive por grupo, no máximo.
    engine_prepare_revive: true,
    # R10 — O CONTROLE É UMA SKILL, NÃO UM AMULETO. Ele guardava a tecla de
    # controle só pro resgate, e ele desmentiu isso vendo a própria caçada
    # (26/08): "tento ir usando o 1 pra quando tem muito monstro, pra eu não
    # morrer, porque se eu ficar guardando o 1 nessas hunts mais sérias não dá
    # certo".
    #
    # UM, e não quatro. Medido em 27/08 com a bancada já destravada (32 sementes
    # × 3 cenários × 120s, vida 300, três áreas fortes):
    #
    #     cenário       crowd_from 4   crowd_from 1
    #     lotavanon           71,61          74,78
    #     formigueiro         12,06          19,02   (+58%)
    #     cacada               3,94           4,47
    #
    # Zero quedas nos seis. O denso ganha mais porque era o mais faminto — 80%
    # do tempo sem cooldown.
    #
    # O motivo não é o controle valer mais, é o que vem DEPOIS dele: o revive
    # sai dentro dos cinco segundos (a regra dele) e devolve a barra inteira. Com
    # o limiar em quatro, uma pilha de dois ou três nunca abria essa porta e a
    # barra ficava vazia esperando o cooldown. Com um, toda pilha abre.
    #
    # Nenhum outro knob some com este: `reset_revive_min_hp` a 70 mede o MESMO
    # número junto dele (65,51 nos dois), porque o revive passa a vir pela janela
    # do controle em vez da R3b — e a janela não olha vida.
    engine_crowd_from: 1,
    # GASTAR O MÍNIMO PRA MATAR. "Se ele se identificar aqui com a skill 4
    # sozinha, ele já mata. Ele não precisa ficar usando 4, 5, 6 sempre. Ele
    # pode usar só 4, esperar um pouquinho. Se não matar, usa 5" (26/08).
    #
    # A rajada é cortada no ponto em que o dano MEDIDO já cobre o que o alvo
    # ainda tem. Uma tecla custa `combat_skill_gap_ms` das seguintes e o corpo
    # não anda enquanto ela sai; cortar a cauda devolve esse tempo E o cooldown
    # da tecla que não saiu.
    #
    # Sem dano medido a regra não faz nada: uma tecla sem número conta como zero
    # e nunca é a última, então a ordem sai inteira. Quem não mediu não economiza.
    #
    # SEMEADO DESLIGADO, e não por desacordo: hoje SÓ A BANCADA obedece esta
    # regra (`Strategy.enough/3` tem um único chamador, `Sim.Bench`), porque o
    # mundo simulado já sabe quanto cada tecla tira e o cérebro não — o dano
    # medido vive no `SkillMeter` e não chega ao `Engine.Worker.hands/2`.
    # Ligado por semente, a linha de base de TODO sweep media um bot que corta a
    # cauda enquanto o de verdade gasta a rajada inteira. Um sweep que pergunta
    # sobre a regra passa o knob explicitamente. Ver `Engine.Config.bench_only/0`.
    engine_spend_the_minimum: false,
    # …e a segunda metade da regra dele, que é o que a torna barata: "SEMPRE
    # usar o revive dentro da range de 5 segundos no máximo depois de usar a
    # skill de controle". A pilha está dormindo, então o campo vazio não custa
    # nada — e o revive devolve o controle junto com o resto da barra.
    engine_stun_window_ms: 5_000,
    # …e o que fazer quando o controle NÃO está pronto e a barra está vazia.
    # Desligado, a R3b gasta o revive assim mesmo: um reset atrasado vale mais
    # que um reset que nunca vem. Ligado, ela ESPERA o controle — a regra dele
    # lida ao pé da letra ("SEMPRE usar o revive dentro da range de 5 segundos
    # no máximo depois de usar a skill de controle"), ao preço de deixar a barra
    # vazia por mais tempo.
    #
    # MEDIDO em 26/08 com `since_stun_ms`: dos revives que a regra governa (fase
    # `engaged`), 60% saíam na janela no anel e 40% no formigueiro. Os que
    # faltam são exatamente estes — o controle em cooldown.
    #
    # LIGADO desde 27/08, pelo que ele viu na segunda pilha de uma rota: "ele
    # quase morreu porque ele não tinha o stun de controle disponível para poder
    # usar o revive de forma segura, então ele usou o revive de forma insegura".
    # O revive recolhe o pokémon; sem ninguém dormindo na frente, o que sobra é
    # o personagem apanhando — e ele tem bicho de ataque à distância na hunt.
    #
    # O que NÃO fecha com isto: o resgate do vermelho (é emergência, e emergência
    # não espera cooldown) e o revive de preparo da R11 (tela limpa, não há bolo
    # acordado pra proteger).
    engine_reset_needs_control: true,
    # How often a plain VITALS reading is filed while nothing is changing. The
    # transitions that carry the four measurements are written the instant they
    # happen (see `Engine.Worker.sample_vitals/4`); this is only the heartbeat
    # between them, so a steady fight still produces a rate and a quiet night
    # still costs ~1 line/s.
    engine_vitals_ms: 1_000,
    # How old the hunt's own fact may be before the engine treats it as "no hunt
    # running". Generous against the cavebot's 200ms tick.
    engine_hunt_max_age_ms: 2_000,
    # How old the engine's ORDERS may be before a worker stops obeying them and
    # falls back to what it does on its own. THIS is the number that makes a
    # central brain safe in an eight-hour hunt: an engine that dies stops
    # refreshing, the fact ages out, and the fleet keeps working without it.
    engine_orders_max_age_ms: 1_500,
    # --- Onde estão os monstros (leitura, não regra) ----------------------------------------------
    # How far out `Pokex.Bots.CrowdScan` looks when asked. The box it captures is
    # this many tiles in EVERY direction, so raising it costs area quadratically —
    # 6 already covers more than any area skill in the game reaches.
    crowd_scan_radius_tiles: 6,
    # How much the evidence picture is shrunk before it is drawn. 4 turns a
    # 1812px box into 453px — small enough for a panel, big enough that a missed
    # name is still visibly a name.
    crowd_scan_evidence_shrink: 4,
    # CALIBRATION MODE, off by default: after every area key the bot presses,
    # take one capture and file where the damage landed. It costs a capture per
    # cast, so it is something he turns on for a hunt and off again — the point
    # is to replace `Sim.World`'s invented `aoe_radius: 4` with a number his own
    # screen produced.
    area_probe_enabled: false,
    # MODO DE CHECAGEM, desligado por padrão: com ele ligado, todo aperto de UMA
    # tecla vira uma medida de quanto ela tirou da barra do alvo e de quanto
    # tempo levou pra tirar. Ideia dele por inteiro (26/08), e o que responde
    # "a skill 4 sozinha já mata?" com um número em vez de um palpite.
    skill_meter_enabled: false
  }

  @setting_keys @seed_settings |> Map.keys() |> Enum.sort_by(&Atom.to_string/1)

  # The per-Pokémon settings a preset bundles (~/.pokex/presets/<slug>.json):
  # combat/hook skills, ball and support setup for ONE Pokémon — switchable as a
  # set (mirrors Calibration profiles). Everything else (timings, vision
  # thresholds, calibration) is rig-specific and stays out.
  #
  # `:capture_enabled` LEFT this list (2026-07-30). It had TWO owners — the
  # presets and `Pokex.Modes` — and Lucas's four presets (4attk, 8attk,
  # svileplume, reset) all carried `false`. Switching the attack preset
  # silently disabled capture, and nothing re-enabled it: the Start button
  # does not reapply the mode bundle. Measured in the 2026-07-30 journal:
  # 1015 kills, 1015 loots, ZERO scans. A preset is about WHICH POKÉMON is
  # fighting; toggling a subsystem is an operations decision, and now has one
  # owner (the panel button, with the mode as the initial preset).
  @preset_keys [
    # combat
    :skill_keys,
    # fishing — kill skills and gates
    :hook_skill_keys,
    :require_cooldowns,
    :require_pokemon_hp,
    :pokemon_hp_fishing_pct,
    :rod_key,
    # balls / post-fight
    :corpse_max_balls,
    # support
    :rescue_enabled,
    :rescue_key,
    :pokemon_hp_rescue_pct,
    :potion_enabled,
    :potion_key,
    :pokemon_hp_potion_pct,
    :reposition_enabled,
    # post-fight policy
    :support_waits_capture
  ]

  # The settings that belong to the CHARACTER, not to the machine — they live in
  # `chars/<slug>/settings.json` and follow whoever is active.
  #
  # The ruler: does it change when you sit down as a DIFFERENT character? Which
  # keys he presses to fight, and the gates that make sense at his level, are
  # his. What describes the Mac and the game's pixels (vision thresholds,
  # timings, calibration, sounds) is the machine's and stays single.
  #
  # This list is written OUT BY HAND on purpose — it is NOT `@preset_keys` plus
  # something. A preset answers "which pokémon is fighting"; this answers "whose
  # settings are these". Deriving one from the other is how `:capture_enabled`
  # ended up with two owners and cost 1015 kills with ZERO scans (see the
  # @preset_keys comment above). `:player_mode` is out for the same reason —
  # `Pokex.Modes` owns it.
  #
  # Deliberately small first cut (Lucas, 2026-08-05): skills and the fishing
  # gates. Balls, potion/revive and the mode stay global until this proves
  # itself in the field. Adding a key here is a one-line change; taking one back
  # out silently drops whatever each character had stored for it.
  @character_keys [
    # combat
    :skill_keys,
    # fishing — kill skills and gates
    :hook_skill_keys,
    :require_cooldowns,
    :require_pokemon_hp,
    :pokemon_hp_fishing_pct
  ]

  # ETS mirror of the GLOBAL instance's overrides. Worker ticks read several
  # settings every 80-400ms across many processes; funnelling those through one
  # GenServer serializes every hot loop behind a single mailbox. Reads against
  # the global name hit this table instead; the GenServer stays the only WRITER
  # (:protected), so the "overrides + seed fallback" semantics are unchanged.
  # The mirror holds the ALREADY-RESOLVED layer (base ⊕ character), so switching
  # character costs nothing on the hot path: it stays one lookup.
  @mirror_table :pokex_settings_overrides

  def defaults, do: @seed_settings

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def get(key, server \\ __MODULE__)

  def get(key, __MODULE__) do
    case :ets.lookup(@mirror_table, key) do
      [{^key, value}] -> value
      [] -> Map.get(@seed_settings, key)
    end
  rescue
    # Mirror not up yet (early boot) — take the slow path.
    ArgumentError -> GenServer.call(__MODULE__, {:get, key})
  end

  def get(key, server), do: GenServer.call(server, {:get, key})
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  @doc """
  Resolve `key` from an already-fetched settings map, falling back to the ONE default source
  (`@seed_settings`) when the map omits it. Pure (no GenServer round-trip). Use this instead of
  scattering `settings[:key] || literal` at call sites — a literal there duplicates the default
  and silently DRIFTS from it (e.g. `glow_threshold || 500` while the seed is 1100). Here the
  fallback IS the seed, so there is exactly one place a default can live.
  """
  def value(settings, key) when is_map(settings),
    do: Map.get(settings, key, Map.fetch!(@seed_settings, key))

  # nil is NEVER a legitimate override (load/1 already drops persisted nulls as
  # corruption) — rejecting it here keeps a bad caller from poisoning reads
  # until the next reboot (a panel_live_test cleanup did exactly that: the nil
  # landed in the ETS mirror and randomly broke settings_test — 2026-07-20).
  # Enums and ranges sit on top of the type check. The range ruler: catch the
  # IMPOSSIBLE (negative, absurd), never taste — tuning a value is the panel's
  # job; this is the boundary that keeps an invalid value off the disk.
  # player_mode/mini_game_mode stay out: their owner modules (Modes/Mode)
  # already validate on their own write path.
  @enums %{
    stagnation_action: ~w(alarm stop logout),
    stop_after_action: ~w(stop logout),
    shiny_action: ~w(alarm escape),
    escape_direction: ~w(up down left right),
    hunt_style: ~w(steady mobbed),
    player_mode: ~w(still moving hunt),
    sweep_side: ~w(square right left)
  }

  # THRESHOLD keys whose seed is an integer but which accept fractions (the
  # calibration suggests 45.0 and the 2026-07 test pins that use). A
  # fractional tick_ms would break send_after — hence a named exception, not a
  # general one.
  @number_keys [:glow_threshold]

  @ranges %{
    logout_attempts: 1..99,
    tab_confirm_frames: 1..99,
    tab_max_attempts: 1..99,
    scenery_hunts_needed: 0..99,
    no_damage_ms: 0..600_000,
    after_kill_hold_ms: 0..600_000,
    scenery_ttl_ms: 1_000..3_600_000,
    target_lost_streak: 1..99,
    combat_aoe_from_enemies: 1..20,
    combat_shield_from_enemies: 1..20,
    timers_tick_ms: 100..60_000,
    pokemon_sprite_box_px: 16..512,
    pokemon_track_step_px: 1..64,
    pokemon_track_radius_px: 32..1200,
    pokemon_park_tolerance_px: 1..1200,
    pokemon_hp_heal_pct: 1..100,
    heal_skill_cooldown_ms: 0..600_000,
    dry_casts_alarm: 0..999,
    corpse_sprite_box_px: 8..512,
    corpse_scan_radius_tiles: 1..8,
    corpse_scan_step_px: 2..256,
    capture_aim_settle_ms: 0..5_000,
    capture_hold_ms: 0..5_000,
    corpse_scan_refine_px: 1..64,
    corpse_scan_refine_peaks: 0..32,
    dry_balls_alarm: 0..999,
    sweep_radius_tiles: 1..8,
    # floor 5s: a sweep of 80 tiles already takes ~15s of Body time — a shorter
    # cadence than that would be a sweep that never stops
    sweep_interval_ms: 5_000..3_600_000,
    mini_game_bar_offset_px: -2000..2000,
    mini_game_bar_width_px: 4..2000,
    mini_game_above_px: 0..2000,
    mini_game_strip_height_px: 20..4000,
    tick_ms_watching: 20..600_000,
    tick_ms_default: 20..600_000,
    settle_max_ms: 100..600_000,
    cast_grace_ms: 0..600_000,
    minimap_coord_ink: 40..255,
    hold_max_ms: 200..30_000,
    cavebot_capture_wait_ms: 0..600_000,
    cavebot_gather_wait_ms: 0..60_000,
    cavebot_gather_wait_min_ms: 0..60_000,
    cavebot_gather_wait_max_ms: 0..120_000,
    rescue_confirm_ms: 0..10_000,
    rescue_stun_settle_ms: 0..10_000,
    pokemon_hp_fainted_below_pct: 0..100,
    fainted_revive_cooldown_ms: 0..600_000,
    combat_confirm_ms: 0..10_000,
    cavebot_precise_tiles: 0..10,
    cavebot_stair_probe_ms: 100..5_000,
    cavebot_stair_max_probes: 0..200,
    cavebot_block_retries: 0..50,
    cavebot_block_retry_ms: 100..600_000,
    cavebot_stair_step_ms: 100..10_000,
    cavebot_stair_step_taps: 1..10,
    cavebot_park_clicks: 1..10,
    cavebot_park_tiles_x: -12..12,
    cavebot_park_tiles_y: -12..12,
    cavebot_park_gap_ms: 0..5_000,
    cavebot_record_dwell_ms: 500..600_000,
    cavebot_record_fight_dwell_ms: 1_000..600_000,
    cavebot_sweep_grace_ms: 0..60_000,
    cavebot_stop_wait_ms: 0..600_000,
    cavebot_hp_abort_pct: 0..100,
    cavebot_hp_resume_pct: 1..100,
    # 1 means "fight anything", which is a legal (if greedy) choice; the ceiling
    # is the battle panel's own row count — a ruler above it never engages.
    engine_engage_from: 1..12,
    engine_reset_revive_cooldown_ms: 0..60_000,
    engine_reset_revive_min_hp: 0..100,
    crowd_scan_radius_tiles: 1..20,
    crowd_scan_evidence_shrink: 1..16,
    engine_crowd_from: 1..20,
    engine_spent_keys_left: 0..9,
    engine_stun_window_ms: 500..60_000,
    engine_vitals_ms: 100..60_000,
    engine_pile_settle_ms: 0..60_000,
    engine_bunch_ms: 0..30_000,
    engine_bunch_walk_tiles: 0..30,
    engine_gather_target: 1..20,
    engine_gather_tiles: 0..60,
    engine_patience_tiles: 1..200,
    engine_size_ceiling_ms: 100..600_000,
    engine_band_yellow_pct: 0..100,
    engine_band_red_pct: 0..100,
    engine_resume_pct: 1..100,
    engine_recover_timeout_ms: 1_000..600_000,
    engine_closing_timeout_ms: 100..600_000,
    engine_revive_confirm_ms: 500..600_000,
    sim_respawn_ms: 1_000..600_000,
    engine_hunt_max_age_ms: 200..60_000,
    engine_orders_max_age_ms: 200..60_000,
    posture_max_age_ms: 500..60_000,
    command_corner_dwell_ms: 0..600_000,
    logout_confirm_delay_ms: 0..600_000,
    logout_verify_delay_ms: 0..600_000,
    alarm_min_gap_ms: 0..600_000
  }

  @doc """
  Writes an override. The BOUNDARY validates: type compatible with the seed,
  enum when the key is a closed choice, range when an impossible number would
  break a worker. `{:error, text}` explains in pt-BR (user-facing); no invalid
  value ever reaches the disk.
  """
  def put(key, value, server \\ __MODULE__)
      when is_map_key(@seed_settings, key) and not is_nil(value) do
    case validate(key, value) do
      :ok -> GenServer.call(server, {:put, key, value})
      {:error, _text} = error -> error
    end
  end

  # One rule per clause, in order: a threshold key accepting fractions short
  # circuits, then type, then the closed enum, then the range, then the
  # similarity floor.
  defp validate(key, value) when key in @number_keys and is_number(value), do: :ok

  defp validate(key, value) do
    with :ok <- validate_type(key, value),
         :ok <- validate_enum(key, value),
         :ok <- validate_range(key, value) do
      validate_similarity(key, value)
    end
  end

  defp validate_type(key, value) do
    if valid_type?(key, value),
      do: :ok,
      else: {:error, "#{key}: esperava #{seed_type(key)}, veio #{inspect(value)}"}
  end

  defp validate_enum(key, value) do
    if is_map_key(@enums, key) and value not in @enums[key],
      do: {:error, "#{key}: precisa ser um de #{Enum.join(@enums[key], ", ")}"},
      else: :ok
  end

  defp validate_range(key, value) do
    if is_map_key(@ranges, key) and is_integer(value) and value not in @ranges[key],
      do:
        {:error,
         "#{key}: fora da faixa #{inspect(@ranges[key])} — valor impossível não vai pro disco"},
      else: :ok
  end

  defp validate_similarity(:corpse_match_min_similarity, value) when value < 0 or value > 1,
    do: {:error, "corpse_match_min_similarity: similaridade é 0..1"}

  defp validate_similarity(_key, _value), do: :ok

  defp seed_type(key) do
    seed = Map.fetch!(@seed_settings, key)

    cond do
      is_boolean(seed) -> "boolean"
      is_integer(seed) -> "inteiro"
      is_float(seed) -> "número"
      is_binary(seed) -> "texto"
      list_of_maps?(seed) -> "lista de registros"
      is_list(seed) -> "lista de textos"
      true -> "?"
    end
  end

  # --- per-Pokémon presets ---------------------------------------------------

  def preset_keys, do: @preset_keys

  @doc "The keys that follow the active character (see the moduledoc)."
  def character_keys, do: @character_keys

  @doc "Saves the CURRENT per-Pokémon settings under `name`. {:ok, slug} | {:error, reason}."
  def save_preset(name, server \\ __MODULE__) do
    with {:ok, slug} <- preset_slug(name) do
      data = Map.new(@preset_keys, fn key -> {key, get(key, server)} end)
      File.mkdir_p!(presets_dir())
      Pokex.Home.write!(preset_path(slug), JSON.encode!(data))
      {:ok, slug}
    end
  end

  @doc """
  Applies the named preset: every known, type-valid preset key is put; anything
  else in the file (unknown keys, non-preset keys, hand-edited values with the
  wrong shape) is IGNORED — a bad file must not poison Settings.
  {:ok, %{slug, applied}} | {:error, reason}.
  """
  def apply_preset(name, server \\ __MODULE__) do
    with {:ok, slug} <- preset_slug(name),
         {:ok, bin} <- read_preset(slug),
         {:ok, json} <- JSON.decode(bin) do
      applied =
        for {key_string, value} <- json,
            key = known_key(key_string),
            key in @preset_keys,
            value <- [Legacy.value(key, value)],
            valid_preset_value?(key, value) do
          :ok = put(key, value, server)
          key
        end

      {:ok, %{slug: slug, applied: length(applied)}}
    end
  end

  def delete_preset(name) do
    with {:ok, slug} <- preset_slug(name) do
      File.rm(preset_path(slug))
      :ok
    end
  end

  @doc "Every saved preset: slug, skills summary and saved-at (unix seconds)."
  def list_presets do
    case File.ls(presets_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.map(&preset_entry/1)

      {:error, _no_dir_yet} ->
        []
    end
  end

  @impl true
  def init(opts) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:pokex, :settings_path) ||
        Pokex.Home.settings_file()

    # Persist ONLY the user's overrides. load/1 drops any persisted value equal to today's seed
    # default, which keeps the file to genuine overrides AND self-heals an older file that
    # materialized every key (so a later change to a seed default reaches existing installs).
    # The heal write is BEST-EFFORT: a read-only home must not crash-loop the app on boot — the
    # in-memory overrides are already correct for this run whether or not the rewrite lands.
    overrides = load(path)
    heal(path, overrides)

    # Only the GLOBAL (named) instance owns the mirror — tmp-scoped test
    # instances must not clobber it.
    mirror? = Keyword.get(opts, :name, __MODULE__) == __MODULE__

    state = %{
      path: path,
      data: overrides,
      char: Map.get(overrides, :active_character, ""),
      char_data: %{},
      mirror?: mirror?
    }

    state = %{state | char_data: load_char(state, state.char)}

    if mirror? do
      :ets.new(@mirror_table, [:named_table, :set, :protected, read_concurrency: true])
      :ets.insert(@mirror_table, Map.to_list(effective(state)))
    end

    {:ok, state}
  end

  @impl true
  # Three layers, always in this order: character ⊕ base ⊕ seed. A value the
  # character did not override falls to their base, and one nobody overrode
  # falls to the code seed — which is what makes changing a default in a new
  # build reach whoever never touched that key.
  def handle_call({:get, key}, _from, state), do: {:reply, resolve(state, key), state}

  def handle_call(:all, _from, state),
    do: {:reply, Map.merge(@seed_settings, effective(state)), state}

  # Switching character: the key itself is global (there would be no way to know
  # who is active before knowing who is active), and it reloads their layer.
  def handle_call({:put, :active_character, slug}, _from, state) do
    state = put_global(state, :active_character, slug)
    state = %{state | char: slug, char_data: load_char(state, slug)}

    # `:active_character` is in the sync list itself: it is read through the
    # mirror like any other key (that is how `Team.file/0` knows whose team it
    # is), and syncing only the character keys left the mirror pointing at the
    # PREVIOUS character — switching changed nothing outside the panel.
    {:reply, :ok, mirror_sync(state, [:active_character | @character_keys])}
  end

  def handle_call({:put, key, value}, _from, state) when key in @character_keys do
    if state.char == "" do
      # With no character selected the panel edits the BASE — exactly the
      # behaviour from before this layer existed, and what every new character
      # inherits.
      {:reply, :ok, state |> put_global(key, value) |> mirror_sync([key])}
    else
      {:reply, :ok, state |> put_char(key, value) |> mirror_sync([key])}
    end
  end

  def handle_call({:put, key, value}, _from, state),
    do: {:reply, :ok, state |> put_global(key, value) |> mirror_sync([key])}

  # Setting a value back to the current default is NOT an override — drop it so the key keeps
  # tracking the code default afterwards.
  defp put_global(state, key, value) do
    data =
      if value == Map.fetch!(@seed_settings, key),
        do: Map.delete(state.data, key),
        else: Map.put(state.data, key, value)

    persist!(state.path, data)
    %{state | data: data}
  end

  # The same discipline one layer up: what the character "overrides" with the
  # value already coming from the base is no override at all — it leaves their
  # file and goes back to following the base. Without this, creating a character
  # and saving the form once would freeze the WHOLE current configuration onto
  # them, and touching the base would never reach them again.
  defp put_char(state, key, value) do
    char_data =
      if value == base_value(state, key),
        do: Map.delete(state.char_data, key),
        else: Map.put(state.char_data, key, value)

    persist!(char_path(state, state.char), char_data)
    %{state | char_data: char_data}
  end

  # --- the character layer ---------------------------------------------------

  defp resolve(state, key) do
    case state.char_data do
      %{^key => value} -> value
      _no_character_override -> base_value(state, key)
    end
  end

  defp base_value(state, key), do: Map.get(state.data, key, Map.get(@seed_settings, key))

  # The overrides IN FORCE — what the ETS mirror holds and what `all/1` shows.
  defp effective(state), do: Map.merge(state.data, state.char_data)

  # Only the keys that changed: rewriting the whole table would leave a window
  # where a worker reading mid-switch would fall to the seed instead of the
  # character's value.
  defp mirror_sync(%{mirror?: false} = state, _keys), do: state

  defp mirror_sync(state, keys) do
    effective = effective(state)
    {present, absent} = Enum.split_with(keys, &is_map_key(effective, &1))

    :ets.insert(@mirror_table, Enum.map(present, &{&1, Map.fetch!(effective, &1)}))
    Enum.each(absent, &:ets.delete(@mirror_table, &1))

    state
  end

  # Derived from `state.path` (not from `Home.dir/0`) so a test instance pointed
  # at a tmp keeps its characters in the same tmp.
  defp char_path(state, slug),
    do: Path.join([Path.dirname(state.path), "chars", slug, "settings.json"])

  defp load_char(_state, ""), do: %{}

  defp load_char(state, slug),
    do: load(char_path(state, slug), @character_keys, &base_value(state, &1))

  # Keep ONLY the keys whose value differs from the current seed default. Restores the
  # "store overrides, not a snapshot" contract and self-heals an older materialized file.
  defp load(path), do: load(path, @setting_keys, &Map.fetch!(@seed_settings, &1))

  # `base_fun` says what "is this an override?" is measured against: the code
  # seed for the global file, the already-resolved base value for a character's.
  # Measuring a character's file against the SEED would be a silent bug — they
  # could never take a key back to the code default while their own base
  # overrides that same key.
  defp load(path, keys, base_fun) do
    with {:ok, bin} <- File.read(path),
         {:ok, json} <- JSON.decode(bin) do
      for {key_string, value} <- json,
          key = known_key(key_string),
          key in keys,
          # A JSON null is file corruption, never a legitimate override — keeping
          # it would make Settings.get return nil to code expecting a number.
          not is_nil(value),
          # A value written in Portuguese by an older build becomes today's
          # spelling BEFORE the seed comparison — otherwise a migrated default
          # would be kept as an override forever. The heal write then fixes the
          # file itself, so this runs once per install.
          # The one-element generator BINDS; a plain `=` here would act as a
          # filter and silently drop every `false` override.
          value <- [Legacy.value(key, value)],
          value != base_fun.(key),
          into: %{},
          do: {key, value}
    else
      _ -> %{}
    end
  end

  defp known_key(key_string) do
    Enum.find(@setting_keys, &(Atom.to_string(&1) == key_string))
  end

  defp persist!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    Pokex.Home.write!(path, JSON.encode!(data))
  end

  # The boot-time rewrite that trims a fat/materialized file down to overrides. Never fatal: if
  # the settings dir isn't writable we keep running off the (already-loaded) in-memory overrides.
  defp heal(path, data) do
    persist!(path, data)
  rescue
    error -> Logger.warning("Settings: could not rewrite #{path}: #{inspect(error)}")
  end

  # --- preset helpers --------------------------------------------------------

  defp presets_dir, do: Path.join(Pokex.Home.dir(), "presets")
  defp preset_path(slug), do: Path.join(presets_dir(), slug <> ".json")

  defp read_preset(slug) do
    case File.read(preset_path(slug)) do
      {:ok, bin} -> {:ok, bin}
      {:error, _enoent_or_other} -> {:error, :not_found}
    end
  end

  # Same normalization as Calibration.profile_slug — kept local on purpose: two
  # call sites, no shared "slug" concept worth an abstraction yet.
  defp preset_slug(name) do
    slug =
      name
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/u, "-")
      |> String.trim("-")

    if slug == "", do: {:error, :invalid_name}, else: {:ok, slug}
  end

  # "Valid" = the same SHAPE as the seed default: booleans stay booleans,
  # integers stay integers, key strings stay strings, key LISTS stay lists of
  # strings — enough to keep a hand-edited preset from feeding Settings a
  # value no consumer expects. The SAME type ruler as put/3 — one boundary
  # (the seed dictates the type; float accepts integer).
  defp valid_preset_value?(key, value), do: valid_type?(key, value)

  defp valid_type?(key, value) do
    seed = Map.fetch!(@seed_settings, key)

    cond do
      is_boolean(seed) -> is_boolean(value)
      is_integer(seed) -> is_integer(value)
      is_float(seed) -> is_number(value)
      is_binary(seed) -> is_binary(value)
      # A list key carries EITHER strings (skill keys, muted sectors) or maps
      # (the balls on the hotbar and the rules that pick between them). The seed
      # says which — the same way it says every other type here.
      list_of_maps?(seed) -> list_of_maps?(value)
      is_list(seed) -> is_list(value) and Enum.all?(value, &is_binary/1)
      true -> false
    end
  end

  defp list_of_maps?(value), do: is_list(value) and value != [] and Enum.all?(value, &is_map/1)

  defp preset_entry(file) do
    slug = String.trim_trailing(file, ".json")
    path = preset_path(slug)

    summary =
      with {:ok, bin} <- File.read(path),
           {:ok, json} <- JSON.decode(bin) do
        %{skill_keys: json["skill_keys"], hook_skill_keys: json["hook_skill_keys"]}
      else
        _corrupt -> %{skill_keys: nil, hook_skill_keys: nil}
      end

    saved_at =
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} -> mtime
        _stat_error -> nil
      end

    Map.merge(summary, %{slug: slug, saved_at: saved_at})
  end
end
