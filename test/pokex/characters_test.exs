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

  test "create/list/delete round-trip", %{settings: s} do
    assert {:ok, "lowbie"} = Characters.create("Lowbie")
    assert Enum.any?(Characters.list(), &(&1.slug == "lowbie" and &1.name == "Lowbie"))
    assert :ok = Characters.delete("lowbie", s)
    refute Enum.any?(Characters.list(), &(&1.slug == "lowbie"))
  end

  test "active reads and writes the setting, empty default", %{settings: s} do
    assert Characters.active(s) == ""
    :ok = Characters.set_active("lowbie", s)
    assert Characters.active(s) == "lowbie"
  end

  test "switching announces it to whoever is listening", %{settings: s} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Characters.topic())

    :ok = Characters.set_active("lowbie", s)

    assert_receive {:character, "lowbie"}
  end

  describe "the pointer never outlives the folder" do
    test "deleting the ACTIVE character drops the pointer", %{settings: s} do
      {:ok, slug} = Characters.create("Lowbie")
      :ok = Characters.set_active(slug, s)

      :ok = Characters.delete(slug, s)

      # otherwise the pointer names a folder that is gone: the team reads as
      # EMPTY with nothing on screen saying why
      assert Characters.active(s) == ""
    end

    test "deleting ANY OTHER character leaves the active one alone", %{settings: s} do
      {:ok, main} = Characters.create("Main")
      {:ok, other} = Characters.create("Outro")
      :ok = Characters.set_active(main, s)

      :ok = Characters.delete(other, s)

      assert Characters.active(s) == main
    end

    test "renaming the ACTIVE character carries the pointer to the new slug", %{settings: s} do
      {:ok, slug} = Characters.create("Lowbie")
      :ok = Characters.set_active(slug, s)

      {:ok, new_slug} = Characters.rename(slug, "Highbie", s)

      # the folder MOVED — a pointer left on "lowbie" is orphan on the spot
      assert new_slug == "highbie"
      assert Characters.active(s) == "highbie"
    end

    test "renaming someone else does not steal the pointer", %{settings: s} do
      {:ok, main} = Characters.create("Main")
      {:ok, other} = Characters.create("Outro")
      :ok = Characters.set_active(main, s)

      {:ok, _} = Characters.rename(other, "Renomeado", s)

      assert Characters.active(s) == main
    end

    test "heal_active clears an orphan pointer and preserves a valid one", %{settings: s} do
      :ok = Characters.set_active("fantasma", s)
      :ok = Characters.heal_active(s)
      assert Characters.active(s) == ""

      {:ok, slug} = Characters.create("De Verdade")
      :ok = Characters.set_active(slug, s)
      :ok = Characters.heal_active(s)
      assert Characters.active(s) == slug
    end
  end
end
