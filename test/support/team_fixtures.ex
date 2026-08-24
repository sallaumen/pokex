defmodule Pokex.TeamFixtures do
  @moduledoc """
  A pokémon on the field that the bots accept.

  Since 2026-08-24 there is no shared skill bar: the creature that is out owns
  its bar and the job of every key, and `Pokex.Preflight` refuses to start
  without both. A test that boots a worker needs a configured pokémon the same
  way it needs a calibration — this is that, in one line.
  """

  alias Pokex.Pokedex.Team

  @doc """
  Puts `name` on the field with a bar and every slot classified.

  `:count` sizes the bar (default 4); `:skills` overrides the jobs, and must
  then cover every slot — the preflight checks exactly that.
  """
  def ready!(name \\ "Bulbasaur", opts \\ []) do
    count = Keyword.get(opts, :count, 4)
    skills = Keyword.get(opts, :skills, Map.new(1..count, &{to_string(&1), :single}))

    {:ok, _} = Team.add(name)
    Team.set_bar(name, %{region: {1610, 1217, 35 * count, 35}, count: count, refs: nil})
    Team.set_skills(name, skills)
    Team.set_active(name)
    name
  end
end
