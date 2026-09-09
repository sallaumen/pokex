defmodule Pokex.Vision.ColorMark do
  @moduledoc """
  Presence of a COLOUR in a frame: "is there a blob of this colour here?"

  This is the eye for the shiny and boss colours (docs/shiny/plano-shiny-por-cor.md). In this
  client a shiny is a RECOLOUR, the same sprite with a swapped palette, and the sprite shows up
  in any pose (an Electrode rolls upside down in rollout), so matching a taught crop would need
  one sample per pose. The HUE does not: the game's shading varies brightness and saturation,
  but the tone stays, which is why the comparison lives in HSV with a tight cone on H and slack
  on S/V.

  Counting is by CELLS (precedent: `corpse_cell_px`): a single pass over the binary sums matched
  pixels per `cell_px` cell, and a blob is a group of neighbouring cells above `min_cell_px`.
  That is what tells "25px concentrated on a differently coloured crest" from "25px of noise
  spread over the grass": sensitive without being nervous.

  ## O TOM QUE NÃO TEM MATIZ

  Some of his shinies are BLACK — "é um dos poucos Shinies Pretos do jogo" (09/09), a Charizard
  whose whole body reads (17, 16, 16) with the channels a single point apart. Black has no hue
  to put a cone around, and the eyedropper refused it by design. So a colour is either a HUE
  cone or a DARK band: `{:dark, v_max, spread_max}` matches pixels no brighter than `v_max`
  whose channels sit within `spread_max` of each other — an achromatic cone, measured the same
  way and proven the same way.

  Measured on his own frame (2026-09-09, the black shiny standing in the lava cave), cell 8 and
  6 matched pixels per cell:

  | v_max | the creature | the loudest blob of ground | margin |
  |-------|--------------|----------------------------|--------|
  | 26    | 8.728 px     | 1.576 px                   | 5,5x   |
  | 30    | 10.503 px    | 2.638 px                   | 4,0x   |
  | 34    | 12.605 px    | 4.449 px                   | 2,8x   |
  | 38    | 16.195 px    | 11.055 px                  | 1,5x   |

  A dark band pays a price a hue never did: THE GAME'S OWN CHROME IS BLACK. In that same frame
  the four loudest blobs were the hotbar (30.841 px), the top toolbar (25.741), the Tracker
  window (20.782) and the bottom-right panel (17.513) — every one of them louder than the
  creature. That is what `box` on each blob is for: the floor proof watches which blobs never
  move and hands them back as `forbidden`.

  Pure and processless, like `SpriteLibrary`: it takes a `Frame` and answers a map. Output
  coordinates are FRAME PIXELS; whoever captured knows the region and the scale, and converts to
  screen points.
  """

  alias Pokex.Vision.Frame

  @default_cell_px 8
  @default_min_cell_px 6
  # o espalhamento entre canais que ainda conta como "sem cor": medido no corpo
  # do shiny preto dele, mediana 0 e p90 4
  @default_spread_max 12

  @typedoc """
  Uma cor de referência compilada pra varredura: um cone de MATIZ, ou uma banda
  ESCURA pros tons que não têm matiz nenhum (o shiny preto).
  """
  @type spec ::
          {h :: 0..359, s :: 0..255, v :: 0..255, tol_h :: pos_integer, tol_sv :: 0..255}
          | {:dark, v_max :: 0..255, spread_max :: 0..255}

  @doc """
  Compiles colours `%{rgb: {r, g, b}, tol_h: degrees, tol_sv: pct}` for the scan.

  `tol_h` is the half-width of the hue cone in degrees; `tol_sv` is the saturation and
  brightness slack in PERCENT (converted to the 0..255 scale here, once).
  """
  def compile(colors) when is_list(colors), do: Enum.map(colors, &compile_one/1)

  # O TOM ESCURO: sem matiz pra cercar, o que se cerca é o TETO DE LUZ e o
  # espalhamento entre os canais — preto é onde os três andam juntos e baixos.
  defp compile_one(%{dark: v_max} = color),
    do:
      {:dark, clamp(v_max, 1, 255),
       color |> Map.get(:spread, @default_spread_max) |> clamp(0, 255)}

  defp compile_one(%{rgb: {r, g, b}} = color) do
    {h, s, v} = hsv(r, g, b)
    tol_h = color |> Map.get(:tol_h, 12) |> max(1)
    tol_sv = color |> Map.get(:tol_sv, 30) |> Kernel.*(255) |> div(100) |> max(1)
    {h, s, v, tol_h, tol_sv}
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_not_a_number, lo, _hi), do: lo

  @doc """
  The teaching EYEDROPPER: the dominant colour of a small square around `{x, y}`, which is what
  his click on the photo becomes.

  A click lands on one pixel, and a sprite pixel is as much anti-aliasing as colour: taking the
  raw pixel would teach its blend with the ground. So the whole patch votes. Grey and near-black
  are out (they have no hue to teach), the rest is grouped by HUE BAND, and the largest band
  answers the MEDIAN of each channel. Median and not mean: the mean between two neighbouring
  tones invents a third that is not on the screen.

  `{:dark, {r, g, b}}` when the patch has no hue but IS dark — his black shiny, whose body is
  (17, 16, 16). There is no cone to put around that, so the teaching turns it into a dark band
  (see the moduledoc). `:none` stays for grey that is not dark either (the rock floor): whoever
  is teaching needs to hear that instead of receiving a silent grey.

  ## The clicked pixel rules

  Voting with the whole patch lost the DETAIL: a shiny's dark crest is only a few pixels, and in
  a 5x5 patch the cyan body around it won the vote. Clicking right on the crest answered the
  body's tone, and the rule never separated the shiny from the common one. So when the clicked
  pixel IS a colour (it has a hue), ITS band is the one that counts, and the patch only corrects
  anti-aliasing inside that band. The full vote is left for the click that lands on a hueless
  edge.
  """
  @pick_min_delta 25
  @pick_min_value 30
  @pick_hue_bin 12
  # Um clique SEM matiz ainda ensina alguma coisa se for escuro: acima disto é
  # pedra cinza, e uma banda que pega pedra pega o mapa inteiro.
  @pick_dark_ceiling 60

  @spec dominant(Frame.t(), {integer, integer}, pos_integer) ::
          {:ok, {0..255, 0..255, 0..255}} | {:dark, {0..255, 0..255, 0..255}} | :none
  def dominant(%Frame{} = frame, {x, y}, raio \\ 2) do
    todos = patch(frame, x, y, raio)
    clicado = Frame.at(frame, x, y)

    cond do
      # O PIXEL CLICADO MANDA, e isto custou a noite de 09/09. O voto do
      # quadradinho só valia quando NENHUM dos 25 tinha matiz, então clicar no
      # corpo preto do Charizard dentro de uma caverna de lava ensinava a LAVA:
      # um pixel alaranjado na borda da silhueta ganhava de vinte e quatro
      # pixels (17,16,16). Ele salvou três tons assim, e cada um casava 3% da
      # tela dele.
      escuro?(clicado) ->
        escuro(todos)

      not hueless?(clicado) ->
        bins = todos |> Enum.reject(&hueless?/1) |> Enum.group_by(&faixa/1)
        {:ok, median(Map.get(bins, faixa(clicado)) || [clicado])}

      true ->
        # Cinza CLARO — a costura entre o bicho e o chão. O quadradinho vota,
        # mas a faixa vencedora tem que valer pelo menos um terço dele: um
        # pixel solto emprestando o matiz é o defeito de cima com outra roupa.
        todos
        |> Enum.reject(&hueless?/1)
        |> Enum.group_by(&faixa/1)
        |> maior_faixa()
        |> maioria(length(todos))
    end
  end

  defp maioria(nil, _total), do: :none

  defp maioria(pixels, total) do
    if length(pixels) * 3 >= total, do: {:ok, median(pixels)}, else: :none
  end

  defp escuro?({r, g, b}), do: max(r, max(g, b)) <= @pick_dark_ceiling

  # O quadradinho em volta de um clique escuro: a mediana dos pixels ESCUROS
  # dele, que é o tom sem o anti-aliasing da borda.
  defp escuro(pixels) do
    case Enum.filter(pixels, &escuro?/1) do
      [] -> :none
      escuros -> {:dark, median(escuros)}
    end
  end

  defp hueless?({r, g, b}) do
    mx = max(r, max(g, b))
    mx - min(r, min(g, b)) < @pick_min_delta or mx < @pick_min_value
  end

  defp faixa({r, g, b}) do
    mx = max(r, max(g, b))
    div(hue(r, g, b, mx, mx - min(r, min(g, b))), @pick_hue_bin)
  end

  defp maior_faixa(bins) do
    case Enum.max_by(bins, fn {_bin, pixels} -> length(pixels) end, fn -> nil end) do
      nil -> nil
      {_bin, pixels} -> pixels
    end
  end

  defp patch(%Frame{width: w, height: h} = frame, x, y, raio) do
    for py <- max(y - raio, 0)..min(y + raio, h - 1)//1,
        px <- max(x - raio, 0)..min(x + raio, w - 1)//1,
        do: Frame.at(frame, px, py)
  end

  defp median(pixels) do
    meio = div(length(pixels), 2)

    {
      pixels |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(meio),
      pixels |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(meio),
      pixels |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> Enum.at(meio)
    }
  end

  @doc """
  Scans the frame for the compiled colours.

  Options: `cell_px` (#{@default_cell_px}), `min_cell_px` (#{@default_min_cell_px} matched
  pixels in a cell for it to count), `forbidden` (boxes `{left, top, right, bottom}` in frame
  px; HIS OWN pokémon lives in one).

  Answers `%{px: total_matched, manchas: [%{point: {x, y}, px: n, cells: n, box: {l, t, r, b}}]}`,
  blobs in decreasing order of size, `point` at the centre of mass and `box` around every cell
  that entered — the box is what tells a creature from the game's own chrome across frames.
  """
  def scan(%Frame{width: w, height: h, rgba: rgba}, specs, opts \\ []) when is_list(specs) do
    cell = Keyword.get(opts, :cell_px, @default_cell_px)
    min_cell = Keyword.get(opts, :min_cell_px, @default_min_cell_px)
    forbidden = Keyword.get(opts, :forbidden, [])

    cells = walk_rows(rgba, 0, w, h, specs, cell, forbidden, %{})
    total = cells |> Map.values() |> Enum.sum()

    manchas =
      cells
      |> Map.filter(fn {_key, n} -> n >= min_cell end)
      |> clusters()
      |> Enum.map(&measure(&1, cell))
      |> Enum.sort_by(& &1.px, :desc)

    %{px: total, manchas: manchas}
  end

  # -- a passada ---------------------------------------------------------------

  # Row by row: the cell row (`cy`) is constant per row, and the row's binary comes out by
  # pattern match without copying. Pixels that do not match cost only the test; the cell map
  # grows only on matches (sparse).
  defp walk_rows(_rgba, y, _w, h, _specs, _cell, _forbidden, acc) when y >= h, do: acc

  defp walk_rows(rgba, y, w, h, specs, cell, forbidden, acc) do
    skip = y * w * 4
    <<_::binary-size(skip), line::binary-size(w * 4), _::binary>> = rgba
    acc = walk_line(line, 0, y, div(y, cell), specs, cell, forbidden, acc)
    walk_rows(rgba, y + 1, w, h, specs, cell, forbidden, acc)
  end

  defp walk_line(<<>>, _x, _y, _cy, _specs, _cell, _forbidden, acc), do: acc

  defp walk_line(<<r, g, b, _a, rest::binary>>, x, y, cy, specs, cell, forbidden, acc) do
    acc =
      if matches?(r, g, b, specs) and not forbidden?(x, y, forbidden) do
        key = {div(x, cell), cy}

        case acc do
          %{^key => n} -> %{acc | key => n + 1}
          _first -> Map.put(acc, key, 1)
        end
      else
        acc
      end

    walk_line(rest, x + 1, y, cy, specs, cell, forbidden, acc)
  end

  defp matches?(_r, _g, _b, []), do: false

  defp matches?(r, g, b, [{:dark, v_max, spread_max} | rest]) do
    mx = max(r, max(g, b))

    if mx <= v_max and mx - min(r, min(g, b)) <= spread_max,
      do: true,
      else: matches?(r, g, b, rest)
  end

  defp matches?(r, g, b, [{rh, rs, rv, tol_h, tol_sv} | rest]) do
    mx = max(r, max(g, b))
    mn = min(r, min(g, b))
    delta = mx - mn

    cond do
      # grey has no hue: only a near-grey cone would accept it, and a shiny rule is never
      # grey; reject before any division
      delta == 0 -> matches?(r, g, b, rest)
      abs(mx - rv) > tol_sv -> matches?(r, g, b, rest)
      abs(sat(mx, delta) - rs) > tol_sv -> matches?(r, g, b, rest)
      hue_dist(hue(r, g, b, mx, delta), rh) > tol_h -> matches?(r, g, b, rest)
      true -> true
    end
  end

  defp sat(mx, delta), do: div(delta * 255, mx)

  defp hue(r, g, b, mx, delta) do
    cond do
      mx == r -> Integer.mod(div(60 * (g - b), delta), 360)
      mx == g -> Integer.mod(div(60 * (b - r), delta) + 120, 360)
      true -> Integer.mod(div(60 * (r - g), delta) + 240, 360)
    end
  end

  defp hue_dist(a, b) do
    d = abs(a - b)
    min(d, 360 - d)
  end

  defp forbidden?(_x, _y, []), do: false

  defp forbidden?(x, y, [{l, t, r, b} | rest]),
    do: (x >= l and x <= r and y >= t and y <= b) or forbidden?(x, y, rest)

  defp hsv(r, g, b) do
    mx = max(r, max(g, b))
    mn = min(r, min(g, b))
    delta = mx - mn
    h = if delta == 0, do: 0, else: hue(r, g, b, mx, delta)
    s = if mx == 0, do: 0, else: sat(mx, delta)
    {h, s, mx}
  end

  # -- as manchas --------------------------------------------------------------

  # Connected components of the cells (8 neighbours: sprite detail crosses diagonals), without
  # recounting what already entered.
  defp clusters(cells) when map_size(cells) == 0, do: []

  defp clusters(cells) do
    {groups, _seen} =
      Enum.reduce(Map.keys(cells), {[], MapSet.new()}, fn key, {groups, seen} ->
        if MapSet.member?(seen, key) do
          {groups, seen}
        else
          {group, seen} = flood(cells, [key], MapSet.put(seen, key), [])
          {[group | groups], seen}
        end
      end)

    Enum.map(groups, fn keys -> Map.new(keys, &{&1, Map.fetch!(cells, &1)}) end)
  end

  defp flood(_cells, [], seen, group), do: {group, seen}

  defp flood(cells, [key | queue], seen, group) do
    {cx, cy} = key

    {queue, seen} =
      Enum.reduce(neighbors(cx, cy), {queue, seen}, fn n, {queue, seen} ->
        if Map.has_key?(cells, n) and not MapSet.member?(seen, n),
          do: {[n | queue], MapSet.put(seen, n)},
          else: {queue, seen}
      end)

    flood(cells, queue, seen, [key | group])
  end

  defp neighbors(cx, cy) do
    for dx <- -1..1, dy <- -1..1, {dx, dy} != {0, 0}, do: {cx + dx, cy + dy}
  end

  defp measure(group, cell) do
    px = group |> Map.values() |> Enum.sum()

    {sx, sy} =
      Enum.reduce(group, {0, 0}, fn {{cx, cy}, n}, {sx, sy} ->
        {sx + (cx * cell + div(cell, 2)) * n, sy + (cy * cell + div(cell, 2)) * n}
      end)

    xs = Enum.map(Map.keys(group), &elem(&1, 0))
    ys = Enum.map(Map.keys(group), &elem(&1, 1))

    %{
      point: {div(sx, px), div(sy, px)},
      px: px,
      cells: map_size(group),
      # ONDE ela está, e não só onde está o centro: a prova do chão compara
      # caixas entre fotos pra separar o que MEXE (uma criatura) do que nunca
      # mexe (o próprio HUD do jogo, que é preto).
      box: {
        Enum.min(xs) * cell,
        Enum.min(ys) * cell,
        (Enum.max(xs) + 1) * cell - 1,
        (Enum.max(ys) + 1) * cell - 1
      }
    }
  end
end
