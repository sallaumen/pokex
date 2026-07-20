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

    body = Frame.crop(frame, {0, 0, frame.width - strip_px, frame.height})
    strip = Frame.crop(frame, {frame.width - strip_px, 0, strip_px, frame.height})

    creatures = body |> Vision.hp_bar_row_positions() |> rows_of(top, band, rows)

    own =
      strip
      |> Vision.pokeball_row_positions(min_count: Settings.value(settings, :pokeball_min_red_px))
      |> rows_of(top, band, rows)

    red = Vision.red_row_counts(body, top: top, band: band, rows: rows)

    locked_row =
      case Vision.locked_row(red, Settings.value(settings, :target_locked_min_pixels)) do
        {:ok, row} -> row
        :none -> nil
      end

    %{
      enemies: Enum.sort(creatures -- own),
      red: red,
      locked?: locked_row != nil,
      locked_row: locked_row
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

  @doc "The arena: the hostile's floating-name point in SCREEN coordinates, or nil."
  def arena(frame, calib, _settings) do
    case Vision.find_hostile(frame) do
      {:ok, pixel} -> %{hostile: Calibration.frame_to_screen(calib, calib.arena_region, pixel)}
      :not_found -> %{hostile: nil}
    end
  end

  # Bucket frame-Ys into distinct 0-based battle rows (same math as the lock sensor).
  defp rows_of(ys, top, band, rows) do
    ys
    |> Enum.map(fn y -> max(0, min(div(y - top, band), rows - 1)) end)
    |> Enum.uniq()
  end
end
