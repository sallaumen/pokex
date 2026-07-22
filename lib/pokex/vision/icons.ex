defmodule Pokex.Vision.Icons do
  @moduledoc """
  Recognising WHICH pokémon a team row is showing, by its portrait.

  Lucas's constraint: "a posição dos pokémons nos atalhos C+N nunca é fixa,
  conforme vou usando pokemons a ordem vai mudando". A configured slot is
  therefore a lie waiting to happen — by the time a combo fires, C+5 may hold
  somebody else. The slot has to be READ, every tick.

  Matching against the scraped wiki sprites was measured and is not good
  enough: colour histograms over his own six pokémon scored 4 of 5 with
  margins as thin as 0.016, because the art differs and each row sits on a
  coloured disc. Comparing his screen against HIS screen is a different
  question entirely — same art, same size, same renderer — and it measures
  1.00 for the right pokémon against 0.25-0.35 for every other, on captures
  taken hours apart with the team in a different order.

  So a signature is learned once from his own panel and matched pixel-block
  against pixel-block. Two things are subtracted first: the coloured disc
  behind the portrait (sampled from its own rim, since it differs per row) and
  the white "C+N" label drawn on top of it.
  """

  alias Pokex.Vision.Frame

  # A coarse grid is deliberate: it survives a pixel of jitter, and colours are
  # quantised to 3 bits per channel so anti-aliasing cannot flip a cell.
  @step 2
  @quantise 32
  @background_max 40
  @label_min 170
  @label_spread 40
  @disc_tolerance 42

  @doc """
  The portrait's signature: a sparse grid of quantised colours, keyed by cell.

  Cells the portrait does not occupy are simply absent — which is itself
  signal, since silhouette is most of what tells a Ditto from a Tentacruel.
  """
  def signature(%Frame{} = frame, {cx, cy, radius}) do
    disc = disc_colour(frame, {cx, cy, radius})

    for y <- (cy - radius)..(cy + radius)//@step,
        x <- (cx - radius)..(cx + radius)//@step,
        inside?(x, y, cx, cy, radius),
        colour = portrait_colour(frame, x, y, disc),
        colour != nil,
        into: %{} do
      {{div(x - cx, @step), div(y - cy, @step)}, colour}
    end
  end

  @doc """
  The best match for `signature` among `learned` (name => signature).

  Returns `{name, score}` when the score clears `min_score` AND beats the
  runner-up by `min_margin`; otherwise nil. Both gates matter: a lone high
  score can come from two similar portraits, and sending the wrong pokémon
  into a fight is worse than sending none.
  """
  def match(signature, learned, opts \\ []) do
    min_score = Keyword.get(opts, :min_score, 0.55)
    min_margin = Keyword.get(opts, :min_margin, 0.15)

    learned
    |> Enum.map(fn {name, reference} -> {name, similarity(signature, reference)} end)
    |> Enum.sort_by(&(-elem(&1, 1)))
    |> case do
      [{name, score} | rest] ->
        runner_up = rest |> Enum.map(&elem(&1, 1)) |> List.first() || 0.0

        if score >= min_score and score - runner_up >= min_margin,
          do: {name, score},
          else: nil

      [] ->
        nil
    end
  end

  @doc """
  How alike two signatures are: the share of occupied cells that agree.

  A cell only counts when at least one side has portrait there, so a small
  sprite is not flattered by all the emptiness it shares with everything else.
  """
  def similarity(a, b) do
    keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))

    {considered, agreed} =
      Enum.reduce(keys, {0, 0}, fn key, {considered, agreed} ->
        left = Map.get(a, key)
        right = Map.get(b, key)

        {considered + 1, if(left != nil and left == right, do: agreed + 1, else: agreed)}
      end)

    if considered == 0, do: 0.0, else: agreed / considered
  end

  # The disc behind the portrait differs per row (and changes with the game's
  # mood), so it is sampled from this row's own rim rather than assumed.
  defp disc_colour(frame, {cx, cy, radius}) do
    0..359//3
    |> Enum.map(fn degrees ->
      radians = degrees * :math.pi() / 180
      x = round(cx + :math.cos(radians) * (radius - 3))
      y = round(cy + :math.sin(radians) * (radius - 3))
      safe_at(frame, x, y)
    end)
    |> Enum.reject(&(&1 == nil or max_channel(&1) <= @background_max))
    |> Enum.frequencies()
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
    |> elem(0)
  end

  defp portrait_colour(frame, x, y, disc) do
    case safe_at(frame, x, y) do
      nil -> nil
      {r, g, b} = pixel -> classify(pixel, r, g, b, disc)
    end
  end

  defp classify({r, g, b}, _r, _g, _b, disc) do
    cond do
      max(r, max(g, b)) <= @background_max ->
        nil

      min(r, min(g, b)) >= @label_min and max(r, max(g, b)) - min(r, min(g, b)) <= @label_spread ->
        nil

      disc != nil and near?({r, g, b}, disc) ->
        nil

      true ->
        {div(r, @quantise), div(g, @quantise), div(b, @quantise)}
    end
  end

  defp near?({r, g, b}, {dr, dg, db}),
    do: abs(r - dr) + abs(g - dg) + abs(b - db) <= @disc_tolerance

  defp inside?(x, y, cx, cy, radius),
    do: (x - cx) * (x - cx) + (y - cy) * (y - cy) <= (radius - 2) * (radius - 2)

  defp max_channel({r, g, b}), do: max(r, max(g, b))

  defp safe_at(%Frame{width: w, height: h} = frame, x, y)
       when x >= 0 and y >= 0 and x < w and y < h,
       do: Frame.at(frame, x, y)

  defp safe_at(_frame, _x, _y), do: nil
end
