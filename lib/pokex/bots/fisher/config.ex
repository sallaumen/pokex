defmodule Pokex.Bots.Fisher.Config do
  @moduledoc "Builds the flat, frozen config map the pure Logic runs on."

  alias Pokex.Calibration

  @setting_keys [
    :rod_key,
    :skill_keys,
    :tile_size,
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
    :fight_timeout_ms,
    :max_consecutive_failures,
    :hostile_scan_every,
    :auto_capture,
    :glow_streak_needed,
    :calm_streak_needed,
    :wait_target_verify_ms,
    :target_locked_min_pixels,
    :target_lock_streak,
    :target_lost_streak,
    :humanize_max_ms
  ]

  def build(%Calibration{} = calib, settings) do
    tile = settings[:tile_size] || 32
    {wx, wy} = calib.water_point
    {fx, fy} = Calibration.battle_first_row(calib)
    row_h = settings[:battle_row_height] || 30
    max_rows = settings[:battle_max_rows] || 6

    settings
    |> Map.take(@setting_keys)
    |> Map.merge(%{
      water_point: calib.water_point,
      neutral_point: calib.neutral_point,
      battle_first_row: Calibration.battle_first_row(calib),
      battle_rows: for(i <- 0..(max_rows - 1), do: {fx, fy + i * row_h}),
      fallback_points: [
        {wx, wy},
        {wx - tile, wy},
        {wx + tile, wy},
        {wx, wy - tile},
        {wx, wy + tile}
      ]
    })
  end
end
