defmodule Pokex.Bots.Fisher.Sensors.Real do
  @moduledoc false
  @behaviour Pokex.Bots.Fisher.Sensors

  alias Pokex.{Calibration, Rig, Settings, Vision}
  alias Pokex.Bots.{Capture, SkillBar}
  alias Pokex.Vision.Frame

  @impl true
  def observe(needs, calib, settings) do
    Enum.reduce_while(needs, {:ok, %{}}, fn need, {:ok, acc} ->
      case fetch(need, calib, settings) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, need, value)}}
        {:error, reason} -> {:halt, {:error, {need, reason}}}
      end
    end)
  end

  defp fetch(:cursor, _calib, _settings), do: Rig.impl().cursor_position()

  # A bite is distinguished from the resting line by MAGNITUDE, not calm-vs-spike.
  # Once cast, the bait's indicator ring pulses continuously (measured: cyan
  # oscillates ~20-305, never 0) and the cast splash flashes ~250; a real BITE is
  # far brighter (measured peaks 800-1022). We return the RAW cyan count so the
  # driver can show it live in the feed; the driver applies the bite threshold.
  defp fetch(:glow, calib, settings) do
    region = Calibration.glow_search_region(calib, Settings.value(settings, :glow_search_margin))

    with {:ok, frame} <- capture_frame(region, "glow.png") do
      {:ok, Vision.fishing_signal(frame, fishing_signal_opts(settings, calib, region, frame))}
    end
  end

  defp fetch(:wild, calib, settings) do
    with {:ok, frame} <- capture_frame(Calibration.battle_strip(calib), "battle.png") do
      min_count = Settings.value(settings, :wild_min_red_pixels)
      {:ok, Vision.wild_present?(frame, min_count: min_count)}
    end
  end

  defp fetch(:battle_lock, calib, settings) do
    with {:ok, frame} <- capture_frame(Calibration.battle_body(calib), "target.png") do
      # Return the RAW per-row red-pixel list (one entry per battle row); Logic
      # applies target_locked_min_pixels per band, so the threshold stays tunable
      # and the numbers stay visible in the activity feed.
      #
      # UNITS: battle_row_height/first_row_offset are POINTS; the frame is scale×
      # pixels — so the geometry multiplies by calib.scale. battle_row_height/
      # battle_max_rows are only in the RAW settings map (config.ex strips them
      # from logic.config), so the sensor is the one correct place to read them.
      # Calibration.row_band_geometry is the single source of truth for {top,
      # band} (centered on the click point) — the same math the visual preview
      # draws, so what you SEE is exactly what the lock samples.
      {top, band} = Calibration.row_band_geometry(calib.scale, Settings.value(settings, :battle_row_height))
      rows = Settings.value(settings, :battle_max_rows)
      {:ok, Vision.red_row_counts(frame, top: top, band: band, rows: rows)}
    end
  end

  # The full battle view Combat needs, from ONE screenshot of the whole battle_region sliced in
  # memory into the body (HP bars + lock ring) and the rightmost pokeball strip. One
  # screencapture per tick (not two), and body+strip come from the SAME instant (no tear).
  # Returns %{enemies: [rows, topmost first], red: [per-row red px]}:
  #   - enemies = HP-bar rows (body) MINUS own-pokemon pokeball rows (strip). The pokeball marks
  #     YOUR pokemon, so subtracting it leaves the wilds/others. These are only CANDIDATES: a
  #     passing player's pokemon has an HP bar and NO pokeball, so it looks attackable — but
  #     clicking it starts no real battle. Combat must CONFIRM the click via the lock ring.
  #   - red = per-row red-pixel counts (the lock-ring signal); Combat treats a row over
  #     target_locked_min_pixels as a confirmed active battle.
  defp fetch(:battle, calib, settings), do: battle_view(calib, settings)

  # Just the candidate rows (same capture+slice), for callers that don't need the ring.
  defp fetch(:enemy_rows, calib, settings) do
    with {:ok, view} <- battle_view(calib, settings), do: {:ok, view.enemies}
  end

  defp fetch(:hostile, calib, _settings) do
    with {:ok, frame} <- capture_frame(calib.arena_region, "arena.png") do
      case Vision.find_hostile(frame) do
        {:ok, pixel} -> {:ok, Calibration.frame_to_screen(calib, calib.arena_region, pixel)}
        :not_found -> {:ok, nil}
      end
    end
  end

  # Is at least one kill-skill ready? This process reads the skill bar itself (one
  # capture, a pure SkillBar.read) — no shared process, nothing to block on. ANY-ready
  # (not ALL): pull the moment one hook-skill is up, so the fish isn't held while the
  # ~40s kill-skills cycle (all-ready held ~54% of Lucas's bites). Fail-open (true with
  # no reading) so require_cooldowns can't softlock fishing. Fishing only asks for this
  # key when the gate is on (see Fishing.Logic.needs/1), so with the gate off there's no
  # extra capture at all.
  defp fetch(:cooldowns_ready?, calib, settings) do
    keys = Settings.value(settings, :hook_skill_keys)
    {:ok, SkillBar.any_ready?(SkillBar.read(calib, settings), keys)}
  end

  # The ready hotbar keys for combat to fire (highest-priority ready first). nil when
  # there's no skill-bar reading → combat falls back to blind rotation.
  defp fetch(:ready_skills, calib, settings) do
    {:ok, SkillBar.ready_keys(SkillBar.read(calib, settings))}
  end

  defp battle_view(calib, settings) do
    with {:ok, frame} <- capture_frame(calib.battle_region, "battle.png") do
      {top, band} = Calibration.row_band_geometry(calib.scale, Settings.value(settings, :battle_row_height))
      rows = Settings.value(settings, :battle_max_rows)
      strip_px = round(Calibration.strip_width() * calib.scale)

      body = Frame.crop(frame, {0, 0, frame.width - strip_px, frame.height})
      strip = Frame.crop(frame, {frame.width - strip_px, 0, strip_px, frame.height})

      min_pokeball = Settings.value(settings, :pokeball_min_red_px)
      creatures = body |> Vision.hp_bar_row_positions() |> rows_of(top, band, rows)

      own =
        strip
        |> Vision.pokeball_row_positions(min_count: min_pokeball)
        |> rows_of(top, band, rows)

      red = Vision.red_row_counts(body, top: top, band: band, rows: rows)

      {:ok, %{enemies: Enum.sort(creatures -- own), red: red}}
    end
  end

  # Bucket a list of frame-Ys into the distinct 0-based battle rows they fall in.
  defp rows_of(ys, top, band, rows) do
    ys |> Enum.map(&row_index(&1, top, band, rows)) |> Enum.uniq()
  end

  # Bucket a frame-Y into a 0-based battle-row index using the SAME band geometry as the
  # lock sensor, clamped into [0, rows-1] so a bar landing just outside the calibrated
  # strip still anchors to the nearest real row rather than vanishing (band >= 1 always,
  # so this never divides by zero).
  defp row_index(y, top, band, rows), do: max(0, min(div(y - top, band), rows - 1))

  # Through the Capture broker so no two screencaptures run at once (concurrent ones balloon on
  # macOS — see Pokex.Bots.Capture). `frame/3` also shares a very short decoded-frame cache
  # between bursty same-region reads, e.g. fishing/combat/panel all looking at the skill bar.
  defp capture_frame(region, filename) do
    Capture.frame(region, filename)
  end

  defp fishing_signal_opts(settings, calib, region, frame) do
    [
      min_lure_pixels: Settings.value(settings, :fishing_lure_min_pixels),
      bubble_radius_px: Settings.value(settings, :fishing_bubble_radius_px),
      line_present_min_px: Settings.value(settings, :line_present_min_px),
      expected_center: expected_glow_center(calib, region, frame)
    ]
  end

  defp expected_glow_center(%Calibration{glow_region: {gx, gy, gw, gh}}, {rx, ry, rw, rh}, frame)
       when rw > 0 and rh > 0 do
    {
      round((gx + gw / 2 - rx) * frame.width / rw),
      round((gy + gh / 2 - ry) * frame.height / rh)
    }
  end
end
