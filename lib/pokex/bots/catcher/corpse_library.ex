defmodule Pokex.Bots.Catcher.CorpseLibrary do
  @moduledoc """
  Os corpos ENSINADOS — a mesma virada que salvou os glifos, aplicada à captura.

  O detector de corpos (chão-base + diff) adivinha, e adivinhar no chão do PXG
  rende clique errado e falso positivo — cada um mexendo o mouse do Lucas à toa
  (queixa ao vivo de 2026-07-30: "tenta capturar pontos errados... mexe demais
  o meu mouse"). Aqui o Lucas fotografa o corpo REAL na tela, dá o nome do
  Pokémon, e o recorte vira verdade no acervo — que desde 2026-07-30 É a mira:
  só candidato PARECIDO com um corpo ensinado recebe Pokébola (o modo que
  adivinhava sem acervo foi aposentado; acervo vazio = nenhum alvo).

  O casamento é por ASSINATURA DE COR (histograma RGB quantizado em 512
  cubos, interseção normalizada 0..1), não por pixel exato: o corpo compõe
  sobre chão que varia, então igualdade exata nunca casaria — mas a paleta do
  sprite domina o recorte e sobrevive ao fundo. O limiar é ajuste
  (`corpse_match_min_similarity`).

  Cada corpo aceita até `@max_samples` AMOSTRAS (Lucas, 2026-07-30): o mesmo
  Seadra fotografado em chões diferentes — o chão é o ruído do histograma, e
  casar contra a MELHOR amostra é o que devolve a precisão que um recorte só
  não tem. Ensinar o mesmo nome de novo adiciona amostra (a mais velha cai ao
  passar do teto); as miniaturas na calibração mostram quais chões já foram
  cobertos.

  Sem processo: o arquivo `~/.pokex/corpses.json` é a verdade, e um cache em
  `:persistent_term` chaveado pelo mtime evita reler e re-hidratar a cada
  candidato. Recortes ficam como rgba cru em base64 — miniatura vira BMP em
  data-URL (24bpp, sem compressão), então nada de encoder de PNG.
  """

  alias Pokex.Home
  alias Pokex.Vision.Frame

  @cache_key {__MODULE__, :cache}
  @max_samples 3

  def max_samples, do: @max_samples

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
      sample = %{
        "w" => crop.width,
        "h" => crop.height,
        "rgba" => Base.encode64(crop.rgba),
        "added_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      slug = slug(name)
      {existing, others} = Enum.split_with(raw_entries(), &(&1["slug"] == slug))

      samples =
        case existing do
          [entry | _] -> Enum.take([sample | entry["samples"]], @max_samples)
          [] -> [sample]
        end

      # re-ensinar não pode religar um corpo que o Lucas desligou de propósito
      ligado? = Enum.all?(existing, &enabled?/1)

      persist([
        %{"name" => name, "slug" => slug, "samples" => samples, "enabled" => ligado?} | others
      ])

      {:ok, length(samples)}
    end
  end

  def delete(slug) do
    persist(Enum.reject(raw_entries(), &(&1["slug"] == slug)))
    :ok
  end

  @doc """
  Liga/desliga um corpo na mira SEM apagá-lo.

  Pedido do Lucas (2026-07-30): "poder colocar um botãozinho, se tá ligado ou
  desligado". Um corpo que dá falso-positivo sai da busca com um clique e volta
  com outro — apagar as amostras e refotografar era o único jeito antes.
  """
  def set_enabled(slug, ligado?) when is_boolean(ligado?) do
    entries =
      Enum.map(raw_entries(), fn
        %{"slug" => ^slug} = entry -> Map.put(entry, "enabled", ligado?)
        outro -> outro
      end)

    persist(entries)
    :ok
  end

  @doc "Apaga UMA amostra (uma foto ruim); a última amostra derruba o corpo inteiro."
  def delete_sample(slug, index) do
    entries =
      raw_entries()
      |> Enum.map(fn
        %{"slug" => ^slug} = entry ->
          %{entry | "samples" => List.delete_at(entry["samples"], index)}

        entry ->
          entry
      end)
      |> Enum.reject(&(&1["samples"] == []))

    persist(entries)
    :ok
  end

  @doc """
  A miniatura de uma amostra como data-URL BMP (24bpp sem compressão, linhas de
  baixo pra cima, cada linha alinhada em 4 bytes) — o navegador renderiza sem
  este projeto carregar um encoder de PNG.
  """
  def thumb(%{"w" => w, "h" => h, "rgba" => rgba_b64}) do
    rgba = Base.decode64!(rgba_b64)
    row_size = div(w * 3 + 3, 4) * 4
    data_size = row_size * h

    rows =
      for y <- (h - 1)..0//-1, into: <<>> do
        row =
          for x <- 0..(w - 1), into: <<>> do
            <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
            <<b, g, r>>
          end

        row <> :binary.copy(<<0>>, row_size - w * 3)
      end

    bmp =
      <<"BM", 14 + 40 + data_size::little-32, 0::32, 54::little-32, 40::little-32, w::little-32,
        h::little-32, 1::little-16, 24::little-16, 0::little-32, data_size::little-32,
        2835::little-32, 2835::little-32, 0::little-32, 0::little-32>> <> rows

    "data:image/bmp;base64," <> Base.encode64(bmp)
  end

  @doc """
  O melhor casamento do recorte contra o acervo: `{:ok, %{name, score}}` quando
  algum corpo ensinado passa do limiar, `:nomatch` senão (inclusive com o
  acervo vazio — quem decide o que fazer nesse caso é o chamador).
  """
  def match(%Frame{} = crop, min_similarity) do
    case best(crop) do
      %{score: score} = info when score >= min_similarity -> {:ok, info}
      _abaixo_ou_vazio -> :nomatch
    end
  end

  @doc """
  O melhor par `%{name, score}` do acervo pra este recorte — SEM limiar; `nil`
  só quando o acervo está vazio.

  Existe porque um score REPROVADO ainda é informação, e jogá-la fora foi o que
  deixou o Lucas validando às cegas (2026-07-30): quando nada casava, o
  `match/2` devolvia `:nomatch` e ninguém sabia se tinha faltado 0,01 ou 0,40 —
  nem contra qual pokémon. Medido nas amostras dele, o score cai ~0,05 a cada
  7px de deslocamento do recorte, então a distância até o limiar É o diagnóstico
  da mira.
  """
  def best(%Frame{} = crop), do: crop.rgba |> signature() |> best_of()

  @doc """
  O mesmo `best/1`, mas pra uma JANELA dentro de um frame maior — sem alocar
  recorte nenhum.

  A varredura densa (`Catcher.SpotScan`) pontua centenas de janelas por
  varredura; `Frame.crop` em cada uma copiaria centenas de binários só pra
  jogá-los fora. Aqui as linhas da janela são sub-binários (fatias sem cópia)
  somados direto no histograma.

  `{x, y}` é o canto superior-esquerdo em px do frame. Fora dos limites devolve
  `nil` — quem varre não precisa checar borda.
  """
  def best_in(%Frame{width: fw, height: fh} = frame, {x, y, w, h})
      when x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= fw and y + h <= fh do
    frame |> window_signature(x, y, w, h) |> best_of()
  end

  def best_in(_frame, _janela_fora), do: nil

  defp best_of(sig) do
    library().signatures
    |> Enum.map(fn {name, ref_sigs} ->
      {name, ref_sigs |> Enum.map(&intersection(sig, &1)) |> Enum.max(fn -> 0.0 end)}
    end)
    |> Enum.max_by(fn {_name, score} -> score end, fn -> nil end)
    |> case do
      {name, score} -> %{name: name, score: score}
      nil -> nil
    end
  end

  defp window_signature(%Frame{width: fw, rgba: rgba}, x0, y0, w, h) do
    counts =
      Enum.reduce(y0..(y0 + h - 1), %{}, fn y, acc ->
        skip = (y * fw + x0) * 4
        <<_::binary-size(skip), linha::binary-size(w * 4), _rest::binary>> = rgba
        count_bins(linha, acc)
      end)

    normalize(counts, w * h)
  end

  # -- assinatura de cor -------------------------------------------------------

  # Histograma RGB quantizado (3 bits por canal → 512 cubos), normalizado pra
  # somar 1.0 — tamanho do recorte não pesa no casamento.
  defp signature(rgba), do: normalize(count_bins(rgba, %{}), byte_size(rgba) / 4)

  defp normalize(counts, total) do
    total = max(total, 1)
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
    # mtime posix tem granularidade de 1s — duas escritas no MESMO segundo
    # (testes em sequência, edição manual rápida) colidiriam; o tamanho junto
    # desempata na prática.
    stamp = file_stamp()

    case :persistent_term.get(@cache_key, nil) do
      %{stamp: ^stamp} = cache ->
        cache

      _stale_ou_nada ->
        entries = raw_entries()

        cache = %{
          stamp: stamp,
          entries: entries,
          # Só os corpos LIGADOS entram na mira. `entries` continua inteiro pra
          # UI mostrar os desligados — desligar é um filtro na busca, não um
          # apagar. É o ponto ÚNICO por onde o casamento enxerga o acervo,
          # então uma linha aqui basta.
          signatures:
            entries
            |> Enum.filter(&enabled?/1)
            |> Enum.map(fn e ->
              {e["name"], Enum.map(e["samples"], &signature(Base.decode64!(&1["rgba"])))}
            end)
        }

        :persistent_term.put(@cache_key, cache)
        cache
    end
  end

  defp raw_entries do
    with {:ok, body} <- File.read(file()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      Enum.map(entries, &migrate/1)
    else
      _sem_acervo -> []
    end
  end

  # O formato do #101 tinha UMA amostra achatada no topo do registro. Lê os
  # dois; grava sempre o novo.
  defp migrate(%{"samples" => _} = entry), do: Map.put_new(entry, "enabled", true)

  defp migrate(%{"rgba" => _} = entry) do
    sample = Map.take(entry, ["w", "h", "rgba", "added_at"])

    entry
    |> Map.drop(["w", "h", "rgba", "added_at"])
    |> Map.put("samples", [sample])
    |> Map.put_new("enabled", true)
  end

  @doc "Um corpo está participando da mira? (acervo antigo, sem o campo, participa)"
  def enabled?(%{"enabled" => false}), do: false
  def enabled?(_entry), do: true

  defp persist(entries) do
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), Jason.encode!(entries, pretty: true))
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp file_stamp do
    case File.stat(file(), time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
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
