defmodule Pokex.Pokedex.TeamSlotsTest do
  @moduledoc """
  The bridge between the team on /time and the team in the game: which hotkey
  swaps whom in, and who best answers a given enemy.
  """
  use ExUnit.Case, async: false

  alias Pokex.Pokedex.Team

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-team-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "a slot holds exactly one pokémon" do
    Team.add("Jigglypuff")
    Team.add("Sceptile")

    Team.set_slot("Jigglypuff", 5)
    assert Team.slot_of("Jigglypuff") == 5

    # giving 5 to somebody else takes it from Jigglypuff — otherwise a combo
    # would swap to a slot the game has since reassigned
    Team.set_slot("Sceptile", 5)
    assert Team.slot_of("Sceptile") == 5
    assert Team.slot_of("Jigglypuff") == nil
  end

  test "by_slot answers for every slot, empty or not" do
    Team.add("Sceptile")
    Team.set_slot("Sceptile", 3)

    by_slot = Team.by_slot()

    assert Map.keys(by_slot) == [2, 3, 4, 5, 6]
    assert by_slot[3].name == "Sceptile"
    assert by_slot[2] == nil
  end

  test "the swap key is what the game shows, in the Rig's spelling" do
    # the HUD prints "C+2"; the rig speaks "ctrl+2" — same modifier the S+Q
    # slot already uses as "shift+q"
    assert Team.swap_key(2) == "ctrl+2"
    assert Team.swap_key(6) == "ctrl+6"
  end

  test "best_counter picks the slot whose elements hit the enemy hardest" do
    # Magikarp (Water) is weak to Grass and Electric
    Team.add("Sceptile")
    Team.add("Jigglypuff")
    Team.set_slot("Sceptile", 4)
    Team.set_slot("Jigglypuff", 5)

    assert Team.best_counter("Magikarp") == 4
  end

  test "no advantage means NO counter — a combo must not run on a guess" do
    Team.add("Jigglypuff")
    Team.set_slot("Jigglypuff", 5)

    assert Team.best_counter("Jigglypuff") == nil
    assert Team.best_counter("Não Existe") == nil
  end

  test "a member with no slot can never be swapped in" do
    Team.add("Sceptile")

    assert Team.best_counter("Magikarp") == nil
  end

  test "v2 files load with no slots and take them without complaint" do
    File.write!(
      Path.join(Application.get_env(:pokex, :home_dir), "team.json"),
      JSON.encode!(%{members: [%{name: "Sceptile", level: 80}], bank: [], player_level: 90})
    )

    assert [%{name: "Sceptile", level: 80}] = Team.members()
    assert Team.slot_of("Sceptile") == nil

    Team.set_slot("Sceptile", 2)
    assert Team.slot_of("Sceptile") == 2
  end
end
