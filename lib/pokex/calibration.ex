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
    # Optional: the character's screen position (the mini-game bar anchor).
    # Older calibrations fall back to the arena-region center.
    :player_point,
    # Optional for backwards compatibility with calibrations created before the
    # skill bar became part of the main wizard.
    :skill_bar_region,
    :skill_bar_count,
    # Optional: per-slot READY colour references ({r,g,b} of the non-white pixels, one per
    # slot, captured from the calibration screenshot with every skill ready). When present,
    # SkillBar matches each live slot against its own reference instead of universal
    # thresholds — icons too white or too colourful for thresholds read correctly.
    :skill_slot_refs,
    # Optional (GameController): the main Pokémon's HP bar, and the portrait to aim Shift+Q at.
    :pokemon_hp_region,
    :pokemon_photo_point,
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
      "player_point" => calib.player_point && Tuple.to_list(calib.player_point),
      "skill_bar_region" => calib.skill_bar_region && Tuple.to_list(calib.skill_bar_region),
      "skill_bar_count" => calib.skill_bar_count,
      "skill_slot_refs" =>
        calib.skill_slot_refs && Enum.map(calib.skill_slot_refs, &(&1 && Tuple.to_list(&1))),
      "pokemon_hp_region" => calib.pokemon_hp_region && Tuple.to_list(calib.pokemon_hp_region),
      "pokemon_photo_point" =>
        calib.pokemon_photo_point && Tuple.to_list(calib.pokemon_photo_point),
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
         player_point: to_tuple(map["player_point"]),
         skill_bar_region: to_tuple(map["skill_bar_region"]),
         skill_bar_count: map["skill_bar_count"],
         skill_slot_refs: map["skill_slot_refs"] && Enum.map(map["skill_slot_refs"], &to_tuple/1),
         pokemon_hp_region: to_tuple(map["pokemon_hp_region"]),
         pokemon_photo_point: to_tuple(map["pokemon_photo_point"]),
         glow_baselines: map["glow_baselines"] || [],
         battle_baseline: map["battle_baseline"],
         suggested_glow_threshold: map["suggested_glow_threshold"]
       }}
    end
  end

  def battle_strip(%__MODULE__{battle_region: region}), do: battle_strip(region)
  def battle_strip({x, y, w, h}), do: {x + w - @strip_width, y, @strip_width, h}

  @doc """
  A wider fishing read around the calibrated bait point.

  The 64x64 `glow_region` is still the precise calibration mark, but the live
  SCK reader can safely sample a larger water patch: the cyan predicate rejects
  normal blue water, and the extra margin absorbs quick-cast landing drift or a
  slightly-off calibration click.
  """
  def glow_search_region(%__MODULE__{glow_region: region} = calib, margin) do
    grow_region(region, margin, calib.screen_w, calib.screen_h)
  end

  @doc "Width (POINTS) of the rightmost pokeball-icon strip cropped off the battle body."
  def strip_width, do: @strip_width

  @doc """
  The battle region WITHOUT the rightmost pokeball-icon column — the portraits
  and names, where the red selection border/name appear. Used for target-lock
  detection so the player's own pokeball icon isn't counted as a lock.
  """
  def battle_body(%__MODULE__{battle_region: region}), do: battle_body(region)
  def battle_body({x, y, w, h}), do: {x, y, w - @strip_width, h}

  @doc """
  The player's screen position: the calibrated point when one was marked (the
  character can stand anywhere in the viewport), else the arena-region center.
  The mini-game overlay bar is anchored here.
  """
  def player_point(%__MODULE__{player_point: point}) when is_tuple(point), do: point
  def player_point(%__MODULE__{arena_region: region}), do: player_point(region)
  def player_point({x, y, w, h}), do: {x + div(w, 2), y + div(h, 2)}

  # Measured on Lucas's 3440×1440 screen (2026-07-10): the main Pokémon is the TOP of the 6 party
  # slots at the game's bottom-left — a green→yellow→red HP bar and the "Q" portrait beside it.
  # These estimates let the GameController run before the field is calibrated; set the real region
  # in the calibration UI to fine-tune per screen.
  @default_pokemon_hp_region {134, 921, 230, 18}
  @default_pokemon_photo_point {70, 934}

  @doc "The main Pokémon's HP bar region (calibrated, else a measured estimate)."
  def pokemon_hp_region(%__MODULE__{pokemon_hp_region: region}) when is_tuple(region), do: region
  def pokemon_hp_region(_calib), do: @default_pokemon_hp_region

  @doc "Screen point of the main Pokémon's portrait — where the mouse goes for the Shift+Q revive."
  def pokemon_photo_point(%__MODULE__{pokemon_photo_point: point}) when is_tuple(point), do: point
  def pokemon_photo_point(_calib), do: @default_pokemon_photo_point

  def battle_first_row(%__MODULE__{battle_region: {x, y, w, _h}}),
    do: {x + div(w, 3), y + @first_row_y_offset}

  @doc "Frame-px offset from the battle region's top to the first row — the band origin for per-row lock reads."
  def first_row_offset, do: @first_row_y_offset

  @doc """
  Frame-pixel geometry of the per-row lock bands: `{top, band}` where band 0
  begins at `top` and each band is `band` px tall. The band is CENTERED on the
  row's click point (shifted up ½ band) because the selection ring is drawn
  AROUND the click, not below it — a band starting at the click would split the
  ring across two rows and under-read the locked one (measured: 231px vs 857px
  once centered). Single source of truth for the lock sensor, the /diagnostics
  read, AND the visual preview — so the red boxes drawn over the screenshot land
  exactly where the bot samples.
  """
  def row_band_geometry(scale, row_height) do
    band = max(round(row_height * scale), 1)
    top = round(@first_row_y_offset * scale) - div(band, 2)
    {top, band}
  end

  @doc """
  Screen-POINT rectangles — one per battle row — covering the exact bands the
  lock sensor reads, for the visual calibration preview. Derived from
  `row_band_geometry/2` and `battle_body/1`, so the red overlay can never drift
  from what the bot actually looks at; if the boxes miss the battle-list rows,
  the calibration is off. Accepts a saved `%Calibration{}` or a raw
  `battle_region` tuple + scale (to preview a draft mid-calibration).
  """
  def battle_row_bands(%__MODULE__{scale: scale, battle_region: region}, row_height, rows),
    do: battle_row_bands(region, scale, row_height, rows)

  def battle_row_bands(region, scale, row_height, rows) when is_tuple(region) do
    {bx, by, bw, _bh} = battle_body(region)
    {top, band} = row_band_geometry(scale, row_height)

    for i <- 0..(rows - 1)//1 do
      {bx, by + (top + i * band) / scale, bw, band / scale}
    end
  end

  @doc "Screen point to click a battle-list row `row_y` pixels down the strip."
  def battle_row_point(%__MODULE__{battle_region: {x, y, w, _h}, scale: scale}, row_y),
    do: {x + div(w, 3), y + round(row_y / scale)}

  def frame_to_screen(%__MODULE__{scale: scale}, {rx, ry, _w, _h}, {fx, fy}),
    do: {rx + round(fx / scale), ry + round(fy / scale)}

  defp grow_region({x, y, w, h}, margin, screen_w, screen_h) do
    margin = if is_number(margin), do: max(round(margin), 0), else: 0

    left = max(x - margin, 0)
    top = max(y - margin, 0)
    right = min_edge(x + w + margin, screen_w)
    bottom = min_edge(y + h + margin, screen_h)

    {left, top, max(right - left, 1), max(bottom - top, 1)}
  end

  defp min_edge(value, nil), do: value
  defp min_edge(value, limit), do: min(value, limit)

  defp to_tuple(nil), do: nil
  defp to_tuple(list), do: List.to_tuple(list)
end
