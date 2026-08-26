defmodule Pokex.Vision.SpriteLibrary do
  @moduledoc """
  A library of TAUGHT sprites: he photographs something on screen, names it, and
  from then on the bot can recognise it.

  This is the machine `Pokex.Bots.Catcher.CorpseLibrary` was, generalised — the
  corpses were the first thing worth teaching and are no longer the only one.
  Each library is a FILE, and that separation is not cosmetic: teaching his own
  pokémon into the corpse library would have the Catcher throw balls at it.

  Matching is by COLOR SIGNATURE (RGB histogram quantized to 512 cubes,
  normalized intersection 0..1), not exact pixels: a sprite composites over
  varying ground, so exact equality would never match — but its palette
  dominates the crop.

  Each name keeps up to `max_samples` SAMPLES — the same thing seen over
  different grounds, or from different angles. Ground and angle are the
  histogram's noise; matching against the BEST sample restores the precision a
  single crop lacks. Re-teaching a name adds a sample (oldest drops past the
  cap).

  No process: the JSON file is the truth, with a `:persistent_term` cache keyed
  by the file's mtime AND size — posix mtime has 1-second granularity, so two
  writes in the same second (back-to-back tests, quick edits) would collide.
  Crops are raw rgba in base64; thumbnails are uncompressed 24bpp BMP data-URLs,
  so this project carries no PNG encoder.
  """

  alias Pokex.Vision.{Evidence, Frame}

  @type t :: %{file: String.t(), max_samples: pos_integer, cache_key: term}

  @doc """
  Declares a library over `file`. `max_samples` caps how many photos one name
  keeps.
  """
  @spec new(String.t(), pos_integer) :: t
  def new(file, max_samples) when is_binary(file) and is_integer(max_samples) do
    %{file: file, max_samples: max_samples, cache_key: {__MODULE__, file}}
  end

  @doc "All taught entries, newest first."
  @spec list(t) :: [map]
  def list(lib), do: cache(lib).entries

  @spec empty?(t) :: boolean
  def empty?(lib), do: list(lib) == []

  @doc """
  Teaches one crop under `name`. `opts[:painted?]` marks a hand-made stand-in
  (see `Pokex.Vision.Recolor`) — it aims like any other sample; the flag exists
  so the page can say which entries are guesses.
  """
  @spec add(t, String.t(), Frame.t(), keyword) :: {:ok, pos_integer} | {:error, :empty_name}
  def add(lib, name, %Frame{} = crop, opts \\ []) when is_binary(name) do
    name = String.trim(name)

    if name == "" do
      {:error, :empty_name}
    else
      sample = %{
        "w" => crop.width,
        "h" => crop.height,
        "rgba" => Base.encode64(crop.rgba),
        "added_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "painted" => Keyword.get(opts, :painted?, false) == true
      }

      slug = slug(name)
      {existing, others} = Enum.split_with(raw_entries(lib), &(&1["slug"] == slug))

      samples =
        case existing do
          [entry | _] -> Enum.take([sample | entry["samples"]], lib.max_samples)
          [] -> [sample]
        end

      # re-teaching must not re-enable something that was deliberately disabled
      on? = Enum.all?(existing, &enabled?/1)

      persist(lib, [
        %{"name" => name, "slug" => slug, "samples" => samples, "enabled" => on?} | others
      ])

      {:ok, length(samples)}
    end
  end

  @doc """
  Renames an entry, keeping its samples and its switch.

  A name typed wrong is not cosmetic here: the corpse's name is what the ball
  rules match on, so "Shiny Craby" silently answered to no rule written for
  Krabby. Deleting and re-teaching would cost the photographs — and the whole
  point of a real shiny corpse is that he may never get another.
  """
  @spec rename(t, String.t(), String.t()) :: {:ok, String.t()} | {:error, :empty_name | :taken}
  def rename(lib, slug, new_name) do
    name = String.trim(new_name)
    novo_slug = slug(name)
    entries = raw_entries(lib)

    cond do
      name == "" ->
        {:error, :empty_name}

      novo_slug != slug and Enum.any?(entries, &(&1["slug"] == novo_slug)) ->
        {:error, :taken}

      true ->
        persist(
          lib,
          Enum.map(entries, fn
            %{"slug" => ^slug} = entry -> %{entry | "name" => name, "slug" => novo_slug}
            other -> other
          end)
        )

        {:ok, novo_slug}
    end
  end

  @spec delete(t, String.t()) :: :ok
  def delete(lib, slug) do
    persist(lib, Enum.reject(raw_entries(lib), &(&1["slug"] == slug)))
  end

  @doc """
  Takes one entry out of the AIM without deleting it: a false positive leaves
  the search with one click and comes back with another, instead of having to
  delete the samples and re-photograph.
  """
  @spec set_enabled(t, String.t(), boolean) :: :ok
  def set_enabled(lib, slug, on?) when is_boolean(on?) do
    entries =
      Enum.map(raw_entries(lib), fn
        %{"slug" => ^slug} = entry -> Map.put(entry, "enabled", on?)
        other -> other
      end)

    persist(lib, entries)
  end

  @doc "Deletes ONE sample (a bad photo); dropping the last one removes the entry."
  @spec delete_sample(t, String.t(), non_neg_integer) :: :ok
  def delete_sample(lib, slug, index) do
    entries =
      raw_entries(lib)
      |> Enum.map(fn
        %{"slug" => ^slug} = entry ->
          %{entry | "samples" => List.delete_at(entry["samples"], index)}

        entry ->
          entry
      end)
      |> Enum.reject(&(&1["samples"] == []))

    persist(lib, entries)
  end

  @doc "Is this entry participating in the aim? (old entries without the field do)"
  @spec enabled?(map) :: boolean
  def enabled?(%{"enabled" => false}), do: false
  def enabled?(_entry), do: true

  @doc """
  Sample thumbnail as a BMP data-URL (24bpp uncompressed, bottom-up rows, lines
  4-byte aligned) — the browser renders it without a PNG encoder here.
  """
  @spec thumb(map) :: String.t()
  def thumb(%{"w" => w, "h" => h, "rgba" => rgba_b64}) do
    rgba = Base.decode64!(rgba_b64)

    Evidence.bmp(w, h, fn x, y ->
      <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
      {r, g, b}
    end)
  end

  @doc """
  Best match of the crop: `{:ok, %{name, score, aimed?}}` above the threshold,
  `:nomatch` otherwise — which now covers three different things: nothing was
  close enough, the library is empty, OR the closest taught body is one he
  switched OFF. That last one is a VETO, not an absence: it is how he says "I
  know this creature and I do not want it".
  """
  @spec match(t, Frame.t(), float) :: {:ok, map} | :nomatch
  def match(lib, %Frame{} = crop, min_similarity) do
    case best(lib, crop) do
      %{score: score, aimed?: true} = info when score >= min_similarity -> {:ok, info}
      _below_or_vetoed_or_empty -> :nomatch
    end
  end

  @doc """
  Best `%{name, score}` for this crop — NO threshold; `nil` only when the
  library is empty.

  A FAILING score is still information: `:nomatch` hides whether it missed by
  0.01 or by 0.40, and against which entry. Measured on real samples the score
  drops ~0.05 per 7px of crop offset, so the distance to the threshold IS the
  aim diagnostic.
  """
  @spec best(t, Frame.t()) :: map | nil
  def best(lib, %Frame{} = crop), do: crop.rgba |> signature() |> best_of(lib)

  @doc """
  Same as `best/2` for a WINDOW inside a larger frame — no crop allocation.

  A dense scan scores hundreds of windows per sweep; cropping each would copy
  hundreds of binaries just to discard them. Window rows are no-copy
  sub-binaries summed straight into the histogram. `{x, y}` is the top-left in
  frame px; out of bounds returns `nil`, so scanners need no border checks.
  """
  @spec best_in(t, Frame.t(), {integer, integer, pos_integer, pos_integer}) :: map | nil
  def best_in(lib, %Frame{width: fw, height: fh} = frame, {x, y, w, h})
      when x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= fw and y + h <= fh do
    frame |> window_signature(x, y, w, h) |> best_of(lib)
  end

  def best_in(_lib, _frame, _window_outside), do: nil

  defp best_of(sig, lib) do
    cache(lib).signatures
    |> Enum.map(fn {name, ref_sigs, aimed?} ->
      {name, ref_sigs |> Enum.map(&intersection(sig, &1)) |> Enum.max(fn -> 0.0 end), aimed?}
    end)
    |> Enum.max_by(fn {_name, score, _aimed?} -> score end, fn -> nil end)
    |> case do
      {name, score, aimed?} -> %{name: name, score: score, aimed?: aimed?}
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

  defp cache(lib) do
    stamp = file_stamp(lib)

    case :persistent_term.get(lib.cache_key, nil) do
      %{stamp: ^stamp} = cache ->
        cache

      _stale_or_absent ->
        entries = raw_entries(lib)

        cache = %{
          stamp: stamp,
          entries: entries,
          # EVERY entry competes, aimed or not. A disabled one used to be dropped
          # from the search, which quietly made it impossible to say "I know this
          # creature and I do NOT want it": with only the shiny taught, a normal
          # Krabby corpse had nowhere else to land and matched the shiny at 0.8+
          # (measured on his library, 2026-08-11: a self-match scores 1.0 and the
          # nearest different creature 0.78 — the margin that makes this work).
          # Now the closest taught body wins, and winning while disabled is a
          # VETO: known, and deliberately not a target.
          signatures:
            Enum.map(entries, fn e ->
              {e["name"], Enum.map(e["samples"], &signature(Base.decode64!(&1["rgba"]))),
               enabled?(e)}
            end)
        }

        :persistent_term.put(lib.cache_key, cache)
        cache
    end
  end

  defp raw_entries(lib) do
    with {:ok, body} <- File.read(lib.file),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      Enum.map(entries, &migrate/1)
    else
      _no_library -> []
    end
  end

  # The oldest format flattened ONE sample into the record top level. Reads
  # both; always writes the new one.
  defp migrate(%{"samples" => _} = entry), do: Map.put_new(entry, "enabled", true)

  defp migrate(%{"rgba" => _} = entry) do
    sample = Map.take(entry, ["w", "h", "rgba", "added_at"])

    entry
    |> Map.drop(["w", "h", "rgba", "added_at"])
    |> Map.put("samples", [sample])
    |> Map.put_new("enabled", true)
  end

  defp persist(lib, entries) do
    File.mkdir_p!(Path.dirname(lib.file))
    File.write!(lib.file, Jason.encode!(entries, pretty: true))
    :persistent_term.erase(lib.cache_key)
    :ok
  end

  defp file_stamp(lib) do
    case File.stat(lib.file, time: :posix) do
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
