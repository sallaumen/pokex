defmodule Pokex.Perception.Interpret.Hud do
  @moduledoc """
  The bottom bar: the character's numbers and the item stocks.

  Everything here is TEXT the client draws, so the whole interpreter is
  `Vision.Glyphs` over regions the layout derived. A number that cannot be read
  with full confidence comes back `nil` — the bot holds instead of acting on a
  guess (a misread stock would either spam alarms or hide a real one).
  """

  alias Pokex.Layout
  alias Pokex.Vision.Glyphs

  @fields [:level, :food, :fishing]
  @slots [:f1, :f2, :e, :s_q]

  @doc "Reads the bottom bar. `frame` is the `hud_bottom` region; rects are absolute."
  def interpret(frame, _calib, _settings, fix \\ nil) do
    fix = fix || Layout.current()

    case fix && Layout.region(:hud_bottom, fix) do
      nil ->
        empty()

      {ox, oy, _w, _h} ->
        read = &read_int(frame, fix, &1, {ox, oy})

        @fields
        |> Map.new(&{&1, read.(&1)})
        |> Map.put(:slots, Map.new(@slots, &{&1, read.(:"slot_#{&1}")}))
    end
  end

  @doc "The shape callers can rely on when nothing could be read."
  def empty, do: %{level: nil, food: nil, fishing: nil, slots: Map.new(@slots, &{&1, nil})}

  # Layout regions are absolute screen rects; the frame is the cropped bottom
  # bar, so every rect shifts by the bar's own origin.
  defp read_int(frame, fix, region, {ox, oy}) do
    case Layout.region(region, fix) do
      nil ->
        nil

      {x, y, w, h} ->
        Glyphs.read_int(frame, {x - ox, y - oy, w, h}, Layout.region_opts(fix, region))
    end
  end
end
