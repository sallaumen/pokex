defmodule Pokex.Bots.Fisher.Config do
  @moduledoc "Builds the flat, frozen config map the pure Logic runs on."

  alias Pokex.{Calibration, Settings}

  @setting_keys [
    :rod_key,
    :skill_keys,
    :combat_skill_burst_size,
    :combat_skill_tap_count,
    :combat_skill_gap_ms,
    :combat_skill_jitter_ms,
    :tick_ms_watching,
    :tick_ms_default,
    :wait_focus_ms,
    :wait_after_equip_ms,
    :wait_cast_settle_ms,
    :wait_assess_ms,
    :watch_timeout_ms,
    :watch_dead_streak_needed,
    :dry_casts_alarm,
    :fight_timeout_ms,
    :max_consecutive_failures,
    :glow_streak_needed,
    :calm_streak_needed,
    :require_cooldowns,
    :hook_hold_max_ms,
    :target_locked_min_pixels,
    :target_lost_streak,
    :tile_px,
    :humanize_max_ms,
    :cast_delay_max_ms,
    :hook_delay_min_ms,
    :hook_delay_max_ms
  ]

  def build(%Calibration{} = calib, settings) do
    {fx, fy} = Calibration.battle_first_row(calib)
    row_h = Settings.value(settings, :battle_row_height)
    max_rows = Settings.value(settings, :battle_max_rows)

    settings
    |> Map.take(@setting_keys)
    |> Map.merge(%{
      water_point: calib.water_point,
      neutral_point: calib.neutral_point,
      player_point: Calibration.player_point(calib),
      battle_first_row: Calibration.battle_first_row(calib),
      battle_rows: for(i <- 0..(max_rows - 1), do: {fx, fy + i * row_h})
    })
  end
end
