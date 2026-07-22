defmodule Pokex.Perception.Interpret.Team do
  @moduledoc """
  The left column: the active pokémon's HP in digits, and the health of every
  team member sitting in a C+N slot.

  The active pokémon's HP is text ("5559/6410"), so it is read exactly. The
  team rows only have bars, so those are measured: each row's green fill runs
  left to right inside a fixed track, and the fraction filled is the health.

  The sprite of each member overlaps the left end of its bar, so a member at
  very low health can have its remaining sliver hidden behind the sprite and
  read as 0.0 — wrong in the safe direction (it never reports a hurt member as
  healthy).
  """

  alias Pokex.Layout
  alias Pokex.Vision.Frame

  # measured on the real capture: rows are 67px apart, the track is 84px wide
  @row_pitch 67
  @rows 5
  @first_slot 2

  def interpret(frame, _calib, _settings) do
    fix = Layout.current()

    case fix && Layout.region(:team_column, fix) do
      nil -> empty()
      {ox, oy, _w, _h} = _column -> %{pokemon_hp: pokemon_hp(frame, fix, ox, oy), rows: rows(frame, fix, ox, oy)}
    end
  end

  @doc "The shape callers can rely on when the layout is not located."
  def empty, do: %{pokemon_hp: nil, rows: []}

  @doc ~S'Parses the active pokémon HP text: "5559/6410" -> {5559, 6410}.'
  def parse_hp(text) do
    case Regex.run(~r"^(\d+)/(\d+)$", String.trim(text)) do
      [_all, current, max] -> {String.to_integer(current), String.to_integer(max)}
      nil -> nil
    end
  end

  defp pokemon_hp(frame, fix, ox, oy) do
    case Layout.region(:pokemon_hp, fix) do
      nil ->
        nil

      {x, y, w, h} ->
        frame
        |> Pokex.Vision.Glyphs.read_line({x - ox, y - oy, w, h})
        |> case do
          %{text: text, confidence: 1.0} -> parse_hp(text)
          _uncertain -> nil
        end
    end
  end

  defp rows(frame, fix, ox, oy) do
    case Layout.region(:team_bar_first, fix) do
      nil ->
        []

      {bx, by, bw, bh} ->
        for i <- 0..(@rows - 1)//1 do
          track = {bx - ox, by - oy + i * @row_pitch, bw, bh}
          fill = fill_fraction(frame, track)

          %{slot: @first_slot + i, present?: fill != nil, hp_pct: fill}
        end
    end
  end

  # The rightmost green pixel is where the health ends; everything to its right
  # is empty track. No green at all means the slot is empty (or the member is
  # down) — reported as absent rather than as zero health.
  defp fill_fraction(%Frame{} = frame, {x, y, w, h}) do
    greens =
      for cy <- y..(y + h - 1)//1,
          cx <- x..(x + w - 1)//1,
          cx >= 0 and cy >= 0 and cx < frame.width and cy < frame.height,
          green?(Frame.at(frame, cx, cy)),
          do: cx

    case greens do
      [] -> nil
      _found -> min((Enum.max(greens) - x + 1) / w, 1.0)
    end
  end

  defp green?({r, g, b}), do: g >= 90 and g > r + 30 and g > b + 30
end
