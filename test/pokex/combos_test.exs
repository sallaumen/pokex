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

    test "um combo com dungeon só casa na DG certa; global casa sempre" do
      glob = %Combo{name: "g", trigger: {:enemy_element, "Water"}, steps: [], dungeon: nil}
      dg = %Combo{name: "d", trigger: {:enemy_element, "Water"}, steps: [], dungeon: "cavena"}

      assert Combos.match([dg], "Magikarp", "cavena").name == "d"
      assert Combos.match([dg], "Magikarp", "outra") == nil
      # fora do cavebot (nenhuma dungeon publicada), um combo restrito não vale
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

    test "a swap is keyed by the team as it is AT THAT MOMENT" do
      # This is the bug that eager resolution hides: swapping Jigglypuff in is
      # itself what reorders the rows, so the counter's key must be computed
      # after that has happened — 3.4 seconds later, from a fresh reading.
      before = live([{5, "Jigglypuff"}, {4, "Sceptile"}])
      assert {:ok, "ctrl+5"} = Combos.key_for({:swap_member, "Jigglypuff"}, "Magikarp", before)

      # Jigglypuff went out; everyone shuffled up a row
      later = live([{4, "Jigglypuff"}, {3, "Sceptile"}])
      assert {:ok, "ctrl+3"} = Combos.key_for({:swap_counter}, "Magikarp", later)

      # the same step against the OLD reading would have pressed the wrong key
      assert {:ok, "ctrl+4"} = Combos.key_for({:swap_counter}, "Magikarp", before)
    end

    test "a pokémon that is NOT on screen means the combo never starts" do
      # half a combo strands whoever it just sent out
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
      # the runner asks for each key at press time; if the pokémon has left the
      # panel between steps, this is where it finds out
      assert {:skip, {:not_on_screen, "Jigglypuff"}} =
               Combos.key_for({:swap_member, "Jigglypuff"}, "Magikarp", live([{2, "Sceptile"}]))
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
