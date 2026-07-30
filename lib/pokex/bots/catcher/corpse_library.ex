defmodule Pokex.Bots.Catcher.CorpseLibrary do
  @moduledoc """
  Os corpos ENSINADOS — a mesma virada que salvou os glifos, aplicada à captura.

  O detector de corpos (chão-base + diff) adivinha, e adivinhar no chão do PXG
  rende clique errado e falso positivo — cada um mexendo o mouse do Lucas à toa
  (queixa ao vivo de 2026-07-30: "tenta capturar pontos errados... mexe demais
  o meu mouse"). Aqui o Lucas fotografa o corpo REAL na tela, dá o nome do
  Pokémon, e o recorte vira verdade no acervo: com
  `catcher_require_known_corpse` ligado, só candidato PARECIDO com um corpo
  ensinado recebe Pokébola.

  O casamento é por ASSINATURA DE COR (histograma RGB quantizado em 512
  cubos, interseção normalizada 0..1), não por pixel exato: o corpo compõe
  sobre chão que varia, então igualdade exata nunca casaria — mas a paleta do
  sprite domina o recorte e sobrevive ao fundo. O limiar é ajuste
  (`corpse_match_min_similarity`).

  Sem processo: o arquivo `~/.pokex/corpses.json` é a verdade, e um cache em
  `:persistent_term` chaveado pelo mtime evita reler e re-hidratar a cada
  candidato. Recortes ficam como rgba cru em base64 — nada de encoder de PNG.
  """

  alias Pokex.Home
  alias Pokex.Vision.Frame

  @cache_key {__MODULE__, :cache}

  def file, do: Path.join(Home.dir(), "corpses.json")

  @doc "Todos os corpos ensinados, mais novos primeiro."
  def list do
    library().entries
  end

  def empty?, do: list() == []

  @doc "Ensina um corpo: o recorte (Frame) vira acervo sob o nome dado."
  def add(name, %Frame{} = crop) when is_binary(name) do
    name = String.trim(name)

    if name == "" do
      {:error, :nome_vazio}
    else
      entry = %{
        "name" => name,
        "slug" => slug(name),
        "w" => crop.width,
        "h" => crop.height,
        "rgba" => Base.encode64(crop.rgba),
        "added_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      entries = [entry | Enum.reject(raw_entries(), &(&1["slug"] == entry["slug"]))]
      persist(entries)
      :ok
    end
  end

  def delete(slug) do
    persist(Enum.reject(raw_entries(), &(&1["slug"] == slug)))
    :ok
  end

  @doc """
  O melhor casamento do recorte contra o acervo: `{:ok, %{name, score}}` quando
  algum corpo ensinado passa do limiar, `:nomatch` senão (inclusive com o
  acervo vazio — quem decide o que fazer nesse caso é o chamador).
  """
  def match(%Frame{} = crop, min_similarity) do
    sig = signature(crop.rgba)

    library().signatures
    |> Enum.map(fn {name, ref_sig} -> {name, intersection(sig, ref_sig)} end)
    |> Enum.max_by(fn {_name, score} -> score end, fn -> nil end)
    |> case do
      {name, score} when score >= min_similarity -> {:ok, %{name: name, score: score}}
      _abaixo_ou_vazio -> :nomatch
    end
  end

  # -- assinatura de cor -------------------------------------------------------

  # Histograma RGB quantizado (3 bits por canal → 512 cubos), normalizado pra
  # somar 1.0 — tamanho do recorte não pesa no casamento.
  defp signature(rgba) do
    counts = count_bins(rgba, %{})
    total = max(byte_size(rgba) / 4, 1)
    Map.new(counts, fn {bin, n} -> {bin, n / total} end)
  end

  defp count_bins(<<r, g, b, _a, rest::binary>>, acc) do
    bin =
      Bitwise.bor(
        Bitwise.bor(Bitwise.bsl(Bitwise.bsr(r, 5), 6), Bitwise.bsl(Bitwise.bsr(g, 5), 3)),
        Bitwise.bsr(b, 5)
      )

    count_bins(rest, Map.update(acc, bin, 1, &(&1 + 1)))
  end

  defp count_bins(_tail, acc), do: acc

  # Interseção de histogramas: soma dos mínimos — 1.0 = paletas idênticas.
  defp intersection(a, b) do
    Enum.reduce(a, 0.0, fn {bin, va}, acc -> acc + min(va, Map.get(b, bin, 0.0)) end)
  end

  # -- acervo ------------------------------------------------------------------

  defp library do
    mtime = file_mtime()

    case :persistent_term.get(@cache_key, nil) do
      %{mtime: ^mtime} = cache ->
        cache

      _stale_ou_nada ->
        entries = raw_entries()

        cache = %{
          mtime: mtime,
          entries: entries,
          signatures:
            Enum.map(entries, fn e ->
              {e["name"], signature(Base.decode64!(e["rgba"]))}
            end)
        }

        :persistent_term.put(@cache_key, cache)
        cache
    end
  end

  defp raw_entries do
    with {:ok, body} <- File.read(file()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries
    else
      _sem_acervo -> []
    end
  end

  defp persist(entries) do
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), Jason.encode!(entries, pretty: true))
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp file_mtime do
    case File.stat(file(), time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _sem_arquivo -> nil
    end
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
