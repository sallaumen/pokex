defmodule Pokex.Perception do
  @moduledoc """
  The perception subsystem: the WorldState blackboard plus one demand-driven Feed per
  screen region (spec: docs/superpowers/specs/2026-07-10-perception-blackboard-tab-combat-design.md).
  Workers attach to the feeds they need and read observations from the WorldState / the
  "world" PubSub topic — no worker takes its own screenshots.
  """
  use Supervisor

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

  @doc "Attach the calling process as a consumer of `key` (starts its captures if first)."
  def attach(key), do: Feed.attach(Feed.name(key))

  @doc "Detach the calling process from `key` (pauses the feed if it was the last)."
  def detach(key), do: Feed.detach(Feed.name(key))

  @doc """
  Is the fishing mini-game being played right now, per the `:mini_game` fact the
  MiniGame worker publishes every tick?

  This is THE coordination read: peers hold themselves and the Body blocks inputs
  on it, instead of being paused/guarded by the mini-game worker directly. It is
  deliberately fail-open — a stale or missing fact (worker crashed, never ran,
  capture stuck past `mini_game_fact_max_age_ms`) reads as "not playing", so a
  dead mini-game worker can never strand the rest of the bot.
  """
  @spec mini_game_playing?(integer) :: boolean
  def mini_game_playing?(now_ms \\ System.monotonic_time(:millisecond)) do
    case WorldState.get(:mini_game, Settings.get(:mini_game_fact_max_age_ms), now_ms) do
      {:ok, %{playing?: playing?}} -> playing?
      _stale_or_missing -> false
    end
  end

  # Feed inventory. Task 5 fills in the :battle and :arena interpreters; later phases add
  # :glow, :pokemon_hp, :mini_game and :skill_bar here.
  def feed_specs do
    [
      %{
        key: :battle,
        region: fn calib -> calib.battle_region end,
        interval_setting: :feed_battle_ms,
        filename: "feed_battle.png",
        interpret: &Interpret.battle/3
      },
      %{
        key: :arena,
        region: fn calib -> calib.arena_region end,
        interval_setting: :feed_arena_ms,
        filename: "feed_arena.png",
        interpret: &Interpret.arena/3
      },
      %{
        key: :corpses,
        region: fn calib -> calib.arena_region end,
        interval_setting: :feed_corpses_ms,
        filename: "feed_corpses.png",
        interpret: &Interpret.Corpses.interpret/4
      }
    ]
  end
end
