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
  def interpret(frame, calib, _settings) do
    fix = calib && calib.layout

    case fix && Layout.region(:hud_bottom, fix) do
      nil ->
        empty()

      {ox, oy, _w, _h} ->
        read = &read_int(frame, fix, &1, {ox, oy})
        count = &read_count(frame, fix, :"slot_#{&1}", {ox, oy})

        @fields
        |> Map.new(&{&1, read.(&1)})
        |> Map.put(:slots, Map.new(@slots, &{&1, count.(&1)}))
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

  # An EMPTY hotkey slot draws no number at all — that is a confident read of
  # zero, not a failure. It only counts as zero when the region has NO ink:
  # if something is written there that couldn't be read, it stays nil.
  # Reporting a misread 561 as 0 would fire a false stock alarm — worse than
  # an honest "?".
  #
  # Slots only: level, food and fishing ALWAYS show a number on screen, so a
  # blank region there means a wrong region — never zero.
  defp read_count(frame, fix, region, {ox, oy}) do
    case Layout.region(region, fix) do
      nil ->
        nil

      {x, y, w, h} ->
        rect = {x - ox, y - oy, w, h}
        opts = Layout.region_opts(fix, region)

        case Glyphs.read_int(frame, rect, opts) do
          nil -> if Glyphs.blank?(frame, rect, opts), do: 0, else: nil
          count -> count
        end
    end
  end
end
