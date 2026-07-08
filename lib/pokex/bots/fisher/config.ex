defmodule Pokex.Bots.Fisher.Config do
  @moduledoc "Builds the flat, frozen config map the pure Logic runs on."

  alias Pokex.Calibration

  @setting_keys [
    :rod_key,
    :skill_keys,
    :tick_ms_watching,
    :tick_ms_fighting,
    :tick_ms_default,
    :wait_focus_ms,
    :wait_after_equip_ms,
    :wait_cast_settle_ms,
    :wait_assess_ms,
    :wait_loot_ms,
    :wait_after_capture_ms,
    :watch_timeout_ms,
    :watch_dead_streak_needed,
    :fight_timeout_ms,
    :max_consecutive_failures,
    :hostile_scan_every,
    :auto_capture,
    :glow_streak_needed,
    :calm_streak_needed,
    :require_cooldowns,
    :target_locked_min_pixels,
    :target_lost_streak,
    :battle_confirm_ms,
    :tile_px,
    :walk_step_ms,
    :loot_presses,
    :max_walk_tiles,
    :capture_aim_up_px,
    :capture_aim_left_px,
    :humanize_max_ms,
    :cast_delay_max_ms,
    :hook_delay_min_ms,
    :hook_delay_max_ms
  ]

  def build(%Calibration{} = calib, settings) do
    {fx, fy} = Calibration.battle_first_row(calib)
    row_h = settings[:battle_row_height] || 30
    max_rows = settings[:battle_max_rows] || 6

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
