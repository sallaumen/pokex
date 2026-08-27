defmodule Pokex.Perception do
  @moduledoc """
  The perception subsystem: the WorldState blackboard plus one demand-driven Feed per
  screen region (spec: docs/superpowers/specs/2026-07-10-perception-blackboard-tab-combat-design.md).
  Workers attach to the feeds they need and read observations from the WorldState / the
  "world" PubSub topic — no worker takes its own screenshots.
  """
  use Supervisor

  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Perception.{Feed, Interpret, WorldState}
  alias Pokex.Settings

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      [Pokex.Perception.WorldState] ++
        Enum.map(feed_specs(), fn spec ->
          Supervisor.child_spec({Feed, spec: spec}, id: Feed.name(spec.key))
        end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def topic, do: Feed.topic()

  @doc """
  Which feeds are being WATCHED right now — the ones whose loop is capturing.

  `attach/1` going inert (`:perception_feeds_active`) only stops NEW attaches;
  a feed a page already attached keeps photographing the real screen. Anything
  that needs the screen to hold still — the simulator's fence — has to ask this
  instead of trusting the flag.
  """
  @spec watched_keys() :: [atom]
  def watched_keys do
    for spec <- feed_specs(), Feed.consumer_count(Feed.name(spec.key)) > 0, do: spec.key
  end

  @doc """
  Attach the calling process as a consumer of `key` (starts its captures if first).

  Inert in the suite (`:perception_feeds_active`). Waking a NAMED feed starts a
  real capture loop that writes observations into the shared blackboard behind
  whatever test happens to be running: measured 2026-08-04, a cavebot test
  published its own `:minimap` position and the feed its own worker had just
  woken overwrote it — so the worker never stepped, and the test passed or
  failed depending on the seed. Feed tests drive their own unnamed `Feed`.
  """
  def attach(key), do: if(feeds_active?(), do: Feed.attach(Feed.name(key)), else: :ok)

  @doc "Detach the calling process from `key` (pauses the feed if it was the last)."
  def detach(key), do: if(feeds_active?(), do: Feed.detach(Feed.name(key)), else: :ok)

  defp feeds_active?, do: Application.get_env(:pokex, :perception_feeds_active, true)

  @doc """
  Is the fishing mini-game being played right now, per the `:mini_game` fact the
  MiniGame worker publishes every tick?

  This is THE coordination read: peers hold themselves and the Body blocks inputs
  on it, instead of being paused/guarded by the mini-game worker directly. It is
  deliberately fail-open — a stale or missing fact (worker crashed, never ran,
  capture stuck past `mini_game_fact_max_age_ms`) reads as "not playing", so a
  dead mini-game worker can never strand the rest of the bot.

  OUTSIDE THE FISHING MODE THERE IS NO GAME TO BE PLAYING. The capsule only
  appears over a rod, so a mode that runs no rod answers false without reading
  the blackboard at all — no fact left over from the last fishing session, no
  hand-written one, nothing can hold a hunt on something that cannot happen
  ("não existe o minigame fora da pesca", Lucas, 2026-08-25). It also keeps the
  hunt's hot path free of a question that only ever has one answer.
  """
  @spec mini_game_playing?(integer) :: boolean
  def mini_game_playing?(now_ms \\ System.monotonic_time(:millisecond)) do
    Pokex.Modes.watches_mini_game?() and playing_fact?(now_ms)
  end

  defp playing_fact?(now_ms) do
    case WorldState.get(:mini_game, Settings.get(:mini_game_fact_max_age_ms), now_ms) do
      {:ok, %{playing?: playing?}} -> playing?
      _stale_or_missing -> false
    end
  end

  @doc """
  `mini_game_playing?/1` in the shape input gates want: `:ok` to act,
  `{:blocked, :mini_game_active}` to stop. Used by the Body around every
  guarded input and by combat around its key bursts.
  """
  @spec mini_game_gate(integer) :: :ok | {:blocked, :mini_game_active}
  def mini_game_gate(now_ms \\ System.monotonic_time(:millisecond)) do
    if mini_game_playing?(now_ms), do: {:blocked, :mini_game_active}, else: :ok
  end

  @doc """
  The `:pokemon` fact PlayerSupport publishes every monitor tick: the active
  Pokémon's HP (`hp_pct`) and whether the HP bar was readable at all
  (`readable?: false` = party window minimized or no Pokémon out of the ball).
  `:unknown` when the fact is missing or older than `pokemon_fact_max_age_ms`
  (monitor halted / not calibrated) — readers fail open on it, as with every
  fact.
  """
  @spec pokemon(integer) ::
          {:ok, %{hp_pct: integer | nil, readable?: boolean, fainted?: boolean}} | :unknown
  def pokemon(now_ms \\ System.monotonic_time(:millisecond)) do
    case WorldState.get(:pokemon, Settings.get(:pokemon_fact_max_age_ms), now_ms) do
      {:ok, obs} -> {:ok, obs}
      _stale_or_missing -> :unknown
    end
  end

  @doc """
  The player's map position per the `:minimap` fact its feed publishes:
  `{:ok, %{pos: {x, y, z}}}` when the fact is fresh (within
  `cavebot_minimap_fact_max_age_ms`) and the position was actually read.
  `:unknown` when the fact is missing, stale, or carries `pos: nil` (anchor
  not located in the frame) — fail-open: an unknown position is never
  reported as a known one, so the cavebot stops instead of walking blind.
  """
  @spec minimap(integer) :: {:ok, %{pos: {integer, integer, integer}}} | :unknown
  def minimap(now_ms \\ System.monotonic_time(:millisecond)) do
    case WorldState.get(:minimap, Settings.get(:cavebot_minimap_fact_max_age_ms), now_ms) do
      {:ok, %{pos: {_x, _y, _z}} = obs} -> {:ok, obs}
      _stale_missing_or_nil -> :unknown
    end
  end

  @doc """
  The ready hotbar keys per the `:skill_bar` fact its feed publishes, or nil when the
  fact is missing, stale (`skill_bar_fact_max_age_ms`) or unreadable — UNKNOWN, and
  consumers must fail OPEN on it (combat falls back to the blind rotation; nothing may
  stop attacking over a bad read).
  """
  @spec ready_skills(integer) :: [String.t()] | nil
  def ready_skills(now_ms \\ System.monotonic_time(:millisecond)) do
    case WorldState.get(:skill_bar, Settings.get(:skill_bar_fact_max_age_ms), now_ms) do
      {:ok, %{ready_keys: keys}} -> keys
      _stale_or_missing -> nil
    end
  end

  @doc """
  The ready keys from a reading captured strictly AFTER `at` — the receipt for
  a press, rather than the photo that was already on the wall when it went out.

  Blocks up to `timeout_ms` waiting for the feed's next publish, then gives up
  with `nil` (unknown, like every other unreadable bar). Callers use it with
  `Pokex.Bots.SkillReceipt`: the reading BEFORE the press and this one after
  it say whether the skill actually went off.
  """
  @spec ready_skills_after(integer, non_neg_integer) :: [String.t()] | nil
  def ready_skills_after(at, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_skills(at, deadline)
  end

  defp await_skills(at, deadline) do
    now = System.monotonic_time(:millisecond)

    case WorldState.age(:skill_bar, now) do
      age when is_integer(age) and now - age > at ->
        ready_skills(now)

      _older_or_missing ->
        if now >= deadline, do: nil, else: sleep_and_await(at, deadline)
    end
  end

  @poll_ms 40
  defp sleep_and_await(at, deadline) do
    Process.sleep(@poll_ms)
    await_skills(at, deadline)
  end

  def feed_specs do
    [
      %{
        key: :battle,
        # The auto-located panel wins over the hand-marked one: his calibration
        # still points where the battle list sat before he enlarged his map, so
        # combat was reading the MINIMAP and saw one enemy where there were six.
        # The manual region stays as the fallback for an uncalibrated layout.
        region: fn calib ->
          Pokex.Layout.region(:battle_list, calib.layout) || calib.battle_region
        end,
        interval_setting: :feed_battle_ms,
        filename: "feed_battle.raw",
        interpret: &Interpret.battle/3
      },
      %{
        key: :skill_bar,
        # the pokémon on the field decides WHERE its bar is; the calibration is
        # the fallback for the ones he has not calibrated yet
        region: fn _calib -> Pokex.Bots.ActiveBar.region() end,
        interval_setting: :feed_skill_bar_ms,
        filename: "feed_skill_bar.raw",
        interpret: &Interpret.skills/3
      },
      %{
        key: :hud,
        region: fn calib -> Pokex.Layout.region(:hud_bottom, calib.layout) end,
        interval_setting: :feed_hud_ms,
        filename: "feed_hud.raw",
        interpret: &Interpret.Hud.interpret/3
      },
      %{
        key: :team,
        region: fn calib -> Pokex.Layout.region(:team_column, calib.layout) end,
        interval_setting: :feed_team_ms,
        filename: "feed_team.raw",
        interpret: &Interpret.Team.interpret/3
      },
      %{
        key: :minimap,
        # Hand-marked calibration wins; layout is fallback. The capture is the
        # UNION of map + coord band — a band poking outside the map would be
        # silently clipped by a map-only capture (2026-08-10).
        region: fn calib -> Pokex.Calibration.minimap_capture_region(calib) end,
        interval_setting: :feed_minimap_ms,
        filename: "feed_minimap.raw",
        interpret: &Interpret.Minimap.interpret/4
      },
      %{
        key: :corpses,
        # The square around the character — the same one SpotScan sweeps. The
        # arena is gone; nothing may ask for a rectangle the user never sees.
        region: fn calib ->
          case SpotScan.region(calib) do
            {:ok, region} -> region
            _no_anchor -> nil
          end
        end,
        interval_setting: :feed_corpses_ms,
        filename: "feed_corpses.raw",
        interpret: &Interpret.Corpses.interpret/4
      }
    ]
  end
end
