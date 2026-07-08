defmodule Pokex.Bots.Fisher.Sensors.Real do
  @moduledoc false
  @behaviour Pokex.Bots.Fisher.Sensors

  alias Pokex.{Calibration, Rig, Vision}
  alias Pokex.Bots.SkillBar
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
  defp fetch(:glow, calib, _settings) do
    with {:ok, frame} <- capture_frame(calib.glow_region, "glow.png") do
      {:ok, Vision.bubble_count(frame)}
    end
  end

  defp fetch(:wild, calib, settings) do
    with {:ok, frame} <- capture_frame(Calibration.battle_strip(calib), "battle.png") do
      min_count = settings[:wild_min_red_pixels] || 12
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
      {top, band} = Calibration.row_band_geometry(calib.scale, settings[:battle_row_height] || 30)
      rows = settings[:battle_max_rows] || 6
      {:ok, Vision.red_row_counts(frame, top: top, band: band, rows: rows)}
    end
  end

  # The attackable ENEMY rows (0-based, topmost first) — the rows Combat clicks. PURE VISION
  # on a fresh screenshot, no clicking. An enemy is a row with an HP bar (BODY) and NO pokeball
  # (STRIP): the pokeball marks the player's OWN active pokemon, so subtracting the pokeball
  # rows from the HP-bar rows drops your own pokemon and leaves the wilds/others to attack.
  # battle_body/1 crops the pokeball column off, so HP bars come from the body and pokeballs
  # from the strip; both share the region's y-origin/height, so ONE band geometry (the same the
  # lock sensor uses) buckets both into the same rows. [] lets Combat.Logic stay IDLE (zero
  # mouse) when there's nothing to fight, freeing the shared mouse for fishing.
  defp fetch(:enemy_rows, calib, settings) do
    with {:ok, body} <- capture_frame(Calibration.battle_body(calib), "battle_creatures.png"),
         {:ok, strip} <- capture_frame(Calibration.battle_strip(calib), "battle_own.png") do
      {top, band} = Calibration.row_band_geometry(calib.scale, settings[:battle_row_height] || 30)
      rows = settings[:battle_max_rows] || 6

      creatures = body |> Vision.hp_bar_row_positions() |> rows_of(top, band, rows)
      own = strip |> Vision.pokeball_row_positions() |> rows_of(top, band, rows)

      {:ok, Enum.sort(creatures -- own)}
    end
  end

  defp fetch(:hostile, calib, _settings) do
    with {:ok, frame} <- capture_frame(calib.arena_region, "arena.png") do
      case Vision.find_hostile(frame) do
        {:ok, pixel} -> {:ok, Calibration.frame_to_screen(calib, calib.arena_region, pixel)}
        :not_found -> {:ok, nil}
      end
    end
  end

  # Are the kill-skills ready? This process reads the skill bar itself (one capture,
  # a pure SkillBar.read) — no shared process, nothing to block on. Fail-open (true
  # with no reading) so require_cooldowns can't softlock fishing. Fishing only asks
  # for this key when the gate is on (see Fishing.Logic.needs/1), so with the gate
  # off there's no extra capture at all.
  defp fetch(:cooldowns_ready?, calib, settings) do
    keys = settings[:hook_skill_keys] || settings[:skill_keys] || []
    {:ok, SkillBar.all_ready?(SkillBar.read(calib, settings), keys)}
  end

  # The ready hotbar keys for combat to fire (highest-priority ready first). nil when
  # there's no skill-bar reading → combat falls back to blind rotation.
  defp fetch(:ready_skills, calib, settings) do
    {:ok, SkillBar.ready_keys(SkillBar.read(calib, settings))}
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

  defp capture_frame(region, filename) do
    with {:ok, path} <- Rig.impl().capture(region, filename) do
      Frame.from_png_file(path)
    end
  end
end
