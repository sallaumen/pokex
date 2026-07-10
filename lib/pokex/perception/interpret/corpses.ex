defmodule Pokex.Perception.Interpret.Corpses do
  @moduledoc """
  Stateful corpse detector for a STATIONARY player (spec
  docs/superpowers/specs/2026-07-10-corpse-capture-design.md).

  Warmup: the first frame is the ground BASELINE; any cell that deviates during the remaining
  warmup frames (animated water, sparkles, the breathing character) joins the variance MASK and
  is ignored forever. Scanning: cells whose sampled pixels moved beyond the diff threshold heat
  up; connected hot cells form blobs; a blob only becomes a CORPSE after holding the same spot
  for consecutive frames — a wandering pet never qualifies. Corpses are reported as SCREEN
  points. All knobs are seeds (see the corpse-capture block in Settings).

  Pure given its inputs: the Feed threads the state (arity-4 interpreter) and resets it when
  the feed resumes from idle, so every bot start relearns the ground.
  """

  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  # Sample every 4th pixel in both axes: a 16px cell yields 16 samples — plenty to vote a cell
  # hot while scanning ~16x fewer pixels than the full frame.
  @stride 4

  def interpret(%Frame{} = frame, _calib, settings, nil) do
    {%{scanning?: false, corpses: []},
     %{phase: :warmup, baseline: grid(frame, cell_px(settings)), bad: MapSet.new(), frames: 1}}
  end

  def interpret(%Frame{} = frame, _calib, settings, %{phase: :warmup} = st) do
    grid = grid(frame, cell_px(settings))
    noise = Settings.value(settings, :corpse_noise_threshold)
    min_samples = Settings.value(settings, :corpse_cell_min_samples)

    bad =
      Enum.reduce(grid, st.bad, fn {cell, samples}, acc ->
        if changed_samples(Map.get(st.baseline, cell), samples, noise) >= min_samples,
          do: MapSet.put(acc, cell),
          else: acc
      end)

    frames = st.frames + 1

    if frames >= Settings.value(settings, :corpse_warmup_frames) do
      {%{scanning?: true, corpses: []},
       %{phase: :scanning, baseline: st.baseline, bad: bad, tracks: %{}}}
    else
      {%{scanning?: false, corpses: []}, %{st | bad: bad, frames: frames}}
    end
  end

  def interpret(%Frame{} = frame, calib, settings, %{phase: :scanning} = st) do
    cell_px = cell_px(settings)
    diff = Settings.value(settings, :corpse_diff_threshold)
    min_samples = Settings.value(settings, :corpse_cell_min_samples)
    min_cells = Settings.value(settings, :corpse_min_cells)
    tolerance = Settings.value(settings, :corpse_stationary_tolerance_px)
    needed = Settings.value(settings, :corpse_stationary_frames)

    hot =
      for {cell, samples} <- grid(frame, cell_px),
          not MapSet.member?(st.bad, cell),
          changed_samples(Map.get(st.baseline, cell), samples, diff) >= min_samples,
          into: MapSet.new(),
          do: cell

    centers =
      hot
      |> clusters()
      |> Enum.filter(&(MapSet.size(&1) >= min_cells))
      |> Enum.map(&center_px(&1, cell_px))

    {tracks, confirmed} = advance_tracks(st.tracks, centers, tolerance, needed)

    corpses =
      confirmed
      |> Enum.map(&Calibration.frame_to_screen(calib, calib.arena_region, &1))
      |> Enum.sort()

    {%{scanning?: true, corpses: corpses}, %{st | tracks: tracks}}
  end

  # -- sampling ---------------------------------------------------------------

  # %{ {cx, cy} => [{r, g, b}] } — samples in deterministic order, so baseline and current
  # lists zip positionally.
  defp grid(%Frame{width: w, height: h, rgba: rgba}, cell_px) do
    for y <- 0..(h - 1)//@stride, x <- 0..(w - 1)//@stride, reduce: %{} do
      acc ->
        offset = (y * w + x) * 4
        <<_::binary-size(offset), r, g, b, _a, _::binary>> = rgba
        Map.update(acc, {div(x, cell_px), div(y, cell_px)}, [{r, g, b}], &[{r, g, b} | &1])
    end
  end

  defp changed_samples(nil, _samples, _threshold), do: 0

  defp changed_samples(baseline, samples, threshold) do
    baseline
    |> Enum.zip(samples)
    |> Enum.count(fn {{br, bg, bb}, {r, g, b}} ->
      abs(r - br) > threshold or abs(g - bg) > threshold or abs(b - bb) > threshold
    end)
  end

  # -- blobs ------------------------------------------------------------------

  # 4-connectivity connected components over the hot-cell set.
  defp clusters(hot) do
    {clusters, _seen} =
      Enum.reduce(hot, {[], MapSet.new()}, fn cell, {clusters, seen} ->
        if MapSet.member?(seen, cell) do
          {clusters, seen}
        else
          cluster = flood(hot, [cell], MapSet.new())
          {[cluster | clusters], MapSet.union(seen, cluster)}
        end
      end)

    clusters
  end

  defp flood(_hot, [], acc), do: acc

  defp flood(hot, [cell | rest], acc) do
    if MapSet.member?(acc, cell) do
      flood(hot, rest, acc)
    else
      {cx, cy} = cell

      neighbors =
        [{cx + 1, cy}, {cx - 1, cy}, {cx, cy + 1}, {cx, cy - 1}]
        |> Enum.filter(&MapSet.member?(hot, &1))

      flood(hot, neighbors ++ rest, MapSet.put(acc, cell))
    end
  end

  defp center_px(cluster, cell_px) do
    n = MapSet.size(cluster)
    {sx, sy} = Enum.reduce(cluster, {0, 0}, fn {cx, cy}, {ax, ay} -> {ax + cx, ay + cy} end)
    half = div(cell_px, 2)
    {div(sx * cell_px, n) + half, div(sy * cell_px, n) + half}
  end

  # -- stationary tracking ------------------------------------------------------

  # tracks: %{center => consecutive_frames_seen}. A center inherits (count + 1) from the
  # nearest previous track within tolerance; otherwise starts at 1. Confirmed at `needed`.
  defp advance_tracks(prev, centers, tolerance, needed) do
    tracks =
      Map.new(centers, fn center ->
        inherited =
          prev
          |> Enum.filter(fn {point, _count} -> near?(point, center, tolerance) end)
          |> Enum.map(fn {_point, count} -> count end)
          |> Enum.max(fn -> 0 end)

        {center, inherited + 1}
      end)

    confirmed = for {center, count} <- tracks, count >= needed, do: center
    {tracks, confirmed}
  end

  defp near?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  defp cell_px(settings), do: Settings.value(settings, :corpse_cell_px)
end
