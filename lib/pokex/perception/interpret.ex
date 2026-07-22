defmodule Pokex.Perception.Interpret do
  @moduledoc """
  Pure frame → observation interpreters, one per feed. Ported from the combat half of
  `Fisher.Sensors.Real` (which stays untouched for fishing until phase 2): same slicing,
  same row-band geometry, same thresholds — the ONLY addition is the lock verdict
  (locked?/locked_row), computed here once so every consumer shares one interpretation.
  """

  alias Pokex.Bots.SkillBar
  alias Pokex.{Calibration, Settings, Vision}
  alias Pokex.Vision.Frame

  @doc """
  The battle panel: candidate enemy rows (HP bar, no own-pokemon pokeball), per-row
  lock-ring red counts, and whether/where the lock ring is up.
  """
  def battle(frame, calib, settings) do
    {top, band} =
      Calibration.row_band_geometry(calib.scale, Settings.value(settings, :battle_row_height))

    rows = Settings.value(settings, :battle_max_rows)
    strip_px = round(Calibration.strip_width() * calib.scale)

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

    # The SHINY star (gold ★ before a shiny's name) — the game telling us
    # outright, on the region combat already captures every ~120ms.
    stars =
      Vision.star_rows(body,
        top: top,
        band: band,
        rows: rows,
        min_cluster: Settings.value(settings, :shiny_star_min_columns)
      )

    %{
      enemies: Enum.sort(creatures),
      red: red,
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

  # Bucket frame-Ys into distinct 0-based battle rows (same math as the lock sensor).
  defp rows_of(ys, top, band, rows) do
    ys
    |> Enum.map(fn y -> max(0, min(div(y - top, band), rows - 1)) end)
    |> Enum.uniq()
  end
end
