defmodule Pokex.TeamFixtures do
  @moduledoc """
  A pokémon on the field that the bots accept.

  Since 2026-08-24 there is no shared skill bar: the creature that is out owns
  its bar and the job of every key, and `Pokex.Preflight` refuses to start
  without both. A test that boots a worker needs a configured pokémon the same
  way it needs a calibration — this is that, in one line.

  It puts the team file back on exit. The home is a GLOBAL app env, so a test
  that forgets to point it at its own tmp dir writes into the one every other
  test shares — which is how a Bulbasaur from one file turned up in another
  file's report (CI, 2026-08-24). Cleaning up here means the fixture is safe
  wherever it is called from.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Pokex.Pokedex.Team

  @doc """
  Puts `name` on the field with a bar and every slot classified.

  `:count` sizes the bar (default 4); `:skills` overrides the jobs, and must
  then cover every slot — the preflight checks exactly that.
  """
  def ready!(name \\ "Bulbasaur", opts \\ []) do
    count = Keyword.get(opts, :count, 4)
    skills = Keyword.get(opts, :skills, Map.new(1..count, &{to_string(&1), :single}))

    restore_team_on_exit()

    {:ok, _} = Team.add(name)
    Team.set_bar(name, %{region: {1610, 1217, 35 * count, 35}, count: count, refs: nil})
    Team.set_skills(name, skills)
    Team.set_active(name)
    name
  end

  defp restore_team_on_exit do
    path = Team.file()
    before = File.read(path)

    on_exit(fn ->
      case before do
        {:ok, contents} -> File.write(path, contents)
        {:error, _never_existed} -> File.rm(path)
      end
    end)
  end
end
