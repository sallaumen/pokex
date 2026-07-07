defmodule Pokex.Bots.Corner do
  @moduledoc """
  Single source of truth for the panic (kill) corner: the top-left screen
  point a human drags the mouse to for an emergency stop. Shared by
  `Fishing.Logic`, `Combat.Logic` (per-tick, self-stop) and `Guardian`
  (polling, whole-bot stop) so the geometry is defined exactly once.
  """

  @doc "True when the cursor point sits in the top-left panic corner (mouse-to-corner = emergency stop)."
  @spec in_kill_corner?(term) :: boolean
  def in_kill_corner?({x, y}) when is_number(x) and is_number(y) and x <= 10 and y <= 10,
    do: true

  def in_kill_corner?(_), do: false
end
