defmodule Pokex.Settings do
  @moduledoc "Runtime-tunable bot settings, persisted as JSON. Keys are a closed set."
  use GenServer

  @defaults %{
    rod_key: "v",
    skill_keys: ["1", "2", "3"],
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
    glow_threshold: nil,
    max_consecutive_failures: 5,
    tile_size: 32,
    hostile_scan_every: 2,
    wild_min_red_pixels: 12,
    auto_capture: true,
    glow_streak_needed: 2,
    # The water must read calm for this many CONSECUTIVE glow frames before a cyan
    # spike is treated as a real bite. An oscillating cast splash keeps interrupting
    # this run (each crest resets it), while calm water (measured stable 0 for 80
    # frames) satisfies it in a few hundred ms.
    calm_streak_needed: 3,
    battle_row_height: 30,
    battle_max_rows: 6,
    # After clicking a Battle row the game takes ~200ms to DRAW the red target
    # ring; screenshot sooner and it reads 0px (no lock) and skips a valid target.
    # This is the one pause that must stay — it waits for the game to respond.
    wait_target_verify_ms: 250,
    target_locked_min_pixels: 40,
    target_lock_streak: 1,
    target_lost_streak: 2,
    humanize_max_ms: 0
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
