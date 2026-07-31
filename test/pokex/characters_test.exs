defmodule Pokex.CharactersTest do
  use ExUnit.Case, async: false
  alias Pokex.{Characters, Settings}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    {:ok, s} = Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    %{settings: s}
  end

  @moduletag :tmp_dir

  test "slugify normalizes and rejects empty" do
    assert Characters.slugify("Meu Char 2") == {:ok, "meu-char-2"}
    assert Characters.slugify("  ") == {:error, :invalid_name}
  end

  test "create/list/delete round-trip" do
    assert {:ok, "lowbie"} = Characters.create("Lowbie")
    assert Enum.any?(Characters.list(), &(&1.slug == "lowbie" and &1.name == "Lowbie"))
    assert :ok = Characters.delete("lowbie")
    refute Enum.any?(Characters.list(), &(&1.slug == "lowbie"))
  end

  test "active reads and writes the setting, empty default", %{settings: s} do
    assert Characters.active(s) == ""
    :ok = Characters.set_active("lowbie", s)
    assert Characters.active(s) == "lowbie"
  end
end
