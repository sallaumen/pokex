defmodule Pokex.Pokedex.SkillProfileTest do
  @moduledoc """
  What each skill of a pokémon is FOR.

  The point of the categories is that a strategy can say "use the area damage"
  without knowing whose bar it is talking about — Vileplume's area is 3 and 5,
  Vespiqueen's is 3, 4 and 5, and the same written plan has to drive both.
  """
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.SkillProfile

  describe "assigning a job to a key" do
    test "an empty profile categorises nothing" do
      assert SkillProfile.by_category(%{}) == %{
               buffs: [],
               aoe: [],
               single: [],
               heal: [],
               crowd: []
             }

      assert SkillProfile.keys(%{}, :aoe) == []
    end

    test "a key gets exactly ONE job — assigning again moves it" do
      profile =
        %{}
        |> SkillProfile.put("3", :aoe)
        |> SkillProfile.put("3", :crowd)

      assert SkillProfile.keys(profile, :crowd) == ["3"]
      assert SkillProfile.keys(profile, :aoe) == []
    end

    test ":none takes the job away" do
      profile = %{} |> SkillProfile.put("3", :aoe) |> SkillProfile.put("3", :none)

      assert SkillProfile.by_category(profile) == %{
               buffs: [],
               aoe: [],
               single: [],
               heal: [],
               crowd: []
             }
    end

    test "a job nobody knows, or a key no hotbar has, changes nothing" do
      profile = SkillProfile.put(%{}, "3", :aoe)

      assert SkillProfile.put(profile, "3", :teleport) == profile
      assert SkillProfile.put(profile, "f1", :aoe) == profile
      assert SkillProfile.put(profile, "12", :aoe) == profile
    end
  end

  describe "the firing order" do
    # Hotbar order IS the firing order, and it matches how he described every
    # one of his own combos ("as skills 3 e 5", "3, 4, 5"): left to right.
    test "keys come out in hotbar order, however they were assigned" do
      profile =
        %{}
        |> SkillProfile.put("5", :aoe)
        |> SkillProfile.put("3", :aoe)
        |> SkillProfile.put("4", :aoe)

      assert SkillProfile.keys(profile, :aoe) == ["3", "4", "5"]
    end

    test "key 0 is the LAST slot, not the first" do
      profile = %{} |> SkillProfile.put("0", :aoe) |> SkillProfile.put("9", :aoe)

      assert SkillProfile.keys(profile, :aoe) == ["9", "0"]
    end
  end

  # The whole reason the categories exist: one written plan, many pokémon.
  describe "the same plan on two different pokémon" do
    test "each answers with its own keys, and an empty category answers []" do
      vileplume =
        %{}
        |> SkillProfile.put("1", :crowd)
        |> SkillProfile.put("2", :crowd)
        |> SkillProfile.put("3", :aoe)
        |> SkillProfile.put("4", :heal)
        |> SkillProfile.put("5", :aoe)

      vespiqueen =
        %{}
        |> SkillProfile.put("1", :crowd)
        |> SkillProfile.put("2", :buffs)
        |> SkillProfile.put("3", :aoe)
        |> SkillProfile.put("4", :aoe)
        |> SkillProfile.put("5", :aoe)

      assert SkillProfile.keys(vileplume, :aoe) == ["3", "5"]
      assert SkillProfile.keys(vespiqueen, :aoe) == ["3", "4", "5"]

      # Vileplume has no barrier at all: the plan's "buffs" step simply has
      # nothing to press, which is what lets the SAME plan drive both
      assert SkillProfile.keys(vileplume, :buffs) == []
      assert SkillProfile.keys(vespiqueen, :heal) == []
    end
  end

  # "eu seleciono, mas o combo não é uma junção" (Lucas, 2026-08-11). The first
  # cut printed every classified key joined left to right; the jobs happen at
  # DIFFERENT moments of the hunt and only two of them are the kill.
  describe "the kill combo" do
    test "area first, single-target after — that is the whole combo" do
      profile =
        %{}
        |> SkillProfile.put("7", :single)
        |> SkillProfile.put("4", :aoe)
        |> SkillProfile.put("3", :aoe)

      assert SkillProfile.combo(profile) == ["3", "4", "7"]
    end

    # Single target "só funciona se eu estiver marcando um alvo": it can never
    # come first, however early on the bar it sits.
    test "a single-target key on a LOW slot still fires after every area one" do
      profile =
        %{}
        |> SkillProfile.put("1", :single)
        |> SkillProfile.put("9", :aoe)

      assert SkillProfile.combo(profile) == ["9", "1"]
    end

    test "the aura and the heal are NOT in it — they have their own moments" do
      profile =
        %{}
        |> SkillProfile.put("1", :buffs)
        |> SkillProfile.put("3", :aoe)
        |> SkillProfile.put("8", :heal)

      assert SkillProfile.combo(profile) == ["3"]
    end

    # The rule that protects the revive: a control skill spent on an ordinary
    # fight is not there when the recall needs the stun.
    test "control is BARRED from the combo, however he classifies it" do
      profile =
        %{}
        |> SkillProfile.put("2", :crowd)
        |> SkillProfile.put("3", :crowd)

      assert SkillProfile.combo(profile) == []
      assert SkillProfile.keys(profile, :crowd) == ["2", "3"]
      refute SkillProfile.in_combo?(:crowd)
    end

    test "a key with its job taken away leaves the combo" do
      profile =
        %{}
        |> SkillProfile.put("1", :aoe)
        |> SkillProfile.put("3", :aoe)
        |> SkillProfile.put("1", :none)

      assert SkillProfile.combo(profile) == ["3"]
    end

    test "nothing classified is an empty combo, not a crash" do
      assert SkillProfile.combo(%{}) == []
    end
  end

  describe "each job is a moment" do
    test "the moments come back in the order the hunt lives them" do
      profile =
        %{}
        |> SkillProfile.put("2", :crowd)
        |> SkillProfile.put("3", :aoe)
        |> SkillProfile.put("1", :buffs)
        |> SkillProfile.put("7", :single)

      assert SkillProfile.moments(profile) == [
               {:buffs, ["1"]},
               {:aoe, ["3"]},
               {:single, ["7"]},
               {:crowd, ["2"]}
             ]
    end

    test "a job this pokémon does not have is simply absent" do
      assert SkillProfile.moments(SkillProfile.put(%{}, "3", :aoe)) == [{:aoe, ["3"]}]
      assert SkillProfile.moments(%{}) == []
    end

    test "only area and single-target belong to the kill" do
      assert Enum.filter(SkillProfile.categories(), &SkillProfile.in_combo?/1) == [:aoe, :single]
    end

    test "every job says when it happens and carries an icon" do
      for category <- SkillProfile.categories() do
        assert is_binary(SkillProfile.moment(category))
        assert is_binary(SkillProfile.icon(category))
        assert is_binary(SkillProfile.label(category))
      end
    end
  end

  describe "putting his own keys in firing order" do
    test "dedupes and sorts by the bar, never by the order they arrived" do
      assert SkillProfile.in_firing_order(["5", "1", "3", "1"]) == ["1", "3", "5"]
    end

    test "the tenth slot fires LAST, because on the bar 0 comes after 9" do
      assert SkillProfile.in_firing_order(["0", "9", "2"]) == ["2", "9", "0"]
    end

    test "a key no hotbar has drops out" do
      assert SkillProfile.in_firing_order(["3", "f1", ""]) == ["3"]
    end
  end
end
