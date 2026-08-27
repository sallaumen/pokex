defmodule Pokex.Pokedex.TeamTest do
  # async: false — scopes the global :home_dir/:pokedex_path env per test
  use ExUnit.Case, async: false

  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Pokedex.Team

  @dataset %{
    "species" => [
      %{"name" => "Seadra", "number" => 117, "elements" => ["Water"]},
      %{
        "name" => "Shiny Seadra",
        "number" => 117,
        "elements" => ["Water"],
        "shiny_of" => "Seadra"
      },
      %{"name" => "Venusaur", "number" => 3, "elements" => ["Grass"]}
    ],
    "lures" => []
  }

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Pokex.TestHome.restore()
    end)

    :ok
  end

  @tag :tmp_dir
  test "add/members/remove round-trip, idempotent across the two lists" do
    assert Team.members() == []
    assert Team.bank() == []

    assert {:ok, _} = Team.add("Seadra")
    assert {:ok, _} = Team.add("Shiny Seadra")
    assert {:ok, _} = Team.add("Seadra")
    assert Team.member_names() == ["Seadra", "Shiny Seadra"]

    Team.remove("Seadra")
    assert Team.member_names() == ["Shiny Seadra"]
  end

  @tag :tmp_dir
  test "bank: add directly, move there and back keeping the level" do
    assert {:ok, _} = Team.add("Venusaur", :bank)
    assert Enum.map(Team.bank(), & &1.name) == ["Venusaur"]
    assert Team.members() == []

    Team.set_level("Venusaur", 72)
    Team.move("Venusaur", :team)
    assert [%{name: "Venusaur", level: 72}] = Team.members()
    assert Team.bank() == []

    Team.move("Venusaur", :bank)
    assert [%{name: "Venusaur", level: 72}] = Team.bank()

    assert {:ok, _} = Team.add("Venusaur", :team)
    assert Team.bank() == []
    assert Team.member_names() == ["Venusaur"]
  end

  @tag :tmp_dir
  test "player level and window persist; margin defaults to 15" do
    assert Team.player_level() == nil
    assert Team.level_margin() == 15

    Team.set_player_level(88)
    Team.set_level_margin(20)
    assert Team.player_level() == 88
    assert Team.level_margin() == 20

    Team.set_player_level(nil)
    assert Team.player_level() == nil
  end

  @tag :tmp_dir
  test "a v1 team.json (list of names) loads as a team without levels" do
    File.write!(
      Path.join(Pokex.Home.dir(), "team.json"),
      JSON.encode!(%{members: ["Seadra", "Venusaur"]})
    )

    # every field a later version added is simply unset — `cooldowns` is the newest
    assert Team.members() == [
             %{name: "Seadra", level: nil, slot: nil, skills: %{}, cooldowns: %{}, bar: nil},
             %{name: "Venusaur", level: nil, slot: nil, skills: %{}, cooldowns: %{}, bar: nil}
           ]

    assert Team.bank() == []
    assert Team.level_margin() == 15
  end

  @tag :tmp_dir
  test "a name the Pokédex doesn't know is rejected" do
    assert Team.add("Digimon") == {:error, :unknown}
    assert Team.members() == []
  end

  @tag :tmp_dir
  test "a corrupt team file degrades to empty" do
    File.write!(Path.join(Pokex.Home.dir(), "team.json"), "{lixo")
    assert Team.members() == []
    assert Team.bank() == []
  end

  # file/0 reads the GLOBAL Settings (via Characters.active/0), so these tests
  # set :active_character globally — SettingsStash restores it on exit.
  @tag :tmp_dir
  test "no character reads the legacy team.json; a character reads chars/<slug>", %{tmp_dir: tmp} do
    Pokex.SettingsStash.stash_keys!([:active_character])

    Pokex.Settings.put(:active_character, "")
    assert Team.file() == Path.join(tmp, "team.json")

    Pokex.Settings.put(:active_character, "lowbie")
    assert Team.file() == Path.join([tmp, "chars", "lowbie", "team.json"])
  end

  @tag :tmp_dir
  test "per-character round-trip: writes land in chars/<slug> and the legacy team reappears",
       %{tmp_dir: tmp} do
    Pokex.SettingsStash.stash_keys!([:active_character])

    Pokex.Settings.put(:active_character, "")
    assert {:ok, _} = Team.add("Venusaur")
    assert Team.member_names() == ["Venusaur"]

    Pokex.Settings.put(:active_character, "lowbie")
    assert Team.members() == []

    assert {:ok, _} = Team.add("Seadra")
    assert Team.member_names() == ["Seadra"]
    assert File.exists?(Path.join([tmp, "chars", "lowbie", "team.json"]))

    Pokex.Settings.put(:active_character, "")
    assert Team.member_names() == ["Venusaur"]
  end

  # A strategy names JOBS ("use the area damage"), and each pokémon answers
  # with its own keys — so the jobs have to survive the disk, per character,
  # beside the level and the slot that were already there.
  describe "what each skill is for" do
    @tag :tmp_dir
    test "a job round-trips, and moving to the bank keeps it" do
      {:ok, _} = Team.add("Venusaur")

      Team.set_skills("Venusaur", %{"4" => :heal, "3" => :aoe, "5" => :aoe})

      assert SkillProfile.keys(Team.skills("Venusaur"), :aoe) == ["3", "5"]
      assert SkillProfile.keys(Team.skills("Venusaur"), :heal) == ["4"]

      Team.move("Venusaur", :bank)
      assert SkillProfile.keys(Team.skills("Venusaur"), :aoe) == ["3", "5"]
    end

    @tag :tmp_dir
    test "the level and the slot survive a skill edit, and vice-versa" do
      {:ok, _} = Team.add("Venusaur")
      Team.set_level("Venusaur", 87)
      Team.set_skills("Venusaur", %{"1" => :crowd})

      assert [%{name: "Venusaur", level: 87, skills: %{"1" => :crowd}}] = Team.members()
    end

    @tag :tmp_dir
    test "a pokémon nobody has answers empty instead of raising" do
      assert Team.skills("Ninguém") == %{}
      assert Team.set_skills("Ninguém", %{"1" => :crowd})
    end

    @tag :tmp_dir
    test "a hand-edited file with a bogus job loads as no job, never a new atom" do
      File.write!(
        Path.join(Pokex.Home.dir(), "team.json"),
        JSON.encode!(%{
          members: [%{"name" => "Venusaur", "skills" => %{"3" => "aoe", "9" => "banana_xyz"}}]
        })
      )

      assert Team.skills("Venusaur") == %{"3" => :aoe}
      assert_raise ArgumentError, fn -> String.to_existing_atom("banana_xyz") end
    end
  end

  # The bot cannot read which pokémon is out yet, so he says it. Every rule that
  # depends on knowing — open with area, keep the control for the revive —
  # hangs off this one answer.
  describe "the pokémon on the field" do
    @tag :tmp_dir
    test "nobody is chosen until he chooses" do
      assert Team.active() == nil
    end

    @tag :tmp_dir
    test "the choice is stored, and nil clears it" do
      {:ok, _} = Team.add("Seadra")

      Team.set_active("Seadra")
      assert Team.active() == "Seadra"

      Team.set_active(nil)
      assert Team.active() == nil
    end

    @tag :tmp_dir
    test "a name outside the TEAM is not a choice — the bank is not on the field" do
      {:ok, _} = Team.add("Venusaur", :bank)

      Team.set_active("Venusaur")
      assert Team.active() == nil

      Team.set_active("Ninguém")
      assert Team.active() == nil
    end

    # Fighting with the bar of a pokémon that left the team would press keys
    # belonging to something that is not out.
    @tag :tmp_dir
    test "a chosen pokémon that leaves the team stops being the choice" do
      {:ok, _} = Team.add("Seadra")
      Team.set_active("Seadra")

      Team.move("Seadra", :bank)
      assert Team.active() == nil

      Team.move("Seadra", :team)
      assert Team.active() == "Seadra"
    end

    # Combat caches the loadout — a cache with no invalidation would keep
    # pressing yesterday's keys after he re-classified them.
    @tag :tmp_dir
    test "choosing, and re-classifying, both announce themselves" do
      {:ok, _} = Team.add("Seadra")
      Phoenix.PubSub.subscribe(Pokex.PubSub, Team.topic())

      Team.set_active("Seadra")
      assert_receive {:team_changed}

      Team.set_skills("Seadra", %{"3" => :aoe})
      assert_receive {:team_changed}
    end
  end
end
