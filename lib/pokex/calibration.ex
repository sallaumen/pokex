defmodule Pokex.Calibration do
  @moduledoc """
  Calibrated screen geometry, persisted at ~/.pokex/calibration.json.
  All coordinates in screen POINTS. The pixel<->point conversion (Retina
  scale) lives HERE and nowhere else.
  """

  require Logger

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
    # DERIVED from the character and the skill bar — see mini_game_region/1.
    :mini_game_region,
    # HAND-MARKED position & minimap (2026-07-30): the map rectangle, the character's FIXED
    # cross (the map slides under it) and the textual coordinate strip.
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
    :pokemon_photo_point,
    # Optional: a barra VERMELHA do painel "Pokémon" — que é a vida do PERSONAGEM, não do
    # pokémon (medido 26/08; o nome do painel é a armadilha).
    :player_hp_region
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
  the hand-marked value always wins; without it, the strip is DERIVED from the
  CHARACTER, which is where the game draws the bar — one anchor, already
  calibrated, moving with the HUD, so a resolution change re-derives by itself.
  """
  # The hand mark always wins; otherwise the strip is DERIVED from the CHARACTER — the one
  # anchor the game itself draws the bar over.
  def mini_game_region(%__MODULE__{mini_game_region: region}) when is_tuple(region), do: region
  def mini_game_region(%__MODULE__{} = calib), do: derived_mini_game_region(calib)

  @doc """
  The strip the anchors SUGGEST, ignoring any hand mark — what the calibration
  page draws on the screenshot so he can accept it with one click instead of
  clicking two corners (his ask, 2026-08-10: "quando for pra calibrar ele ter
  essa sugestão, mostrando como ficaria na tela").
  """
  def derived_mini_game_region(%__MODULE__{player_point: {px, py}}) do
    width = max(Pokex.Settings.get(:mini_game_bar_width_px), 1)
    centre = px + Pokex.Settings.get(:mini_game_bar_offset_px)
    top = max(py - Pokex.Settings.get(:mini_game_above_px), 0)
    height = max(Pokex.Settings.get(:mini_game_strip_height_px), 1)

    {centre - div(width, 2), top, width, height}
  end

  # The MARKED character, never `player_point/1`'s screen-centre fallback: a strip hung off a
  # guessed anchor is guess number three, and the first two both failed
  def derived_mini_game_region(%__MODULE__{}), do: nil

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
  What the `:minimap` feed must CAPTURE: the union of the map and the coord
  band. The feed used to capture `minimap_region` alone, and a hand-marked band
  poking outside it (the real 2026-08-10 case: band 2pt above the map's top
  edge) was silently decapitated before the reader saw a pixel. The reader
  subtracts this same origin, so band and capture can never disagree.
  """
  def minimap_capture_region(%__MODULE__{} = calib),
    do: region_union(minimap_region(calib), minimap_coord_region(calib))

  defp region_union(nil, band), do: band
  defp region_union(map, nil), do: map

  defp region_union({x1, y1, w1, h1}, {x2, y2, w2, h2}) do
    x = min(x1, x2)
    y = min(y1, y2)
    {x, y, max(x1 + w1, x2 + w2) - x, max(y1 + h1, y2 + h2) - y}
  end

  @doc """
  The character's cross on the minimap — FIXED in the window, the map slides
  under it (2026-07-30). Unmarked, the map rectangle's center: what the step
  always assumed, now as fallback instead of dogma.

  A STRAY mark is refused: the real 2026-08-10 calibration carried a cross at
  {3171, 3} — the macOS menu bar — and `minimap_step` clamps every walk from
  such a start into the map's corner, a permanent north-west drift no screen
  ever explained. Refusing means the healthy center fallback walks; the review
  shows the refusal via `minimap_stray_cross/1`.
  """
  def minimap_player_point(%__MODULE__{minimap_player_point: point} = calib)
      when is_tuple(point) do
    if minimap_stray_cross(calib), do: map_center(calib), else: point
  end

  def minimap_player_point(%__MODULE__{} = calib), do: map_center(calib)

  @doc """
  The hand-marked cross when it is NOT plausible — outside the map's clickable
  rectangle — or nil. With no map region to judge against, the mark stands: a
  region-less calibration cannot walk anyway.
  """
  def minimap_stray_cross(%__MODULE__{minimap_player_point: {px, py} = point} = calib) do
    case minimap_map_region(calib) do
      {x, y, w, h} when px >= x and px < x + w and py >= y and py < y + h -> nil
      nil -> nil
      _outside -> point
    end
  end

  def minimap_stray_cross(_calib), do: nil

  defp map_center(calib) do
    case minimap_map_region(calib) do
      {x, y, w, h} -> {x + div(w, 2), y + div(h, 2)}
      nil -> nil
    end
  end

  def save(%__MODULE__{} = calib, path \\ nil) do
    # Saving the ACTIVE calibration also snapshots it under this monitor's key (see
    # snapshot_for_screen/1).
    if is_nil(path), do: snapshot_for_screen(calib)
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
      "player_hp_region" => to_list(calib.player_hp_region),
      "pokemon_photo_point" => to_list(calib.pokemon_photo_point)
    }

    Pokex.Home.write!(path, JSON.encode!(map))
  end

  # JSON has no tuples, and an unmarked field stays nil rather than becoming [].
  defp to_list(nil), do: nil
  defp to_list(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)

  def load(path \\ nil) do
    with {:ok, bin} <- File.read(path || Pokex.Home.calibration_file()),
         {:ok, map} <- JSON.decode(bin) do
      {:ok, from_map(map)}
    end
  catch
    # This answers {:ok, t} | {:error, reason}, and every caller is written to that contract —
    # including the always-on support monitor, which reloads the calibration EVERY TICK (120ms).
    kind, reason -> {:error, {:calibracao_ilegivel, {kind, reason}}}
  end

  defp from_map(map) do
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
      layout: layout_in_force(map["screen_w"], map["screen_h"]),
      pokemon_hp_region: to_tuple(map["pokemon_hp_region"]),
      player_hp_region: to_tuple(map["player_hp_region"]),
      pokemon_photo_point: to_tuple(map["pokemon_photo_point"])
    }
  end

  # A layout located on ANOTHER screen is worse than none: its regions land outside the frame,
  # the captures quarantine, and every consumer goes blind while looking calibrated.
  defp layout_in_force(screen_w, screen_h) do
    case Pokex.Layout.current() do
      nil -> nil
      fix -> Pokex.Layout.fitting(fix, screen_w, screen_h)
    end
  catch
    kind, reason ->
      Logger.warning(
        "layout ignorado nesta leitura da calibração (#{inspect({kind, reason})}) — " <>
          "as marcações à mão seguem valendo"
      )

      nil
  end

  # Named snapshots of a whole calibration (~/.pokex/calibrations/<slug>.json):
  # one per monitor layout, so plugging the second monitor back in is a one-click
  # switch instead of a full wizard redo.

  @doc """
  Saves the CURRENT calibration under `name`, WITH the numbers that belong to
  this screen. `{:ok, slug}` | `{:error, reason}`.

  The regions alone were never enough: every threshold and box size is measured
  in pixels of ONE screen (see `Pokex.ScreenScale`), so a profile that restored
  only the marks brought back a calibration the numbers no longer fitted. They
  ride in a sidecar file rather than inside the calibration JSON because they
  are Settings, not calibration — and because an older profile without one must
  keep applying cleanly.
  """
  def save_profile(name) do
    with {:ok, slug} <- profile_slug(name),
         {:ok, calib} <- load() do
      File.mkdir_p!(profiles_dir())
      save(calib, profile_path(slug))
      write_profile_settings(slug, calib)
      {:ok, slug}
    end
  end

  @doc """
  Makes the named profile the ACTIVE calibration, and puts back the numbers it
  was saved with. `{:ok, calib, settings_applied}` | `{:error, reason}`.

  `settings_applied` is 0 for a profile saved before they were carried — the
  marks still land, and the count is what tells him the numbers did not.
  """
  def apply_profile(name) do
    with {:ok, slug} <- profile_slug(name),
         {:ok, calib} <- load(profile_path(slug)) do
      applied = apply_profile_settings(slug)
      save(calib)
      {:ok, calib, applied}
    end
  end

  def delete_profile(name) do
    with {:ok, slug} <- profile_slug(name) do
      File.rm(profile_path(slug))
      File.rm(profile_settings_path(slug))
      :ok
    end
  end

  @doc "The screen-dependent numbers stored with `slug`, as a map (empty when there are none)."
  def profile_settings(slug) do
    with {:ok, raw} <- File.read(profile_settings_path(slug)),
         {:ok, decoded} <- Jason.decode(raw) do
      Map.new(decoded, fn {key, value} -> {String.to_existing_atom(key), value} end)
    else
      _none -> %{}
    end
  rescue
    # a hand-edited file naming a key this build does not have
    ArgumentError -> %{}
  end

  # THE SEED SCREEN KEEPS NO SIDECAR.
  defp write_profile_settings(slug, calib) do
    if Pokex.ScreenScale.reference_screen?(calib) do
      File.rm(profile_settings_path(slug))
      :ok
    else
      %{linear: linear, area: area} = Pokex.ScreenScale.keys()
      values = Map.new(linear ++ area, &{&1, Pokex.Settings.get(&1)})
      File.write(profile_settings_path(slug), Jason.encode!(values))
    end
  end

  defp apply_profile_settings(slug) do
    slug
    |> profile_settings()
    |> Enum.count(fn {key, value} -> Pokex.Settings.put(key, value) == :ok end)
  end

  defp profile_settings_path(slug), do: Path.join(profiles_dir(), slug <> ".settings.json")

  # --- one calibration per MONITOR (Lucas, 2026-08-07) -------------------------
  # "A calibração não tem que se adaptar automaticamente, ficar fazendo essas
  # multiplicações... tem que ser uma calibração por monitor." The monitor's
  # size IS the key: every save of the active calibration refreshes this
  # monitor's snapshot (marks + the screen-dependent settings), and coming back
  # to a monitor offers its LAST calibration back — no arithmetic, no wizard.

  defp screen_slug({w, h}), do: "auto-#{w}x#{h}"

  @doc false
  def snapshot_for_screen(%__MODULE__{screen_w: w, screen_h: h} = calib)
      when is_integer(w) and is_integer(h) do
    slug = screen_slug({w, h})
    File.mkdir_p!(profiles_dir())
    save(calib, profile_path(slug))
    write_profile_settings(slug, calib)
    :ok
  end

  def snapshot_for_screen(_no_screen), do: :ok

  @doc "The LAST calibration saved on a `{w, h}` monitor — `{:ok, calib}` | `:none`."
  def last_for_screen({w, h}) do
    case load(profile_path(screen_slug({w, h}))) do
      {:ok, calib} -> {:ok, calib}
      _absent -> :none
    end
  end

  @doc """
  Makes this monitor's last calibration ACTIVE again, with the numbers it was
  saved with. `{:ok, calib, settings_applied}` | `:none`.
  """
  def restore_last_for_screen({w, h}) do
    with {:ok, calib} <- last_for_screen({w, h}) do
      # settings FIRST: save/1 re-snapshots this monitor, and doing that before
      # applying would overwrite the stored numbers with the previous monitor's
      applied = apply_profile_settings(screen_slug({w, h}))
      save(calib)
      {:ok, calib, applied}
    end
  end

  @doc "Every saved profile: name, screen dims/scale and saved-at (unix seconds)."
  def list_profiles do
    case File.ls(profiles_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(
          &(String.ends_with?(&1, ".json") and not String.ends_with?(&1, ".settings.json") and
              not String.starts_with?(&1, "auto-"))
        )
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
  Screen points per game tile — the game's own ruler, and the unit anything
  measured FROM THE CHARACTER is written in.

  One name for it, because it is one measurement: the sweep's grid, the corpse
  search square and the tile the pokémon is parked on all stretch or shrink
  together, and two of them disagreeing is a bug nobody can see.
  """
  @spec tile_px() :: pos_integer
  def tile_px, do: max(Pokex.Settings.get(:tile_px), 1)

  @doc """
  The screen point `{dx, dy}` TILES from the character — right and down positive.

  "Talvez até uma distância do meu personagem, algo assim mais fácil de eu
  poder medir" (Lucas, 2026-08-11). A screen point recorded from his own click
  is only true while the game window stays put; a distance from the character
  survives the window moving, because the character is re-marked with it.

  `nil` when nothing anchors the character (no calibration, no screen).
  """
  @spec tile_point(t, {integer, integer}) :: {integer, integer} | nil
  def tile_point(%__MODULE__{} = calib, {dx, dy}) do
    case player_point(calib) do
      {px, py} -> {px + dx * tile_px(), py + dy * tile_px()}
      nil -> nil
    end
  end

  @doc """
  The reverse: how many TILES from the character a screen point is, rounded to
  whole tiles — which is not a loss, since a click lands on a tile either way.
  """
  @spec tile_offset(t, {integer, integer}) :: {integer, integer} | nil
  def tile_offset(%__MODULE__{} = calib, {x, y}) do
    case player_point(calib) do
      {px, py} -> {round((x - px) / tile_px()), round((y - py) / tile_px())}
      nil -> nil
    end
  end

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
               pokemon_photo_point player_hp_region)a

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

  # Measured on Lucas's 3440×1440 screen (2026-08-26): the active Pokémon's bar is the FIRST row
  # of the Pokebar panel — its track runs x 46..166 at y 1105, and the row pitch is 49.
  @default_pokemon_hp_region {46, 1105, 121, 13}
  # Still the old client's point: nothing reads it today (the revive presses a key), so it is
  # left unmeasured rather than guessed.
  @default_pokemon_photo_point {70, 934}

  @doc "The main Pokémon's HP bar region (calibrated, else a measured estimate)."
  def pokemon_hp_region(%__MODULE__{pokemon_hp_region: region}) when is_tuple(region), do: region
  def pokemon_hp_region(_calib), do: @default_pokemon_hp_region

  @doc "Screen point of the main Pokémon's portrait — where the mouse goes for the Shift+Q revive."
  def pokemon_photo_point(%__MODULE__{pokemon_photo_point: point}) when is_tuple(point), do: point
  def pokemon_photo_point(_calib), do: @default_pokemon_photo_point

  def battle_first_row(calib, first_row_y \\ @first_row_y_offset)

  def battle_first_row(%__MODULE__{battle_region: {x, y, w, _h}}, first_row_y),
    do: {x + div(w, 3), y + first_row_y}

  @doc """
  Points from the battle region's top to the CENTER of row 0 — where a click
  lands and where the lock band is centered. The default is the old client's;
  the number in force is `battle_first_row_y`, and both readers take it so the
  click and the band can never disagree about where a row is.
  """
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
  def row_band_geometry(scale, row_height, first_row_y \\ @first_row_y_offset) do
    band = max(round(row_height * scale), 1)
    top = round(first_row_y * scale) - div(band, 2)
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
  def battle_row_bands(calib, row_height, rows, first_row_y \\ @first_row_y_offset)

  def battle_row_bands(%__MODULE__{scale: scale, battle_region: region}, row_height, rows, first),
    do: battle_row_bands(region, scale, row_height, rows, first)

  def battle_row_bands(region, scale, row_height, rows, first_row_y) when is_tuple(region) do
    {bx, by, bw, _bh} = battle_body(region)
    {top, band} = row_band_geometry(scale, row_height, first_row_y)

    for i <- 0..(rows - 1)//1 do
      {bx, by + (top + i * band) / scale, bw, band / scale}
    end
  end

  # No battle window marked yet: no bands to draw. Without this the review
  # preview CRASHED on a half-calibrated file — the page you open precisely to
  # find out what is missing.
  def battle_row_bands(_unmarked, _scale, _row_height, _rows, _first), do: []

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
