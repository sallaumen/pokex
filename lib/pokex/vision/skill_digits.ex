defmodule Pokex.Vision.SkillDigits do
  @moduledoc """
  The count the GAME writes on top of a cooling key, read as what it is: the definitive answer
  about readiness.

  Reading by colour reference compares the slot with a photo taken at calibration, and it failed
  in BOTH directions on two consecutive days: references taken while the skill was charging read
  ready as cooling, and correct references read cooling as ready (this client only darkens PART
  of the icon, so the distance from the cold state falls inside the ceiling). One of those
  nights produced 2,372 "did not fire" lines: every receipt lied, the mute silenced good keys,
  and the rescue stun never confirmed.

  Meanwhile the game was writing `32`, `33`, `43`, `44` on top of the keys, in white with a
  black outline, at the top of the slot. A cooling key ALWAYS has that number; a ready one never
  does. This module looks for exactly that.

  ## What tells a digit from the icon's art (measured on a real capture)

    * **White core**: `min(r,g,b) >= 180` and saturation <= 40.
    * **Glyph size**: 2-10 px wide, 5-11 tall (per scale point). The white explosion in
      one slot's icon measures 15x20 and falls outside.
    * **Black outline**: >= 70% of the cluster's pixels touch a near-black neighbour
      (`max(r,g,b) <= 60`). The digits measured 100%; that white art, 8%.
    * **Zone**: the count lives in the TOP HALF of the slot. The key label (1-9) uses the
      same font but sits below it: measured, the count at y 8-15 and the label at y 20-28
      in a 38px frame.

  Only PRESENCE decides the state. The value (how many seconds) would look good on the panel,
  but a `6` read as a `9` becomes a wrong clock that looks measured, and the glyph atlas does
  not know this font yet. Presence cannot fail that way: either there is a digit-shaped cluster
  or there is not.
  """

  alias Pokex.Vision.Frame

  @white_floor 180
  @white_max_sat 40
  @dark_ceiling 60
  @min_cluster_px 8
  @min_outline_ratio 0.7

  @doc """
  The (0-based) indices of the slots that are COUNTING, a cooldown written by the game itself.
  `count` is the bar's calibrated number of slots.
  """
  @spec counting(Frame.t(), pos_integer) :: MapSet.t(non_neg_integer)
  def counting(%Frame{} = frame, count) when is_integer(count) and count > 0 do
    scale = max(frame.scale, 0.5)
    slot_w = max(div(frame.width, count), 1)

    frame
    |> clusters()
    |> Enum.filter(&countdown_digit?(&1, frame, scale))
    |> Enum.map(fn %{min_x: x} -> min(div(x, slot_w), count - 1) end)
    |> MapSet.new()
  end

  @doc """
  The (0-based) indices of the slots that hold a GLYPH of the game's font: the key label (1-9,
  0) under every slot, or the count above it. This is the signature of "this IS the bar": the
  game always draws the label, with the skill ready or cooling, and nothing else on screen puts
  a white digit with a black outline in each of nine identical rectangles side by side.

  Measured on the five real bars that exist (the three August fixtures, one later capture and
  the tight Venusaur crop): 9 of 9 slots in all of them. On the six non-bars (a bright panel,
  the world, the battle list, the chat): at most 1.
  """
  @spec labelled_slots(Frame.t(), pos_integer) :: MapSet.t(non_neg_integer)
  def labelled_slots(%Frame{} = frame, count) when is_integer(count) and count > 0 do
    scale = max(frame.scale, 0.5)
    slot_w = max(div(frame.width, count), 1)

    frame
    |> clusters()
    |> Enum.filter(&label_glyph?(&1, frame, scale))
    |> Enum.map(fn %{min_x: x} -> min(div(x, slot_w), count - 1) end)
    |> MapSet.new()
  end

  # --- aglomerados de branco --------------------------------------------------

  defp clusters(frame) do
    whites =
      for y <- 0..(frame.height - 1),
          x <- 0..(frame.width - 1),
          white?(Frame.at(frame, x, y)),
          into: MapSet.new(),
          do: {x, y}

    collect(whites, [])
  end

  defp collect(whites, acc) do
    case Enum.at(whites, 0) do
      nil ->
        acc

      seed ->
        {cluster, rest} = flood(MapSet.new([seed]), MapSet.delete(whites, seed), [seed])
        collect(rest, [summarize(cluster) | acc])
    end
  end

  defp flood(cluster, whites, [] = _frontier), do: {cluster, whites}

  defp flood(cluster, whites, frontier) do
    neighbours =
      for {x, y} <- frontier,
          {nx, ny} <- [{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}],
          MapSet.member?(whites, {nx, ny}),
          uniq: true,
          do: {nx, ny}

    flood(
      Enum.into(neighbours, cluster),
      Enum.reduce(neighbours, whites, &MapSet.delete(&2, &1)),
      neighbours
    )
  end

  defp summarize(cluster) do
    {xs, ys} = {Enum.map(cluster, &elem(&1, 0)), Enum.map(cluster, &elem(&1, 1))}

    %{
      pixels: cluster,
      size: MapSet.size(cluster),
      min_x: Enum.min(xs),
      width: Enum.max(xs) - Enum.min(xs) + 1,
      min_y: Enum.min(ys),
      max_y: Enum.max(ys)
    }
  end

  # --- the digit test --------------------------------------------------------

  defp countdown_digit?(cluster, frame, scale),
    do: upper_half?(cluster, frame) and label_glyph?(cluster, frame, scale)

  # A glyph of the game's font, at any height in the slot: digit-sized with a black outline.
  # The count and the key label are the SAME font.
  defp label_glyph?(cluster, frame, scale) do
    height = cluster.max_y - cluster.min_y + 1

    cluster.size >= round(@min_cluster_px * scale * scale) and
      cluster.width in round(2 * scale)..round(10 * scale) and
      height in round(5 * scale)..round(11 * scale) and
      outlined?(cluster, frame)
  end

  # The cluster's centre above the frame's midline: what separates the count from the key
  # label, which uses the SAME font in the lower half.
  defp upper_half?(cluster, frame),
    do: (cluster.min_y + cluster.max_y) / 2 < frame.height / 2

  defp outlined?(cluster, frame) do
    dark =
      Enum.count(cluster.pixels, fn {x, y} ->
        Enum.any?(neighbours8(x, y), fn {nx, ny} ->
          nx >= 0 and ny >= 0 and nx < frame.width and ny < frame.height and
            dark?(Frame.at(frame, nx, ny))
        end)
      end)

    dark / cluster.size >= @min_outline_ratio
  end

  defp neighbours8(x, y),
    do: for(dx <- -1..1, dy <- -1..1, {dx, dy} != {0, 0}, do: {x + dx, y + dy})

  defp white?({r, g, b}),
    do:
      min(r, min(g, b)) >= @white_floor and
        max(r, max(g, b)) - min(r, min(g, b)) <= @white_max_sat

  defp dark?({r, g, b}), do: max(r, max(g, b)) <= @dark_ceiling
end
