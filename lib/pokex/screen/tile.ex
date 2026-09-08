defmodule Pokex.Screen.Tile do
  @moduledoc """
  How many screen POINTS one game tile is, per screen — measured on his own
  captures, never typed in.

  The tile is a property of the screen, not a setting: the client draws the
  map at 151 points a tile on the ultrawide and at 36 on the notebook, and
  every distance "from the character" (the eye, the park click, the corpse
  box) is written in that unit. Until 2026-09-08 it was a number on the
  cavebot page that nobody remembered to change: the notebook ran three days
  with the ultrawide's 151, the eye called every creature "1 tile" away and
  the park clicks landed off screen.

  A screen that is not here is refused by the preflight and shouted by the
  watchman — "dar erro" was his own word for it. Adding a screen means
  measuring it (the floor's autocorrelation on a capture, or the grid on a
  screenshot) and writing the number down here with the date.
  """

  @measured %{
    # his ultrawide: the map at 151 pt a tile (park clicks and corpse boxes, 2026-08)
    {3440, 1440} => 151,
    # his notebook: floor autocorrelation of the 2026-09-07 capture = 36, the grid
    # visible on the screenshot, his own health bar 36 px above the character point
    {1512, 982} => 36
  }

  @doc "The tile of a screen given in points, when it has been measured."
  @spec for_screen({term, term}) :: {:ok, pos_integer} | :unknown
  def for_screen({w, h}) when is_integer(w) and is_integer(h) do
    case Map.fetch(@measured, {w, h}) do
      {:ok, tile} -> {:ok, tile}
      :error -> :unknown
    end
  end

  def for_screen(_no_screen), do: :unknown

  @doc "Every measured screen, largest first: `[{{w, h}, tile}]`."
  @spec known() :: [{{pos_integer, pos_integer}, pos_integer}]
  def known, do: Enum.sort_by(@measured, fn {{w, _h}, _tile} -> -w end)

  @doc "The measured screens in one sentence, for a refusal or an alarm."
  @spec known_text() :: String.t()
  def known_text do
    Enum.map_join(known(), ", ", fn {{w, h}, tile} -> "#{w}×#{h} → #{tile}" end)
  end
end
