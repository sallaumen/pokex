defmodule Pokex.Settings do
  @moduledoc "Runtime-tunable bot settings, persisted as JSON. Keys are a closed set."
  use GenServer

  @defaults %{
    rod_key: "v",
    skill_keys: ["1", "2", "3"],
    # Global cast cooldown (ms) between ANY two skills. The game swallows skills
    # fired faster than this (spamming many lands only one), so Skills paces to it:
    # one skill per window, strongest first. ~1s is the typical value; tune to your
    # server. Phase 2 (skill-bar image) will make firing exact per-skill cooldown.
    skill_cast_ms: 1000,
    # No delays for now — everything runs as fast as the screen captures allow.
    # A tiny post-success pause (10–50ms) is all that stays, so the game has a
    # frame to register the previous input before the next one.
    tick_ms_watching: 100,
    tick_ms_fighting: 150,
    tick_ms_default: 80,
    wait_focus_ms: 20,
    wait_after_equip_ms: 30,
    # Let the cast SPLASH settle before watching, so the line landing isn't read
    # as a bite; then give the hooked pokemon time to teleport in before checking.
    # Widened to fully outlast the ~1-1.5s splash so most ambiguous frames never
    # even enter the sample stream (an independent second layer of defense).
    wait_cast_settle_ms: 1600,
    wait_assess_ms: 700,
    wait_loot_ms: 30,
    wait_after_capture_ms: 50,
    watch_timeout_ms: 30_000,
    # A locked target that hasn't died in this long isn't a real hostile (our own
    # pokemon) or is hopelessly tanky → drop it and try the next battle row.
    fight_timeout_ms: 6000,
    # Min cyan pixels for a BITE. The bite bubbles flash ON/OFF frame-to-frame
    # (measured 2..1513 during one bite) but their PEAKS hit 1100-1500, while the
    # resting bait ring pulses higher than first thought — 800 still let resting
    # frames through as false bites. 1100 clears the resting ceiling with margin;
    # only a real bubble burst reaches it. Tunable via /diagnostics "Bolhas (ciano)".
    glow_threshold: 1100,
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
    # After clicking a Battle row the game takes ~200ms to DRAW the red target
    # ring; screenshot sooner and it reads 0px (no lock) and skips a valid target.
    # This is the one pause that must stay — it waits for the game to respond.
    wait_target_verify_ms: 250,
    # Re-read the lock this many times after clicking a Battle row before deciding
    # it didn't lock: the red ring draws ~200ms after the click and the capture
    # adds 100-200ms, so a single read often sees a PRE-RING frame — advancing on
    # it clicks (= LURES) the next row while the first ring is still in flight.
    target_verify_attempts: 3,
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
    # A real lock ring reads 600-900 red px in the battle body; the UNLOCKED
    # baseline (wild red NAMES + reddish sprites like Magikarp, with no fight at
    # all) measures ~40-150. The old threshold of 40 sat ON the baseline, so the
    # bot "fought" nobody. 350 splits the two populations cleanly.
    target_locked_min_pixels: 350,
    # Clicking our OWN pokemon blinks red briefly then fades; a real lock stays
    # for the whole fight. Two reads spaced wait_target_verify_ms filter the blink.
    target_lock_streak: 2,
    target_lost_streak: 2,
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

  def defaults, do: @defaults

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def get(key, server \\ __MODULE__), do: GenServer.call(server, {:get, key})
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  def put(key, value, server \\ __MODULE__) when is_map_key(@defaults, key),
    do: GenServer.call(server, {:put, key, value})

  @impl true
  def init(opts) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:pokex, :settings_path) ||
        Pokex.Home.settings_file()

    # Store ONLY the user's explicit overrides — never a full snapshot of the
    # defaults. Otherwise a settings.json written by an older build would freeze
    # every key at its old value and silently override new code defaults. get/all
    # fall back to @defaults for anything not overridden here.
    {:ok, %{path: path, data: load(path)}}
  end

  @impl true
  # Fall back to @defaults so a process that started before a new key was added
  # (e.g. after a hot code reload) returns the default instead of crashing.
  def handle_call({:get, key}, _from, state),
    do: {:reply, Map.get(state.data, key, Map.get(@defaults, key)), state}

  # Merge over @defaults so newly-added keys are present even for a process that
  # started before them (hot reload) — otherwise Config.build hits nil arithmetic.
  def handle_call(:all, _from, state), do: {:reply, Map.merge(@defaults, state.data), state}

  def handle_call({:put, key, value}, _from, state) do
    data = Map.put(state.data, key, value)
    File.mkdir_p!(Path.dirname(state.path))
    File.write!(state.path, JSON.encode!(data))
    {:reply, :ok, %{state | data: data}}
  end

  defp load(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, json} <- JSON.decode(bin) do
      for {key_string, value} <- json,
          key = known_key(key_string),
          key != nil,
          into: %{},
          do: {key, value}
    else
      _ -> %{}
    end
  end

  defp known_key(key_string) do
    Enum.find(Map.keys(@defaults), &(Atom.to_string(&1) == key_string))
  end
end
