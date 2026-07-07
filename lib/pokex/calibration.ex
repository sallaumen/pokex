defmodule Pokex.Calibration do
  @moduledoc """
  Calibrated screen geometry, persisted at ~/.pokex/calibration.json.
  All coordinates in screen POINTS. The pixel<->point conversion (Retina
  scale) lives HERE and nowhere else.
  """

  defstruct [
    :scale,
    :screen_w,
    :screen_h,
    :water_point,
    :glow_region,
    :battle_region,
    :arena_region,
    :neutral_point,
    :battle_baseline,
    :suggested_glow_threshold,
    glow_baselines: []
  ]

  @strip_width 30
  @first_row_y_offset 18

  def exists?(path \\ nil), do: File.exists?(path || Pokex.Home.calibration_file())

  def save(%__MODULE__{} = calib, path \\ nil) do
    path = path || Pokex.Home.calibration_file()
    File.mkdir_p!(Path.dirname(path))

    map = %{
      "scale" => calib.scale,
      "screen_w" => calib.screen_w,
      "screen_h" => calib.screen_h,
      "water_point" => Tuple.to_list(calib.water_point),
      "glow_region" => Tuple.to_list(calib.glow_region),
      "battle_region" => Tuple.to_list(calib.battle_region),
      "arena_region" => Tuple.to_list(calib.arena_region),
      "neutral_point" => Tuple.to_list(calib.neutral_point),
      "glow_baselines" => calib.glow_baselines,
      "battle_baseline" => calib.battle_baseline,
      "suggested_glow_threshold" => calib.suggested_glow_threshold
    }

    File.write!(path, JSON.encode!(map))
  end

  def load(path \\ nil) do
    with {:ok, bin} <- File.read(path || Pokex.Home.calibration_file()),
         {:ok, map} <- JSON.decode(bin) do
      {:ok,
       %__MODULE__{
         scale: map["scale"] / 1,
         screen_w: map["screen_w"],
         screen_h: map["screen_h"],
         water_point: to_tuple(map["water_point"]),
         glow_region: to_tuple(map["glow_region"]),
         battle_region: to_tuple(map["battle_region"]),
         arena_region: to_tuple(map["arena_region"]),
         neutral_point: to_tuple(map["neutral_point"]),
         glow_baselines: map["glow_baselines"] || [],
         battle_baseline: map["battle_baseline"],
         suggested_glow_threshold: map["suggested_glow_threshold"]
       }}
    end
  end

  def battle_strip(%__MODULE__{battle_region: region}), do: battle_strip(region)
  def battle_strip({x, y, w, h}), do: {x + w - @strip_width, y, @strip_width, h}

  @doc """
  The battle region WITHOUT the rightmost pokeball-icon column — the portraits
  and names, where the red selection border/name appear. Used for target-lock
  detection so the player's own pokeball icon isn't counted as a lock.
  """
  def battle_body(%__MODULE__{battle_region: {x, y, w, h}}), do: {x, y, w - @strip_width, h}

  def battle_first_row(%__MODULE__{battle_region: {x, y, w, _h}}),
    do: {x + div(w, 3), y + @first_row_y_offset}

  @doc "Screen point to click a battle-list row `row_y` pixels down the strip."
  def battle_row_point(%__MODULE__{battle_region: {x, y, w, _h}, scale: scale}, row_y),
    do: {x + div(w, 3), y + round(row_y / scale)}

  def frame_to_screen(%__MODULE__{scale: scale}, {rx, ry, _w, _h}, {fx, fy}),
    do: {rx + round(fx / scale), ry + round(fy / scale)}

  defp to_tuple(list), do: List.to_tuple(list)
end
