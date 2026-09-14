defmodule Pokex.Bots.Corner do
  @moduledoc """
  Single source of truth for the panic (kill) corner: the top-left screen
  point a human drags the mouse to for an emergency stop. Shared by
  `Fishing.Logic`, `Combat.Logic` (per-tick, self-stop) and `Guardian`
  (polling, whole-bot stop) so the geometry is defined exactly once.
  """

  @doc """
  True when the cursor point sits in the top-left panic corner (mouse-to-corner
  = emergency stop).

  BOUNDED ON BOTH SIDES, and that is not decoration. Cursor points are LOCAL to
  the display the eye films (`Pokex.Screen.Display`), and a local coordinate goes
  NEGATIVE the moment another monitor sits above or to the left of the game's —
  Lucas's ultrawide is the whole rectangle from (-3440, -1007) to (0, 433) once
  the game moves to the built-in screen. With only `<= 10` to answer to, every
  one of those points read as "in the panic corner" and the gate would sit
  closed, silently, through most of a session with his hand on the panel.
  """
  @spec in_kill_corner?(term) :: boolean
  def in_kill_corner?({x, y})
      when is_number(x) and is_number(y) and x >= 0 and y >= 0 and x <= 10 and y <= 10,
      do: true

  def in_kill_corner?(_), do: false

  @doc """
  True when the cursor sits in the TOP-RIGHT corner — the COMMAND corner:
  holding the mouse there toggles the last used mode from inside the game.

  Exists because the panel's Iniciar requires clicking the browser — stealing
  the game's focus and closing the input gate exactly when the fleet attempts
  its first steps. Moving the mouse changes no focus: the command is born with
  the game focused and the gate open. Mirrors the panic corner (still the kill
  switch, in the OPPOSITE corner — the two never overlap).

  Needs the screen width (panic doesn't: {0,0} is universal) — callers pass
  the calibration's width.
  """
  @spec in_command_corner?(term, term) :: boolean
  def in_command_corner?({x, y}, screen_w)
      when is_number(x) and is_number(y) and is_number(screen_w) and x >= screen_w - 10 and
             y >= 0 and y <= 10,
      do: true

  def in_command_corner?(_point, _screen_w), do: false
end
