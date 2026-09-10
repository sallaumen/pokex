defmodule Pokex.Vision.ToneFinder do
  @moduledoc """
  Um clique em cima do bicho vira um TOM MEDIDO: a cor que aparece nele e não aparece no
  resto da foto, com a folga e o gatilho já calculados.

  ## Por que isto existe

  Até aqui a calibração pedia que ele adivinhasse três números — o tom, a folga por canal e o
  gatilho em pixels — e só depois lhe dizia se tinha adivinhado bem. Em 10/09 ele desistiu:
  "tentei por TUDO e não fui capaz de marcar cores onde fizesse circular o shiny venusaur e
  não os outros, e quase nenhuma cor nem circula o venusaur com o quadrado".

  Medido na foto de calibração dele daquele dia (2566×1440, o Venusaur shiny roxo com cinco
  Venusaur comuns na mesma tela):

  | tom | folga | px no bicho | px no resto da tela |
  |-----|-------|-------------|---------------------|
  | (83,38,98) — o que o conta-gotas lhe deu | 0 | **1** | 0 |
  | (83,38,98) | 8 | 638 | 457, em 23 manchas |
  | (129,117,142) — idem | 1 | **4** | 0 |
  | **(88,45,103)** — o que este módulo acha | **2** | **197** | **8** |

  O conta-gotas antigo devolvia um pixel REAL (foi o conserto do #582), mas real não basta:
  aquele quadro tem 15.485 cores distintas dentro de um quadrado de 150×150, porque a arte é
  misturada com o chão na borda. `(83,38,98)` existe — uma vez na tela inteira. Um tom que não
  se repete não é um tom, é um acidente de mistura.

  ## O que se mede

  A pergunta certa nunca foi "qual a cor deste pixel", e sim **"qual cor está neste bicho e em
  mais lugar nenhum"**. Isso é uma medida, não um palpite, e é o que este módulo faz:

  1. o quadrado de um tile em volta do clique é O BICHO;
  2. as cores que se repetem dentro dele são as candidatas (mistura de borda não se repete);
  3. UMA passada pelo quadro conta, pra cada candidata e cada folga de 0 a 2, quantos pixels
     caem dentro do bicho e quantos caem fora;
  4. sobrevive quem quase não vaza pra fora; ganha quem tem a maior mancha DENTRO depois do
     filtro de células — a mesma peneira que o vigia usa, senão o tom ganha no papel e o vigia
     não vê nada;
  5. o gatilho sai da mancha medida, não de uma prova de chão feita noutra hora.

  O que sobra pra ele é uma frase com números que ele consegue conferir com os olhos.

  ## Medido no quadro dele, inteiro

  Um clique no corpo do shiny em `special_teach.png` de 10/09 (2566×1440, cinco Venusaur comuns
  na mesma tela), **215 ms**:

      tom (88,45,103), folga ±2
      195 px dentro do quadrado do bicho, 8 px em todo o resto da tela
      mancha de 179 px em cima dele, NENHUMA mancha em qualquer outro lugar
      gatilho sugerido: 107

  E um clique num Venusaur COMUM responde `:nothing_separates` em 146 ms — o que é a resposta
  certa e não uma falha: existe outro igual a ele na tela, então nenhuma cor separa um do
  outro. Essa recusa é a mesma peneira que faz o clique no shiny valer alguma coisa.
  """

  alias Pokex.Vision.{ColorMark, Frame}

  # Uma cor precisa SE REPETIR pra ser um tom. Abaixo disto é mistura de borda:
  # na foto dele o tom que ele pegou aparecia 1 vez na tela inteira.
  @min_repeats 12
  # quantas candidatas entram na conta (as mais frequentes do quadrado)
  @max_candidates 16
  # a folga por canal que se experimenta. Acima de 2 o tom começa a aceitar a
  # mesma arte com outra luz, que é justamente o eixo que separa shiny de comum.
  @tols [0, 1, 2]
  @max_tol 2
  # O VAZAMENTO ACEITO: por cento do que casou no bicho, com um piso pra não
  # reprovar um tom perfeito por causa de três pixels perdidos no chão.
  @leak_share 10
  @leak_floor 8
  # quantas candidatas passam pela peneira de células (cada uma é uma varredura)
  @measured 3
  # o gatilho sai em 6/10 da mancha medida: folga pro bicho virar de lado
  @trigger_tenths 6
  @min_trigger 20
  @default_box_px 150

  @type reading :: %{
          rgb: {0..255, 0..255, 0..255},
          tol: 0..2,
          on_target: non_neg_integer,
          elsewhere: non_neg_integer,
          blob: non_neg_integer,
          biggest_elsewhere: non_neg_integer,
          min_px: pos_integer,
          box: {integer, integer, integer, integer}
        }

  @doc """
  O tom que separa o bicho clicado do resto de `frame`, ou o motivo de não haver um.

  `opts[:box_px]` é o lado do quadrado que conta como "o bicho" (um tile, em pixels do quadro);
  `opts[:min_cell_px]` é a peneira de células do vigia, que tem que ser a mesma.
  """
  @spec find(Frame.t(), {integer, integer}, keyword) ::
          {:ok, reading} | {:error, :nothing_repeats | :nothing_separates | :too_thin}
  def find(%Frame{} = frame, {cx, cy}, opts \\ []) do
    box = square(frame, {cx, cy}, Keyword.get(opts, :box_px, @default_box_px))
    min_cell = Keyword.get(opts, :min_cell_px, 6)

    with {:ok, candidatas} <- candidates(frame, box),
         {:ok, separadoras} <- separators(frame, box, candidatas) do
      pick(frame, box, separadoras, min_cell)
    end
  end

  # -- 1. o quadrado do bicho --------------------------------------------------

  defp square(%Frame{width: w, height: h}, {cx, cy}, lado) do
    meia = max(div(lado, 2), 4)

    {clamp(cx - meia, 0, w - 1), clamp(cy - meia, 0, h - 1), clamp(cx + meia, 0, w - 1),
     clamp(cy + meia, 0, h - 1)}
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # -- 2. as cores que se repetem dentro dele ----------------------------------

  defp candidates(%Frame{rgba: rgba, width: w}, {l, t, r, b}) do
    hist =
      Enum.reduce(t..b, %{}, fn y, acc ->
        span = (r - l + 1) * 4
        acc_line(:binary.part(rgba, (y * w + l) * 4, span), acc)
      end)

    hist
    |> Enum.filter(fn {_cor, n} -> n >= @min_repeats end)
    |> Enum.sort_by(fn {_cor, n} -> -n end)
    |> Enum.take(@max_candidates)
    |> Enum.map(&elem(&1, 0))
    |> case do
      [] -> {:error, :nothing_repeats}
      cores -> {:ok, cores}
    end
  end

  defp acc_line(<<>>, acc), do: acc

  defp acc_line(<<r, g, b, _a, rest::binary>>, acc),
    do: acc_line(rest, Map.update(acc, {r, g, b}, 1, &(&1 + 1)))

  # -- 3. uma passada pelo quadro inteiro --------------------------------------

  defp separators(%Frame{rgba: rgba, width: w, height: h}, box, candidatas) do
    conta = walk_rows(rgba, 0, w, h, lookup(candidatas), box, %{})

    candidatas
    |> Enum.with_index()
    |> Enum.flat_map(fn {rgb, idx} -> Enum.map(@tols, &score(conta, rgb, idx, &1)) end)
    |> Enum.filter(&separates?/1)
    |> Enum.sort_by(& &1.on_target, :desc)
    |> case do
      [] -> {:error, :nothing_separates}
      boas -> {:ok, boas}
    end
  end

  # A CAIXA DE CADA CANDIDATA, ACHATADA NUMA TABELA. Percorrer o quadro uma vez
  # por candidata seria 16 varreduras de 3,7 milhões de pixels; com a tabela
  # `cor => {candidata, distância}` a passada é UMA, e a distância guardada diz
  # a partir de que folga aquele pixel conta.
  defp lookup(candidatas) do
    for {{r, g, b}, idx} <- Enum.with_index(candidatas),
        dr <- -@max_tol..@max_tol,
        dg <- -@max_tol..@max_tol,
        db <- -@max_tol..@max_tol,
        rr = r + dr,
        gg = g + dg,
        bb = b + db,
        rr in 0..255 and gg in 0..255 and bb in 0..255,
        reduce: %{} do
      acc -> nearest(acc, {rr, gg, bb}, idx, Enum.max([abs(dr), abs(dg), abs(db)]))
    end
  end

  # a mesma cor pode cair na caixa de duas candidatas: fica com a mais perto, e
  # no empate com a mais frequente (as candidatas vêm ordenadas)
  defp nearest(acc, cor, idx, d) do
    case acc do
      %{^cor => {_idx0, d0}} when d0 <= d -> acc
      _mais_longe_ou_ausente -> Map.put(acc, cor, {idx, d})
    end
  end

  defp walk_rows(_rgba, y, _w, h, _lookup, _box, acc) when y >= h, do: acc

  defp walk_rows(rgba, y, w, h, lookup, {l, t, r, b} = box, acc) do
    <<_::binary-size(y * w * 4), line::binary-size(w * 4), _::binary>> = rgba
    acc = walk_line(line, 0, lookup, l, r, y >= t and y <= b, acc)
    walk_rows(rgba, y + 1, w, h, lookup, box, acc)
  end

  defp walk_line(<<>>, _x, _lookup, _l, _r, _linha_no_bicho?, acc), do: acc

  defp walk_line(<<r, g, b, _a, rest::binary>>, x, lookup, l, rr, linha?, acc) do
    acc =
      case Map.get(lookup, {r, g, b}) do
        {idx, d} ->
          chave = {idx, d}
          {dentro, fora} = Map.get(acc, chave, {0, 0})

          if linha? and x >= l and x <= rr,
            do: Map.put(acc, chave, {dentro + 1, fora}),
            else: Map.put(acc, chave, {dentro, fora + 1})

        nil ->
          acc
      end

    walk_line(rest, x + 1, lookup, l, rr, linha?, acc)
  end

  # -- 4. quem separa ----------------------------------------------------------

  defp score(conta, rgb, idx, tol) do
    {dentro, fora} =
      Enum.reduce(0..tol, {0, 0}, fn d, {sd, sf} ->
        {d1, f1} = Map.get(conta, {idx, d}, {0, 0})
        {sd + d1, sf + f1}
      end)

    %{rgb: rgb, tol: tol, on_target: dentro, elsewhere: fora}
  end

  defp separates?(%{on_target: dentro, elsewhere: fora}),
    do: dentro >= @min_repeats and fora <= max(@leak_floor, div(dentro * @leak_share, 100))

  # -- 5. a peneira do vigia decide o vencedor ---------------------------------

  # A CONTAGEM DE PIXELS NÃO É A MANCHA. O vigia só enxerga cor que se junta em
  # células de 8px com pelo menos `min_cell_px` acesas; um tom espalhado em
  # pixels soltos ganha na contagem e some na peneira. Então as melhores passam
  # pela MESMA peneira antes de a ferramenta prometer qualquer coisa.
  defp pick(frame, box, separadoras, min_cell) do
    separadoras
    |> Enum.take(@measured)
    |> Enum.map(&measure(frame, box, &1, min_cell))
    |> Enum.filter(&(&1.blob > 0))
    |> Enum.max_by(& &1.blob, fn -> nil end)
    |> case do
      nil -> {:error, :too_thin}
      melhor -> {:ok, melhor}
    end
  end

  defp measure(frame, box, cand, min_cell) do
    %{manchas: manchas} =
      ColorMark.scan(frame, ColorMark.compile([%{rgb: cand.rgb, tol: cand.tol}]),
        min_cell_px: min_cell
      )

    {no_bicho, fora} = Enum.split_with(manchas, &centred_in?(&1.box, box))
    blob = px_of(no_bicho)

    Map.merge(cand, %{
      blob: blob,
      biggest_elsewhere: px_of(fora),
      min_px: max(div(blob * @trigger_tenths, 10), @min_trigger),
      box: box
    })
  end

  defp px_of([%{px: px} | _resto]), do: px
  defp px_of([]), do: 0

  defp centred_in?({bl, bt, br, bb}, {l, t, r, b}) do
    cx = div(bl + br, 2)
    cy = div(bt + bb, 2)
    cx >= l and cx <= r and cy >= t and cy <= b
  end
end
