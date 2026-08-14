defmodule Pokex.CombosTest do
  @moduledoc """
  The deciding half of a combo: does it apply, and to whom does it swap?

  Nothing here touches the game — that is the point. A combo is data, so the
  question "would this run, and how" is answerable at rest.
  """
  use ExUnit.Case, async: false

  alias Pokex.Combos
  alias Pokex.Combos.{Combo, Store}

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-combos-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Pokex.TestHome.restore()
      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp sing, do: hd(Store.seed())

  describe "matching" do
    test "an element trigger fires on any enemy made of it" do
      assert %Combo{name: "sing"} = Combos.match(Store.seed(), "Magikarp")
    end

    test "a species trigger beats an element trigger — naming is more specific" do
      species = %Combo{name: "só-magikarp", trigger: {:enemy_species, "Magikarp"}, steps: []}

      assert %Combo{name: "só-magikarp"} = Combos.match([sing(), species], "Magikarp")
    end

    test "an enemy the trigger does not describe fires nothing" do
      assert Combos.match(Store.seed(), "Sceptile") == nil
      assert Combos.match(Store.seed(), "Não Existe") == nil
      assert Combos.match(Store.seed(), nil) == nil
    end

    test "a disabled combo never fires" do
      off = %Combo{sing() | enabled?: false}

      assert Combos.match([off], "Magikarp") == nil
    end

    test "a combo with a dungeon only matches in the right one; a global combo always matches" do
      glob = %Combo{name: "g", trigger: {:enemy_element, "Water"}, steps: [], dungeon: nil}
      dg = %Combo{name: "d", trigger: {:enemy_element, "Water"}, steps: [], dungeon: "cavena"}

      assert Combos.match([dg], "Magikarp", "cavena").name == "d"
      assert Combos.match([dg], "Magikarp", "outra") == nil
      assert Combos.match([dg], "Magikarp") == nil
      assert Combos.match([glob], "Magikarp", "qualquer").name == "g"
      assert Combos.match([glob], "Magikarp").name == "g"
    end
  end

  describe "planning and pressing" do
    # what the :team feed sees on screen at this instant
    defp live(pairs), do: Enum.map(pairs, fn {slot, name} -> %{slot: slot, name: name} end)

    test "fixed steps resolve up front; swaps stay symbolic" do
      rows = live([{5, "Jigglypuff"}, {4, "Sceptile"}])

      assert {:ok, steps} = Combos.plan(sing(), "Magikarp", rows)

      assert [
               {:swap_member, "Jigglypuff"},
               {:wait, 900},
               {:press, "4"},
               {:wait, 2_500},
               {:swap_counter}
             ] = steps

      assert Combos.duration(steps) == 3_400
    end

    # The bug eager resolution hides: the swap itself reorders the rows, so the counter's
    # key must be computed after that happens — seconds later, from a fresh reading.
    test "a swap is keyed by the team as it is AT THAT MOMENT" do
      before = live([{5, "Jigglypuff"}, {4, "Sceptile"}])
      assert {:ok, "ctrl+5"} = Combos.key_for({:swap_member, "Jigglypuff"}, "Magikarp", before)

      later = live([{4, "Jigglypuff"}, {3, "Sceptile"}])
      assert {:ok, "ctrl+3"} = Combos.key_for({:swap_counter}, "Magikarp", later)

      assert {:ok, "ctrl+4"} = Combos.key_for({:swap_counter}, "Magikarp", before)
    end

    test "a pokémon that is NOT on screen means the combo never starts" do
      rows = live([{4, "Sceptile"}])

      assert {:skip, {:not_on_screen, "Jigglypuff"}} = Combos.plan(sing(), "Magikarp", rows)
    end

    test "an enemy nobody answers means the combo never starts" do
      rows = live([{5, "Jigglypuff"}])

      assert {:skip, {:no_counter, "Magikarp"}} = Combos.plan(sing(), "Magikarp", rows)
    end

    test "a row with no hotkey label is never swapped to" do
      rows = [%{slot: nil, name: "Jigglypuff"}, %{slot: 4, name: "Sceptile"}]

      assert {:skip, {:not_on_screen, "Jigglypuff"}} = Combos.plan(sing(), "Magikarp", rows)
    end

    test "a row whose portrait was not recognised is never swapped to" do
      rows = [%{slot: 5, name: "Jigglypuff"}, %{slot: 4, name: nil}]

      assert {:skip, {:no_counter, "Magikarp"}} = Combos.plan(sing(), "Magikarp", rows)
    end

    test "a swap that became impossible mid-combo refuses instead of guessing" do
      assert {:skip, {:not_on_screen, "Jigglypuff"}} =
               Combos.key_for({:swap_member, "Jigglypuff"}, "Magikarp", live([{2, "Sceptile"}]))
    end
  end

  describe "triggers" do
    test "\"any enemy\" matches everything that engages" do
      qualquer = %Combo{name: "abertura", trigger: {:any_enemy}, steps: [{:skill, "1"}]}

      assert %Combo{name: "abertura"} = Combos.match([qualquer], "Magikarp")
      assert %Combo{name: "abertura"} = Combos.match([qualquer], "Pidgey")
    end

    test "specificity: species > element > any enemy" do
      qualquer = %Combo{name: "abertura", trigger: {:any_enemy}, steps: []}
      especie = %Combo{name: "só-magikarp", trigger: {:enemy_species, "Magikarp"}, steps: []}

      assert %Combo{name: "sing"} = Combos.match([qualquer, sing()], "Magikarp")
      assert %Combo{name: "só-magikarp"} = Combos.match([qualquer, sing(), especie], "Magikarp")
    end

    test "\"rescue only\" never runs in a fight — that is what reserves the skills" do
      resgate = %Combo{name: "resgate", trigger: {:rescue_only}, steps: [{:skill, "1"}]}

      assert Combos.match([resgate], "Magikarp") == nil
      assert Combos.rescue_eligible?(resgate)
    end
  end

  describe "rescue_eligible?/1" do
    test "only skills and waits can prefix the rescue" do
      eligible = %Combo{
        name: "stun",
        trigger: nil,
        steps: [{:skill, "1"}, {:wait, 500}, {:skill, "2"}, {:wait, :combo_sing_wait_ms}]
      }

      assert Combos.rescue_eligible?(eligible)
    end

    test "any team swap makes the combo ineligible" do
      with_swap = %Combo{name: "sing", trigger: nil, steps: [{:skill, "1"}, {:swap_counter}]}
      refute Combos.rescue_eligible?(with_swap)

      with_member = %Combo{
        name: "jiggly",
        trigger: nil,
        steps: [{:swap_member, "Jigglypuff"}, {:skill, "4"}]
      }

      refute Combos.rescue_eligible?(with_member)
    end
  end

  describe "the store" do
    test "seeds itself, round-trips, and survives a corrupt file" do
      assert [%Combo{name: "sing"}, %Combo{name: "resgate"}] = Store.all()

      Store.set_enabled("sing", false)
      assert [%Combo{name: "sing", enabled?: false}, %Combo{name: "resgate"}] = Store.all()

      assert [%Combo{steps: steps} | _resgate] = Store.all()
      assert {:swap_member, "Jigglypuff"} in steps
      assert {:wait, :combo_sing_wait_ms} in steps
      assert {:swap_counter} in steps

      File.write!(Path.join(Application.get_env(:pokex, :home_dir), "combos.json"), "{[nope")
      assert [%Combo{name: "sing", enabled?: true}, %Combo{name: "resgate"}] = Store.all()
    end
  end
end
