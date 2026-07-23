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

  test "slugify normaliza e recusa vazio" do
    assert Characters.slugify("Meu Char 2") == {:ok, "meu-char-2"}
    assert Characters.slugify("  ") == {:error, :invalid_name}
  end

  test "create/list/delete round-trip" do
    assert {:ok, "lowbie"} = Characters.create("Lowbie")
    assert Enum.any?(Characters.list(), &(&1.slug == "lowbie" and &1.name == "Lowbie"))
    assert :ok = Characters.delete("lowbie")
    refute Enum.any?(Characters.list(), &(&1.slug == "lowbie"))
  end

  test "active lê e escreve o setting, default vazio", %{settings: s} do
    assert Characters.active(s) == ""
    :ok = Characters.set_active("lowbie", s)
    assert Characters.active(s) == "lowbie"
  end

  test "trocar de personagem avisa quem estiver ouvindo", %{settings: s} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Characters.topic())

    :ok = Characters.set_active("lowbie", s)

    assert_receive {:character, "lowbie"}
  end

  test "apagar o personagem ATIVO larga o ponteiro", %{settings: s} do
    {:ok, slug} = Characters.create("Lowbie")
    :ok = Characters.set_active(slug, s)

    :ok = Characters.delete(slug, s)

    # senão o ponteiro fica apontando pra uma pasta que não existe mais: o time
    # aparece vazio e o painel edita a config de um personagem inexistente
    assert Characters.active(s) == ""
  end

  test "apagar um personagem QUALQUER não mexe em quem está ativo", %{settings: s} do
    {:ok, main} = Characters.create("Main")
    {:ok, outro} = Characters.create("Outro")
    :ok = Characters.set_active(main, s)

    :ok = Characters.delete(outro, s)

    assert Characters.active(s) == main
  end

  test "heal_active zera um ponteiro órfão e preserva um válido", %{settings: s} do
    :ok = Characters.set_active("fantasma", s)
    :ok = Characters.heal_active(s)
    assert Characters.active(s) == ""

    {:ok, slug} = Characters.create("De Verdade")
    :ok = Characters.set_active(slug, s)
    :ok = Characters.heal_active(s)
    assert Characters.active(s) == slug
  end
end
