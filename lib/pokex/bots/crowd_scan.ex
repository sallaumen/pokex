defmodule Pokex.Bots.CrowdScan do
  @moduledoc """
  How many creatures are CLOSE, and how close.

  The battle list has always answered "how many exist" — that is where
  `world.enemies` comes from, and it is the count every rule in
  `Pokex.Bots.Engine.Logic` reasons with. It cannot answer "how many are within
  reach of an area skill", and that gap is the waste he named: "não adianta a
  gente otimizar ele ter mais cooldowns pra usar com Revives se ele não espera
  os pokémons estarem próximos pra realmente usar as skills e aí desperdiçam as
  skills todas" (2026-08-26).

  This looks at the screen around the character and reports distances, in tiles,
  from the name labels `Pokex.Vision.NameLabels` reads. It DECIDES NOTHING. The
  count it produces sits beside the battle-list total everywhere it is shown, on
  purpose: the two disagreeing is the single most useful fact about how much the
  reading can be trusted on any given screen, and hiding that behind one number
  would be the assumption this module exists to remove.

  ## Cost

  One capture (~0.28s serialized through `Pokex.Bots.Capture`) plus a row scan
  of the box. That is a per-DECISION cost, not a per-tick one — nothing here is
  wired into a feed. Ask when about to spend a skill, or when he is watching the
  panel; never in a loop.

  ## Reads low, never high

  A creature standing under a bright spell effect loses its label to the effect
  (measured on his own recording: the three labels readable during an Earthquake
  were the ones OUTSIDE the blast). So `seen` is a floor, and a rule that gates
  on "enough of them are close" gets more cautious under effects rather than
  more reckless — the safe direction for a mistake to run.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Calibration
  alias Pokex.Vision.{Frame, NameLabels}

  @type spot :: %{tiles: non_neg_integer, dx: integer, dy: integer, point: {integer, integer}}
  @type reading ::
          %{
            read?: true,
            seen: non_neg_integer,
            listed: non_neg_integer | nil,
            spots: [spot],
            radius: pos_integer,
            took_ms: non_neg_integer
          }
          | %{read?: false, reason: atom}

  @doc """
  Looks around the character and reports every creature it could place.

  Options:

    * `:radius_tiles` — how far out to look (default `crowd_scan_radius_tiles`)
    * `:listed` — the battle-list count to report alongside, when the caller has one
    * `:capture` — injected for tests
  """
  @spec look(keyword) :: reading
  def look(opts \\ []) do
    started = System.monotonic_time(:millisecond)
    radius = Keyword.get(opts, :radius_tiles, Pokex.Settings.get(:crowd_scan_radius_tiles))
    capture = Keyword.get(opts, :capture, &Capture.frame/2)

    with {:ok, calib} <- calibration(),
         {px, py} when is_integer(px) <- Calibration.player_point(calib),
         region = box_around({px, py}, radius, calib),
         {:ok, frame} <- capture.(region, "crowd_scan.raw") do
      %{
        read?: true,
        seen: 0,
        listed: Keyword.get(opts, :listed),
        spots: spots(frame, region, {px, py}),
        radius: radius,
        took_ms: System.monotonic_time(:millisecond) - started
      }
      |> then(&%{&1 | seen: length(&1.spots)})
    else
      {:error, reason} -> %{read?: false, reason: reason}
      :not_calibrated -> %{read?: false, reason: :not_calibrated}
      _no_anchor -> %{read?: false, reason: :no_player_point}
    end
  end

  @doc """
  How many of them are within `tiles`. The question a rule actually asks, kept
  here so no caller has to re-derive it from `spots`.
  """
  @spec within(reading, pos_integer) :: non_neg_integer
  def within(%{read?: true, spots: spots}, tiles), do: Enum.count(spots, &(&1.tiles <= tiles))
  def within(_unread, _tiles), do: 0

  @doc """
  The nearest creature's distance in tiles, or `nil` when none was placed.
  """
  @spec nearest(reading) :: non_neg_integer | nil
  def nearest(%{read?: true, spots: [_ | _] = spots}),
    do: spots |> Enum.map(& &1.tiles) |> Enum.min()

  def nearest(_none), do: nil

  # --- geometry ------------------------------------------------------------

  defp spots(%Frame{} = frame, {rx, ry, _w, _h}, {px, py}) do
    tile = Calibration.tile_px()
    scale = frame_scale(frame)

    frame
    |> NameLabels.find(band(scale))
    |> Enum.map(fn label ->
      # The label is drawn ABOVE the creature it names — one tile up, measured
      # on his recording. Expressed in TILES so it survives any client zoom that
      # moves `tile_px`; a pixel constant here would silently rot.
      x = rx + round((label.x + div(label.w, 2)) / scale)
      y = ry + round((label.y + div(label.h, 2)) / scale) + tile

      dx = round((x - px) / tile)
      dy = round((y - py) / tile)
      %{tiles: max(abs(dx), abs(dy)), dx: dx, dy: dy, point: {x, y}}
    end)
    |> Enum.sort_by(& &1.tiles)
  end

  # The label bands were measured in PIXELS on his 2× display ("Pikachu" came out
  # 56×10). A frame captured at 1× carries the same label at half that, so the
  # band travels with the frame's own scale instead of assuming his monitor.
  defp band(scale) do
    [
      min_w: round(22 * scale),
      max_w: round(150 * scale),
      min_h: round(6 * scale),
      max_h: round(20 * scale)
    ]
  end

  defp frame_scale(%Frame{scale: scale}) when is_number(scale) and scale > 0, do: scale
  defp frame_scale(_frame), do: 1.0

  defp box_around({px, py}, radius_tiles, %Calibration{screen_w: sw, screen_h: sh}) do
    radius = radius_tiles * Calibration.tile_px()
    x = max(px - radius, 0)
    y = max(py - radius, 0)
    w = min(2 * radius, max(sw, 1) - x)
    h = min(2 * radius, max(sh, 1) - y)

    {x, y, max(w, 1), max(h, 1)}
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
