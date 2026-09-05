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

  Pure and processless, like `SpriteLibrary`: it takes a `Frame` and answers a map. Output
  coordinates are FRAME PIXELS; whoever captured knows the region and the scale, and converts to
  screen points.
  """

  alias Pokex.Vision.Frame

  @default_cell_px 8
  @default_min_cell_px 6

  @typedoc "Uma cor de referência compilada pra varredura."
  @type spec :: {h :: 0..359, s :: 0..255, v :: 0..255, tol_h :: pos_integer, tol_sv :: 0..255}

  @doc """
  Compiles colours `%{rgb: {r, g, b}, tol_h: degrees, tol_sv: pct}` for the scan.

  `tol_h` is the half-width of the hue cone in degrees; `tol_sv` is the saturation and
  brightness slack in PERCENT (converted to the 0..255 scale here, once).
  """
  def compile(colors) when is_list(colors) do
    Enum.map(colors, fn %{rgb: {r, g, b}} = color ->
      {h, s, v} = hsv(r, g, b)
      tol_h = color |> Map.get(:tol_h, 12) |> max(1)
      tol_sv = color |> Map.get(:tol_sv, 30) |> Kernel.*(255) |> div(100) |> max(1)
      {h, s, v, tol_h, tol_sv}
    end)
  end

  @doc """
  The teaching EYEDROPPER: the dominant colour of a small square around `{x, y}`, which is what
  his click on the photo becomes.

  A click lands on one pixel, and a sprite pixel is as much anti-aliasing as colour: taking the
  raw pixel would teach its blend with the ground. So the whole patch votes. Grey and near-black
  are out (they have no hue to teach), the rest is grouped by HUE BAND, and the largest band
  answers the MEDIAN of each channel. Median and not mean: the mean between two neighbouring
  tones invents a third that is not on the screen.

  `:none` when there is no colour there at all (he clicked on the rock floor): whoever is
  teaching needs to hear that instead of receiving a silent grey.

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

  @spec dominant(Frame.t(), {integer, integer}, pos_integer) ::
          {:ok, {0..255, 0..255, 0..255}} | :none
  def dominant(%Frame{} = frame, {x, y}, raio \\ 2) do
    bins =
      frame
      |> patch(x, y, raio)
      |> Enum.reject(&hueless?/1)
      |> Enum.group_by(&faixa/1)

    clicado = Frame.at(frame, x, y)

    faixa_do_clique =
      if hueless?(clicado), do: nil, else: Map.get(bins, faixa(clicado))

    case faixa_do_clique || maior_faixa(bins) do
      nil -> :none
      pixels -> {:ok, median(pixels)}
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

  Answers `%{px: total_matched, manchas: [%{point: {x, y}, px: n, cells: n}]}`, blobs in
  decreasing order of size, `point` at the centre of mass.
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

    %{point: {div(sx, px), div(sy, px)}, px: px, cells: map_size(group)}
  end
end
