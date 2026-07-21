defmodule Pokex.Pokedex.ShinySignatures do
  @moduledoc """
  The shiny detector's eyes, built from the wiki sprites the Pokédex scraped —
  no in-game photo needed: a PXG Shiny is a full RECOLOR of the base sprite
  (white Seadra vs blue), so the tell is COLOR, which survives the size
  difference between the wiki icon and the in-game sprite.

  For each watched base name (`shiny_watch_names`) it loads BOTH sprites and
  keeps the quantized color buckets that are prominent in the Shiny but absent
  from the normal — the "only a shiny looks like this" palette. `scan/2` then
  sweeps an arena frame for a spatial CLUSTER of those colors (per-cell counts,
  best 2×2 block), which is what separates a shiny standing there from stray
  background pixels.

  Normal sprites come as animated GIFs — `sips` (built into macOS, the same
  platform the whole Rig depends on) converts the first frame to PNG once,
  cached under the Pokex home.
  """

  import Bitwise

  alias Pokex.{Home, Pokedex, Settings}
  alias Pokex.Vision.Frame

  @key {__MODULE__, :signatures}
  # 8 levels per channel — coarse enough to absorb in-game lighting, fine
  # enough to keep "white" and "pale blue" apart
  @bucket_shift 5
  # a cell of the arena grid; a shiny cluster must light up a 2×2 block
  @cell_px 16
  # prominence floors: a shiny color must cover ≥2% of the shiny sprite; ANY
  # color covering ≥0.5% of the normal sprite is disqualified
  @shiny_min_pct 0.02
  @base_max_pct 0.005
  # outline/near-black pixels carry no recolor signal
  @min_brightness 90

  @doc "The cached signatures ([%{name, buckets}]); [] until rebuild/0 runs."
  def signatures, do: :persistent_term.get(@key, [])

  @doc "Empties the cache (tests, and the guard's disable path can if ever needed)."
  def clear, do: :persistent_term.put(@key, [])

  @doc """
  Rebuilds the signature cache from `shiny_watch_names` + the scraped sprites.
  Returns {:ok, built_names} — a name is skipped (not failed) when the dex
  entry or a sprite file is missing, so one bad name never blinds the rest.
  """
  def rebuild do
    sigs =
      Settings.get(:shiny_watch_names)
      |> List.wrap()
      |> Enum.map(&build/1)
      |> Enum.reject(&is_nil/1)

    :persistent_term.put(@key, sigs)
    {:ok, Enum.map(sigs, & &1.name)}
  end

  @doc """
  Sweeps a frame for the best shiny cluster: `%{name, px}` (px = matching
  pixels in the best 2×2 cell block) when some signature clusters at least
  `min_px`, else nil. O(pixels), one pass — runs inside the arena feed.
  """
  def scan(frame, min_px) do
    case probe(frame) do
      [] ->
        nil

      results ->
        {name, px} = Enum.max_by(results, &elem(&1, 1))
        if px >= min_px, do: %{name: name, px: px}
    end
  end

  @doc "Per-name best cluster size for a frame ([{name, px}]) — the panel's probe."
  def probe(frame) do
    case signatures() do
      [] ->
        []

      sigs ->
        counts = cell_counts(frame, sigs)

        for %{name: name} <- sigs do
          {name, best_block(Map.get(counts, name, %{}))}
        end
    end
  end

  # -- signature building ------------------------------------------------------

  defp build(base_name) do
    with %{shiny_name: shiny_name} = base when is_binary(shiny_name) <- Pokedex.get(base_name),
         %{} = shiny <- Pokedex.get(shiny_name),
         {:ok, shiny_frame} <- sprite_frame(shiny.sprite),
         {:ok, base_frame} <- sprite_frame(base.sprite),
         buckets when buckets != [] <- distinctive_buckets(shiny_frame, base_frame) do
      %{name: shiny_name, buckets: MapSet.new(buckets)}
    else
      _missing_entry_sprite_or_empty -> nil
    end
  end

  @doc false
  # Shiny-prominent buckets minus EVERYTHING the normal sprite shows — public
  # for doctests/tests; the tuning constants live here in one place.
  def distinctive_buckets(shiny_frame, base_frame) do
    base = base_frame |> bucket_counts() |> significant(@base_max_pct) |> MapSet.new()

    shiny_frame
    |> bucket_counts()
    |> significant(@shiny_min_pct)
    |> Enum.reject(&MapSet.member?(base, &1))
  end

  defp bucket_counts(%Frame{rgba: rgba}) do
    for <<r, g, b, a <- rgba>>,
        a >= 128,
        r + g + b >= @min_brightness,
        reduce: %{} do
      acc -> Map.update(acc, bucket(r, g, b), 1, &(&1 + 1))
    end
  end

  defp significant(counts, pct_floor) do
    total = counts |> Map.values() |> Enum.sum()

    if total == 0,
      do: [],
      else: for({bucket, count} <- counts, count / total >= pct_floor, do: bucket)
  end

  defp bucket(r, g, b), do: {r >>> @bucket_shift, g >>> @bucket_shift, b >>> @bucket_shift}

  # -- frame sweep -------------------------------------------------------------

  # One pass over the frame: per signature, count matching pixels per grid cell.
  defp cell_counts(%Frame{rgba: rgba, width: width}, sigs) do
    walk(rgba, 0, width, sigs, %{})
  end

  defp walk(<<>>, _i, _width, _sigs, acc), do: acc

  defp walk(<<r, g, b, _a, rest::binary>>, i, width, sigs, acc) do
    acc =
      if r + g + b >= @min_brightness do
        pixel_bucket = bucket(r, g, b)
        cell = {div(rem(i, width), @cell_px), div(div(i, width), @cell_px)}

        Enum.reduce(sigs, acc, fn %{name: name, buckets: buckets}, acc ->
          if MapSet.member?(buckets, pixel_bucket),
            do: Map.update(acc, name, %{cell => 1}, &Map.update(&1, cell, 1, fn c -> c + 1 end)),
            else: acc
        end)
      else
        acc
      end

    walk(rest, i + 1, width, sigs, acc)
  end

  # The densest 2×2 cell block — a real sprite lights up neighbouring cells,
  # scattered background matches don't.
  defp best_block(cells) when map_size(cells) == 0, do: 0

  defp best_block(cells) do
    cells
    |> Map.keys()
    |> Enum.map(fn {cx, cy} ->
      Map.get(cells, {cx, cy}, 0) + Map.get(cells, {cx + 1, cy}, 0) +
        Map.get(cells, {cx, cy + 1}, 0) + Map.get(cells, {cx + 1, cy + 1}, 0)
    end)
    |> Enum.max()
  end

  # -- sprite files ------------------------------------------------------------

  defp sprite_frame(nil), do: :error

  defp sprite_frame(rel_path) do
    path = Path.join(sprites_root(), rel_path)

    case Path.extname(path) do
      ".png" ->
        Frame.from_png_file(path)

      ".gif" ->
        with {:ok, png} <- gif_to_png(path), do: Frame.from_png_file(png)

      _other ->
        :error
    end
  end

  # sips ships with macOS — the one platform Pokex runs on (SCK, osascript).
  # First GIF frame → PNG, cached by basename under the Pokex home.
  defp gif_to_png(gif_path) do
    png = Path.join(cache_dir(), Path.basename(gif_path, ".gif") <> ".png")

    cond do
      File.exists?(png) ->
        {:ok, png}

      true ->
        File.mkdir_p!(cache_dir())

        case System.cmd("sips", ["-s", "format", "png", gif_path, "--out", png],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> {:ok, png}
          _error -> :error
        end
    end
  end

  defp cache_dir, do: Path.join(Home.dir(), "cache")

  defp sprites_root,
    do: Application.get_env(:pokex, :sprites_root, "priv/static")
end
