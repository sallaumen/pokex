defmodule Pokex.Bots.Fisher.Config do
  @moduledoc "Builds the flat, frozen config map the pure Logic runs on."

  alias Pokex.Calibration

  @setting_keys [
    :skill_keys,
    :tile_size,
    :tick_ms_watching,
    :tick_ms_fighting,
    :tick_ms_default,
    :wait_focus_ms,
    :wait_after_equip_ms,
    :wait_assess_ms,
    :wait_loot_ms,
    :wait_after_capture_ms,
    :watch_timeout_ms,
    :fight_timeout_ms,
    :max_consecutive_failures,
    :hostile_scan_every,
    :auto_capture,
    :glow_streak_needed
  ]

  def build(%Calibration{} = calib, settings) do
    tile = settings[:tile_size]
    {wx, wy} = calib.water_point

    settings
    |> Map.take(@setting_keys)
    |> Map.merge(%{
      water_point: calib.water_point,
      neutral_point: calib.neutral_point,
      battle_first_row: Calibration.battle_first_row(calib),
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
