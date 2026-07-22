defmodule Pokex.CombosTest do
  @moduledoc """
  The deciding half of a combo: does it apply, and to whom does it swap?

  Nothing here touches the game — that is the point. A combo is data, so the
  question "would this run, and how" is answerable at rest.
  """
  use ExUnit.Case, async: false

  alias Pokex.Combos
  alias Pokex.Combos.{Combo, Store}
  alias Pokex.Pokedex.Team

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-combos-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp sing, do: hd(Store.seed())

  describe "matching" do
    test "an element trigger fires on any enemy made of it" do
      # Magikarp is Water
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
  end

  describe "resolution" do
    test "the sing combo becomes real key presses and waits" do
      Team.add("Jigglypuff")
      Team.add("Sceptile")
      Team.set_slot("Jigglypuff", 5)
      Team.set_slot("Sceptile", 4)

      assert {:ok, steps} = Combos.resolve(sing(), "Magikarp")

      assert [
               {:press, "ctrl+5"},
               {:wait, 900},
               {:press, "4"},
               {:wait, 2_500},
               {:press, "ctrl+4"}
             ] = steps

      assert Combos.duration(steps) == 3_400
    end

    test "a pokémon with no slot means the combo does NOT run" do
      # half a combo is worse than none: it would leave Jigglypuff out, asleep
      # in front of the enemy, with no counter coming
      Team.add("Jigglypuff")
      Team.add("Sceptile")
      Team.set_slot("Sceptile", 4)

      assert {:skip, {:no_slot, "Jigglypuff"}} = Combos.resolve(sing(), "Magikarp")
    end

    test "an enemy nobody answers means the combo does NOT run" do
      Team.add("Jigglypuff")
      Team.set_slot("Jigglypuff", 5)

      assert {:skip, {:no_counter, "Magikarp"}} = Combos.resolve(sing(), "Magikarp")
    end
  end

  describe "the store" do
    test "seeds itself, round-trips, and survives a corrupt file" do
      assert [%Combo{name: "sing"}] = Store.all()

      Store.set_enabled("sing", false)
      assert [%Combo{name: "sing", enabled?: false}] = Store.all()

      # every step shape must survive the trip
      assert [%Combo{steps: steps}] = Store.all()
      assert {:swap_member, "Jigglypuff"} in steps
      assert {:wait, :combo_sing_wait_ms} in steps
      assert {:swap_counter} in steps

      File.write!(Path.join(Application.get_env(:pokex, :home_dir), "combos.json"), "{[nope")
      assert [%Combo{name: "sing", enabled?: true}] = Store.all()
    end
  end
end
