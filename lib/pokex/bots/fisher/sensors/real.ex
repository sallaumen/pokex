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

  # The bite shows as bright-cyan bubble rings around the bait; calm water reads
  # ~0 such pixels (measured in-game: bite ≈ 512, calm = 0). Count them directly —
  # baseline-free, single-capture, robust to day/night lighting.
  defp fetch(:glow, calib, settings) do
    with {:ok, frame} <- capture_frame(calib.glow_region, "glow.png") do
      threshold = settings[:glow_threshold] || 60
      {:ok, Vision.bubble_count(frame) > threshold}
    end
  end

  defp fetch(:wild, calib, settings) do
    with {:ok, frame} <- capture_frame(Calibration.battle_strip(calib), "battle.png") do
      min_count = settings[:wild_min_red_pixels] || 12
      {:ok, Vision.wild_present?(frame, min_count: min_count)}
    end
  end

  defp fetch(:target_locked, calib, _settings) do
    with {:ok, frame} <- capture_frame(Calibration.battle_body(calib), "target.png") do
      # Return the raw red-pixel count; Logic compares it to target_locked_min_pixels
      # (so the threshold is tunable and the count is visible in the activity feed).
      {:ok, Vision.red_count(frame)}
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
