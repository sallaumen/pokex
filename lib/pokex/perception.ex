defmodule Pokex.Perception do
  @moduledoc """
  The perception subsystem: the WorldState blackboard plus one demand-driven Feed per
  screen region (spec: docs/superpowers/specs/2026-07-10-perception-blackboard-tab-combat-design.md).
  Workers attach to the feeds they need and read observations from the WorldState / the
  "world" PubSub topic — no worker takes its own screenshots.
  """
  use Supervisor

  alias Pokex.Perception.{Feed, Interpret}

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
      }
    ]
  end
end
