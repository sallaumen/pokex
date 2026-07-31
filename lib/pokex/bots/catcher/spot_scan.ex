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
      _sem_calibracao -> cego(:sem_calibracao)
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
    with {:ok, centro} <- centro(calib),
         {:ok, region} <- scan_region(centro, calib),
         {:ok, %Frame{} = frame} <- capture.(region, "corpse_scan.png") do
      varrer(frame, calib, region, centro)
    else
      {:erro, motivo} -> cego(motivo)
      {:error, motivo} -> cego({:captura_falhou, motivo})
      outro -> cego({:captura_falhou, outro})
    end
  end

  @doc """
  The region the search scans — the SAME one calibration must photograph to
  teach a corpse. Teaching used `arena_region` while the search used the square:
  a corpse near the character (outside the arena) didn't fit the photo and
  couldn't be clicked to teach — seen live with a Gyarados clipped at the bottom
  edge (2026-07-30). `{:ok, {x, y, w, h}}` or `{:erro, motivo}`.
  """
  def regiao(%Calibration{} = calib) do
    with {:ok, centro} <- centro(calib), do: scan_region(centro, calib)
  end

  # Search center. The hand-marked point wins; without it, the SCREEN center —
  # which lands within half a tile of the real character (measured: (1720,720)
  # vs (1688,697)). The old fallback was the ARENA center, 268px above the
  # character on his calibration. This is what allows capturing WITHOUT a
  # calibrated arena.
  defp centro(%Calibration{player_point: {_x, _y} = ponto}), do: {:ok, ponto}

  defp centro(%Calibration{screen_w: w, screen_h: h}) when is_integer(w) and is_integer(h),
    do: {:ok, {div(w, 2), div(h, 2)}}

  defp centro(_sem_nada), do: {:erro, :sem_ancora}

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
      |> abracar(calib.pokemon_spot_point, tile)

    left = max(left, 0)
    top = max(top, 0)
    right = min(right, sw)
    bottom = min(bottom, sh)

    box = Settings.get(:corpse_sprite_box_px)

    if right - left >= box and bottom - top >= box,
      do: {:ok, {left, top, right - left, bottom - top}},
      else: {:erro, :quadro_pequeno_demais}
  end

  defp scan_region(_centro, _sem_tela), do: {:erro, :sem_tela}

  defp abracar(caixa, nil, _tile), do: caixa

  defp abracar({left, top, right, bottom}, {px, py}, tile) do
    {min(left, px - tile), min(top, py - tile), max(right, px + tile), max(bottom, py + tile)}
  end

  # Slide the teach-sized box over the whole region at a coarse step, refine
  # around the best peaks, keep local maxima above the threshold. Two phases
  # because the fine phase alone would cost ~40x more windows for the same result.
  defp varrer(%Frame{} = frame, calib, region, centro) do
    box = Settings.get(:corpse_sprite_box_px)
    min_sim = Settings.get(:corpse_match_min_similarity)
    passo = max(Settings.get(:corpse_scan_step_px), 1)
    refino = max(Settings.get(:corpse_scan_refine_px), 1)

    proibidos = zonas_proibidas(calib, region, box)

    grosso = pontuar(frame, janelas(frame, box, passo), box, proibidos)

    finas =
      grosso
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(Settings.get(:corpse_scan_refine_peaks))
      |> Enum.flat_map(&janelas_ao_redor(&1, frame, box, passo, refino))
      |> Enum.uniq()

    todas = grosso ++ pontuar(frame, finas, box, proibidos)

    alvos = picos(todas, min_sim, Settings.get(:corpse_match_tolerance_px))

    known =
      Map.new(alvos, fn %{x: x, y: y, name: nome, score: score} ->
        {centro_na_tela(x, y, box, calib, region), %{name: nome, score: score}}
      end)

    %{
      scanning?: true,
      corpses: known |> Map.keys() |> Enum.sort(),
      known: known,
      captured_at: System.monotonic_time(:millisecond),
      janelas: length(todas),
      regiao: region,
      centro: centro,
      limiar: min_sim,
      melhor: melhor(todas, box, calib, region)
    }
  end

  defp janelas(%Frame{width: w, height: h}, box, passo) do
    for y <- 0..max(h - box, 0)//passo, x <- 0..max(w - box, 0)//passo, do: {x, y}
  end

  # Refinement covers ±step in fine increments around a coarse peak — where the
  # ~0.05 score per 7px of offset is recovered.
  defp janelas_ao_redor(%{x: x, y: y}, %Frame{width: w, height: h}, box, passo, refino) do
    for dy <- -passo..passo//refino,
        dx <- -passo..passo//refino,
        nx = x + dx,
        ny = y + dy,
        nx >= 0 and ny >= 0 and nx + box <= w and ny + box <= h,
        do: {nx, ny}
  end

  defp pontuar(frame, posicoes, box, proibidos) do
    for {x, y} <- posicoes,
        not proibida?(x, y, box, proibidos),
        info = CorpseLibrary.best_in(frame, {x, y, box, box}),
        info != nil,
        do: %{x: x, y: y, name: info.name, score: info.score}
  end

  # Tiles OCCUPIED by live anchors: a standing sprite of the same species would
  # match the taught corpse by palette, and the ball would fly at Lucas's own
  # pokémon. Each anchor's CENTER is kept in frame px; any window whose center
  # falls within half a tile of one is discarded.
  defp zonas_proibidas(calib, region, _box) do
    [calib.player_point, calib.pokemon_spot_point]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {sx, sy} -> na_moldura(sx, sy, calib, region) end)
  end

  defp proibida?(x, y, box, proibidos) do
    meia_caixa = div(box, 2)
    limite = div(max(Settings.get(:tile_px), 1), 2)
    cx = x + meia_caixa
    cy = y + meia_caixa

    Enum.any?(proibidos, fn {px, py} -> abs(cx - px) < limite and abs(cy - py) < limite end)
  end

  # Local maxima above the threshold with neighbor suppression: the dense scan
  # yields a plateau of good windows over the SAME corpse — without this each
  # corpse would become dozens of queue targets.
  defp picos(candidatos, min_sim, tolerancia) do
    candidatos
    |> Enum.filter(&(&1.score >= min_sim))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.reduce([], fn cand, aceitos ->
      if Enum.any?(aceitos, &perto?(&1, cand, tolerancia)),
        do: aceitos,
        else: [cand | aceitos]
    end)
    |> Enum.reverse()
  end

  defp perto?(%{x: ax, y: ay}, %{x: bx, y: by}, tolerancia),
    do: abs(ax - bx) <= tolerancia and abs(ay - by) <= tolerancia

  defp melhor([], _box, _calib, _region), do: nil

  defp melhor(candidatos, box, calib, region) do
    %{x: x, y: y, name: nome, score: score} = Enum.max_by(candidatos, & &1.score)
    %{name: nome, score: score, ponto: centro_na_tela(x, y, box, calib, region)}
  end

  # Window corner (frame px) → its CENTER as a screen point. This is the aim:
  # teaching centers on the click over the corpse, so the winning window's
  # center is the point Lucas chose himself.
  defp centro_na_tela(x, y, box, %Calibration{scale: scale}, {rx, ry, _w, _h}) do
    meia = div(box, 2)
    {rx + round((x + meia) / scale), ry + round((y + meia) / scale)}
  end

  # SCREEN point → px in the captured region's frame (inverse of
  # frame_to_screen, with the region origin instead of the arena).
  defp na_moldura(sx, sy, %Calibration{scale: scale}, {rx, ry, _w, _h}),
    do: {round((sx - rx) * scale), round((sy - ry) * scale)}

  defp cego(motivo) do
    %{
      scanning?: false,
      corpses: [],
      known: %{},
      captured_at: System.monotonic_time(:millisecond),
      janelas: 0,
      regiao: nil,
      centro: nil,
      limiar: nil,
      melhor: nil,
      motivo: motivo
    }
  end
end
