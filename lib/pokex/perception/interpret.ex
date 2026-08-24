defmodule Pokex.Perception.Interpret do
  @moduledoc """
  Pure frame → observation interpreters, one per feed. Ported from the combat half of
  `Fisher.Sensors.Real` (which stays untouched for fishing until phase 2): same slicing,
  same row-band geometry, same thresholds — the ONLY addition is the lock verdict
  (locked?/locked_row), computed here once so every consumer shares one interpretation.
  """

  alias Pokex.Bots.SkillBar
  alias Pokex.{Calibration, Settings, Vision}
  alias Pokex.Vision.{Frame, Glyphs}

  @doc """
  The battle panel: candidate enemy rows (HP bar, no own-pokemon pokeball), per-row
  lock-ring red counts, and whether/where the lock ring is up.
  """
  def battle(frame, calib, settings) do
    measured = calib && calib.layout && Pokex.Layout.battle_rows()

    {top, band, rows} =
      case measured do
        # The profile carries the geometry MEASURED on real captures. His
        # battle_row_height setting says 52, tuned when the panel sat 173px
        # higher; the rows actually repeat every 46, and bands built from the
        # stale number land between rows.
        %{band_top: t, pitch: p, max_rows: r} ->
          {t, p, r}

        nil ->
          {t, b} =
            Calibration.row_band_geometry(
              frame.scale,
              Settings.value(settings, :battle_row_height),
              Settings.value(settings, :battle_first_row_y)
            )

          {t, b, Settings.value(settings, :battle_max_rows)}
      end

    strip_px = round(Calibration.strip_width() * frame.scale)

    # The strip (the rightmost pokeball column) is cropped OFF the body so its
    # red ball pixels can't read as the lock ring — but a pokeball on a row no
    # longer subtracts it from the enemies: measured live (2026-07-20), a
    # "Catch Pokémon" quest marks the CATCHABLE enemy's row with a pokeball —
    # the very creature the bot must attack — while the own pokemon (out, HP
    # readable) doesn't appear in the list at all. The old "pokeball = own
    # pokemon" subtraction erased the only enemy: battle read 0 forever and
    # combat stood still while the creature beat the player. Every HP-bar row
    # is a candidate; the lock ring (and the game's own Tab, which cannot
    # target your pokemon) confirms real targets.
    body = Frame.crop(frame, {0, 0, frame.width - strip_px, frame.height})

    creatures = body |> Vision.hp_bar_row_positions() |> rows_of(top, band, rows)
    red = Vision.red_row_counts(body, top: top, band: band, rows: rows)

    locked_row =
      case Vision.locked_row(red, Settings.value(settings, :target_locked_min_pixels)) do
        {:ok, row} -> row
        :none -> nil
      end

    # The SHINY star (gold ★ before a shiny's name), on the region combat
    # already captures every ~120ms. The search is restricted to the NAME zone:
    # creature icons (x<=72) contain yellows that read as the star (Shuckle,
    # Vileplume — the false alarms that made Lucas turn the guard off;
    # reproduced on his real captures).
    stars =
      Vision.star_rows(body,
        top: top,
        band: band,
        rows: rows,
        min_cluster: Settings.value(settings, :shiny_star_min_columns),
        min_x: star_zone(measured)
      )

    detail = enemies_detail(body, measured, creatures, Enum.map(stars, &elem(&1, 0)))

    %{
      enemies: Enum.sort(creatures),
      enemies_detail: detail,
      red: red,
      # Per-row HP-bar green, on the SAME bands as the lock ring: how combat
      # tells a fight from a stalemate. Deliberately not `enemies_detail`'s
      # hp_pct — that one needs a located layout, and this must read with or
      # without one.
      hp: Vision.hp_row_counts(body, top: top, band: band, rows: rows),
      locked?: locked_row != nil,
      locked_row: locked_row,
      shiny_rows: Enum.map(stars, &elem(&1, 0)),
      shiny_star_run: stars |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    }
  end

  @doc """
  The skill hotbar: per-slot readiness (`:ready | :cooldown`) plus the ready hotbar keys in
  ascending slot order. Both are NIL when the frame stopped looking like the calibrated bar
  (window moved/covered) — UNKNOWN, never a guess, so consumers fail open (combat: blind
  rotation; fishing: the hold's own ceiling).
  """
  def skills(frame, calib, settings) do
    if SkillBar.valid_frame?(frame) do
      slots = SkillBar.slots_from_frame(frame, calib, settings)
      %{states: SkillBar.states(slots), ready_keys: SkillBar.ready_keys(slots)}
    else
      %{states: nil, ready_keys: nil}
    end
  end

  # The star sits right at the name's start (name at x=83 in the measured
  # profile). 20px slack: genuinely golden icons — which the color floor cannot
  # separate (measured: 976/976 px with g<=r on a real golden icon) — end at
  # x<=52, and the slack covers the whole star glyph even if it starts before
  # the name. Without a measured layout, no restriction — the predicate's color
  # floor stands alone as the defense (covers the Shuckle/Vileplume class).
  defp star_zone(%{name: {[nx, _ny], _size}}), do: max(nx - 20, 0)
  defp star_zone(_no_layout), do: 0

  # Only rows that actually hold a creature are described — an empty row has no
  # name to read and no bar to measure.
  defp enemies_detail(_body, nil, _creatures, _shiny_rows), do: []

  defp enemies_detail(body, measured, creatures, shiny_rows) do
    %{name: {[nx, ny], [nw, nh]}, bar: {[bx, by], [bw, bh]}, pitch: pitch} = measured
    lexicon = Pokex.Pokedex.names()

    for row <- Enum.sort(creatures) do
      %{
        row: row,
        name: Glyphs.read_name(body, {nx, ny + row * pitch, nw, nh}, lexicon),
        hp_pct: bar_fill(body, {bx, by + row * pitch, bw, bh}),
        shiny?: row in shiny_rows
      }
    end
  end

  # The green fill runs left to right inside a fixed track; where it stops is
  # the health. No green at all means the row has no bar to read.
  defp bar_fill(%Frame{} = frame, {x, y, w, h}) do
    greens =
      for cy <- y..(y + h - 1)//1,
          cx <- x..(x + w - 1)//1,
          cy >= 0 and cx >= 0 and cy < frame.height and cx < frame.width,
          green?(Frame.at(frame, cx, cy)),
          do: cx

    case greens do
      [] -> nil
      found -> min((Enum.max(found) - x + 1) / w, 1.0)
    end
  end

  defp green?({r, g, b}), do: g >= 90 and g > r + 30 and g > b + 30

  # Bucket frame-Ys into distinct 0-based battle rows (same math as the lock sensor).
  defp rows_of(ys, top, band, rows) do
    ys
    |> Enum.map(fn y -> max(0, min(div(y - top, band), rows - 1)) end)
    |> Enum.uniq()
  end
end
