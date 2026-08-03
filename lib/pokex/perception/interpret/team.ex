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
  alias Pokex.Pokedex.TeamIcons
  alias Pokex.Vision.Frame
  alias Pokex.Vision.Glyphs
  alias Pokex.Vision.Icons

  # measured on the real capture: rows are 67px apart, the track is 84px wide
  @row_pitch 67
  @rows 5
  @slots 2..6//1 |> Enum.to_list()

  def interpret(frame, calib, _settings) do
    fix = calib && calib.layout

    case fix && Layout.region(:team_column, fix) do
      nil ->
        empty()

      {ox, oy, _w, _h} = _column ->
        %{pokemon_hp: pokemon_hp(frame, fix, ox, oy), rows: rows(frame, fix, ox, oy)}
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
        |> Glyphs.read_line({x - ox, y - oy, w, h})
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
        learned = TeamIcons.all()
        portrait = Layout.region(:team_icon_first, fix)
        label = Layout.region(:team_label_first, fix)

        for i <- 0..(@rows - 1)//1 do
          track = {bx - ox, by - oy + i * @row_pitch, bw, bh}
          fill = fill_fraction(frame, track)

          %{
            slot: read_slot(frame, label, i, ox, oy),
            present?: fill != nil,
            hp_pct: fill,
            name: identify(frame, portrait, i, ox, oy, learned)
          }
        end
    end
  end

  # WHICH hotkey this row answers to, read rather than counted from its
  # position. Measured on the committed captures: earlier the same day the
  # fifth row carried no label at all, and a row with no hotkey must never be
  # a swap target — pressing a key that is not bound does something else.
  defp read_slot(_frame, nil, _row, _ox, _oy), do: nil

  defp read_slot(frame, {lx, ly, lw, lh}, row, ox, oy) do
    frame
    |> Glyphs.read_line({lx - ox, ly - oy + row * @row_pitch, lw, lh})
    |> case do
      %{text: text, confidence: 1.0} -> parse_slot(text)
      _uncertain -> nil
    end
  end

  @doc ~S'Parses the hotkey label: "C+4" -> 4. Anything else is no hotkey at all.'
  def parse_slot(text) do
    case Regex.run(~r"^C\+(\d)$", String.trim(text)) do
      [_all, digit] -> slot_in_range(String.to_integer(digit))
      nil -> nil
    end
  end

  defp slot_in_range(slot) when slot in @slots, do: slot
  defp slot_in_range(_out_of_range), do: nil

  # WHO is in this row. The slot order changes as Lucas plays, so this is read
  # every tick rather than configured — see Vision.Icons for why the portraits
  # are learned from his own screen instead of matched against wiki art.
  defp identify(_frame, nil, _row, _ox, _oy, _learned), do: nil
  defp identify(_frame, _portrait, _row, _ox, _oy, learned) when map_size(learned) == 0, do: nil

  defp identify(frame, {px, py, pw, ph}, row, ox, oy, learned) do
    centre = {px - ox + div(pw, 2), py - oy + div(ph, 2) + row * @row_pitch, div(ph, 2)}

    case Icons.match(Icons.signature(frame, centre), learned) do
      {name, _score} -> name
      nil -> nil
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
