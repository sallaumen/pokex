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
      # pixels — so multiply by calib.scale. battle_row_height/battle_max_rows are
      # only in the RAW settings map (config.ex strips them from logic.config), so
      # the sensor is the one correct place to read them.
      # The click for row i lands at battle_first_row + i*row_height (the row's
      # CENTER), and the selection ring is drawn AROUND that point — measured on
      # the real game the ring's red sits at the click Y, not below it. So CENTER
      # each band on the click (shift the top up by half a band); a band that
      # started at the click would split the ring across two rows and under-read
      # the locked row (measured: 231px in-band vs 857px once centered).
      scale = calib.scale
      band = max(round((settings[:battle_row_height] || 30) * scale), 1)
      top = round(Calibration.first_row_offset() * scale) - div(band, 2)
      rows = settings[:battle_max_rows] || 6
      {:ok, Vision.red_row_counts(frame, top: top, band: band, rows: rows)}
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

  defp capture_frame(region, filename) do
    with {:ok, path} <- Rig.impl().capture(region, filename) do
      Frame.from_png_file(path)
    end
  end
end
