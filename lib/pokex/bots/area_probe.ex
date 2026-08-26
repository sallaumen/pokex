defmodule Pokex.Bots.AreaProbe do
  @moduledoc """
  How far his area skill actually reaches, measured from his own hunt.

  ## Why this exists

  `Pokex.Sim.World` resolves every area press with `aoe_radius: 4`, sitting
  under a comment that says the number is invented. It is load-bearing: at
  radius 4 the area covers 81 of the screen's 165 tiles, so "are they close
  enough?" is nearly always yes — which is why a full sweep of the engine's
  knobs (24 seeds × 4 scenarios, 2026-08-26) found not one that moved kills/min
  by more than 5%. A flat tuning surface is what a wrong model looks like.

  The other invented number in that file was an 8s cooldown. His video measured
  45s, and every conclusion drawn before it had to be thrown away.

  ## How it measures

  One capture right after the bot presses an area key. The green name gives
  where his pokémon was standing; each orange damage number gives a tile that
  took a hit. The furthest one is a LOWER BOUND on the radius for that cast.

  Samples are filed, not averaged away: `summary/0` reports the spread across
  casts so the shape of the distribution is visible.

  ## Its honest confound

  A damage number does not say who dealt it. Other players hunt the same floor
  and their hits print the same orange, which can only inflate the reading. So
  the summary leads with the MEDIAN of per-cast maxima rather than the maximum,
  and carries the top of the range beside it — a number that quietly averaged in
  someone else's Thunderbolt would be the invented 4 all over again, just with
  more ceremony.

  ## It costs a capture per cast

  Which is why it is a MODE, off by default (`area_probe_enabled`). He turns it
  on for one hunt, collects casts, turns it off. Nothing about the hunt's
  behaviour changes while it runs — this only watches.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Calibration
  alias Pokex.Vision.{DamageNumbers, Frame, Ink, NameLabels}

  @type sample :: %{tiles: [float], anchor: :pokemon | :character, hits: non_neg_integer}

  @doc "Whether the probe should run at all — off unless he turned it on."
  @spec on?() :: boolean
  def on?, do: Pokex.Settings.get(:area_probe_enabled) == true

  @doc """
  One look: where the damage landed, in tiles from his pokémon.

  `{:ok, sample}` or `{:error, reason}`. A cast whose ANCHOR is the character
  rather than the pokémon is still returned, flagged — the caller files it and
  `summary/1` leaves it out, because a radius measured from the wrong origin is
  the exact mistake this is here to fix.
  """
  @spec look(keyword) :: {:ok, sample} | {:error, atom}
  def look(opts \\ []) do
    capture = Keyword.get(opts, :capture, &Capture.frame/2)
    radius = Keyword.get(opts, :radius_tiles, Pokex.Settings.get(:crowd_scan_radius_tiles))

    with {:ok, calib} <- calibration(),
         {px, py} when is_integer(px) <- Calibration.player_point(calib),
         region = box_around({px, py}, radius, calib),
         {:ok, frame} <- capture.(region, "area_probe.raw") do
      {anchor, from} = anchor(frame, region, {px, py})
      hits = DamageNumbers.find(frame)

      {:ok,
       %{
         anchor: anchor,
         hits: length(hits),
         tiles: Enum.sort(Enum.map(hits, &distance(&1, region, from, frame)))
       }}
    else
      {:error, reason} -> {:error, reason}
      :not_calibrated -> {:error, :not_calibrated}
      _no_anchor -> {:error, :no_player_point}
    end
  end

  @doc """
  Takes one look and FILES it. What the burst process calls in calibration mode.

  Never raises and never answers back: a measurement that could take the hunt
  down with it would be a worse trade than not measuring.
  """
  @spec file(keyword) :: :ok
  def file(opts \\ []) do
    case look(opts) do
      {:ok, sample} -> save([sample | samples()])
      {:error, _cannot_look} -> :ok
    end
  rescue
    _anything -> :ok
  end

  @doc "Every filed cast, newest first."
  @spec samples() :: [sample]
  def samples do
    with {:ok, raw} <- File.read(Pokex.Home.area_probe_file()),
         {:ok, %{"samples" => list}} <- JSON.decode(raw) do
      Enum.map(list, fn s ->
        %{
          anchor: if(s["anchor"] == "pokemon", do: :pokemon, else: :character),
          hits: s["hits"] || 0,
          tiles: s["tiles"] || []
        }
      end)
    else
      _nothing_or_torn -> []
    end
  end

  @doc "Throws the filed casts away — a new pokémon has a new reach."
  @spec clear() :: :ok
  def clear, do: save([])

  @doc "What the FILED casts say."
  @spec summary() :: map | nil
  def summary, do: summary(samples())

  # The cap is not tidiness: this file is read whole on every cast, and a
  # calibration left running all night would make each look cost more than the
  # capture it is measuring.
  @max_samples 500

  defp save(samples) do
    body =
      JSON.encode!(%{
        "samples" =>
          samples
          |> Enum.take(@max_samples)
          |> Enum.map(
            &%{"anchor" => to_string(&1.anchor), "hits" => &1.hits, "tiles" => &1.tiles}
          )
      })

    Pokex.Home.write!(Pokex.Home.area_probe_file(), body)
  end

  @doc """
  What the filed casts say, or `nil` when none was usable.

  `%{casts:, hits:, p50:, p75:, top:}` — every figure in TILES, computed over
  the per-cast furthest hit. Casts measured from the character are dropped here
  and counted in `:discarded`, so the number is never quietly wrong about its
  own origin.
  """
  @spec summary([sample]) :: map | nil
  def summary(samples) do
    {usable, dropped} = Enum.split_with(samples, &(&1.anchor == :pokemon and &1.tiles != []))
    maxima = usable |> Enum.map(&Enum.max(&1.tiles)) |> Enum.sort()

    if maxima == [] do
      nil
    else
      %{
        casts: length(maxima),
        discarded: length(dropped),
        hits: Enum.sum(Enum.map(usable, & &1.hits)),
        p50: at(maxima, 0.50),
        p75: at(maxima, 0.75),
        top: List.last(maxima)
      }
    end
  end

  # Index from the LAST element, not past it: with three casts `round(3 * 0.5)`
  # is 2 — the biggest one — so the "median" would have been the outlier this
  # statistic exists to survive. And FLOOR rather than round, so an even number
  # of casts settles on the LOWER of the middle two: everything in this feature
  # errs downward, because the only contamination it can suffer inflates.
  defp at(sorted, q),
    do: Enum.at(sorted, min(floor((length(sorted) - 1) * q), length(sorted) - 1))

  # --- geometry (shared shape with CrowdScan, deliberately) ----------------

  defp anchor(frame, region, player) do
    case frame |> NameLabels.find() |> NameLabels.own() do
      nil -> {:character, player}
      label -> {:pokemon, screen_point(label, region, frame)}
    end
  end

  defp distance(shape, region, {ax, ay}, frame) do
    {x, y} = screen_point(shape, region, frame)
    tile = Calibration.tile_px()
    max(abs(x - ax), abs(y - ay)) / tile
  end

  # A NAME sits one tile above the creature it belongs to; a DAMAGE NUMBER sits
  # on the creature it hit. Same lift for both is what would make every measured
  # radius one tile too long.
  defp screen_point(%{kind: :own} = label, region, frame),
    do: screen_point(label, region, frame, Calibration.tile_px())

  defp screen_point(shape, region, frame), do: screen_point(shape, region, frame, 0)

  defp screen_point(shape, {rx, ry, _w, _h}, frame, lift) do
    scale = frame_scale(frame)
    {cx, cy} = Ink.centre(shape)
    {rx + round(cx / scale), ry + round(cy / scale) + lift}
  end

  defp frame_scale(%Frame{scale: scale}) when is_number(scale) and scale > 0, do: scale
  defp frame_scale(_frame), do: 1.0

  defp box_around({px, py}, radius_tiles, %Calibration{screen_w: sw, screen_h: sh}) do
    radius = radius_tiles * Calibration.tile_px()
    x = max(px - radius, 0)
    y = max(py - radius, 0)
    {x, y, max(min(2 * radius, max(sw, 1) - x), 1), max(min(2 * radius, max(sh, 1) - y), 1)}
  end

  defp calibration do
    case Calibration.load() do
      {:ok, %Calibration{screen_w: w, screen_h: h} = calib}
      when is_integer(w) and is_integer(h) ->
        {:ok, calib}

      _no_calibration ->
        :not_calibrated
    end
  end
end
