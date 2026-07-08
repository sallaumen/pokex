defmodule Pokex.Bots.Fisher.Sensors.Real do
  @moduledoc false
  @behaviour Pokex.Bots.Fisher.Sensors

  alias Pokex.{Calibration, Rig, Vision}
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

  # Is there ANY creature in the Battle list right now? PURE VISION on a fresh
  # screenshot — no clicking involved. Lets Combat.Logic stay IDLE (zero mouse
  # actions) over an empty list instead of clicking a row every tick and
  # starving the fishing bot of the shared mouse.
  defp fetch(:battle_creatures?, calib, _settings) do
    with {:ok, frame} <- capture_frame(Calibration.battle_body(calib), "battle_creatures.png") do
      {:ok, Vision.battle_has_creature?(frame)}
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

  # Are the kill-skills ready? Read from the shared Cooldowns store (which does the
  # skill-bar capture on its own timer) rather than capturing here every watch tick.
  # Fail-open (all_ready? returns true with no reading) so require_cooldowns can't
  # softlock fishing.
  defp fetch(:cooldowns_ready?, _calib, settings) do
    keys = settings[:hook_skill_keys] || settings[:skill_keys] || []
    {:ok, Pokex.Bots.Cooldowns.all_ready?(keys)}
  end

  defp capture_frame(region, filename) do
    with {:ok, path} <- Rig.impl().capture(region, filename) do
      Frame.from_png_file(path)
    end
  end
end
