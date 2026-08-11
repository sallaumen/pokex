defmodule Pokex.Bots.Combat.StrategyTest do
  @moduledoc """
  Which keys the fight presses, and in what order.

  Every rule here is one he stated on 2026-08-11, and each test is written so
  that breaking the rule breaks the test — the point of moving the decision out
  of a hand-written `skill_keys` list is that the reasoning becomes arguable.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.{Loadout, Strategy}

  # His Shiny Vileplume as he classified it: aura on 1, control on 2, area on
  # 3..6, and a single-target on 7.
  defp vileplume do
    Loadout.resolve("Shiny Vileplume", %{
      "1" => :buffs,
      "2" => :crowd,
      "3" => :aoe,
      "4" => :aoe,
      "5" => :aoe,
      "6" => :aoe,
      "7" => :single
    })
  end

  describe "opening a pile that has just finished gathering" do
    # "quando termina o período de mobar, ele vai começar sempre usando as
    # skills em área"
    test "area comes first, always — the gathering only exists for this" do
      assert Strategy.opening(vileplume()) == ~w(3 4 5 6 7)
    end

    # The crowd is why the hunt walked the whole blue stretch; the battle list
    # at that instant may still be catching up with what is walking in.
    test "even reading ONE enemy, the opening still leads with area" do
      assert Strategy.skill_order(vileplume(), opening?: true, enemies: 1) == ~w(3 4 5 6 7)
    end
  end

  describe "counting what is on screen" do
    # "poderíamos contar a quantidade de inimigos, e ir usando as skills single
    # target primeiro com poucos inimigos e guardar para mobar em inimigos
    # maiores" — the fishing case, where nothing is ever gathered.
    test "one enemy: single-target first, area behind it" do
      assert Strategy.skill_order(vileplume(), enemies: 1) == ~w(7 3 4 5 6)
    end

    test "a crowd: area first, without any gathering needed" do
      assert Strategy.skill_order(vileplume(), enemies: 5) == ~w(3 4 5 6 7)
    end

    test "the threshold is the number, not a feeling — and it is configurable" do
      assert Strategy.skill_order(vileplume(), enemies: 2, aoe_from: 3) == ~w(7 3 4 5 6)
      assert Strategy.skill_order(vileplume(), enemies: 3, aoe_from: 3) == ~w(3 4 5 6 7)
      assert Strategy.skill_order(vileplume(), enemies: 2, aoe_from: 2) == ~w(3 4 5 6 7)
    end

    test "with nothing said about the crowd it assumes ONE — the cautious read" do
      assert Strategy.skill_order(vileplume(), []) == ~w(7 3 4 5 6)
    end
  end

  describe "what the fight must never press" do
    # The rule that protects the auto-revive: the control skill has to survive
    # the fight to be there when the recall needs the stun.
    test "the control key is in NO order, in any situation" do
      for opts <- [[enemies: 1], [enemies: 9], [opening?: true]] do
        refute "2" in Strategy.skill_order(vileplume(), opts)
      end

      assert Strategy.reserved(vileplume()) == ["2"]
    end

    # Not because they are useless — because they answer to moments this
    # function does not own: the middle of the huddle, and a health bar.
    test "the aura and the heal are not in the attack order either" do
      loadout =
        Loadout.resolve("Gardevoir", %{"1" => :buffs, "3" => :aoe, "8" => :heal})

      order = Strategy.skill_order(loadout, enemies: 4)

      assert order == ["3"]
      refute "1" in order
      refute "8" in order
    end
  end

  describe "when there is nothing to go on" do
    # nil is what makes every consumer fall back to the global key list, which
    # is exactly the behaviour that existed before any of this.
    test "no loadout answers an empty order, never a crash" do
      assert Strategy.skill_order(nil, enemies: 3) == []
      assert Strategy.opening(nil) == []
      assert Strategy.reserved(nil) == []
    end

    # nil means "he classified NOTHING". A pokémon with only a control and a
    # heal is classified — it just has nothing to fight with, which is the
    # fight's question (`attacks?/1`) and not the same one a scheduled aura asks.
    test "only reserved and reactive keys: a loadout, but nothing to attack with" do
      loadout = Loadout.resolve("Gogoat", %{"2" => :crowd, "8" => :heal})

      refute Loadout.attacks?(loadout)
      assert Strategy.skill_order(loadout, enemies: 4) == []
      assert loadout.crowd == ["2"]

      assert Loadout.resolve("Gogoat", %{}) == nil
    end
  end

  describe "reading the loadout out loud" do
    test "it names the pokémon and what it brings" do
      assert Loadout.describe(vileplume()) ==
               "Shiny Vileplume · área 3+4+5+6 · alvo único 7 · aura 1"
    end

    test "no choice says so, instead of an empty line" do
      assert Loadout.describe(nil) == "sem pokémon escolhido"
    end
  end
end
