defmodule Pokex.Vision.NameLabels do
  @moduledoc """
  Where the creatures ARE, read from the name the game itself draws over each
  one.

  ## Why the name and not the sprite

  "eu teria que calibrar cada sprite de monstro acredito" (Lucas, 2026-08-26) —
  he would not, and the reason is worth writing down. A sprite is a different
  picture per species, per animation frame and per facing; a name label is the
  SAME picture always: red text the client draws above every hostile creature,
  fixed colour, fixed height, whatever the species. One rule covers the Pikachus
  he farms and the Ratatas he has never managed to kill, with nothing to teach.

  It also answers the right question. The battle list already says HOW MANY
  creatures exist — `Pokex.Bots.CrowdScan` keeps leaning on it for that. What no
  reading had was WHERE, and an area skill that fires at a pile eight tiles away
  is the waste he described: "não adianta a gente otimizar ele ter mais
  cooldowns pra usar com Revives se ele não espera os pokémons estarem próximos".

  ## Measured, and honest about its blind spot

  Measured on a 53s recording of his own hunt (2026-08-26): every "Pikachu"
  label came out 56±2 px wide and 10 px tall, at exactly one label per creature.
  The same pass found NOTHING where the screen was under his Dugtrio's Earthquake
  — a bright spell effect paints over the labels of precisely the creatures it
  is hitting.

  That blind spot is why this counts DOWN and never up: a hidden label reads as
  one creature fewer, so a rule that requires a pile fires LESS often under
  effects, never more. Nothing here decides anything; it reports what it could
  read, and `CrowdScan` reports it beside the battle-list total so the gap is
  visible instead of assumed.

  ## Row runs, not a flood fill

  A per-pixel component search over a 1500px box is millions of `binary_part/3`
  calls. Letters of one word sit on the same rows, so the scan walks sampled
  ROWS collecting red runs (small gaps bridged — the space between letters) and
  merges runs that touch across rows. Same answer, a fraction of the work.
  """

  alias Pokex.Vision.Frame

  # Compression darkens the text's edges, so the test is a RATIO (red dominates
  # both other channels) rather than a floor on red alone: sampled from his
  # recording, label pixels ran 124..231 red with green/blue near zero.
  @min_red 110
  @min_margin 60
  # Green and blue stay together in red text; they diverge in orange damage
  # numbers ("1889") and yellow skill banners ("AGILITY!"), which sit in the
  # same places and must not be counted as creatures.
  @max_channel_split 40

  # A 10px-tall label survives sampling every other row, and halves the work.
  @row_step 2
  # Letter spacing, in px, that still belongs to one word.
  @gap 6

  @type label :: %{x: integer, y: integer, w: pos_integer, h: pos_integer, rows: pos_integer}

  @doc """
  Every name label in `frame`, in frame coordinates.

  Options (all measured defaults; exposed because a different client zoom moves
  them together):

    * `:min_w` / `:max_w` — label width band in px (default #{22}/#{150})
    * `:min_h` / `:max_h` — label height band in px (default #{6}/#{20})
    * `:min_rows` — how many sampled rows must agree (default #{2})
  """
  @spec find(Frame.t(), keyword) :: [label]
  def find(%Frame{} = frame, opts \\ []) do
    min_w = Keyword.get(opts, :min_w, 22)
    max_w = Keyword.get(opts, :max_w, 150)
    min_h = Keyword.get(opts, :min_h, 6)
    max_h = Keyword.get(opts, :max_h, 20)
    min_rows = Keyword.get(opts, :min_rows, 2)

    0..(frame.height - 1)//@row_step
    |> Enum.flat_map(&runs(frame, &1, min_w, max_w))
    |> Enum.reduce([], &merge/2)
    |> Enum.filter(fn l ->
      l.rows >= min_rows and l.w >= min_w and l.w <= max_w and l.h >= min_h and l.h <= max_h
    end)
    |> Enum.sort_by(&{&1.y, &1.x})
  end

  # --- one row -------------------------------------------------------------

  defp runs(frame, y, min_w, max_w) do
    row = binary_part(frame.rgba, y * frame.width * 4, frame.width * 4)
    scan(row, 0, nil, nil, y, min_w, max_w, [])
  end

  defp scan(<<r, g, b, _a, rest::binary>>, x, start, last, y, min_w, max_w, acc) do
    cond do
      red?(r, g, b) ->
        scan(rest, x + 1, start || x, x, y, min_w, max_w, acc)

      last != nil and x - last > @gap ->
        scan(rest, x + 1, nil, nil, y, min_w, max_w, close(acc, start, last, y, min_w, max_w))

      true ->
        scan(rest, x + 1, start, last, y, min_w, max_w, acc)
    end
  end

  defp scan(<<>>, _x, start, last, y, min_w, max_w, acc),
    do: close(acc, start, last, y, min_w, max_w)

  defp close(acc, nil, _last, _y, _min_w, _max_w), do: acc

  defp close(acc, start, last, y, min_w, max_w) do
    w = last - start + 1
    if w >= min_w and w <= max_w, do: [{y, start, last} | acc], else: acc
  end

  defp red?(r, g, b) do
    r > @min_red and r - g > @min_margin and r - b > @min_margin and
      abs(g - b) < @max_channel_split
  end

  # --- rows into labels ----------------------------------------------------

  # A run joins a label when it is on the next sampled row (or the one after —
  # compression eats whole rows of thin text) and overlaps it horizontally.
  defp merge({y, a, b}, labels) do
    case Enum.split_with(labels, &touches?(&1, y, a, b)) do
      {[], rest} ->
        [%{x: a, y: y, w: b - a + 1, h: @row_step, rows: 1} | rest]

      {[hit | _] = hits, rest} ->
        grown = %{
          x: min(hit.x, a),
          y: min(hit.y, y),
          w: max(hit.x + hit.w, b + 1) - min(hit.x, a),
          h: max(hit.y + hit.h, y + @row_step) - min(hit.y, y),
          rows: hit.rows + 1
        }

        [grown | rest ++ tl(hits)]
    end
  end

  defp touches?(l, y, a, b) do
    y >= l.y and y - (l.y + l.h) <= @row_step and
      not (b < l.x - 8 or a > l.x + l.w + 8)
  end
end
