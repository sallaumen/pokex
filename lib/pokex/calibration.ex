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
    :neutral_point,
    # The character's screen position: the anchor EVERYTHING about the world
    # hangs off — the corpse search square, the mini-game box, the reposition.
    # Unmarked, the centre of the screen.
    :player_point,
    # Optional: a DEDICATED strip where the mini-game bar appears (marked from
    # the fishing spot the player always uses). When set, the mini-game worker
    # watches ONLY this region and searches all of it. Without it, the box is
    # derived from the character.
    :mini_game_region,
    # HAND-MARKED position & minimap (2026-07-30): the map rectangle, the
    # character's FIXED cross (the map slides under it) and the textual
    # coordinate strip. Auto-layout regions are anchored and die when the game
    # window moves — the drift class that took the cavebot down. Manual wins;
    # layout becomes the fallback (resolvers minimap_*_region/1 and
    # minimap_player_point/1 below).
    :minimap_region,
    :minimap_player_point,
    :minimap_coord_region,
    # Optional: where the active Pokémon should STAND (the strategic attack tile).
    # PlayerSupport middle-clicks this point after battles to send it back there.
    :pokemon_spot_point,
    # Optional: the escape STAIRCASE tile — the emergency-escape protocol
    # left-clicks here (click-to-walk) to flee danger (e.g. a shiny).
    :escape_point,
    # Optional for backwards compatibility with calibrations created before the
    # skill bar became part of the main wizard.
    :skill_bar_region,
    :skill_bar_count,
    # The auto-located HUD layout (Pokex.Layout.Fix) in force for this load.
    # Resolved ONCE here so a feed's capture region and its interpreter's
    # offsets always come from the same fix — a re-locate between the two
    # would otherwise silently shift every reading.
    :layout,
    # Optional: per-slot READY colour references ({r,g,b} of the non-white pixels, one per
    # slot, captured from the calibration screenshot with every skill ready). When present,
    # SkillBar matches each live slot against its own reference instead of universal
    # thresholds — icons too white or too colourful for thresholds read correctly.
    :skill_slot_refs,
    # Optional (PlayerSupport): the main Pokémon's HP bar, and the portrait to aim Shift+Q at.
    :pokemon_hp_region,
    :pokemon_photo_point
  ]

  @typedoc "A loaded calibration. Two specs already referenced this type before it existed."
  @type t :: %__MODULE__{}

  @strip_width 30
  @first_row_y_offset 18

  def exists?(path \\ nil), do: File.exists?(path || Pokex.Home.calibration_file())

  @doc "The active calibration file's mtime (unix seconds), or nil when absent."
  def mtime(path \\ nil) do
    case File.stat(path || Pokex.Home.calibration_file(), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _absent -> nil
    end
  end

  @doc """
  Where the fishing mini-game bar is, resolved.

  The HAND wins. The auto-layout "fixed" strip was an ABSOLUTE screen
  coordinate ({3067, 800, ...}, glued to the battle list) — proven stable when
  the game's PANELS moved, but the proof assumed the WINDOW never moved. On
  2026-07-30 it did (same root as the minimap at y=-132): the strip pointed at
  the wrong place and still silently VETOED the manual calibration. Inverted:
  the hand-marked value always wins; without it, a box around the CHARACTER —
  the bar appears over him. The worker searches whatever it gets; marking the
  strip is what makes the search cheap and accurate.
  """
  def mini_game_region(%__MODULE__{} = calib) do
    manual_mini_game_region(calib) || centered_mini_game_region(calib)
  end

  defp manual_mini_game_region(%__MODULE__{mini_game_region: region}) when is_tuple(region),
    do: region

  defp manual_mini_game_region(_no_mark), do: nil

  # A BOX AROUND THE CHARACTER — the mini-game bar appears over him, so he is
  # the anchor. This used to be the middle of the calibrated "arena", which drew
  # a second rectangle inside a rectangle and asked for two clicks that taught
  # the bot nothing (2026-08-03: "a área do minigame está duplicada").
  #
  # Sized in TILES, from his own six hand-marked strips: every one of them sits
  # within 2 tiles either side of the character and runs from 1 tile above him
  # to 7 below. Three tiles of margin each way covers them all. Half the screen
  # — the previous default — searched 25% of the display and drew a rectangle
  # nobody recognised as the mini-game ("aquela área grandona").
  @mini_game_tiles_side 3
  @mini_game_tiles_above 3
  @mini_game_tiles_below 7

  defp centered_mini_game_region(%__MODULE__{screen_w: w, screen_h: h} = calib)
       when is_integer(w) and is_integer(h) do
    {cx, cy} = player_point(calib)
    tile = max(Pokex.Settings.get(:tile_px), 1)

    bw = min(2 * @mini_game_tiles_side * tile, w)
    bh = min((@mini_game_tiles_above + @mini_game_tiles_below) * tile, h)

    {clamp(cx - @mini_game_tiles_side * tile, 0, w - bw),
     clamp(cy - @mini_game_tiles_above * tile, 0, h - bh), bw, bh}
  end

  defp centered_mini_game_region(_uncalibrated), do: nil

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc """
  Where the MINIMAP is, resolved — the HAND wins, auto-layout is the fallback
  (same inversion as the mini-game): layout regions are anchored on
  `battle_header` and die when the game window moves — exactly the drift class
  that blinded the cavebot (2026-07-30).
  """
  def minimap_region(%__MODULE__{minimap_region: region}) when is_tuple(region), do: region
  def minimap_region(%__MODULE__{layout: fix}), do: Pokex.Layout.region(:minimap, fix)

  @doc "The textual \"(x, y, z)\" coordinate strip, resolved — hand > layout."
  def minimap_coord_region(%__MODULE__{minimap_coord_region: region}) when is_tuple(region),
    do: region

  def minimap_coord_region(%__MODULE__{layout: fix}),
    do: Pokex.Layout.region(:minimap_coord, fix)

  @doc """
  The map's CLICKABLE rectangle (where the cavebot step lands): with a manual
  mark it is `minimap_region` itself — the map proper is what gets marked;
  without one, the layout's `:minimap_map`, as always.
  """
  def minimap_map_region(%__MODULE__{minimap_region: region}) when is_tuple(region), do: region
  def minimap_map_region(%__MODULE__{layout: fix}), do: Pokex.Layout.region(:minimap_map, fix)

  @doc """
  The character's cross on the minimap — FIXED in the window, the map slides
  under it (2026-07-30). Unmarked, the map rectangle's center: what the step
  always assumed, now as fallback instead of dogma.
  """
  def minimap_player_point(%__MODULE__{minimap_player_point: point}) when is_tuple(point),
    do: point

  def minimap_player_point(%__MODULE__{} = calib) do
    case minimap_map_region(calib) do
      {x, y, w, h} -> {x + div(w, 2), y + div(h, 2)}
      nil -> nil
    end
  end

  def save(%__MODULE__{} = calib, path \\ nil) do
    path = path || Pokex.Home.calibration_file()
    File.mkdir_p!(Path.dirname(path))

    map = %{
      "scale" => calib.scale,
      "screen_w" => calib.screen_w,
      "screen_h" => calib.screen_h,
      "water_point" => to_list(calib.water_point),
      "glow_region" => to_list(calib.glow_region),
      "battle_region" => to_list(calib.battle_region),
      "neutral_point" => to_list(calib.neutral_point),
      "player_point" => to_list(calib.player_point),
      "mini_game_region" => to_list(calib.mini_game_region),
      "minimap_region" => to_list(calib.minimap_region),
      "minimap_player_point" => to_list(calib.minimap_player_point),
      "minimap_coord_region" => to_list(calib.minimap_coord_region),
      "pokemon_spot_point" => to_list(calib.pokemon_spot_point),
      "escape_point" => to_list(calib.escape_point),
      "skill_bar_region" => to_list(calib.skill_bar_region),
      "skill_bar_count" => calib.skill_bar_count,
      "skill_slot_refs" => calib.skill_slot_refs && Enum.map(calib.skill_slot_refs, &to_list/1),
      "pokemon_hp_region" => to_list(calib.pokemon_hp_region),
      "pokemon_photo_point" => to_list(calib.pokemon_photo_point)
    }

    File.write!(path, JSON.encode!(map))
  end

  # JSON has no tuples, and an unmarked field stays nil rather than becoming [].
  defp to_list(nil), do: nil
  defp to_list(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)

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
         neutral_point: to_tuple(map["neutral_point"]),
         player_point: to_tuple(map["player_point"]),
         mini_game_region: to_tuple(map["mini_game_region"]),
         minimap_region: to_tuple(map["minimap_region"]),
         minimap_player_point: to_tuple(map["minimap_player_point"]),
         minimap_coord_region: to_tuple(map["minimap_coord_region"]),
         pokemon_spot_point: to_tuple(map["pokemon_spot_point"]),
         escape_point: to_tuple(map["escape_point"]),
         skill_bar_region: to_tuple(map["skill_bar_region"]),
         skill_bar_count: map["skill_bar_count"],
         skill_slot_refs: map["skill_slot_refs"] && Enum.map(map["skill_slot_refs"], &to_tuple/1),
         # A layout located on ANOTHER screen is worse than none: its regions
         # land outside the frame, the captures quarantine, and every consumer
         # goes blind while looking calibrated. Geometry decides.
         layout: Pokex.Layout.current() |> Pokex.Layout.fitting(map["screen_w"], map["screen_h"]),
         pokemon_hp_region: to_tuple(map["pokemon_hp_region"]),
         pokemon_photo_point: to_tuple(map["pokemon_photo_point"])
       }}
    end
  end

  # Named snapshots of a whole calibration (~/.pokex/calibrations/<slug>.json):
  # one per monitor layout, so plugging the second monitor back in is a one-click
  # switch instead of a full wizard redo.

  @doc "Saves the CURRENT calibration under `name`. {:ok, slug} | {:error, reason}."
  def save_profile(name) do
    with {:ok, slug} <- profile_slug(name),
         {:ok, calib} <- load() do
      File.mkdir_p!(profiles_dir())
      save(calib, profile_path(slug))
      {:ok, slug}
    end
  end

  @doc "Makes the named profile the ACTIVE calibration. {:ok, calib} | {:error, reason}."
  def apply_profile(name) do
    with {:ok, slug} <- profile_slug(name),
         {:ok, calib} <- load(profile_path(slug)) do
      save(calib)
      {:ok, calib}
    end
  end

  def delete_profile(name) do
    with {:ok, slug} <- profile_slug(name) do
      File.rm(profile_path(slug))
      :ok
    end
  end

  @doc "Every saved profile: name, screen dims/scale and saved-at (unix seconds)."
  def list_profiles do
    case File.ls(profiles_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.map(&profile_entry/1)

      {:error, _no_dir_yet} ->
        []
    end
  end

  defp profile_entry(file) do
    slug = String.trim_trailing(file, ".json")
    path = profile_path(slug)

    dims =
      case load(path) do
        {:ok, calib} -> %{screen_w: calib.screen_w, screen_h: calib.screen_h, scale: calib.scale}
        _corrupt -> %{screen_w: nil, screen_h: nil, scale: nil}
      end

    saved_at =
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} -> mtime
        _stat_error -> nil
      end

    Map.merge(%{name: slug, saved_at: saved_at}, dims)
  end

  defp profiles_dir, do: Path.join(Pokex.Home.dir(), "calibrations")
  defp profile_path(slug), do: Path.join(profiles_dir(), slug <> ".json")

  defp profile_slug(name) do
    slug =
      name
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/u, "-")
      |> String.trim("-")

    if slug == "", do: {:error, :invalid_name}, else: {:ok, slug}
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
  The player's screen position: the calibrated point when one was marked, else
  the CENTRE OF THE SCREEN — where an MMO keeps the character. The old fallback
  was the centre of the calibrated arena, which sat 268px above the real
  character on his screen (the same measurement that made SpotScan drop the
  arena). Everything the character anchors hangs off this.
  """
  def player_point(%__MODULE__{player_point: point}) when is_tuple(point), do: point

  def player_point(%__MODULE__{screen_w: w, screen_h: h})
      when is_integer(w) and is_integer(h),
      do: {div(w, 2), div(h, 2)}

  def player_point(%__MODULE__{}), do: nil
  def player_point({x, y, w, h}), do: {x + div(w, 2), y + div(h, 2)}

  @doc """
  How the saved calibration relates to the display in front of him NOW:
  `:same`, `:unknown` (nothing to compare), `{:another_screen, saved, current}`
  or `{:rescalable, saved, current}`.

  The same SHAPE at a different size cannot be a different monitor — it is one
  screenshot divided by two different rulers. On 2026-08-04 the wizard divided a
  3440×1440 screenshot by the window server's union of two displays and recorded
  4952×2073: every point 1.44× off, and the fishing rod landed on dry rock. That
  case is exactly repairable (see `rescale/2`); a different shape is not.
  """
  def screen_check(%__MODULE__{screen_w: w, screen_h: h}, {:ok, {cw, ch}})
      when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    cond do
      {w, h} == {cw, ch} -> :same
      same_shape?({w, h}, {cw, ch}) -> {:rescalable, {w, h}, {cw, ch}}
      true -> {:another_screen, {w, h}, {cw, ch}}
    end
  end

  def screen_check(_calib, _unmeasurable), do: :unknown

  # Scaling the saved screen onto the current one must land on its height (the
  # derived side is a rounded division, so ±1 point).
  defp same_shape?({w, h}, {cw, ch}), do: abs(round(h * cw / w) - ch) <= 1

  @geometry ~w(water_point glow_region battle_region neutral_point player_point
               mini_game_region minimap_region minimap_player_point minimap_coord_region
               pokemon_spot_point escape_point skill_bar_region pokemon_hp_region
               pokemon_photo_point)a

  @doc """
  Re-expresses every marked point in the coordinates of a `{w, h}` screen.

  Only meaningful for `{:rescalable, _, _}`: the clicks were right, the ruler
  was not, so `current_w / saved_w` puts them back where he clicked. Colours
  (`skill_slot_refs`) and counts carry no geometry and are left alone.
  """
  def rescale(%__MODULE__{screen_w: w, scale: scale} = calib, {cw, ch})
      when is_integer(w) and w > 0 do
    ratio = cw / w
    rescaled = %{calib | screen_w: cw, screen_h: ch, scale: scale && scale / ratio}

    Enum.reduce(@geometry, rescaled, fn key, acc ->
      Map.update!(acc, key, &scaled(&1, ratio))
    end)
  end

  defp scaled({x, y}, ratio), do: {round(x * ratio), round(y * ratio)}

  defp scaled({x, y, w, h}, ratio),
    do: {round(x * ratio), round(y * ratio), round(w * ratio), round(h * ratio)}

  defp scaled(_unmarked, _ratio), do: nil

  # Measured on Lucas's 3440×1440 screen (2026-07-10): the main Pokémon is the TOP of the 6 party
  # slots at the game's bottom-left — a green→yellow→red HP bar and the "Q" portrait beside it.
  # These estimates let the PlayerSupport run before the field is calibrated; set the real region
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
