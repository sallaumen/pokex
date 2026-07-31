defmodule Pokex.Bots.Catcher.SpotScan do
  @moduledoc """
  Capture vision: KILL-anchored, DENSELY scanned around the character.

  Kill-anchored (2026-07-30) because the ground detector (baseline + diff +
  tracking) needed a QUIET warmup window that real operation never has: warmup
  ran with a fight on screen, masked exactly the tiles where corpses land, and
  capture stayed mute all session while kill-anchored looting worked beside it.

  The search is DENSE, not a tile lattice — three defects measured 2026-07-30
  killed the lattice: (1) the arena clip decapitated the ring (his arena
  y 217..642 does not contain the character at y 697 — live log:
  `olhei 11/16 tiles`); (2) two lattices out of phase (`player_point` and
  `pokemon_spot_point` differed by (28, 26) mod tile — fixing one's phase
  misaligned the other, and the pokémon is who kills); (3) teach vs search
  framing (calibration crops around the CLICK on the creature, the search
  cropped around the tile's geometric center — taught framing scores 1.000 vs
  0.56..0.87 on grids; live Kingler best was 0.39, a pure-ground box). Sliding
  the teach-sized box over the WHOLE region (coarse step + refinement around
  peaks) removes grid phase entirely, and the winning framing is by construction
  the closest to what was taught.

  The aim comes free: the thrown point is the WINNING WINDOW's center — teaching
  centers on the click over the corpse, so the ball inherits that aim (commit
  2f21811's `capture_aim_up_px`/`left_px` constants were the same fix by guess).

  The region is a `(2r+1)`-tile square centered on the character, clamped to the
  SCREEN — never the arena. `corpse_scan_radius_tiles` sets the radius; a
  calibrated pokémon point falling outside grows the square just enough to
  embrace it. Returns the SAME observation shape `Catcher.Logic` consumes
  (`%{scanning?, corpses, known, captured_at}`) plus diagnostics (`janelas`,
  `melhor`, `motivo`), so queue/ball-in-flight/confirmation/retry stay untouched.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  @doc "Loads the current calibration and scans. Blind observation when it cannot see."
  def scan do
    case Calibration.load() do
      {:ok, calib} -> scan(calib)
      _no_calibration -> blind(:no_calibration)
    end
  end

  @doc """
  Scans the square around the character against the taught library.

  ALWAYS returns an observation — never `nil`. A scan that found nothing and one
  that never HAPPENED used to be the same silence, leaving no way to tell whether
  the problem was aim, library, or gate. The observation carries diagnostics:
  `janelas` (positions scored), `melhor` (best `%{name, score, ponto}` even when
  FAILING), `regiao`, `limiar`, and `motivo` when blind.

  Blind observations carry `scanning?: false`: `Catcher.Logic` treats them as a
  step that proves nothing, so a vision failure never confirms a ball in flight.

  `capture` is injectable in tests (same seam as the other workers).
  """
  def scan(%Calibration{} = calib, capture \\ &Capture.frame/2) do
    with {:ok, center} <- center(calib),
         {:ok, region} <- scan_region(center, calib),
         {:ok, %Frame{} = frame} <- grab(capture, region) do
      sweep(frame, calib, region, center)
    else
      {:error, reason} -> blind(reason)
    end
  end

  # A capture failure reads differently from "the calibration cannot tell me
  # where to look": it is tagged here so the log says which of the two it was.
  defp grab(capture, region) do
    case capture.(region, "corpse_scan.png") do
      {:ok, %Frame{} = frame} -> {:ok, frame}
      {:error, reason} -> {:error, {:capture_failed, reason}}
      other -> {:error, {:capture_failed, other}}
    end
  end

  @doc """
  The region the search scans — the SAME one calibration must photograph to
  teach a corpse. Teaching used `arena_region` while the search used the square:
  a corpse near the character (outside the arena) didn't fit the photo and
  couldn't be clicked to teach — seen live with a Gyarados clipped at the bottom
  edge (2026-07-30). `{:ok, {x, y, w, h}}` or `{:error, reason}`.
  """
  def region(%Calibration{} = calib) do
    with {:ok, center} <- center(calib), do: scan_region(center, calib)
  end

  # Search center. The hand-marked point wins; without it, the SCREEN center —
  # which lands within half a tile of the real character (measured: (1720,720)
  # vs (1688,697)). The old fallback was the ARENA center, 268px above the
  # character on his calibration. This is what allows capturing WITHOUT a
  # calibrated arena.
  defp center(%Calibration{player_point: {_x, _y} = point}), do: {:ok, point}

  defp center(%Calibration{screen_w: w, screen_h: h}) when is_integer(w) and is_integer(h),
    do: {:ok, {div(w, 2), div(h, 2)}}

  defp center(_nothing), do: {:error, :no_anchor}

  # The square: (2r+1) tiles centered on the character, stretched to embrace the
  # pokémon point if it falls outside, clamped to the SCREEN — never the arena
  # (the arena clip decapitated the ring). Screen clamping also keeps the region
  # on the display, which the broker's quarantine would otherwise reject.
  defp scan_region({cx, cy}, %Calibration{screen_w: sw, screen_h: sh} = calib)
       when is_integer(sw) and is_integer(sh) do
    tile = max(Settings.get(:tile_px), 1)
    raio = max(Settings.get(:corpse_scan_radius_tiles), 1)
    meia = div((2 * raio + 1) * tile, 2)

    {left, top, right, bottom} =
      {cx - meia, cy - meia, cx + meia, cy + meia}
      |> hug(calib.pokemon_spot_point, tile)

    left = max(left, 0)
    top = max(top, 0)
    right = min(right, sw)
    bottom = min(bottom, sh)

    box = Settings.get(:corpse_sprite_box_px)

    if right - left >= box and bottom - top >= box,
      do: {:ok, {left, top, right - left, bottom - top}},
      else: {:error, :frame_too_small}
  end

  defp scan_region(_centro, _no_screen), do: {:error, :no_screen}

  defp hug(box, nil, _tile), do: box

  defp hug({left, top, right, bottom}, {px, py}, tile) do
    {min(left, px - tile), min(top, py - tile), max(right, px + tile), max(bottom, py + tile)}
  end

  # Slide the teach-sized box over the whole region at a coarse step, refine
  # around the best peaks, keep local maxima above the threshold. Two phases
  # because the fine phase alone would cost ~40x more windows for the same result.
  defp sweep(%Frame{} = frame, calib, region, center) do
    box = Settings.get(:corpse_sprite_box_px)
    min_sim = Settings.get(:corpse_match_min_similarity)
    step = max(Settings.get(:corpse_scan_step_px), 1)
    refine = max(Settings.get(:corpse_scan_refine_px), 1)

    forbidden = forbidden_zones(calib, region, box)

    grosso = score(frame, windows(frame, box, step), box, forbidden)

    finas =
      grosso
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(Settings.get(:corpse_scan_refine_peaks))
      |> Enum.flat_map(&windows_around(&1, frame, box, step, refine))
      |> Enum.uniq()

    todas = grosso ++ score(frame, finas, box, forbidden)

    targets = peaks(todas, min_sim, Settings.get(:corpse_match_tolerance_px))

    known =
      Map.new(targets, fn %{x: x, y: y, name: name, score: score} ->
        {center_on_screen(x, y, box, calib, region), %{name: name, score: score}}
      end)

    %{
      scanning?: true,
      corpses: known |> Map.keys() |> Enum.sort(),
      known: known,
      captured_at: System.monotonic_time(:millisecond),
      windows: length(todas),
      region: region,
      center: center,
      threshold: min_sim,
      best: best(todas, box, calib, region)
    }
  end

  defp windows(%Frame{width: w, height: h}, box, step) do
    for y <- 0..max(h - box, 0)//step, x <- 0..max(w - box, 0)//step, do: {x, y}
  end

  # Refinement covers ±step in fine increments around a coarse peak — where the
  # ~0.05 score per 7px of offset is recovered.
  defp windows_around(%{x: x, y: y}, %Frame{width: w, height: h}, box, step, refine) do
    for dy <- -step..step//refine,
        dx <- -step..step//refine,
        nx = x + dx,
        ny = y + dy,
        nx >= 0 and ny >= 0 and nx + box <= w and ny + box <= h,
        do: {nx, ny}
  end

  defp score(frame, positions, box, forbidden) do
    for {x, y} <- positions,
        not forbidden?(x, y, box, forbidden),
        info = CorpseLibrary.best_in(frame, {x, y, box, box}),
        info != nil,
        do: %{x: x, y: y, name: info.name, score: info.score}
  end

  # Tiles OCCUPIED by live anchors: a standing sprite of the same species would
  # match the taught corpse by palette, and the ball would fly at Lucas's own
  # pokémon. Each anchor's CENTER is kept in frame px; any window whose center
  # falls within half a tile of one is discarded.
  defp forbidden_zones(calib, region, _box) do
    [calib.player_point, calib.pokemon_spot_point]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {sx, sy} -> in_frame(sx, sy, calib, region) end)
  end

  defp forbidden?(x, y, box, forbidden) do
    meia_caixa = div(box, 2)
    limite = div(max(Settings.get(:tile_px), 1), 2)
    cx = x + meia_caixa
    cy = y + meia_caixa

    Enum.any?(forbidden, fn {px, py} -> abs(cx - px) < limite and abs(cy - py) < limite end)
  end

  # Local maxima above the threshold with neighbor suppression: the dense scan
  # yields a plateau of good windows over the SAME corpse — without this each
  # corpse would become dozens of queue targets.
  defp peaks(candidatos, min_sim, tolerancia) do
    candidatos
    |> Enum.filter(&(&1.score >= min_sim))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.reduce([], fn cand, aceitos ->
      if Enum.any?(aceitos, &near?(&1, cand, tolerancia)),
        do: aceitos,
        else: [cand | aceitos]
    end)
    |> Enum.reverse()
  end

  defp near?(%{x: ax, y: ay}, %{x: bx, y: by}, tolerancia),
    do: abs(ax - bx) <= tolerancia and abs(ay - by) <= tolerancia

  defp best([], _box, _calib, _region), do: nil

  defp best(candidatos, box, calib, region) do
    %{x: x, y: y, name: name, score: score} = Enum.max_by(candidatos, & &1.score)
    %{name: name, score: score, point: center_on_screen(x, y, box, calib, region)}
  end

  # Window corner (frame px) → its CENTER as a screen point. This is the aim:
  # teaching centers on the click over the corpse, so the winning window's
  # center is the point Lucas chose himself.
  defp center_on_screen(x, y, box, %Calibration{scale: scale}, {rx, ry, _w, _h}) do
    meia = div(box, 2)
    {rx + round((x + meia) / scale), ry + round((y + meia) / scale)}
  end

  # SCREEN point → px in the captured region's frame (inverse of
  # frame_to_screen, with the region origin instead of the arena).
  defp in_frame(sx, sy, %Calibration{scale: scale}, {rx, ry, _w, _h}),
    do: {round((sx - rx) * scale), round((sy - ry) * scale)}

  defp blind(reason) do
    %{
      scanning?: false,
      corpses: [],
      known: %{},
      captured_at: System.monotonic_time(:millisecond),
      windows: 0,
      region: nil,
      center: nil,
      threshold: nil,
      best: nil,
      reason: reason
    }
  end
end
