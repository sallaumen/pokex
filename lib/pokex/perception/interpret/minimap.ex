defmodule Pokex.Perception.Interpret.Minimap do
  @moduledoc """
  Where we are — read, not inferred.

  PXG prints the player's position as text at the top of the minimap
  ("(337, 46107, 4)"), which is why this bot will never need to understand the
  map picture to walk it.

  Two sanity gates keep a garbled frame from teleporting the world model: the
  floor must be plausible, and a jump larger than `@max_jump` tiles against the
  last good read is rejected. The rejection is not sticky — a genuine teleport
  (stairs, boat) re-baselines as soon as a second read agrees with the first.
  """

  alias Pokex.Layout
  alias Pokex.Vision.Glyphs

  @max_floor 15
  @max_jump 50

  def interpret(frame, calib, _settings, state \\ nil) do
    state = state || %{last: nil, pending: nil}
    fix = calib && calib.layout

    read =
      case fix && Layout.region(:minimap_coord, fix) do
        nil ->
          nil

        {x, y, w, h} ->
          {ox, oy, _, _} = Layout.region(:minimap, fix)
          # com as opções que a REGIÃO declara: ignorá-las é como o piso de
          # tinta de um slot do HUD deixar de valer justamente ao vivo
          Glyphs.read_coord(
            frame,
            {x - ox, y - oy, w, h},
            Layout.region_opts(fix, :minimap_coord)
          )
      end

    accept(read, state)
  end

  @doc """
  The sanity gates, as a pure step: a read plus the last-good state gives the
  position to publish and the next state. Public because this is the part with
  real logic — the pixels around it are just `Glyphs.read_coord/2`.
  """
  def accept(nil, state), do: {%{pos: nil}, %{state | pending: nil}}

  def accept({_x, _y, z} = pos, state) when z < 0 or z > @max_floor,
    do: {%{pos: nil}, %{state | pending: pos}}

  def accept(pos, %{last: nil} = state), do: {%{pos: pos}, %{state | last: pos, pending: nil}}

  def accept(pos, %{last: last} = state) do
    cond do
      near?(pos, last) ->
        {%{pos: pos}, %{state | last: pos, pending: nil}}

      # a second read agreeing with the first is a real move (stairs, boat),
      # not a glitch — re-baseline instead of rejecting forever
      state.pending && near?(pos, state.pending) ->
        {%{pos: pos}, %{state | last: pos, pending: nil}}

      true ->
        {%{pos: last}, %{state | pending: pos}}
    end
  end

  defp near?({x1, y1, z1}, {x2, y2, z2}),
    do: z1 == z2 and abs(x1 - x2) <= @max_jump and abs(y1 - y2) <= @max_jump
end
