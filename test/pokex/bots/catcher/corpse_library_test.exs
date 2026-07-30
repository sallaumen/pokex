defmodule Pokex.Bots.Catcher.CorpseLibraryTest do
  # async: false — home_dir e o cache em :persistent_term são globais
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Vision.Frame

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  # um "sprite" sólido de uma cor — paleta inconfundível pro histograma
  defp solid(r, g, b, px \\ 16) do
    %Frame{width: px, height: px, rgba: :binary.copy(<<r, g, b, 255>>, px * px)}
  end

  # metade cor do sprite, metade "chão" — simula o corpo composto sobre fundo
  defp half(r, g, b, ground, px \\ 16) do
    {gr, gg, gb} = ground
    metade = div(px * px, 2)

    %Frame{
      width: px,
      height: px,
      rgba: :binary.copy(<<r, g, b, 255>>, metade) <> :binary.copy(<<gr, gg, gb, 255>>, metade)
    }
  end

  @tag :tmp_dir
  test "ensinar, listar, sobrescrever pelo slug e apagar" do
    assert CorpseLibrary.empty?()

    :ok = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    :ok = CorpseLibrary.add("Zubat", solid(60, 60, 220))
    assert [%{"name" => "Zubat"}, %{"name" => "Rattata"}] = CorpseLibrary.list()

    # mesmo nome = re-ensino, não duplicata
    :ok = CorpseLibrary.add("rattata", solid(181, 121, 201))
    assert length(CorpseLibrary.list()) == 2

    :ok = CorpseLibrary.delete("zubat")
    assert [%{"name" => "rattata"}] = CorpseLibrary.list()
  end

  @tag :tmp_dir
  test "nome vazio é recusado" do
    assert {:error, :nome_vazio} = CorpseLibrary.add("   ", solid(1, 2, 3))
  end

  @tag :tmp_dir
  test "casa o corpo certo mesmo com METADE do recorte sendo chão" do
    :ok = CorpseLibrary.add("Rattata", half(180, 120, 200, {90, 70, 40}))
    :ok = CorpseLibrary.add("Zubat", half(60, 60, 220, {90, 70, 40}))

    # candidato: a MESMA paleta do Rattata sobre um chão DIFERENTE
    candidato = half(180, 120, 200, {50, 110, 60})

    assert {:ok, %{name: "Rattata", score: score}} = CorpseLibrary.match(candidato, 0.4)
    assert score >= 0.4
  end

  @tag :tmp_dir
  test "paleta desconhecida não casa; acervo vazio nunca casa" do
    assert :nomatch = CorpseLibrary.match(solid(9, 9, 9), 0.4)

    :ok = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    assert :nomatch = CorpseLibrary.match(solid(9, 200, 9), 0.7)
  end

  @tag :tmp_dir
  test "o cache respeita o mtime: um add é visível na leitura seguinte" do
    :ok = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    assert [_] = CorpseLibrary.list()
    :ok = CorpseLibrary.add("Zubat", solid(60, 60, 220))
    assert length(CorpseLibrary.list()) == 2
  end
end
