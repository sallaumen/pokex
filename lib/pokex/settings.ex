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
  alias Pokex.Settings.Locked

  @seed_settings %{
    # Active character slug (see Pokex.Characters). "" = no character selected — per-character
    # files (chars/<slug>/…) fall back to the legacy shared ones.
    active_character: "",
    rod_key: "shift+v",
    skill_keys: ["1", "2", "3"],
    # Combat does not need the mouse once a target is locked.
    combat_skill_burst_size: 3,
    # From how many enemies on the battle list the fight leads with AREA damage instead of
    # single-target.
    combat_aoe_from_enemies: 3,
    # Whether the hunt spends the single-target keys.
    combat_single_target: false,
    # A PARTIR DE QUANTOS INIMIGOS a aura de DEFESA vale a pena.
    combat_shield_from_enemies: 2,
    # --- Tracking HIS OWN pokémon on screen (Pokex.Bots.PokemonTracker) ---
    # The teach-sized square, and the coarse stride the finder slides it by. The
    # box is a tile and a bit: a pokémon is bigger than a corpse and the taught
    # framing is what the search has to reproduce.
    pokemon_sprite_box_px: 96,
    pokemon_track_step_px: 8,
    # How far around the expected point to look.
    pokemon_track_radius_px: 160,
    # Above this the sighting counts. Lower than the corpse threshold because a
    # pokémon TURNS: the sample that matches is rarely the exact angle.
    pokemon_track_min_similarity: 0.55,
    # How far from the park point still counts as "it got there".
    pokemon_park_tolerance_px: 90,
    # How often the scheduled actions (`Pokex.Timers`) check their clocks.
    timers_tick_ms: 1_000,
    combat_skill_tap_count: 1,
    # The universal gap between two skill presses.
    combat_skill_gap_ms: 300,
    combat_skill_jitter_ms: 100,
    # How long a held modifier waits before the key, in combos like `shift+1`.
    key_modifier_settle_ms: 30,
    # --- Skill-bar cooldown tracking (SkillBar reads the hotbar per-process) ---
    # Legacy fallback when an old calibration has no explicit count. New calibrations
    # ask for 1..10 and persist that fixed geometry; cooldown frames never change it.
    skill_bar_count: 6,
    # A slot reads :ready when its average SATURATION clears this (or the vivid floor below) —
    # readiness is COLOUR, never brightness alone. Under ~20s the game renders the countdown BIG
    # with decimals ("17.6"); that white number lifted average brightness enough that the old
    skill_ready_min_saturation: 25,
    # The countdown NUMBER wins over everything: a slot with at least this % of PURE-white
    # pixels (the glyph body) reads :cooldown regardless of colour — the
    skill_cooldown_min_white_pct: 4,
    # Reference match (preferred, when the calibration carries per-slot references captured with
    # every skill READY): a slot is :ready while its live non-white colour
    skill_ref_max_distance: 25,
    # A slot also reads :ready when at least this % of its pixels are strongly COLOURED (the
    # coloured glyph of a usable icon).
    skill_ready_min_vivid_pct: 7,
    # Fishing gate (toggle in the panel): when true, a bite is HELD (line stays in the water,
    # bubbles keep flashing) and the rod is only pulled once AT LEAST ONE
    require_cooldowns: false,
    # Fishing HP gate (toggle in the panel), the cooldown gate's sibling: when true, a bite is
    # HELD unless the :pokemon blackboard fact says the active Pokémon can
    require_pokemon_hp: false,
    pokemon_hp_fishing_pct: 40,
    # Max age of the :pokemon fact before the fishing gate treats it as unknown.
    pokemon_fact_max_age_ms: 3_000,
    # Which skills the gate watches — it pulls as soon as ANY of them is ready. Lucas
    # uses 4-7 (~40s each) to kill; edit in the panel. These are hotbar keys ("1".."N").
    hook_skill_keys: ["4", "5", "6", "7"],
    # Ceiling on ONE held bite: if no watched skill reads ready for this long, pull anyway
    # (logged loudly).
    hook_hold_max_ms: 180_000,
    # 100 → 150: each watcher tick is ONE capture on the serialized queue, and at 100ms fishing
    # alone asked for ~10 captures/s — drowning the battle feed (2026-07-29
    tick_ms_watching: 150,
    tick_ms_default: 80,
    wait_focus_ms: 20,
    wait_after_equip_ms: 30,
    # Let the cast SPLASH settle before watching, so the line landing isn't read as a bite; then
    # give the game time to finish the hook/reel animation before the next cast.
    wait_cast_settle_ms: 800,
    # Pause between pulling the fish and the next cast. Was 1500 — half a
    # second covers the catch animation; the rest was fish/minute thrown away.
    wait_assess_ms: 700,
    watch_timeout_ms: 30_000,
    # N CONSECUTIVE casts with NO bubbles at all = the rod key is probably not reaching the game
    # (swallowed key, focus, helper) — the screen is the only witness that a cast happened.
    dry_casts_alarm: 3,
    # MAPPED corpses (the glyph approach applied to capture): the library taught in calibration
    # IS the aim — only a candidate whose palette matches a known corpse gets a Pokéball.
    corpse_match_min_similarity: 0.72,
    # side of the square crop (RAW frame px) when photographing/validating a corpse Derived, not
    # measured: this and the corpse lengths below follow the tile, which
    corpse_sprite_box_px: 65,
    # The capture SCAN SQUARE: radius in tiles of the square swept around the character when a
    # kill happens.
    corpse_scan_radius_tiles: 3,
    # DENSE two-phase sweep: coarse step across the whole region, fine refinement around the N
    # best peaks.
    ball_key: "f1",
    ball_needs_click: false,
    # The balls on his hotbar. `ball_key` above is the DEFAULT — what an
    # unrecognised corpse, or one no rule mentions, gets thrown at it.
    ball_types: [
      %{"key" => "f1", "name" => "Poké Ball"},
      %{"key" => "f2", "name" => "Bola de aquáticos"}
    ],
    # WHICH ball for WHICH corpse, read like the combo triggers: naming the creature beats
    # naming what it is made of, and both beat the default.
    ball_rules: [
      %{"trigger" => %{"kind" => "species", "value" => "Tentacool"}, "key" => "f2"},
      %{"trigger" => %{"kind" => "species", "value" => "Krabby"}, "key" => "f2"}
    ],
    # The beat between positioning the cursor and firing the hotkey.
    capture_aim_settle_ms: 30,
    # How long the cursor stays parked on the target after the throw, before the Body returns it
    # to Lucas's spot (restore_mouse_after_actions).
    capture_hold_ms: 120,
    corpse_scan_step_px: 51,
    corpse_scan_refine_px: 8,
    corpse_scan_refine_peaks: 4,
    # Auto-recovery: consecutive NEAR-EMPTY-water frames (bubble px below line_present_min_px —
    # no line in the water) before we assume the cast FAILED (a dropped rod press, or the game
    # itself just not casting, which happens even when Lucas fishes by hand) and re-throw.
    watch_dead_streak_needed: 5,
    # ...but the streak only starts counting THIS long after the cast.
    cast_grace_ms: 5_000,
    # A locked target that hasn't died in this long isn't a real hostile (our own
    # pokemon) or is hopelessly tanky → drop it and try the next battle row.
    fight_timeout_ms: 6000,
    # Min cyan pixels for a BITE.
    glow_search_margin: 192,
    # Inside the expanded region, find the red/orange lure first, then count cyan
    # only near it. This keeps random water sparkles from looking like a live line.
    fishing_lure_min_pixels: 20,
    fishing_bubble_radius_px: 64,
    glow_threshold: 1100,
    # Legacy/raw fallback for line presence when a sensor only returns an integer.
    line_present_min_px: 100,
    max_consecutive_failures: 5,
    wild_min_red_pixels: 12,
    # A SINGLE bite-magnitude frame (> glow_threshold) hooks.
    glow_streak_needed: 1,
    # Consecutive below-threshold (resting/splash level) frames before a cyan spike
    # counts as a bite. Guards against a splash that briefly clears glow_threshold.
    calm_streak_needed: 3,
    # TIME ceiling on settling: past this since the cast, the water has settled BY PHYSICS (the
    # splash lasts ~1-1.5s) even if the calm frames never accumulated.
    settle_max_ms: 2_500,
    # Height (points) of ONE battle-list row = the vertical spacing between rows.
    battle_row_height: 30,
    # Where row 0's band is CENTERED inside the battle region, in points.
    battle_first_row_y: 31,
    # How many rows the reader is willing to bucket creatures into.
    battle_max_rows: 10,
    # Min bright-red (r>=200,g<=60,b<=60) px on a scanline of the rightmost strip for it to
    # count as the OWN-pokemon pokeball (so that row is EXCLUDED from attack candidates).
    pokeball_min_red_px: 5,
    # Screen points per game tile — the ruler for everything measured FROM THE CHARACTER.
    tile_px: 151,
    # /diagnostics still shows the per-row red target-ring read for manual inspection; this is
    # the threshold it uses (a real ring is 600-900 red px, the unlocked baseline ~40-150).
    target_locked_min_pixels: 120,
    # Consecutive ticks the enemy must be GONE from the Battle list before the fight is
    # declared over — filters a 1-frame HP-bar blink on a hit/death animation.
    target_lost_streak: 1,
    # What the bot DOES when the overlay opens (see Pokex.Bots.MiniGame.Mode): "manual_assist"
    # (default, safe: detect + hold the other workers + alert, Lucas plays),
    mini_game_mode: "manual_assist",
    # How often the "resolve o minigame" alert repeats while a manual game waits.
    mini_game_manual_alert_ms: 5_000,
    # Per-game diagnostics (always collected, in every mode — a game Lucas played by hand is the
    # most informative recording there is).
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
    # Half-width of the mini-game band; the rest comes from the anchors (character above,
    # skill bar below).
    mini_game_bar_offset_px: 12,
    mini_game_bar_width_px: 24,
    mini_game_above_px: 16,
    mini_game_strip_height_px: 474,
    # Half-width (screen points) of the window around the player point where the bar may sit.
    mini_game_anchor_tolerance: 70,
    # Playing the mini-game (hold/release Space chasing the fish).
    mini_game_play_tick_ms: 80,
    mini_game_min_toggle_ms: 50,
    # End-of-game detection is DEFENSE IN DEPTH — the "track gone" exit streak alone hung the
    # whole bot (2026-07-20): after a WIN the world behind the strip held a
    mini_game_no_capsule_exit_ticks: 25,
    # Hard duration cap per game — the backstop for ANY unseen wedge (same philosophy as
    # hook_hold_max_ms): no real game lasts minutes; a "game" that does is a stuck reading.
    mini_game_max_game_ms: 90_000,
    mini_game_deadband_pct: 0.011,
    # Stopping-distance braking (track/s²), per direction — the REAL game is asymmetric: thrust
    # arrests a fall almost instantly (brake late: sink to the fish before
    mini_game_fish_max_speed: 2.0,
    # ...unless the last plausible reading is older than this — then the new reading is adopted
    # and the history restarts (bounded blindness beats chasing ghosts, and
    mini_game_fish_reacquire_ms: 700,
    mini_game_brake_up: 0.8,
    mini_game_brake_down: 3.0,
    # Browser alert on enter/leave (panel mute button). Muting stops the panel
    # from pushing the sound event at all.
    mini_game_sound: true,
    # Session ALARMS (panel): sound on a worker error edge or the Pokémon's HP crossing below
    # the rescue threshold.
    alarm_sound: true,
    alarm_min_gap_ms: 30_000,
    # Per-SECTOR mute (Lucas, 2026-07-30: too noisy, asked for per-sector alert config).
    alarm_muted_categories: [],
    # Stop conditions (hunt goals): the Guardian halts the WHOLE fleet — with the same latch as
    # the panic corner, so nothing auto-resumes until Iniciar — when the running session crosses
    stop_after_minutes: 0,
    stop_after_kills: 0,
    # What to do when a goal is hit: "stop" latches everything like Stop;
    # "logout" logs the account out — which is what actually saves stamina.
    stop_after_action: "stop",
    # The COMMAND corner (top right): holding the mouse there for command_corner_dwell_ms
    # toggles the last used mode — from INSIDE the game, without clicking the
    command_corner: true,
    command_corner_dwell_ms: 600,
    # Shiny guard: watches for the special colours of shinies and bosses
    # (docs/shiny/plano-shiny-por-cor.md).
    shiny_guard_enabled: false,
    # A shiny ALWAYS deserves a pokéball, even with capture_enabled off.
    shiny_always_ball: true,
    # Colour-scan cadence (the SpotScan square) and how many CONSECUTIVE scans with a blob
    # confirm a sighting.
    special_color_scan_ms: 700,
    special_color_confirm_frames: 2,
    # Anti-stagnation: an ACTIVE session with no sign of life for this window is a stuck bot
    # (empty water, wedged detector, dead spot).
    stagnation_minutes: 0,
    stagnation_action: "alarm",
    # Escape WALK (the flee protocol): clicking ON a ladder tries to USE it, which only works
    # when adjacent (Lucas, live 2026-07-20) — so escape_point is a WALKABLE
    escape_direction: "right",
    escape_steps: 2,
    escape_walk_wait_ms: 2_000,
    # Auto-logout: actually end the session — STOPPING the bot saves no stamina, which burns
    # while the character is online.
    logout_key: "ctrl+q",
    logout_confirm_key: "enter",
    logout_confirm_delay_ms: 300,
    # Time given to the screen to switch before the first check. If Lucas's
    # screen takes longer, one attempt is wasted — it still converges.
    logout_verify_delay_ms: 1_500,
    logout_attempts: 3,
    # Max age of the :mini_game WorldState fact before readers treat it as unknown (= not
    # playing, fail-open).
    mini_game_fact_max_age_ms: 2_000,
    humanize_max_ms: 0,
    # Anti-bot: a RANDOM 0..this ms jitter before each CAST (the rod throw), so the bot doesn't
    # fish on a perfectly fixed cadence.
    cast_delay_max_ms: 250,
    # Anti-bot: once a bite is confirmed, wait a RANDOM hook_delay_min..max ms before pulling.
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
    # The floor between two rescues. Measured on the dense circuit with the stun before the
    # revive: a 2s floor gave zero falls, a 3s floor doubled the dead.
    rescue_cooldown_ms: 3_000,
    # ms between the stun prefix and the revive so the game registers each.
    rescue_step_ms: 40,
    # How long to wait for a skill-bar reading NEWER than the crowd-control press, before giving
    # up on confirming it.
    rescue_confirm_ms: 900,
    # …and the receipt is NOT the sleep.
    rescue_stun_settle_ms: 2_000,
    # The other half of the window: how long the pokémon takes to cast again AFTER the
    # revive.
    rescue_blackout_ms: 2_000,
    # MORREU.
    pokemon_hp_fainted_below_pct: 35,
    # Seat belt after reviving a fainted pokémon.
    fainted_revive_cooldown_ms: 3_000,
    # Stun BEFORE reviving (2026-07-30): hunting strong mobs, the pokémon's own area-control
    # keys are reserved for this moment and become the PREFIX of the same
    revive_dry_action: "logout",
    rescue_stun_first: true,
    # The main Pokémon's own HEALING SKILL — the rung above the potion.
    heal_skill_enabled: true,
    pokemon_hp_heal_pct: 70,
    # Anti-spam only: whether the skill is UP is the skill bar's answer, not a
    # guess kept here.
    heal_skill_cooldown_ms: 3_000,
    # The defence aura, one rung above the heal: below this HP enough enemies are hitting
    # him to be worth the buff. Fires only when the bar reads ready.
    shield_skill_enabled: true,
    pokemon_hp_shield_pct: 85,
    shield_skill_cooldown_ms: 3_000,
    # …and before the chain: the revive restores the bar every chain, so the pokémon rarely
    # drops to 85% and the aura would never fire by HP. With the pile closing (the brain in
    # `:bunching`, standing and waiting for the pile) and the aura ready, it fires, full HP
    # or not.
    shield_on_mob_enabled: true,
    # How often the PlayerSupport samples the main Pokémon's HP bar.
    support_tick_ms: 120,
    # HP-bar fill detection is COLOUR-AGNOSTIC: a column counts as filled when it holds a
    # COLOURED pixel (bright enough to not be black, saturated enough to not be the white
    pokemon_hp_min_brightness: 45,
    pokemon_hp_min_saturation: 30,
    # The HP bar's tips are ROUNDED: the last few columns of the calibrated box never hold a
    # coloured pixel even at genuinely full health, so the raw column-fill can
    pokemon_hp_full_at_pct: 100,
    # Sanity floor on the HP read: at least this % of the region's pixels must be the bar's own
    # two populations (warm fill + near-black track).
    pokemon_hp_min_known_pct: 55,
    # How bright the bar's EMPTY track is allowed to be, and the reason the floor above is
    # survivable.
    pokemon_hp_max_track_brightness: 75,
    # A uniformly DARK strip is a covered window, not an empty bar: every dark pixel used to
    # count as the bar's empty track, so the browser in front of the game read
    pokemon_hp_min_bright_pct: 10,
    # --- Status cure: the Status Potion in front of every attack --------------------------------
    # His pokémon can be asleep, silenced or frozen when the chain goes out, and in that state the
    # combo key does nothing: no skill leaves, the bar is not spent, and the bot keeps pressing at
    # a mob that keeps hitting. The E slot cures every negative status and is a NO-OP when there is
    # none to cure, so the prefix costs time and never an item. Auto Combo cleans before every
    # chain (its 4s window caps it at ~15/min); the other modes clean once per fight — see
    # `Combat.Plan.cure_policy/1`.
    status_cure_enabled: true,
    status_cure_key: "e",
    # How long the game gets to apply the potion before the attack leaves.
    status_cure_settle_ms: 100,
    # --- Potion: cheap top-up so the expensive revive rarely fires ------------------------------
    # Below pokemon_hp_potion_pct AND out of combat (the heal channel is interrupted by entering a
    # fight, so an in-combat potion is a wasted potion), press potion_key — the game applies it to
    # the active Pokémon by itself, no mouse needed. The cooldown covers the heal channel: firing
    # again mid-channel wastes a potion, so wait it out before another sip.
    potion_enabled: false,
    potion_key: "e",
    pokemon_hp_potion_pct: 70,
    potion_cooldown_ms: 10_000,
    # One out-of-combat read is NOT "battle over": fished enemies re-aggress in the post-kill
    # gap and the game cancels the heal channel, wasting the potion.
    potion_battle_clear_ms: 2_000,
    # After every battle, middle-click the calibrated pokemon_spot_point to send the Pokémon
    # back to its strategic tile (toggle in the panel).
    reposition_enabled: false,
    reposition_battle_clear_ms: 2_000,
    # Pokéballs are only thrown with this on. Capture is the only item use left (F1/F2): the
    # game picks up the loot by itself.
    capture_enabled: true,
    # Post-fight ORDER policy (ball → support): with this on, a due potion/reposition ALSO waits
    # for the catcher to resolve its pending corpses (queued + ball in flight) before acting.
    support_waits_capture: false,
    support_capture_wait_max_ms: 10_000,
    # --- Perception feeds -----------------------------------------------------------------------
    # Capture cadence per feed. A feed only captures while a consumer is attached, so these are
    # upper bounds on broker demand, not constant costs. battle is the combat hot path; arena has
    # no consumer today (the Loot walk that read it is gone) — kept registered for a future
    # feature that wants `arena_region` again, at effectively zero cost while unattached.
    feed_battle_ms: 120,
    # The skill hotbar changes at ~1s granularity (countdown numbers), so its feed runs far
    # slower than battle; it only captures while combat is attached anyway.
    feed_skill_bar_ms: 400,
    # How old the :skill_bar fact may be before combat treats it as UNKNOWN (→ blind rotation).
    skill_bar_fact_max_age_ms: 1_500,
    # Consecutive failed captures (bad region, or the OS revoked Screen Recording mid-run) a
    # feed tolerates at :debug before it escalates to a loud Logger.warning.
    feed_failure_warn_streak: 10,
    # HUD numbers change slowly (stocks, level); position changes as fast as Lucas walks, so the
    # minimap is read more often than the rest.
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
    # MEASURED, not guessed: between two captures the coordinate moved (-5,-11) tiles while the
    # map image shifted (+10,+22) pixels — 2px per tile on both axes, at 98.5% correlation.
    minimap_px_per_tile: 2,
    # Ink floor of the minimap COORDINATE strip.
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
    tab_confirm_frames: 1,
    tab_max_attempts: 3,
    hunt_cooldown_ms: 1_500,
    # SCENERY (unattackable) pokémon parked in the list: N complete consecutive hunts — each
    # with tab_max_attempts Tabs WITH frame evidence and no lock — promote
    scenery_hunts_needed: 3,
    # A row Combat gave up on is re-probed when this expires (3 Tabs, ~8s).
    scenery_ttl_ms: 300_000,
    # THE STALEMATE.
    no_damage_ms: 8_000,
    # ONE fight at a time, when he wants it: how long combat waits after a kill before hunting
    # anything else.
    after_kill_hold_ms: 0,
    skill_burst_every_ms: 300,
    # After every kill/timeout rehunt (and on a fish hook), hunting keeps PROBING with blind
    # Tabs for this long even when the HP-bar detector reports no enemy —
    hunt_probe_window_ms: 8_000,
    # Battle observations older than this are treated as unknown by combat (fail-safe: no keys).
    combat_world_max_age_ms: 2_500,
    # Hunting is not fishing: a skill that silently never left is damage he is not doing while a
    # pile eats him.
    combat_confirm_skills: true,
    combat_confirm_ms: 900,
    # How long the hunt's `:posture` fact stays believable.
    posture_max_age_ms: 3_000,
    # --- Keyboard focus guard --------------------------------------------------------------------
    # System Events keystrokes land in the FRONTMOST app: with the panel focused (watching the
    # activity feed in the browser), every bot key typed into Chrome and the game never saw it —
    # fishing recast forever into the void (2026-07-10). The guard re-fronts the game inside the
    # same keystroke script whenever something else is focused. The game runs under Wine, so
    # System Events knows its process as "wine"; update game_app_name if it ever changes client.
    ensure_game_focus: true,
    game_app_name: "wine",
    # SAFETY: pause everything while the game window isn't frontmost.
    pause_when_unfocused: true,
    # How often the Focus poller checks the frontmost app.
    focus_poll_ms: 250,
    # Calibration on ONE monitor: "Capturar tela" fronts the GAME, waits this long for it to
    # render (fullscreen games need a beat after the focus switch),
    calibration_front_delay_ms: 700,
    # Cursor setup/teardown: every Body sequence that USES the mouse (cast, ball throw, revive
    # combo) captures the pointer position first and restores it after, so
    restore_mouse_after_actions: true,
    # A held key dies on its own after this long without a refresh.
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
    # Catcher: one ball in flight at a time, confirmed against the next observations.
    player_mode: "still",
    # Independent switches, both only meaningful while parado:
    corpse_match_tolerance_px: 37,
    corpse_max_balls: 2,
    corpse_ignore_ttl_ms: 45_000,
    corpse_confirm_after_ms: 800,
    # N consecutive balls resolved WITHOUT a confirmed capture → :capture
    # alarm (the mirror of fishing's dry_casts_alarm). 0 = off.
    dry_balls_alarm: 4,
    # --- Blind sweep ------------------------------------------------------------------------------
    #
    # The safety net UNDER the aimed capture: on a slow cadence, a ball at every tile around
    # the character, with no detector involved. Not efficient, but no body goes unclaimed.
    # Independent of `capture_enabled` on purpose: this is the guarantee you switch on when
    # you stopped trusting the aim, so it must not hang off the aim's own switch.
    sweep_enabled: false,
    sweep_interval_ms: 30_000,
    # 4 = a 9×9 tile square, ~80 balls per pass. `sweep_side` halves it because
    # his fishing spot has the SEA to the left — see Catcher.Sweep.
    sweep_radius_tiles: 4,
    sweep_side: "square",
    # --- Cavebot (waypoint-route hunting) --------------------------------------------------------
    # Which combat strategy the hunt runs when the route does not pick one. `auto_combo` is
    # the default: the game chains the offensive skills behind ONE key, so the bot presses
    # once and only manages the revive. `economy` is the cheap route: Tab, single target,
    # area only when still needed. See `Pokex.Bots.HuntMode`: the route wins, this is the
    # floor.
    hunt_mode: "auto_combo",
    # The combo key and how long it occupies the hands.
    auto_combo_key: "r",
    auto_combo_window_ms: 4_000,
    defense_mode_key: "shift+3",
    attack_mode_key: "shift+1",
    cavebot_arrival_tolerance_tiles: 1,
    # How long without the brain before the hunt stops. Orders are republished every tick
    # (200ms): five seconds of silence is a dead brain, and hunting without it is hunting
    # without revive.
    cavebot_brain_gone_ms: 5_000,
    cavebot_walk_timeout_ms: 3000,
    # Standing still and blind, the client renders no coordinate (it only draws the label while
    # the position CHANGES, or under a hovering mouse) — so a blind cavebot
    cavebot_blind_kick_ms: 1200,
    cavebot_minimap_fact_max_age_ms: 800,
    # MEASURING THE WALK — off, and off means SILENT.
    cavebot_measure_walk: false,
    cavebot_stuck_max_retries: 4,
    # The whole night is the product: the bot farms unattended for hours.
    cavebot_block_retries: 3,
    # Time standing still before retrying: long enough for a self-resolving obstacle (a
    # passing player) to clear.
    cavebot_block_retry_ms: 30_000,
    cavebot_post_kill_dwell_ms: 1200,
    # After a kill the CAPTURE needs the floor: picking a corpse up is seconds of Body time,
    # while the old fixed dwell was 1.2s — the hunt walked away mid-catch and both workers
    cavebot_capture_wait_ms: 8_000,
    # Still standing ON the tile of the last skip, the walk timeout shrinks to this: every
    # unstick nudge already failed from that exact tile, so one second of walking answers "did
    cavebot_pinned_probe_ms: 1_000,
    # The plain "esperar" stop: seconds standing still so cooldowns come back on their own.
    cavebot_stop_wait_ms: 5_000,
    # After luring, the mobs take about four seconds to gather around the pokémon (his
    # measurement).
    cavebot_gather_wait_ms: 4_000,
    # The recorder learns this pause from his own hands, and a learned number is only trusted
    # inside a plausible band: his real route came back with 2.0s, 3.3s and
    cavebot_gather_wait_min_ms: 500,
    cavebot_gather_wait_max_ms: 8_000,
    cavebot_clear_debounce_ms: 800,
    # Recording the route WHILE WALKING: a new waypoint only lands after walking this far since
    # the last one.
    cavebot_record_min_tiles: 4,
    # The last tiles are TAPPED, not held.
    cavebot_precise_tiles: 2,
    # THE STAIRCASE.
    cavebot_fight_only_at_stops: true,
    cavebot_stair_probe_ms: 450,
    # STEPS, not ring entries: 16 is one full lap around the corner (each side and each
    # diagonal, with a step back to the middle between them), 32 is two — about 14
    cavebot_stair_max_probes: 32,
    # ONE KEY, TWO TILES.
    cavebot_stair_step_ms: 700,
    # How many taps a staircase gets before the ring search above takes over.
    cavebot_stair_step_taps: 3,
    # How many times the park click goes out.
    cavebot_park_clicks: 4,
    cavebot_park_gap_ms: 120,
    # WHERE the pokémon is sent at a kill spot that has no spot of its own — a distance from the
    # character in TILES, right and down positive.
    cavebot_park_tiles_x: 0,
    cavebot_park_tiles_y: 0,
    # Recording reads the CLOCK too.
    cavebot_record_dwell_ms: 5_000,
    # …and standing still THIS long is a kill spot: he gathered a pile, killed it and picked it
    # up.
    cavebot_record_fight_dwell_ms: 12_000,
    # Reading intentions off the clock is a big assist and a big assumption: off, the recording
    # is the plain list of places it always was.
    cavebot_smart_recording: true,
    cavebot_fight_timeout_ms: 20_000,
    # --- Engine ---------------------------------------------------------------------------------
    # HIS RULER for when the pile is worth the area, moved several times (3, then 2, then
    # 6): the last one wins. The bench cannot tell the values apart (16.9-18.3 kills/min for
    # every value from 1 to 8 on his route) because `engine_gather_target` already decides
    # when the window closes and the simulated pile grows fast. In his game the ruler does
    # bite: a pair that never becomes a pile is a spent bar on two mobs.
    engine_engage_from: 6,
    # Whether the hunt GATHERS a pile before hitting it.
    engine_gather_piles: true,
    # …and the patience on the other side: after this many steps with nobody new arriving,
    # killing what is here beats searching on.
    engine_patience_tiles: 10,
    # "Pararam de chegar" needs a floor: how long the count must hold still before the pile
    # counts as closed.
    engine_pile_settle_ms: 1_500,
    # R12: how long to wait after closing the window for the mobs to reach the pokémon
    # before the area fires.
    engine_bunch_ms: 6_000,
    # How many mobs make a pile: the target the ruler chases before closing the window.
    engine_gather_target: 6,
    # …and a ceiling, because R2 says greed makes the pile VANISH: past this the hunt
    # decides with whatever showed up. It OPENS if the pile is worth the area and SKIPS if
    # not. The patience in steps must fit: 10 steps fit in 8s, 20 steps need ~16s.
    engine_size_ceiling_ms: 8_000,
    # THE BANDS (2026-08-17).
    engine_band_yellow_pct: 60,
    engine_band_red_pct: 30,
    # R3b — THE REVIVE AS A COOLDOWN RESET, mid-round.
    engine_reset_revive: true,
    # The floor between two of them, so a fight whose bar stays empty does not become a key held
    # down.
    engine_reset_revive_cooldown_ms: 3_000,
    # …and the HP below which a revive is not spent just to reset cooldowns.
    engine_reset_revive_min_hp: 0,
    # …and the route only walks again above this.
    engine_resume_pct: 80,
    # A revive that never lands must not end the night standing still: the request slows
    # down to one per half minute…
    engine_recover_timeout_ms: 30_000,
    # …and gives up here.
    engine_downed_give_up_ms: 300_000,
    # R11 on the road: how many leftovers on screen still count as "between groups".
    engine_prepare_max_enemies: 2,
    # The revive stock he typed in. Typing IS the restock button: the ReviveLedger count
    # resets when the number changes.
    revive_stock: 0,
    # Revives kept for emergencies: the convenience rules (prepare, reset) stop spending at
    # this count; red and fainted spend to the end.
    engine_revive_reserve: 5,
    # The CHARACTER's HP (the red bar of the "Pokémon" panel): below this for two readings
    # the support alarms, and logs out if player_hp_logout is on.
    player_hp_floor_pct: 50,
    player_hp_logout: false,
    # Nor may closing a round wait forever for a pile that stopped coming — the
    # ceiling this same number doubles as, for when to give up and revive.
    engine_closing_timeout_ms: 8_000,
    # R5: how long a revive has to prove it landed before the engine calls it a refusal and
    # walks again.
    engine_revive_confirm_ms: 3_000,
    # R7: with every damage key cooling and mobs on top, standing still is a trade where
    # only one side hits.
    engine_kite_when_spent: true,
    # …and the longest a retreat may last.
    engine_kite_max_ms: 20_000,
    # How many damage keys still ready count as "bar spent": the condition that allows a
    # revive just to reset cooldowns.
    engine_spent_keys_left: 0,
    # Arrive prepared at the next group: rather than wait out the cooldowns, spend a revive.
    engine_prepare_revive: true,
    # R10: the control key is a skill, not an amulet.
    engine_crowd_from: 1,
    # …and the second half of his rule, the part that makes it cheap: the revive ALWAYS goes
    # out within 5s of the control key.
    engine_stun_window_ms: 5_000,
    # How long his control holds, counted from the PRESS. Measured by him: 2s to land (the
    # same settle the rescue waits for) + 5s of sleep = 7s of cover.
    engine_stun_hold_ms: 7_000,
    # Boss names, comma-separated.
    engine_boss_names: "",
    # A boss by time-to-kill: how many damage skills DELIVERED (cooldown moved) with no body
    # dropping from the pile before the brain declares a boss.
    engine_boss_grit: 10,
    # How many tiles his control reaches, the gate of the boss stun: pressing with the
    # target beyond it stuns the wind.
    engine_stun_reach_tiles: 3,
    # QUANTO TEMPO um reset desarmado fica fora do jogo antes de tentar de novo.
    engine_reset_rearm_ms: 600_000,
    # How often a plain VITALS reading is filed while nothing is changing.
    engine_vitals_ms: 1_000,
    # How old the hunt's own fact may be before the engine treats it as "no hunt
    # running". Generous against the cavebot's 200ms tick.
    engine_hunt_max_age_ms: 2_000,
    # How old the engine's ORDERS may be before a worker stops obeying them and falls back to
    # what it does on its own.
    engine_orders_max_age_ms: 1_500,
    # --- Where the monsters are (a reading, not a rule) --------------------------------------------
    # How far out `Pokex.Bots.CrowdScan` looks when asked. The box it captures is
    # this many tiles in EVERY direction, so raising it costs area quadratically —
    # 6 already covers more than any area skill in the game reaches.
    # The waiting eye (phase 1): photographs around the pokémon while the brain waits for
    # the pile and writes to the feed how many stand within 1 tile. It only measures.
    crowd_watch_enabled: true,
    crowd_scan_radius_tiles: 6,
    # How much the evidence picture is shrunk before it is drawn.
    crowd_scan_evidence_shrink: 4,
    # CALIBRATION MODE, off by default: after every area key the bot presses, take one capture
    # and file where the damage landed.
    area_probe_enabled: false,
    # Check mode, off by default: every single-key press becomes a measurement of how much
    # it took from the target's bar and how long it took.
    skill_meter_enabled: false
  }

  @setting_keys @seed_settings |> Map.keys() |> Enum.sort_by(&Atom.to_string/1)

  # The per-Pokémon settings a preset bundles (~/.pokex/presets/<slug>.json): combat/hook
  # skills, ball and support setup for ONE Pokémon — switchable as a set (mirrors Calibration
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
  @character_keys [
    # combat
    :skill_keys,
    # fishing — kill skills and gates
    :hook_skill_keys,
    :require_cooldowns,
    :require_pokemon_hp,
    :pokemon_hp_fishing_pct
  ]

  # ETS mirror of the GLOBAL instance's overrides.
  @mirror_table :pokex_settings_overrides

  def defaults, do: @seed_settings

  @doc "Is this key a constant: it exists, it shows, and the file does not rule it?"
  @spec locked?(atom) :: boolean
  defdelegate locked?(key), to: Locked

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

  # nil is NEVER a legitimate override (load/1 already drops persisted nulls as corruption) —
  # rejecting it here keeps a bad caller from poisoning reads until the next reboot (a
  # panel_live_test cleanup did exactly that: the nil landed in the ETS mirror and randomly
  @enums %{
    stagnation_action: ~w(alarm stop logout),
    revive_dry_action: ~w(alarm stop logout),
    stop_after_action: ~w(stop logout),
    escape_direction: ~w(up down left right),
    hunt_mode: ~w(auto_combo economy),
    player_mode: ~w(still moving hunt),
    sweep_side: ~w(square right left)
  }

  @doc "The valid values of a closed enum setting; [] for anything that is not an enum."
  @spec enum_values(atom) :: [String.t()]
  def enum_values(key), do: Map.get(@enums, key, [])

  # THRESHOLD keys whose seed is an integer but which accept fractions (the calibration suggests
  # 45.0 and the 2026-07 test pins that use).
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
    escape_walk_wait_ms: 0..30_000,
    combat_aoe_from_enemies: 1..20,
    combat_shield_from_enemies: 1..20,
    timers_tick_ms: 100..60_000,
    pokemon_sprite_box_px: 16..512,
    pokemon_track_step_px: 1..64,
    pokemon_track_radius_px: 32..1200,
    pokemon_park_tolerance_px: 1..1200,
    pokemon_hp_heal_pct: 1..100,
    heal_skill_cooldown_ms: 0..600_000,
    pokemon_hp_shield_pct: 1..100,
    shield_skill_cooldown_ms: 0..600_000,
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
    rescue_blackout_ms: 0..10_000,
    pokemon_hp_fainted_below_pct: 0..100,
    fainted_revive_cooldown_ms: 0..600_000,
    combat_confirm_ms: 0..10_000,
    cavebot_precise_tiles: 0..10,
    cavebot_brain_gone_ms: 1_000..60_000,
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
    cavebot_pinned_probe_ms: 200..30_000,
    cavebot_stop_wait_ms: 0..600_000,
    # 1 means "fight anything", which is a legal (if greedy) choice; the ceiling
    # is the battle panel's own row count — a ruler above it never engages.
    engine_engage_from: 1..12,
    engine_reset_revive_cooldown_ms: 0..60_000,
    engine_reset_revive_min_hp: 0..100,
    crowd_scan_radius_tiles: 1..20,
    crowd_scan_evidence_shrink: 1..16,
    engine_crowd_from: 1..20,
    engine_spent_keys_left: 0..9,
    auto_combo_window_ms: 500..30_000,
    key_modifier_settle_ms: 0..1_000,
    engine_stun_window_ms: 500..60_000,
    engine_stun_hold_ms: 1_000..120_000,
    engine_boss_grit: 0..40,
    special_color_scan_ms: 50..5_000,
    special_color_confirm_frames: 1..5,
    engine_stun_reach_tiles: 1..10,
    engine_reset_rearm_ms: 10_000..3_600_000,
    engine_kite_max_ms: 0..600_000,
    engine_vitals_ms: 100..60_000,
    engine_pile_settle_ms: 0..60_000,
    engine_bunch_ms: 0..30_000,
    # 8 is what fits around the pokémon; beyond that the rest stands far and hits the
    # CHARACTER.
    engine_gather_target: 1..8,
    engine_patience_tiles: 1..200,
    engine_size_ceiling_ms: 100..600_000,
    engine_band_yellow_pct: 0..100,
    engine_band_red_pct: 0..100,
    engine_resume_pct: 1..100,
    engine_recover_timeout_ms: 1_000..600_000,
    engine_downed_give_up_ms: 0..7_200_000,
    engine_prepare_max_enemies: 0..10,
    revive_stock: 0..10_000,
    engine_revive_reserve: 0..1_000,
    player_hp_floor_pct: 0..99,
    # The ranges the /config page edits directly: the limits the old forms kept client-side
    # (input min/max) are now the owner's rule.
    pokemon_hp_rescue_pct: 1..90,
    pokemon_hp_potion_pct: 1..99,
    status_cure_settle_ms: 0..2_000,
    pokemon_hp_fishing_pct: 1..90,
    rescue_cooldown_ms: 0..600_000,
    fight_timeout_ms: 1_000..600_000,
    combat_skill_burst_size: 1..10,
    combat_skill_gap_ms: 20..5_000,
    escape_steps: 1..10,
    stagnation_minutes: 0..999,
    stop_after_minutes: 0..999,
    stop_after_kills: 0..9_999,
    engine_closing_timeout_ms: 100..600_000,
    engine_revive_confirm_ms: 500..600_000,
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

  # One rule per clause, in order: a threshold key accepting fractions short circuits, then
  # type, then the closed enum, then the range, then the similarity floor.
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

    # Persist ONLY the user's overrides.
    overrides = load(path)

    # …and the keys this build does not know travel along, untouched.
    foreign = foreign_keys(path)

    # …and a build older than the file does not write to it.
    somos_velhos? = older_build?(path)
    if somos_velhos?, do: announce_read_only(path), else: heal(path, overrides, foreign)
    announce_foreign(foreign, path)

    # Only the GLOBAL (named) instance owns the mirror — tmp-scoped test
    # instances must not clobber it.
    mirror? = Keyword.get(opts, :name, __MODULE__) == __MODULE__

    state = %{
      path: path,
      data: overrides,
      foreign: foreign,
      read_only?: somos_velhos?,
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
  # Three layers, always in this order: character ⊕ base ⊕ seed.
  def handle_call({:get, key}, _from, state), do: {:reply, resolve(state, key), state}

  def handle_call(:read_only?, _from, state),
    do: {:reply, Map.get(state, :read_only?, false), state}

  def handle_call(:all, _from, state),
    do: {:reply, Map.merge(@seed_settings, effective(state)), state}

  # Switching character: the key itself is global (there would be no way to know
  # who is active before knowing who is active), and it reloads their layer.
  def handle_call({:put, :active_character, slug}, _from, state) do
    state = put_global(state, :active_character, slug)
    state = %{state | char: slug, char_data: load_char(state, slug)}

    # `:active_character` is in the sync list itself: it is read through the mirror like any
    # other key (that is how `Team.file/0` knows whose team it is), and
    {:reply, :ok, mirror_sync(state, [:active_character | @character_keys])}
  end

  def handle_call({:put, key, value}, _from, state) when key in @character_keys do
    note_change(key, resolve(state, key), value)

    if state.char == "" do
      # With no character selected the panel edits the BASE — exactly the behaviour from before
      # this layer existed, and what every new character inherits.
      {:reply, :ok, state |> put_global(key, value) |> mirror_sync([key])}
    else
      {:reply, :ok, state |> put_char(key, value) |> mirror_sync([key])}
    end
  end

  def handle_call({:put, key, value}, _from, state) do
    note_change(key, resolve(state, key), value)
    {:reply, :ok, state |> put_global(key, value) |> mirror_sync([key])}
  end

  # Every change goes to the journal (`~/.pokex/journal/`, source `config`), so a lost setting
  # can be read back. The same key with the same value is not a change.
  defp note_change(_key, before, value) when before == value, do: :ok

  defp note_change(key, before, value) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "settings",
      {:settings_log, :macro, "⚙️ #{key}: #{inspect(before)} → #{inspect(value)}"}
    )
  catch
    :exit, _sem_pubsub -> :ok
  end

  # Setting a value back to the current default is NOT an override — drop it so the key keeps
  # tracking the code default afterwards.
  defp put_global(state, key, value) do
    data =
      if value == Map.fetch!(@seed_settings, key),
        do: Map.delete(state.data, key),
        else: Map.put(state.data, key, value)

    # Foreign keys travel on EVERY write, not only the boot heal: otherwise the first saved
    # tweak would erase what the boot preserved.
    if Map.get(state, :read_only?, false) do
      Logger.warning(
        "Settings: #{key} mudou só nesta sessão — o arquivo foi escrito por uma versão mais " <>
          "nova e esta build não grava nele. Rode o checkout novo pra salvar de verdade."
      )
    else
      persist!(state.path, data, Map.get(state, :foreign, %{}))
    end

    %{state | data: data}
  end

  # The same discipline one layer up: what the character "overrides" with the value already
  # coming from the base is no override at all — it leaves their file and goes back to following
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

  # Only the keys that changed: rewriting the whole table would leave a window where a worker
  # reading mid-switch would fall to the seed instead of the character's value.
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

  # `base_fun` says what "is this an override?" is measured against: the code seed for the
  # global file, the already-resolved base value for a character's.
  defp load(path, keys, base_fun) do
    with {:ok, bin} <- File.read(path),
         {:ok, json} <- JSON.decode(bin) do
      for {key_string, value} <- json,
          key = known_key(key_string),
          key in keys,
          # A locked constant never comes from the file: the number is the code's
          # (`Pokex.Settings.Locked`). A stale override stays on disk until the next
          # write, which drops it.
          not Locked.locked?(key),
          # A JSON null is file corruption, never a legitimate override — keeping
          # it would make Settings.get return nil to code expecting a number.
          not is_nil(value),
          # A value written in Portuguese by an older build becomes today's spelling BEFORE the
          # seed comparison — otherwise a migrated default would be kept as an override forever.
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

  # The alphabet the writing build knew, stamped on every write. Not a setting but the file's
  # badge, hence excluded from `foreign_keys/1`.
  @alphabet_key "__keys__"

  @doc false
  # The file's keys THIS build does not know: raw, string key and value as they came.
  def foreign_keys(path) do
    for {key_string, value} <- read_json(path),
        key_string != @alphabet_key,
        known_key(key_string) == nil,
        not is_nil(value),
        into: %{},
        do: {key_string, value}
  end

  @doc """
  Is this build OLDER than the file it has just read?

  True when the file declares a key this build does not know AND knows every key this one has:
  whoever wrote last knew everything this build knows and more. In that case it reads and does
  not write, because a build that does not know the alphabet cannot decide what is rubbish.

  An unknown key ALONE does not accuse: keys retire (twelve left the code in one cleanup), and a
  file written before that declares them forever. Under the old rule the NEW build thought
  itself old because of them and stopped writing in silence, so everything he changed in /config
  over two days lasted only until the next restart. A build that knows keys the file does not
  have is, by definition, newer at something, and the keys it does not know travel untouched in
  the write (`foreign_keys/1`), which is the real net.

  A file with no badge (the first boot after this change, or one written by hand) answers FALSE:
  nobody is old for lack of proof, and preserving unknown keys is still the net underneath that.
  """
  @spec older_build?(String.t()) :: boolean
  def older_build?(path) do
    case Map.get(read_json(path), @alphabet_key) do
      alfabeto when is_list(alfabeto) ->
        Enum.any?(alfabeto, &(known_key(&1) == nil)) and
          Enum.all?(@setting_keys, &(Atom.to_string(&1) in alfabeto))

      _sem_cracha ->
        false
    end
  end

  @doc "Is this session writing to the file? False when the build declared itself older than it."
  @spec read_only?(GenServer.server()) :: boolean
  def read_only?(server \\ __MODULE__), do: GenServer.call(server, :read_only?)

  defp read_json(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{} = json} <- JSON.decode(bin) do
      json
    else
      _unreadable_or_absent -> %{}
    end
  end

  defp announce_read_only(path) do
    Logger.warning(
      "Settings: #{path} foi escrito por uma versão MAIS NOVA que esta — lendo, mas NÃO " <>
        "escrevendo. Nenhum ajuste será perdido; nenhuma mudança feita aqui será gravada. " <>
        "Rode o checkout novo (o de verdade é ~/projects/pokex) pra voltar a escrever."
    )
  end

  defp announce_foreign(foreign, _path) when map_size(foreign) == 0, do: :ok

  defp announce_foreign(foreign, path) do
    Logger.info(
      "Settings: #{map_size(foreign)} chave(s) em #{path} que esta versão não conhece, " <>
        "preservadas intactas: #{foreign |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
    )
  end

  # The file is the union of the overrides this build understands and the keys it does not.
  defp persist!(path, data, foreign \\ %{}) do
    File.mkdir_p!(Path.dirname(path))
    backup(path)

    body =
      foreign
      |> Map.merge(
        for {key, value} <- data,
            not Locked.locked?(key),
            into: %{},
            do: {Atom.to_string(key), value}
      )
      # The badge, on every write: the alphabet THIS build knows.
      |> Map.put(@alphabet_key, Enum.map(@setting_keys, &Atom.to_string/1))
      |> JSON.encode!()

    Pokex.Home.write!(path, body)
  end

  # A backup before every write; the last ten are kept.
  @backups 10

  defp backup(path) do
    with {:ok, bin} <- File.read(path) do
      dir = Path.join(Path.dirname(path), "settings-bak")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "settings-#{System.system_time(:second)}.json"), bin)
      rotate(dir)
    end
  rescue
    _sem_backup -> :ok
  end

  defp rotate(dir) do
    dir
    |> File.ls!()
    |> Enum.sort(:desc)
    |> Enum.drop(@backups)
    |> Enum.each(&File.rm(Path.join(dir, &1)))
  end

  # The boot-time rewrite that trims a fat/materialized file down to overrides. Never fatal: if
  # the settings dir isn't writable we keep running off the (already-loaded) in-memory overrides.
  defp heal(path, data, foreign) do
    persist!(path, data, foreign)
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

  # "Valid" = the same SHAPE as the seed default: booleans stay booleans, integers stay
  # integers, key strings stay strings, key LISTS stay lists of strings —
  defp valid_preset_value?(key, value), do: valid_type?(key, value)

  defp valid_type?(key, value) do
    seed = Map.fetch!(@seed_settings, key)

    cond do
      is_boolean(seed) -> is_boolean(value)
      is_integer(seed) -> is_integer(value)
      is_float(seed) -> is_number(value)
      is_binary(seed) -> is_binary(value)
      # A list key carries EITHER strings (skill keys, muted sectors) or maps (the balls on the
      # hotbar and the rules that pick between them).
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
