defmodule Pokex.Bots.CrowdScan do
  @moduledoc """
  How many creatures are CLOSE, how close, and close to WHAT.

  The battle list has always answered "how many exist", which is where `world.enemies` comes
  from and the count every rule in `Pokex.Bots.Engine.Logic` reasons with. It cannot answer "how
  many are within reach of an area skill", and that gap is the waste he named: there is no point
  optimising for more cooldowns via revives if the bot does not wait for the mobs to be close,
  because then all the skills are wasted.

  ## Measured from the pokémon, not the trainer

  An area skill leaves the POKÉMON. The first version of this measured from the character
  because that is the point the calibration knows, and on his screen the two sit two tiles apart
  routinely: every distance carried that error.

  The fix needed no sprite taught: the game draws HIS pokémon's name in green, so the same pass
  that finds the red hostiles finds the green anchor. `Pokex.Bots.PokemonTracker` could have
  answered too, but only for pokémon he has photographed, and his library held two he no longer
  plays.

  When the green label is covered, the reading falls back to the character and SAYS SO in
  `:anchor`. A distance whose origin is unknown is worse than no distance, because it looks the
  same as a good one.

  ## It shows its work

  He called the reading still very imprecise, and a number cannot say whether it was the
  detector, the anchor or the ruler. `look/1` with `evidence: true` returns the picture it read
  with boxes on what it found and a cross on what it measured from.

  ## Cost

  One capture (~0.28s serialized through `Pokex.Bots.Capture`, raw pixels, see
  `capture_format_test.exs`) plus a row scan of the box (14-31ms). That is a per-DECISION cost,
  not a per-tick one; nothing here is wired into a feed.

  ## Reads low, never high

  A creature standing under a bright spell effect loses its label to the effect, and a yellow
  skill banner lands in the same band as the names. Measured in the field: four hostiles on
  screen, the two with uncovered names counted. So `seen` is a floor, and a rule that gates on
  "enough of them are close" gets more cautious under effects rather than more reckless.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Calibration
  alias Pokex.Vision.{Evidence, Frame, NameLabels}

  @hostile_box {0, 220, 255}
  @own_box {0, 255, 120}
  @anchor_cross {255, 0, 255}

  @type spot :: %{tiles: non_neg_integer, dx: integer, dy: integer, point: {integer, integer}}
  @type reading ::
          %{
            read?: true,
            seen: non_neg_integer,
            listed: non_neg_integer | nil,
            spots: [spot],
            anchor: :pokemon | :character,
            radius: pos_integer,
            took_ms: non_neg_integer,
            evidence: String.t() | nil
          }
          | %{read?: false, reason: atom}

  @doc """
  Looks around the character and reports every creature it could place.

  Options:

    * `:radius_tiles` — how far out to look (default `crowd_scan_radius_tiles`)
    * `:listed` — the battle-list count to report alongside, when the caller has one
    * `:evidence` — also return the picture it read, with its findings drawn on
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
      labels = NameLabels.find(frame)
      {anchor, from} = anchor(labels, frame, region, {px, py})

      %{
        read?: true,
        seen: 0,
        listed: Keyword.get(opts, :listed),
        spots: spots(labels, region, from, frame),
        anchor: anchor,
        radius: radius,
        took_ms: System.monotonic_time(:millisecond) - started,
        evidence: evidence(opts, frame, labels, region, from)
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

  @doc "The nearest creature's distance in tiles, or `nil` when none was placed."
  @spec nearest(reading) :: non_neg_integer | nil
  def nearest(%{read?: true, spots: [_ | _] = spots}),
    do: spots |> Enum.map(& &1.tiles) |> Enum.min()

  def nearest(_none), do: nil

  # --- geometry ------------------------------------------------------------

  # His pokémon's own green name when it was readable, else the calibrated
  # character point — and the caller is told which, because the two are
  # routinely two tiles apart.
  defp anchor(labels, frame, region, player) do
    case NameLabels.own(labels) do
      nil -> {:character, player}
      label -> {:pokemon, creature_point(label, region, frame)}
    end
  end

  defp spots(labels, region, {ax, ay}, frame) do
    tile = Calibration.tile_px()

    labels
    |> NameLabels.hostiles()
    |> Enum.map(fn label ->
      {x, y} = creature_point(label, region, frame)
      dx = round((x - ax) / tile)
      dy = round((y - ay) / tile)
      %{tiles: max(abs(dx), abs(dy)), dx: dx, dy: dy, point: {x, y}}
    end)
    |> Enum.sort_by(& &1.tiles)
  end

  # The label is drawn ABOVE the creature it names — one tile up, measured on
  # his recording. Expressed in TILES so it survives any client zoom that moves
  # `tile_px`; a pixel constant here would silently rot.
  defp creature_point(label, {rx, ry, _w, _h}, frame) do
    scale = frame_scale(frame)

    {
      rx + round((label.x + div(label.w, 2)) / scale),
      ry + round((label.y + div(label.h, 2)) / scale) + Calibration.tile_px()
    }
  end

  defp evidence(opts, frame, labels, {rx, ry, _w, _h}, {ax, ay}) do
    if Keyword.get(opts, :evidence, false) do
      scale = frame_scale(frame)

      Evidence.data_url(frame,
        shrink: Pokex.Settings.get(:crowd_scan_evidence_shrink),
        boxes:
          Enum.map(labels, fn l ->
            %{
              x: l.x,
              y: l.y,
              w: l.w,
              h: l.h,
              colour: if(l.kind == :hostile, do: @hostile_box, else: @own_box)
            }
          end),
        marks: [{round((ax - rx) * scale), round((ay - ry) * scale), @anchor_cross}]
      )
    end
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
