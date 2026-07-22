defmodule Pokex.World do
  @moduledoc """
  The whole game state in one struct — what the bot currently believes about
  the screen.

  Every field comes from a blackboard fact published by a feed, read through
  the same staleness gate the workers use: a fact nobody is feeding goes nil
  rather than lingering as a confident lie. Assembling never raises, so a
  caller (a combo, an alarm, the /world page, tomorrow's cavebot) can always
  ask "what is happening?" and get an honest answer, holes included.
  """

  alias Pokex.Perception.WorldState

  defmodule Snapshot do
    @moduledoc "One coherent view of the game, as of `at`."
    defstruct me: %{pokemon_hp: nil, level: nil, food: nil, fishing: nil},
              inventory: %{f1: nil, f2: nil, e: nil, s_q: nil},
              team: [],
              enemies: [],
              shiny?: false,
              engaged?: false,
              pos: nil,
              layout?: false,
              at: nil
  end

  # A fact older than this is not the present any more. Generous next to the
  # feed cadences (250-500ms) so a single slow tick never blanks the page.
  @max_age_ms 5_000

  @doc "The current world, assembled from every fact a feed has published."
  def snapshot(now \\ nil) do
    now = now || System.monotonic_time(:millisecond)
    hud = fact(:hud, now)
    team = fact(:team, now)
    battle = fact(:battle, now)
    minimap = fact(:minimap, now)

    %Snapshot{
      me: %{
        pokemon_hp: team[:pokemon_hp],
        level: hud[:level],
        food: hud[:food],
        fishing: hud[:fishing]
      },
      inventory: hud[:slots] || %{f1: nil, f2: nil, e: nil, s_q: nil},
      team: team[:rows] || [],
      enemies: battle[:enemies_detail] || [],
      shiny?: (battle[:shiny_rows] || []) != [],
      engaged?: battle[:locked?] == true,
      pos: minimap[:pos],
      # NOT time-limited: the layout is configuration, not an observation. It
      # stops being true when the panels MOVE (the sentinel's job to notice),
      # never merely because it was located a while ago.
      layout?: match?({:ok, _fact}, WorldState.get(:layout, :infinity, now)),
      at: DateTime.utc_now()
    }
  end

  @doc "Health of the whole team as a slot => percentage map (nil where unknown)."
  def team_health(%Snapshot{team: rows}),
    do: Map.new(rows, fn row -> {row.slot, row.hp_pct} end)

  @doc "The active pokémon's health as a fraction, or nil when unread."
  def pokemon_hp_pct(%Snapshot{me: %{pokemon_hp: {current, max}}}) when max > 0,
    do: current / max

  def pokemon_hp_pct(_snapshot), do: nil

  defp fact(key, now) do
    case WorldState.get(key, @max_age_ms, now) do
      {:ok, obs} when is_map(obs) -> obs
      _stale_or_missing -> %{}
    end
  end
end
