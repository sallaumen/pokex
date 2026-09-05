defmodule Pokex.Rig.Mac.CommandsNativeTest do
  use ExUnit.Case, async: true

  alias Pokex.Rig.Mac.Commands

  # 02/09: "shift+1 e shift+3 às vezes saem separadas, daí a skill 1 ou 3 sai
  # sozinha e o modo não muda". A postura passa a sair pelo helper nativo como
  # UMA sequência — e este é o parse que decide quem pode ir por lá.
  describe "native_combo/1" do
    test "the stance key becomes code + modifier" do
      assert Commands.native_combo("shift+3") == {:ok, 20, ["shift"]}
      assert Commands.native_combo("shift+1") == {:ok, 18, ["shift"]}
      assert Commands.native_combo("ctrl+shift+f4") == {:ok, 118, ["ctrl", "shift"]}
    end

    test "without a modifier it is the usual key" do
      assert Commands.native_combo("3") == {:ok, 20, []}
      assert Commands.native_combo("tab") == {:ok, 48, []}
    end

    test "a key without a code or with an unknown modifier stays with osascript" do
      assert Commands.native_combo("shift+z") == :error
      assert Commands.native_combo("fn+3") == :error
      assert Commands.native_combo("z") == :error
    end
  end
end
