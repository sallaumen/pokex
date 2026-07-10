defmodule Pokex.Settings do
  @moduledoc """
  Runtime-tunable bot settings, persisted as JSON.

  The checked-in @seed_settings map is the source of truth for defaults. The file at
  `~/.pokex/settings.json` stores ONLY the keys the user has explicitly changed, so a default
  that isn't overridden always comes from code — changing a seed default in a new build takes
  effect for everyone who hasn't overridden that key. (Persisting a full snapshot instead would
  freeze every default at its first-boot value and silently shadow later code changes.)
  """
  use GenServer
  require Logger

  @seed_settings %{
    rod_key: "shift+v",
    skill_keys: ["1", "2", "3"],
    # Combat does not need the mouse once a target is locked. Fire a short keyboard-only burst
    # per battle read, then re-check the ring/list. This keeps the mouse free for fishing and
    # reduces capture pressure during fights.
    combat_skill_burst_size: 3,
    combat_skill_tap_count: 1,
    combat_skill_gap_ms: 35,
    combat_skill_jitter_ms: 20,
    # --- Skill-bar cooldown tracking (SkillBar reads the hotbar per-process) ---
    # Legacy fallback when an old calibration has no explicit count. New calibrations
    # ask for 1..10 and persist that fixed geometry; cooldown frames never change it.
    skill_bar_count: 6,
    # A slot reads :ready when its average brightness OR saturation clears these;
    # :cooldown only when BOTH are below (dark + grey overlay). MEASURED on Lucas's
    # real bar (2026-07-08 diagnostic): ready icons sit at brightness 97-131 /
    # saturation 27-68, while the two measured cooldown slots read brightness 54/49,
    # saturation 19/19 and vivid 6%/4%. The 90/25/7 floors split those populations
    # (the old 140/40 misread the dimmer pink icon as cooldown). Saturation is the
    # more reliable signal: the overlay greys the icon regardless of the number.
    skill_ready_min_brightness: 90,
    skill_ready_min_saturation: 25,
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
    # Which skills the gate watches — it pulls as soon as ANY of them is ready. Lucas
    # uses 4-7 (~40s each) to kill; edit in the panel. These are hotbar keys ("1".."N").
    hook_skill_keys: ["4", "5", "6", "7"],
    # No delays for now — everything runs as fast as the screen captures allow.
    # A tiny post-success pause (10–50ms) is all that stays, so the game has a
    # frame to register the previous input before the next one.
    tick_ms_watching: 100,
    tick_ms_fighting: 300,
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
    wait_cast_settle_ms: 1600,
    wait_assess_ms: 1500,
    wait_loot_ms: 30,
    wait_after_capture_ms: 50,
    watch_timeout_ms: 30_000,
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
    watch_dead_streak_needed: 10,
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
    hostile_scan_every: 2,
    wild_min_red_pixels: 12,
    auto_capture: true,
    # A SINGLE bite-magnitude frame (> glow_threshold) hooks. The bite oscillates
    # hard (2..1513), so requiring CONSECUTIVE frames never confirms — but one frame
    # over 800 is unambiguous (nothing else reaches it) and the post-hook anti-bot
    # delay covers the "too instant" concern, so first detection = caught.
    glow_streak_needed: 1,
    # Consecutive below-threshold (resting/splash level) frames before a cyan spike
    # counts as a bite. Guards against a splash that briefly clears glow_threshold.
    calm_streak_needed: 3,
    # Height (points) of ONE battle-list row = the vertical spacing between rows.
    # MEASURED live via hp_bar_rows: HP bars at frame-y 42 and 95 → ~53px apart
    # (matches the documented 52-53px rows). The old 30 compressed the click grid
    # (config.battle_rows = first_row + i*row_height) to ~half the real spacing, so
    # row-N clicks landed BETWEEN real rows / on row N-1 — the bot clicked, missed
    # the creature, and "kept searching". Drives BOTH the row click points and the
    # per-row lock read bands, so they now line up with the real rows.
    battle_row_height: 52,
    battle_max_rows: 6,
    # Min bright-red (r>=200,g<=60,b<=60) px on a scanline of the rightmost strip for it to count
    # as the OWN-pokemon pokeball (so that row is EXCLUDED from attack candidates). MEASURED on
    # Lucas's real Mareep (2026-07-09): the icon is a small ~7-px red blob per scanline, so the
    # old 12 never matched and his own pokemon got clicked as an enemy. 5 catches it with margin;
    # RAISE it if a red enemy element in the strip ever gets mistaken for a pokeball.
    pokeball_min_red_px: 5,
    # Screen pixels per game tile. MEASURED at 3440x1440, scale 1.0: the floor
    # texture autocorrelates at 44px (two plank rows per tile sprite) → tile = 88;
    # the character sprite (~88px) confirms it. Converts the corpse's screen
    # offset into arrow-key steps, the capture click point, and the corpse's
    # body position one tile below its floating name.
    tile_px: 88,
    # The character walks fast (~200ms/tile measured on video), but instant
    # back-to-back movement inputs bug out and he doesn't move at all — so every
    # step press is spaced by this conservative pause.
    walk_step_ms: 400,
    # SPACE loots any ADJACENT corpse (no aiming); press a couple of times to be safe.
    loot_presses: 2,
    # A corpse offset beyond this many tiles per axis is a bad hostile read →
    # treat the corpse as unknown and loot in place instead of marching off.
    max_walk_tiles: 7,
    # Pokeball AIM correction (px): the capture point is the corpse's TILE centre, but a pokemon
    # sprite is drawn ABOVE the tile floor, so aiming at the tile centre lands on the sprite's
    # lower edge (Lucas: "cai no canto inferior/direito e não acerta"). Nudge the throw UP by this
    # much (and LEFT by _left) to land on the body. Tunable because sprites vary; if it lands too
    # high, lower `_up`. A proper per-corpse aim would detect the sprite blob — see the notes.
    capture_aim_up_px: 30,
    capture_aim_left_px: 12,
    # /diagnostics still shows the per-row red target-ring read for manual inspection; this
    # is the threshold it uses (a real ring is 600-900 red px, the unlocked baseline ~40-150).
    # Combat itself no longer reads the ring — it targets by HP bar + pokeball (enemy_rows).
    target_locked_min_pixels: 350,
    # Consecutive ticks the enemy must be GONE from the Battle list before the fight is
    # declared over — filters a 1-frame HP-bar blink on a hit/death animation.
    target_lost_streak: 2,
    # Fishing mini-game monitor. It only detects the overlay and coordinates worker pause/resume.
    mini_game_tick_ms: 150,
    mini_game_enter_streak: 1,
    mini_game_exit_streak: 2,
    mini_game_min_confidence: 0.62,
    mini_game_min_dark_ratio: 0.34,
    # After clicking a candidate row, how long to wait for the red target RING to appear before
    # deciding the click started no real battle. A passing player's pokemon has an HP bar and no
    # pokeball, so it looks attackable — but clicking it engages nothing (no ring). The ring
    # renders ~200ms + capture latency; 500 gives a couple of reads to catch it, then combat
    # marks the row and tries the next candidate instead of fake-fighting nothing.
    battle_confirm_ms: 500,
    humanize_max_ms: 0,
    # Anti-bot: a RANDOM 0..this ms jitter before each CAST (the rod throw), so the
    # bot doesn't fish on a perfectly fixed cadence.
    cast_delay_max_ms: 450,
    # Anti-bot: once a bite is confirmed, wait a RANDOM hook_delay_min..max ms
    # before pulling. The bubbles keep flashing until we pull — the bite window
    # NEVER closes — so a human-like 0.5-1s reaction is safe AND avoids a robotic
    # instant yank.
    hook_delay_min_ms: 500,
    hook_delay_max_ms: 1000
  }

  @setting_keys @seed_settings |> Map.keys() |> Enum.sort_by(&Atom.to_string/1)

  def defaults, do: @seed_settings

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def get(key, server \\ __MODULE__), do: GenServer.call(server, {:get, key})
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  def put(key, value, server \\ __MODULE__) when is_map_key(@seed_settings, key),
    do: GenServer.call(server, {:put, key, value})

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
    {:ok, %{path: path, data: overrides}}
  end

  @impl true
  # Any key the user hasn't overridden falls back to the code seed — this is what lets a later
  # change to a @seed_settings default actually take effect.
  def handle_call({:get, key}, _from, state),
    do: {:reply, Map.get(state.data, key, Map.get(@seed_settings, key)), state}

  def handle_call(:all, _from, state),
    do: {:reply, Map.merge(@seed_settings, state.data), state}

  # Setting a value back to the current default is NOT an override — drop it so the key keeps
  # tracking the code default afterwards.
  def handle_call({:put, key, value}, _from, state) do
    data =
      if value == Map.fetch!(@seed_settings, key),
        do: Map.delete(state.data, key),
        else: Map.put(state.data, key, value)

    persist!(state.path, data)
    {:reply, :ok, %{state | data: data}}
  end

  # Keep ONLY the keys whose value differs from the current seed default. Restores the
  # "store overrides, not a snapshot" contract and self-heals an older materialized file.
  defp load(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, json} <- JSON.decode(bin) do
      for {key_string, value} <- json,
          key = known_key(key_string),
          key != nil,
          value != Map.fetch!(@seed_settings, key),
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
    File.write!(path, JSON.encode!(data))
  end

  # The boot-time rewrite that trims a fat/materialized file down to overrides. Never fatal: if
  # the settings dir isn't writable we keep running off the (already-loaded) in-memory overrides.
  defp heal(path, data) do
    persist!(path, data)
  rescue
    error -> Logger.warning("Settings: could not rewrite #{path}: #{inspect(error)}")
  end
end
