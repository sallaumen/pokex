defmodule Pokex.Diagnostics.Report do
  @moduledoc """
  One-shot diagnostics capture: everything the bot sees, as data.

  Captures every calibrated region (glow / battle body / battle strip / arena) and the
  full screen through the Rig, decodes each to a Frame, runs every Vision metric,
  downsamples the glow + battle + arena regions into a colour matrix, and returns a
  JSON-serializable map. `capture/1` also writes the map to
  `~/.pokex/exports/diagnostics-<ms>.json` and overwrites `~/.pokex/exports/latest.json`;
  the region PNGs stay in `~/.pokex/captures/` and are referenced by filename (served
  via `/captures/:name`).

  The point: Lucas clicks one button, and Claude reads `latest.json` (+ the referenced
  PNGs) the next morning to diagnose a fishing/combat problem without a hand-captured,
  hand-described screenshot. The Rig, calibration, settings, now-timestamp and output
  directory are all injectable so the whole thing is testable with a Fake rig.
  """

  alias Pokex.{Calibration, Home, Rig, Settings}
  alias Pokex.Vision
  alias Pokex.Vision.Frame

  # class → single glyph, so `matrix.ascii` reads like a tiny picture of the region.
  @glyphs %{
    pokeball_red: "P",
    lock_red: "R",
    hp_green: "G",
    cyan: "c",
    other: ".",
    dark: " "
  }

  @doc """
  Captures a full diagnostics report and writes it to the exports dir.

  Options (all optional; defaults hit the live system):
    * `:rig` — Rig module (default `Rig.impl()`)
    * `:calib` — a `%Calibration{}` (default `Calibration.load()`)
    * `:settings` — settings map (default `Settings.all()`)
    * `:exports_dir` — output dir (default `Home.exports_dir()`)
    * `:now` — capture timestamp in ms (default `System.system_time(:millisecond)`)

  Returns `{:ok, report_map, json_path}` or `{:error, reason}` if calibration is missing.
  """
  def capture(opts \\ []) do
    rig = Keyword.get(opts, :rig, Rig.impl())
    now_ms = Keyword.get(opts, :now, System.system_time(:millisecond))

    with {:ok, calib} <- load_calib(opts) do
      settings = Keyword.get(opts, :settings) || Settings.all()
      report = build(rig, calib, settings, now_ms)
      {:ok, report, write(report, now_ms, opts)}
    end
  end

  defp load_calib(opts) do
    case Keyword.get(opts, :calib) do
      nil -> Calibration.load()
      calib -> {:ok, calib}
    end
  end

  defp build(rig, calib, settings, now_ms) do
    %{
      captured_at_ms: now_ms,
      captured_at: iso8601(now_ms),
      calibration: calibration_map(calib),
      settings: settings,
      regions: %{
        glow:
          region_report(rig, calib.glow_region, "diag_glow.png", &glow_metrics(&1, settings),
            matrix: [cols: 16]
          ),
        battle_body:
          region_report(
            rig,
            Calibration.battle_body(calib),
            "diag_battle_body.png",
            &battle_metrics(&1, calib, settings),
            matrix: [cols: 18]
          ),
        battle_strip:
          region_report(
            rig,
            Calibration.battle_strip(calib),
            "diag_battle_strip.png",
            &strip_metrics(&1, settings),
            matrix: false
          ),
        arena:
          region_report(rig, calib.arena_region, "diag_arena.png", &arena_metrics(&1, calib),
            matrix: [cols: 24]
          ),
        skill_bar: skill_bar_report(rig, calib, settings)
      },
      screen: screen_report(rig)
    }
  end

  # The skill hotbar with the per-slot brightness/saturation/state — the numbers to
  # tune skill_ready_min_brightness/saturation against. `calibrated?: false` when the
  # skill bar hasn't been calibrated yet.
  defp skill_bar_report(_rig, %Calibration{skill_bar_region: nil}, _settings),
    do: %{calibrated?: false}

  defp skill_bar_report(rig, %Calibration{skill_bar_region: region}, settings) do
    case capture_frame(rig, region, "diag_skill_bar.png") do
      {:ok, frame, image} ->
        slots =
          Vision.skill_slots(frame,
            count: settings[:skill_bar_count],
            min_brightness: settings[:skill_ready_min_brightness],
            min_saturation: settings[:skill_ready_min_saturation]
          )

        %{
          calibrated?: true,
          region: Tuple.to_list(region),
          image: image,
          width: frame.width,
          height: frame.height,
          thresholds: %{
            min_brightness: settings[:skill_ready_min_brightness],
            min_saturation: settings[:skill_ready_min_saturation]
          },
          states: Enum.map(slots, & &1.state),
          slots: slots
        }

      {:error, reason} ->
        %{calibrated?: true, region: Tuple.to_list(region), error: inspect(reason)}
    end
  end

  # --- per-region capture + metrics ------------------------------------------

  defp region_report(rig, {x, y, w, h} = region, filename, metrics_fun, opts) do
    case capture_frame(rig, region, filename) do
      {:ok, frame, image} ->
        %{region: [x, y, w, h], image: image, width: frame.width, height: frame.height}
        |> Map.put(:metrics, metrics_fun.(frame))
        |> maybe_matrix(frame, Keyword.get(opts, :matrix, false))

      {:error, reason} ->
        %{region: [x, y, w, h], image: filename, error: inspect(reason)}
    end
  end

  defp capture_frame(rig, region, filename) do
    with {:ok, path} <- rig.capture(region, filename),
         {:ok, frame} <- Frame.from_png_file(path) do
      {:ok, frame, Path.basename(path)}
    end
  end

  defp maybe_matrix(report, _frame, false), do: report
  defp maybe_matrix(report, frame, m_opts), do: Map.put(report, :matrix, matrix(frame, m_opts))

  defp glow_metrics(frame, settings) do
    count = Vision.bubble_count(frame)
    threshold = settings[:glow_threshold] || 500
    line_min = settings[:line_present_min_px] || 100

    %{
      bubble_count: count,
      glow_threshold: threshold,
      line_present_min_px: line_min,
      bite?: count > threshold,
      line_present?: count >= line_min
    }
  end

  defp battle_metrics(frame, calib, settings) do
    {top, band} = Calibration.row_band_geometry(calib.scale, settings[:battle_row_height])
    rows = settings[:battle_max_rows]
    min = settings[:target_locked_min_pixels]
    counts = Vision.red_row_counts(frame, top: top, band: band, rows: rows)

    locked =
      case Vision.locked_row(counts, min) do
        {:ok, i} -> i
        :none -> nil
      end

    %{
      has_creature?: Vision.battle_has_creature?(frame),
      hp_bar_rows: Vision.hp_bar_rows(frame),
      calibrated_row_centers: for(i <- 0..(rows - 1)//1, do: top + i * band + div(band, 2)),
      red_row_counts: counts,
      locked_row: locked,
      target_locked_min_pixels: min,
      red_count: Vision.red_count(frame)
    }
  end

  defp strip_metrics(frame, settings) do
    min = settings[:wild_min_red_pixels]

    wild_row =
      case Vision.find_wild_row(frame) do
        {:ok, y} -> y
        :not_found -> nil
      end

    %{
      wild_present?: Vision.wild_present?(frame, min_count: min),
      red_count: Vision.red_count(frame),
      wild_min_red_pixels: min,
      wild_row_frame_y: wild_row
    }
  end

  defp arena_metrics(frame, calib) do
    hostile =
      case Vision.find_hostile(frame) do
        {:ok, {fx, fy}} ->
          {sx, sy} = Calibration.frame_to_screen(calib, calib.arena_region, {fx, fy})
          %{frame_px: [fx, fy], screen_point: [sx, sy]}

        :not_found ->
          nil
      end

    %{find_hostile: hostile}
  end

  defp screen_report(rig) do
    with {:ok, probe_path} <- rig.capture({0, 0, 100, 100}, "diag_scale_probe.png"),
         {:ok, {probe_px, _}} <- Frame.png_dimensions(probe_path),
         {:ok, screen_path} <- rig.capture_screen(),
         {:ok, {fw, fh}} <- Frame.png_dimensions(screen_path) do
      %{
        image: Path.basename(screen_path),
        pixels: [fw, fh],
        probe_px: probe_px,
        r_scale: probe_px / 100
      }
    else
      error -> %{error: inspect(error)}
    end
  end

  # --- matrix ----------------------------------------------------------------

  # Turn the downsampled grid into JSON: the full per-cell data AND a one-string-per-
  # row `ascii` picture (via @glyphs) that reads at a glance — spaces are black/empty,
  # letters are signal (G = HP bar, R/P = lock/pokeball red, c = bubbles).
  defp matrix(frame, m_opts) do
    grid = Vision.downsample(frame, m_opts)

    %{
      cols: grid.cols,
      rows: grid.rows,
      cell_w: grid.cell_w,
      cell_h: grid.cell_h,
      legend: @glyphs,
      ascii: Enum.map(grid.cells, fn row -> Enum.map_join(row, &@glyphs[&1.class]) end),
      cells:
        Enum.map(grid.cells, fn row ->
          Enum.map(row, fn c -> %{class: c.class, rgb: [c.r, c.g, c.b]} end)
        end)
    }
  end

  # --- serialization ---------------------------------------------------------

  defp calibration_map(calib) do
    %{
      scale: calib.scale,
      screen_w: calib.screen_w,
      screen_h: calib.screen_h,
      water_point: to_list(calib.water_point),
      neutral_point: to_list(calib.neutral_point),
      glow_region: to_list(calib.glow_region),
      battle_region: to_list(calib.battle_region),
      battle_body: to_list(Calibration.battle_body(calib)),
      battle_strip: to_list(Calibration.battle_strip(calib)),
      arena_region: to_list(calib.arena_region),
      suggested_glow_threshold: calib.suggested_glow_threshold
    }
  end

  defp write(report, now_ms, opts) do
    dir = Keyword.get(opts, :exports_dir) || Home.exports_dir()
    File.mkdir_p!(dir)
    json = JSON.encode!(report)
    path = Path.join(dir, "diagnostics-#{now_ms}.json")
    File.write!(path, json)
    File.write!(Path.join(dir, "latest.json"), json)
    path
  end

  defp to_list(nil), do: nil
  defp to_list(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)

  defp iso8601(now_ms) do
    now_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end
end
