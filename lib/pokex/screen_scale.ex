defmodule Pokex.ScreenScale do
  @moduledoc """
  How big this screen's game is compared to the screen the numbers were measured
  on — and what each screen-dependent setting should become because of it.

  Every pixel-denominated seed in `Settings` was measured once, on the 3440×1440
  ultrawide. None of them survives a change of screen: on Lucas's MacBook the
  same skill bar is 0.67× as wide, so `tile_px: 88` overshoots by half a tile,
  the corpse box crops the wrong square, and `glow_threshold: 1100` asks for
  more than twice the cyan a real bite can produce. That is what "nada funciona
  em 1 monitor só" was made of (2026-08-06).

  ## The ruler is the GAME, never the display

  Measured on his two screens: the display went 3440 → 1512 points (0.44) while
  the game's HUD went 53.8 → 36.1 points per skill slot (**0.67**). Deriving
  from the display size would be wrong by half. So the ruler is a piece of the
  GAME that is always calibrated and has crisp edges — one skill slot:

      ui_scale = (skill_bar_region width / skill_bar_count) / #{53.75}

  ## Two families, and why the exponent differs

  A LINEAR measure (a tile, a box side, a search margin) scales with the ruler.
  A PIXEL COUNT (how much cyan makes a bite) is an AREA, so it scales with the
  ruler SQUARED — a bubble 0.67× as wide covers 0.45× the pixels. Getting this
  wrong is not cosmetic: at 0.67 the fishing threshold would still be 50% too
  high and no bite would ever register.

  Deliberately NOT here: anything counted in TILES (`corpse_scan_radius_tiles`,
  `sweep_radius_tiles`, the cavebot's) — a tile is a game unit and already
  immune — and anything that is a colour or a percentage
  (`corpse_diff_threshold`, `minimap_coord_ink`, `skill_ready_*`), which a
  smaller screen does not change.

  ## Proposals come from the SEED, never from the value in force

  `proposals/2` derives from `Settings.defaults()`, so applying twice lands on
  the same number instead of scaling an already-scaled value. It also means a
  hand-tuned override shows up in the table as being replaced — which is the
  honest thing to show, since the tuning belonged to the other screen.
  """

  alias Pokex.{Calibration, Settings}

  # One skill slot on the screen every seed was measured on: the 2026-07-31
  # ultrawide profile, skill_bar_region 430 points wide over **9** slots (the
  # file is named "8skill" but carries skill_bar_count 9 and nine
  # skill_slot_refs). 53.75 = 430/8 read the NAME instead of the data and made
  # the reference slot 12% too wide, so the reference screen itself measured
  # 0.87 and every seed was offered back 12% (24% for the area family) smaller
  # than it was measured. That is the shrink that reached his settings.
  @reference_slot_pt 430 / 9

  # How far the ruler may sit from the reference and still BE the reference. The
  # game window is resizable, so the SAME ultrawide measures 47.0-49.0 pt/slot
  # across his own saved profiles (±2.6%) — a tighter band would call one screen
  # two. His other screen is at 0.76, nowhere near this.
  @reference_tolerance 0.05

  @linear [
    :tile_px,
    :battle_row_height,
    :corpse_sprite_box_px,
    :corpse_scan_step_px,
    :corpse_scan_refine_px,
    :corpse_match_tolerance_px,
    :corpse_stationary_tolerance_px,
    :corpse_cell_px,
    :fishing_bubble_radius_px,
    :glow_search_margin,
    :mini_game_bar_offset_px,
    :mini_game_bar_width_px,
    :mini_game_above_px,
    :mini_game_strip_height_px
  ]

  @area [
    :glow_threshold,
    :line_present_min_px,
    :fishing_lure_min_pixels,
    :wild_min_red_pixels,
    :pokeball_min_red_px,
    :target_locked_min_pixels,
    :corpse_cell_min_samples
  ]

  @doc "The keys this module rescales, by family."
  def keys, do: %{linear: @linear, area: @area}

  @doc """
  This screen's game scale against the reference — `{:ok, ratio}`, or
  `:unknown` when the skill bar is not calibrated (the only ruler there is).
  """
  @spec measure(Calibration.t()) :: {:ok, float} | :unknown
  def measure(%Calibration{skill_bar_region: {_x, _y, w, _h}, skill_bar_count: count})
      when is_integer(w) and w > 0 and is_integer(count) and count > 0,
      do: {:ok, w / count / @reference_slot_pt}

  def measure(_uncalibrated), do: :unknown

  @doc """
  What each screen-dependent setting should become at `ratio`, as
  `%{key: , from: , to: , family: }` — only the ones that would actually change.

  `from` is the value in force (what he sees today); `to` comes from the SEED,
  so this is idempotent and a stale override is visibly replaced.
  """
  @spec proposals(float, keyword) :: [map]
  def proposals(ratio, opts \\ []) when is_number(ratio) and ratio > 0 do
    seeds = Settings.defaults()
    get = Keyword.get(opts, :get, &Settings.get/1)

    Enum.flat_map(@linear ++ @area, fn key ->
      family = if key in @area, do: :area, else: :linear
      to = scaled(Map.fetch!(seeds, key), ratio, family)
      from = get.(key)

      if to == from, do: [], else: [%{key: key, from: from, to: to, family: family}]
    end)
  end

  @doc "Writes the proposals. Returns how many changed."
  @spec apply!([map]) :: non_neg_integer
  def apply!(proposals) do
    Enum.count(proposals, fn %{key: key, to: to} -> Settings.put(key, to) == :ok end)
  end

  @doc """
  Is this screen close enough to the reference that rescaling is noise?

  Inside the band the rounding moves almost nothing, and offering a "fix" that
  changes two values by one point each only teaches him to distrust the screen.

  This answers "which screen is this", NOT "are the numbers right" — a caller
  that skips `proposals/2` on a true here is blind to the settings of a
  DIFFERENT screen still being in force, which is exactly how the reference
  monitor ended up fishing with the MacBook's thresholds (2026-08-10). Snap the
  ratio to 1.0 on a true and let `proposals/2` answer; it returns [] on its own
  when the values in force already match.
  """
  def matches_reference?(ratio), do: abs(ratio - 1.0) < @reference_tolerance

  # An area threshold scales with the ratio SQUARED; a length, with the ratio.
  # Floor of 1: a rescaled threshold of zero would make every frame a match,
  # which reads as "the detector went crazy" rather than "the number is wrong".
  defp scaled(seed, ratio, :area) when is_float(seed), do: max(seed * ratio * ratio, 1.0)
  defp scaled(seed, ratio, :area), do: max(round(seed * ratio * ratio), 1)
  defp scaled(seed, ratio, :linear) when is_float(seed), do: max(seed * ratio, 1.0)
  defp scaled(seed, ratio, :linear), do: max(round(seed * ratio), 1)
end
