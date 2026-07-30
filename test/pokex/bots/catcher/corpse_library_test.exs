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
  test "ensinar acumula AMOSTRAS por corpo, com teto e queda da mais velha" do
    assert CorpseLibrary.empty?()

    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    {:ok, 1} = CorpseLibrary.add("Zubat", solid(60, 60, 220))
    assert [%{"name" => "Zubat"}, %{"name" => "Rattata"}] = CorpseLibrary.list()

    # mesmo nome = amostra nova do MESMO corpo (chão diferente), não duplicata
    {:ok, 2} = CorpseLibrary.add("rattata", solid(181, 121, 201))
    {:ok, 3} = CorpseLibrary.add("rattata", solid(182, 122, 202))
    assert length(CorpseLibrary.list()) == 2

    # a 4ª amostra derruba a mais velha — o teto vale
    {:ok, n} = CorpseLibrary.add("rattata", solid(183, 123, 203))
    assert n == CorpseLibrary.max_samples()

    :ok = CorpseLibrary.delete("zubat")
    assert [%{"name" => "rattata", "samples" => samples}] = CorpseLibrary.list()
    assert length(samples) == CorpseLibrary.max_samples()

    # apagar uma amostra ruim mantém o corpo; apagar a última derruba o corpo
    :ok = CorpseLibrary.delete_sample("rattata", 0)
    assert [%{"samples" => rest}] = CorpseLibrary.list()
    assert length(rest) == CorpseLibrary.max_samples() - 1

    :ok = CorpseLibrary.delete_sample("rattata", 0)
    :ok = CorpseLibrary.delete_sample("rattata", 0)
    assert CorpseLibrary.empty?()
  end

  @tag :tmp_dir
  test "amostra de OUTRO chão melhora o casamento — o máximo entre amostras vence" do
    # amostra 1: sprite sobre chão A; candidato: sprite sobre chão C — casa fraco
    {:ok, 1} = CorpseLibrary.add("Rattata", half(180, 120, 200, {90, 70, 40}))
    candidato = half(180, 120, 200, {30, 30, 120})
    {:ok, %{score: fraco}} = CorpseLibrary.match(candidato, 0.3)

    # amostra 2: o MESMO chão do candidato — o máximo entre amostras dispara
    {:ok, 2} = CorpseLibrary.add("Rattata", half(180, 120, 200, {30, 30, 120}))
    {:ok, %{name: "Rattata", score: forte}} = CorpseLibrary.match(candidato, 0.3)

    assert forte > fraco
    assert forte > 0.95
  end

  @tag :tmp_dir
  test "o acervo do #101 (uma amostra achatada) continua legível" do
    antigo = [
      %{
        "name" => "Zubat",
        "slug" => "zubat",
        "w" => 4,
        "h" => 4,
        "rgba" => Base.encode64(:binary.copy(<<60, 60, 220, 255>>, 16)),
        "added_at" => "2026-07-30T00:00:00Z"
      }
    ]

    File.mkdir_p!(Path.dirname(CorpseLibrary.file()))
    File.write!(CorpseLibrary.file(), Jason.encode!(antigo))

    assert [%{"name" => "Zubat", "samples" => [_uma]}] = CorpseLibrary.list()
    assert {:ok, %{name: "Zubat"}} = CorpseLibrary.match(solid(60, 60, 220, 4), 0.7)
  end

  @tag :tmp_dir
  test "a miniatura é um BMP válido em data-URL" do
    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200, 4))
    [%{"samples" => [sample]}] = CorpseLibrary.list()

    url = CorpseLibrary.thumb(sample)
    assert String.starts_with?(url, "data:image/bmp;base64,")

    <<"BM", _resto::binary>> =
      url |> String.replace_prefix("data:image/bmp;base64,", "") |> Base.decode64!()
  end

  @tag :tmp_dir
  test "nome vazio é recusado" do
    assert {:error, :nome_vazio} = CorpseLibrary.add("   ", solid(1, 2, 3))
  end

  @tag :tmp_dir
  test "casa o corpo certo mesmo com METADE do recorte sendo chão" do
    {:ok, 1} = CorpseLibrary.add("Rattata", half(180, 120, 200, {90, 70, 40}))
    {:ok, 1} = CorpseLibrary.add("Zubat", half(60, 60, 220, {90, 70, 40}))

    # candidato: a MESMA paleta do Rattata sobre um chão DIFERENTE
    candidato = half(180, 120, 200, {50, 110, 60})

    assert {:ok, %{name: "Rattata", score: score}} = CorpseLibrary.match(candidato, 0.4)
    assert score >= 0.4
  end

  @tag :tmp_dir
  test "paleta desconhecida não casa; acervo vazio nunca casa" do
    assert :nomatch = CorpseLibrary.match(solid(9, 9, 9), 0.4)

    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    assert :nomatch = CorpseLibrary.match(solid(9, 200, 9), 0.7)
  end

  @tag :tmp_dir
  test "o cache respeita o mtime: um add é visível na leitura seguinte" do
    {:ok, 1} = CorpseLibrary.add("Rattata", solid(180, 120, 200))
    assert [_] = CorpseLibrary.list()
    {:ok, 1} = CorpseLibrary.add("Zubat", solid(60, 60, 220))
    assert length(CorpseLibrary.list()) == 2
  end
end
