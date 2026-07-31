defmodule Pokex.Combos.StoreTest do
  use ExUnit.Case, async: false

  alias Pokex.Combos.{Combo, Store}

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp combo(name, member) do
    %Combo{
      name: name,
      trigger: {:enemy_element, "Water"},
      steps: [{:swap_member, member}, {:skill, "4"}, {:swap_counter}]
    }
  end

  test "add round-trips through the file, keeping the seed alongside" do
    assert :ok = Store.add(combo("dorme", "Wigglytuff"))

    names = Enum.map(Store.all(), & &1.name)
    assert "dorme" in names
    assert "sing" in names

    saved = Enum.find(Store.all(), &(&1.name == "dorme"))
    assert saved.steps == [{:swap_member, "Wigglytuff"}, {:skill, "4"}, {:swap_counter}]
    assert saved.enabled?
  end

  # The name is the identity delete/2 and set_enabled/2 work by. Two combos
  # sharing one would make both unreachable, so saving onto a used name replaces.
  test "adding onto an existing name replaces it instead of duplicating" do
    :ok = Store.add(combo("dorme", "Wigglytuff"))
    :ok = Store.add(combo("dorme", "Xatu"))

    matching = Enum.filter(Store.all(), &(&1.name == "dorme"))
    assert length(matching) == 1
    assert hd(matching).steps == [{:swap_member, "Xatu"}, {:skill, "4"}, {:swap_counter}]
  end

  test "a nameless combo is refused rather than written" do
    assert Store.add(%Combo{name: "", trigger: nil, steps: []}) == {:error, :invalid_name}
    refute Enum.any?(Store.all(), &(&1.name == ""))
  end

  test "delete removes only the named one, and is safe on a name that is gone" do
    :ok = Store.add(combo("dorme", "Wigglytuff"))

    assert :ok = Store.delete("dorme")
    refute Enum.any?(Store.all(), &(&1.name == "dorme"))
    assert Enum.any?(Store.all(), &(&1.name == "sing"))

    assert :ok = Store.delete("dorme")
  end

  test "set_enabled survives the round trip" do
    :ok = Store.set_enabled("sing", false)
    refute Enum.find(Store.all(), &(&1.name == "sing")).enabled?
  end

  test "the new triggers survive the round-trip" do
    :ok = Store.add(%Combo{name: "abertura", trigger: {:any_enemy}, steps: [{:skill, "1"}]})
    :ok = Store.add(%Combo{name: "stun", trigger: {:rescue_only}, steps: [{:skill, "1"}]})

    assert Enum.find(Store.all(), &(&1.name == "abertura")).trigger == {:any_enemy}
    assert Enum.find(Store.all(), &(&1.name == "stun")).trigger == {:rescue_only}
  end

  test "the seed already ships the rescue combo, ready for auto-revive" do
    assert %Combo{trigger: {:rescue_only}, steps: steps} =
             Enum.find(Store.all(), &(&1.name == "resgate"))

    assert [{:skill, "1"}, {:wait, _}, {:skill, "2"}] = steps
  end

  test "the dungeon field survives the round-trip; absent in the JSON it reads as nil" do
    :ok = Store.add(%Combo{combo("na-dg", "Wigglytuff") | dungeon: "cavena"})

    assert Enum.find(Store.all(), &(&1.name == "na-dg")).dungeon == "cavena"
    assert Enum.find(Store.all(), &(&1.name == "sing")).dungeon == nil
  end
end
