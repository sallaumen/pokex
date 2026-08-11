defmodule Pokex.Bots.Catcher.Sweep do
  @moduledoc """
  The BLIND sweep: every tile around the character, in throwing order.

  Deliberately ignorant. `SpotScan` + `CorpseLibrary` are the aimed capture —
  they only throw at a corpse whose palette matched something taught in
  calibration, which is precise and, when the aim or the library is off,
  silently throws nothing (Lucas, 2026-08-05: *"atualmente eu tô vendo ele
  perder muito pokémon"*). This module is the safety net under that: no vision,
  no library, no score. A ball at every tile in reach, on a slow cadence,
  accepting waste in exchange for never missing a body that WAS there.

  Two shapes of waste it does refuse: the character's own tile and the tile
  where his active Pokémon stands (SpotScan's forbidden zones, same reasoning),
  plus anything off the display. And `sweep_side` exists because his fishing
  spot has the SEA to the left — half the square is water, so the sweep can be
  told to cover only the character's column and everything right of it.

  Order is NEAREST RING FIRST: a sweep interrupted mid-way (a fight starting,
  the game losing focus) has already covered the tiles a corpse is most likely
  to be on.
  """

  alias Pokex.{Calibration, Settings}

  @sides ~w(square right left)

  @doc "The sides a sweep can cover, as stored."
  def sides, do: @sides

  @doc """
  The SCREEN points to throw at, nearest tile first, centred on `around` (the
  tile his pokémon was parked on) or on the character when there is none.

  `{:error, :no_screen}` when the calibration has no display dimensions (there
  is nothing to clamp the grid against) and `{:error, :no_anchor}` when it
  cannot say where the character is — an honest refusal instead of a grid
  guessed around the wrong point, which is how the mini-game box earned its
  ghosts.
  """
  @spec points(Calibration.t(), {integer, integer} | nil) ::
          {:ok, [{integer, integer}]} | {:error, :no_screen | :no_anchor}
  def points(%Calibration{} = calib, around \\ nil) do
    with {:ok, screen} <- screen(calib),
         {:ok, anchor} <- anchor(calib, around) do
      {:ok, sweep(calib, anchor, screen)}
    end
  end

  @doc """
  How many tiles a sweep of `radius` on `side` covers.

  An UPPER bound — the screen clamp and his Pokémon's tile only ever remove
  from it — and what the settings screen shows so the cost of a radius is
  visible before the first ball flies.
  """
  @spec tile_count(pos_integer, String.t()) :: non_neg_integer
  def tile_count(radius, side) when is_integer(radius) and radius >= 1 do
    rows = 2 * radius + 1
    columns = if side in ["right", "left"], do: radius + 1, else: rows
    columns * rows - 1
  end

  def tile_count(_radius, _side), do: 0

  defp sweep(calib, {ax, ay}, {sw, sh}) do
    tile = Calibration.tile_px()
    radius = max(Settings.get(:sweep_radius_tiles), 1)
    side = Settings.get(:sweep_side)
    skip = own_tiles(calib, {ax, ay}, tile)

    ordered =
      for dy <- -radius..radius,
          dx <- -radius..radius,
          covers?(side, dx),
          {dx, dy} not in skip,
          point = {ax + dx * tile, ay + dy * tile},
          on_screen?(point, sw, sh),
          do: {ring(dx, dy), dy, dx, point}

    ordered
    |> Enum.sort()
    |> Enum.map(fn {_ring, _dy, _dx, point} -> point end)
  end

  # Ring = Chebyshev distance in tiles. Sorting by it (then by row, then by
  # column, so the order is stable and readable in the log) puts the adjacent
  # eight first — where a corpse from the fight that just ended lies.
  defp ring(dx, dy), do: max(abs(dx), abs(dy))

  defp covers?("right", dx), do: dx >= 0
  defp covers?("left", dx), do: dx <= 0
  # Anything else — including a hand-edited settings file — sweeps the whole square.
  defp covers?(_square, _dx), do: true

  defp own_tiles(%Calibration{pokemon_spot_point: spot}, anchor, tile),
    do: [{0, 0} | pokemon_tile(spot, anchor, tile)]

  defp pokemon_tile({px, py}, {ax, ay}, tile),
    do: [{round((px - ax) / tile), round((py - ay) / tile)}]

  defp pokemon_tile(_unmarked, _anchor, _tile), do: []

  defp on_screen?({x, y}, sw, sh), do: x >= 0 and y >= 0 and x < sw and y < sh

  defp screen(%Calibration{screen_w: w, screen_h: h}) when is_integer(w) and is_integer(h),
    do: {:ok, {w, h}}

  defp screen(%Calibration{}), do: {:error, :no_screen}

  # Where the corpses ARE, which is not always where he is.
  #
  # "Como eu apertei o botão do meio do mouse, esses corpos de pokémons não
  # estão ao redor do meu personagem" (Lucas, 2026-08-11): the pile dies
  # around the tile his pokémon was PARKED on, several tiles away. Sweeping
  # around the character throws balls at empty ground and leaves the corpses
  # where they fell.
  defp anchor(_calib, {_x, _y} = around), do: {:ok, around}

  defp anchor(calib, _no_park) do
    case Calibration.player_point(calib) do
      {_x, _y} = point -> {:ok, point}
      nil -> {:error, :no_anchor}
    end
  end
end
