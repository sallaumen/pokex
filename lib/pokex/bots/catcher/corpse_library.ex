defmodule Pokex.Bots.Catcher.CorpseLibrary do
  @moduledoc """
  TAUGHT corpses — since 2026-07-30 the library IS the aim (the guessing mode was
  retired): only candidates SIMILAR to a taught corpse get a Pokéball; empty
  library = no target. Lucas photographs the real on-screen corpse and names it.

  Matching is by COLOR SIGNATURE (RGB histogram quantized to 512 cubes,
  normalized intersection 0..1), not exact pixels: the corpse composites over
  varying ground, so exact equality would never match — but the sprite's palette
  dominates the crop. Threshold is a setting (`corpse_match_min_similarity`).

  Each corpse keeps up to `@max_samples` SAMPLES (the same Pokémon over different
  grounds — ground is the histogram noise; matching against the BEST sample
  restores the precision a single crop lacks). Re-teaching a name adds a sample
  (oldest drops past the cap).

  No process: `~/.pokex/corpses.json` is the truth, with a `:persistent_term`
  cache keyed by mtime to avoid re-reading per candidate. Crops are raw rgba in
  base64; thumbnails are uncompressed 24bpp BMP data-URLs — no PNG encoder.
  """

  alias Pokex.Home
  alias Pokex.Vision.Frame

  @cache_key {__MODULE__, :cache}
  @max_samples 3

  def max_samples, do: @max_samples

  def file, do: Path.join(Home.dir(), "corpses.json")

  @doc "All taught corpses, newest first."
  def list do
    library().entries
  end

  def empty?, do: list() == []

  @doc "Teaches a corpse: the crop (Frame) joins the library under the given name."
  def add(name, %Frame{} = crop) when is_binary(name) do
    name = String.trim(name)

    if name == "" do
      {:error, :empty_name}
    else
      sample = %{
        "w" => crop.width,
        "h" => crop.height,
        "rgba" => Base.encode64(crop.rgba),
        "added_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      slug = slug(name)
      {existing, others} = Enum.split_with(raw_entries(), &(&1["slug"] == slug))

      samples =
        case existing do
          [entry | _] -> Enum.take([sample | entry["samples"]], @max_samples)
          [] -> [sample]
        end

      # re-teaching must not re-enable a corpse that was deliberately disabled
      ligado? = Enum.all?(existing, &enabled?/1)

      persist([
        %{"name" => name, "slug" => slug, "samples" => samples, "enabled" => ligado?} | others
      ])

      {:ok, length(samples)}
    end
  end

  def delete(slug) do
    persist(Enum.reject(raw_entries(), &(&1["slug"] == slug)))
    :ok
  end

  @doc """
  Enables/disables a corpse in the aim WITHOUT deleting it (2026-07-30 request):
  a false-positive corpse leaves the search with one click and comes back with
  another — before, deleting the samples and re-photographing was the only way.
  """
  def set_enabled(slug, ligado?) when is_boolean(ligado?) do
    entries =
      Enum.map(raw_entries(), fn
        %{"slug" => ^slug} = entry -> Map.put(entry, "enabled", ligado?)
        outro -> outro
      end)

    persist(entries)
    :ok
  end

  @doc "Deletes ONE sample (a bad photo); dropping the last sample removes the whole corpse."
  def delete_sample(slug, index) do
    entries =
      raw_entries()
      |> Enum.map(fn
        %{"slug" => ^slug} = entry ->
          %{entry | "samples" => List.delete_at(entry["samples"], index)}

        entry ->
          entry
      end)
      |> Enum.reject(&(&1["samples"] == []))

    persist(entries)
    :ok
  end

  @doc """
  Sample thumbnail as a BMP data-URL (24bpp uncompressed, bottom-up rows, lines
  4-byte aligned) — the browser renders it without this project carrying a PNG
  encoder.
  """
  def thumb(%{"w" => w, "h" => h, "rgba" => rgba_b64}) do
    rgba = Base.decode64!(rgba_b64)
    row_size = div(w * 3 + 3, 4) * 4
    data_size = row_size * h

    rows =
      for y <- (h - 1)..0//-1, into: <<>> do
        row =
          for x <- 0..(w - 1), into: <<>> do
            <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
            <<b, g, r>>
          end

        row <> :binary.copy(<<0>>, row_size - w * 3)
      end

    bmp =
      <<"BM", 14 + 40 + data_size::little-32, 0::32, 54::little-32, 40::little-32, w::little-32,
        h::little-32, 1::little-16, 24::little-16, 0::little-32, data_size::little-32,
        2835::little-32, 2835::little-32, 0::little-32, 0::little-32>> <> rows

    "data:image/bmp;base64," <> Base.encode64(bmp)
  end

  @doc """
  Best match of the crop against the library: `{:ok, %{name, score}}` when a
  taught corpse passes the threshold, `:nomatch` otherwise (including an empty
  library — the caller decides what to do then).
  """
  def match(%Frame{} = crop, min_similarity) do
    case best(crop) do
      %{score: score} = info when score >= min_similarity -> {:ok, info}
      _abaixo_ou_vazio -> :nomatch
    end
  end

  @doc """
  Best `%{name, score}` in the library for this crop — NO threshold; `nil` only
  when the library is empty. A FAILING score is still information: `match/2`'s
  `:nomatch` hid whether it missed by 0.01 or 0.40, and against which Pokémon
  (blind validation, 2026-07-30). Measured on real samples the score drops ~0.05
  per 7px of crop offset, so distance to the threshold IS the aim diagnostic.
  """
  def best(%Frame{} = crop), do: crop.rgba |> signature() |> best_of()

  @doc """
  Same as `best/1` for a WINDOW inside a larger frame — no crop allocation.
  The dense scan (`Catcher.SpotScan`) scores hundreds of windows per sweep;
  `Frame.crop` on each would copy hundreds of binaries just to discard them.
  Window rows are no-copy sub-binaries summed straight into the histogram.
  `{x, y}` is the top-left in frame px; out of bounds returns `nil`, so scanners
  need no border checks.
  """
  def best_in(%Frame{width: fw, height: fh} = frame, {x, y, w, h})
      when x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= fw and y + h <= fh do
    frame |> window_signature(x, y, w, h) |> best_of()
  end

  def best_in(_frame, _window_outside), do: nil

  defp best_of(sig) do
    library().signatures
    |> Enum.map(fn {name, ref_sigs} ->
      {name, ref_sigs |> Enum.map(&intersection(sig, &1)) |> Enum.max(fn -> 0.0 end)}
    end)
    |> Enum.max_by(fn {_name, score} -> score end, fn -> nil end)
    |> case do
      {name, score} -> %{name: name, score: score}
      nil -> nil
    end
  end

  defp window_signature(%Frame{width: fw, rgba: rgba}, x0, y0, w, h) do
    counts =
      Enum.reduce(y0..(y0 + h - 1), %{}, fn y, acc ->
        skip = (y * fw + x0) * 4
        <<_::binary-size(skip), line::binary-size(w * 4), _rest::binary>> = rgba
        count_bins(line, acc)
      end)

    normalize(counts, w * h)
  end

  # RGB histogram quantized to 3 bits/channel (512 cubes), normalized to sum
  # 1.0 — crop size doesn't weigh in the match.
  defp signature(rgba), do: normalize(count_bins(rgba, %{}), byte_size(rgba) / 4)

  defp normalize(counts, total) do
    total = max(total, 1)
    Map.new(counts, fn {bin, n} -> {bin, n / total} end)
  end

  defp count_bins(<<r, g, b, _a, rest::binary>>, acc) do
    bin =
      Bitwise.bor(
        Bitwise.bor(Bitwise.bsl(Bitwise.bsr(r, 5), 6), Bitwise.bsl(Bitwise.bsr(g, 5), 3)),
        Bitwise.bsr(b, 5)
      )

    count_bins(rest, Map.update(acc, bin, 1, &(&1 + 1)))
  end

  defp count_bins(_tail, acc), do: acc

  # Histogram intersection: sum of minima — 1.0 = identical palettes.
  defp intersection(a, b) do
    Enum.reduce(a, 0.0, fn {bin, va}, acc -> acc + min(va, Map.get(b, bin, 0.0)) end)
  end

  defp library do
    # Posix mtime has 1s granularity — two writes in the SAME second
    # (back-to-back tests, quick manual edits) would collide; size breaks the tie.
    stamp = file_stamp()

    case :persistent_term.get(@cache_key, nil) do
      %{stamp: ^stamp} = cache ->
        cache

      _stale_ou_nada ->
        entries = raw_entries()

        cache = %{
          stamp: stamp,
          entries: entries,
          # Only ENABLED corpses join the aim. `entries` stays whole so the UI
          # shows disabled ones — disabling filters the search, it doesn't
          # delete. This is the ONE point where matching sees the library.
          signatures:
            entries
            |> Enum.filter(&enabled?/1)
            |> Enum.map(fn e ->
              {e["name"], Enum.map(e["samples"], &signature(Base.decode64!(&1["rgba"])))}
            end)
        }

        :persistent_term.put(@cache_key, cache)
        cache
    end
  end

  defp raw_entries do
    with {:ok, body} <- File.read(file()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      Enum.map(entries, &migrate/1)
    else
      _no_library -> []
    end
  end

  # The #101 format flattened ONE sample into the record top level. Reads both;
  # always writes the new format.
  defp migrate(%{"samples" => _} = entry), do: Map.put_new(entry, "enabled", true)

  defp migrate(%{"rgba" => _} = entry) do
    sample = Map.take(entry, ["w", "h", "rgba", "added_at"])

    entry
    |> Map.drop(["w", "h", "rgba", "added_at"])
    |> Map.put("samples", [sample])
    |> Map.put_new("enabled", true)
  end

  @doc "Is this corpse participating in the aim? (old entries without the field participate)"
  def enabled?(%{"enabled" => false}), do: false
  def enabled?(_entry), do: true

  defp persist(entries) do
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), Jason.encode!(entries, pretty: true))
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp file_stamp do
    case File.stat(file(), time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _no_file -> nil
    end
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
