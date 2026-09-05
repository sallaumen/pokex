defmodule Pokex.Bots.CrowdScan do
  @moduledoc """
  Where every creature around the character stands, in tiles from HIM and
  from his pokemon.

  ## Measured from the character, always

  The calibrated character point never disappears and is never mistaken for
  a monster. His pokemon is one more mark — the one with the number box under
  its bar, nearest to him — and it is optional: without it `from_pet` is
  `nil`, and a consumer knows it only has distances from the character.

  The first eye anchored on "the green name", which in this client is any
  creature at full health: on 2026-09-03 it measured from a Feraligatr, and
  from a palm tree.

  ## Marks in, tiles out

  `Pokex.Vision.CreatureMarks` turns pixels into bar marks; `place/3` turns
  marks into tiles and is pure, so the simulator can feed it the marks its
  own world would draw. `look/1` is the only function here that touches the
  screen.

  ## It shows its work

  With `evidence: true` the reading carries the captured box with the marks
  drawn on it: bars boxed (blue hostile, green pet), skulls tagged, a magenta
  cross where the character is. A number cannot say whether the detector, the
  anchor or the ruler was wrong; a picture can.

  ## Cost

  Measured on the live server log (2026-09-05): ~9 ms for the capture of a
  1812×1440 box and ~18 ms for the read. A per-tick cost, not a per-decision
  one.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Calibration
  alias Pokex.Vision.{CreatureMarks, Evidence, Frame}

  @hostile_box {0, 220, 255}
  @pet_box {0, 255, 120}
  @skull_box {255, 255, 255}
  @me_cross {255, 0, 255}

  # A mark whose body stands within this many tiles of the character IS the
  # character (his own bar floats over his head).
  @me_tiles 0.6

  @type hostile :: %{
          point: {integer, integer},
          dx: integer,
          dy: integer,
          from_me: non_neg_integer,
          from_pet: non_neg_integer | nil,
          hp_pct: 0..100,
          skull?: boolean
        }
  @type pet :: %{
          point: {integer, integer},
          dx: integer,
          dy: integer,
          tiles: non_neg_integer,
          hp_pct: 0..100
        }
  @type placed :: %{read?: true, me: {integer, integer}, pet: pet | nil, hostiles: [hostile]}
  @type reading ::
          %{
            read?: true,
            at: integer,
            took_ms: non_neg_integer,
            me: {integer, integer},
            box: {integer, integer, integer, integer},
            pet: pet | nil,
            hostiles: [hostile],
            listed: non_neg_integer | nil,
            evidence: String.t() | nil
          }
          | %{read?: false, reason: atom}

  @doc """
  Captures the box around the character and places every creature in it.

  Options:

    * `:radius_tiles` — how far out to look (default `crowd_scan_radius_tiles`)
    * `:listed` — the battle-list count to carry alongside, when the caller has one
    * `:evidence` — also return the picture it read, with the marks drawn on
    * `:capture` — injected for tests
  """
  @spec look(keyword) :: reading
  def look(opts \\ []) do
    started = System.monotonic_time(:millisecond)
    radius = Keyword.get(opts, :radius_tiles, Pokex.Settings.get(:crowd_scan_radius_tiles))
    capture = Keyword.get(opts, :capture, &Capture.frame/2)

    with {:ok, calib} <- calibration(),
         {px, py} when is_integer(px) <- Calibration.player_point(calib),
         box = box_around({px, py}, radius, calib),
         {:ok, frame} <- capture.(box, "crowd_scan.raw") do
      scale = frame_scale(frame)
      tile = Calibration.tile_px()
      found = CreatureMarks.find(frame, tile_px: round(tile * scale))
      marks = Enum.map(found, &to_screen(&1, box, scale))

      marks
      |> place({px, py}, tile)
      |> Map.merge(%{
        at: started,
        took_ms: System.monotonic_time(:millisecond) - started,
        box: box,
        listed: Keyword.get(opts, :listed),
        evidence: evidence(opts, frame, found, box, {px, py}, scale)
      })
    else
      {:error, reason} -> %{read?: false, reason: reason}
      :not_calibrated -> %{read?: false, reason: :not_calibrated}
      _no_anchor -> %{read?: false, reason: :no_player_point}
    end
  end

  @doc """
  Marks (bar centres, in screen points) placed in tiles from `me` and from
  his pokemon. Pure: the simulator calls it with the marks its world draws.
  """
  @spec place([CreatureMarks.mark()], {integer, integer}, pos_integer) :: placed
  def place(marks, {px, py} = me, tile) do
    bodies =
      marks
      |> Enum.map(fn %{point: {x, y}} = mark -> %{mark | point: {x, y + tile}} end)
      |> Enum.reject(&(chebyshev(&1.point, me) <= @me_tiles * tile))

    pet =
      bodies
      |> Enum.filter(& &1.pet?)
      |> Enum.min_by(&chebyshev(&1.point, me), fn -> nil end)

    hostiles =
      bodies
      |> Enum.reject(&(&1 == pet))
      |> Enum.map(&hostile(&1, me, pet, tile))
      |> Enum.sort_by(&{&1.from_me, &1.dx, &1.dy})

    %{read?: true, me: {px, py}, pet: pet && pet_of(pet, me, tile), hostiles: hostiles}
  end

  @doc "How many hostiles stand within `tiles` of the CHARACTER. Zero for an unread scan, never a guess."
  @spec within(reading | placed, non_neg_integer) :: non_neg_integer
  def within(%{read?: true, hostiles: hostiles}, tiles),
    do: Enum.count(hostiles, &(&1.from_me <= tiles))

  def within(_unread, _tiles), do: 0

  # --- geometry ------------------------------------------------------------

  defp hostile(%{point: point, hp_pct: hp, skull?: skull?}, me, pet, tile) do
    {dx, dy} = offset(point, me, tile)

    %{
      point: point,
      dx: dx,
      dy: dy,
      from_me: max(abs(dx), abs(dy)),
      from_pet: pet && tiles_between(point, pet.point, tile),
      hp_pct: hp,
      skull?: skull?
    }
  end

  defp pet_of(%{point: point, hp_pct: hp}, me, tile) do
    {dx, dy} = offset(point, me, tile)
    %{point: point, dx: dx, dy: dy, tiles: max(abs(dx), abs(dy)), hp_pct: hp}
  end

  defp offset({x, y}, {px, py}, tile), do: {round((x - px) / tile), round((y - py) / tile)}

  defp tiles_between(a, b, tile) do
    {dx, dy} = offset(a, b, tile)
    max(abs(dx), abs(dy))
  end

  defp chebyshev({ax, ay}, {bx, by}), do: max(abs(ax - bx), abs(ay - by))

  # Frame pixels → screen points: the box's origin plus the pixel over the
  # backend's scale.
  defp to_screen(%{point: {x, y}} = mark, {rx, ry, _w, _h}, scale),
    do: %{mark | point: {rx + round(x / scale), ry + round(y / scale)}}

  defp evidence(opts, frame, marks, {rx, ry, _w, _h}, {px, py}, scale) do
    if Keyword.get(opts, :evidence, false) do
      geo = CreatureMarks.geometry(round(Calibration.tile_px() * scale))

      Evidence.data_url(frame,
        shrink: Pokex.Settings.get(:crowd_scan_evidence_shrink),
        boxes: Enum.flat_map(marks, &mark_boxes(&1, geo)),
        marks: [{round((px - rx) * scale), round((py - ry) * scale), @me_cross}]
      )
    end
  end

  # The bar boxed in its kind's colour, and the skull boxed above it when
  # there is one.
  defp mark_boxes(%{point: {x, y}} = mark, %{bar_w: bw, bar_h: bh}) do
    bar = %{
      x: x - div(bw, 2),
      y: y - div(bh, 2),
      w: bw,
      h: bh,
      colour: if(mark.pet?, do: @pet_box, else: @hostile_box)
    }

    skull = %{x: x - 8, y: y - 34, w: 16, h: 17, colour: @skull_box}

    if mark.skull?, do: [bar, skull], else: [bar]
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
