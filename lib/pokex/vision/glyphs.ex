defmodule Pokex.Vision.Glyphs do
  @moduledoc """
  Deterministic bitmap-font reader — the eye that turns pixels into text.

  The PXG client draws every label, name and number with a fixed bitmap font:
  a given character is ALWAYS the same pixels. So reading is exact matching
  against a learned atlas (`priv/glyphs/atlas.json`, built by `mix
  glyphs.learn` from the labeled real captures) — no OCR, no dependency, no
  guessing, and a client font change breaks the tests loudly instead of
  silently feeding the bot lies.

  ## What counts as ink

  Measured on the real capture: game text is NEUTRAL and bright — pure white
  (255,255,255) in the HUD, grey (136,136,136) for an idle battle-list row —
  while the bars and sprites around it are saturated (the HP bar is
  (100,240,100)). So ink = "bright AND neutral", which excludes every coloured
  bar by construction.

  The brightness floor is per region (`:ink`, default #{120}) because the HUD's
  slot counts sit ON TOP of bright item sprites: a loose floor lets the
  pokeball's grey highlights merge with the digits. The layout profile and the
  label file declare the floor each region needs.
  """

  alias Pokex.Vision.Frame

  @default_ink 120
  @max_spread 60
  @atlas_key {:pokex, :glyph_atlas}

  @doc """
  Splits a region into glyphs, left to right.

  A glyph is a maximal run of columns containing ink; one fully empty column
  separates two glyphs. Each glyph carries its tight bitmap (rows trimmed) —
  the signature the atlas is keyed by.
  """
  def segment(%Frame{} = frame, {x, y, w, h}, opts \\ []) do
    ink = Keyword.get(opts, :ink, @default_ink)

    x..(x + w - 1)//1
    |> Enum.map(fn cx -> {cx, Enum.map(y..(y + h - 1)//1, &ink?(frame, cx, &1, ink))} end)
    |> Enum.chunk_by(fn {_cx, col} -> Enum.any?(col) end)
    |> Enum.filter(fn [{_cx, col} | _] -> Enum.any?(col) end)
    |> Enum.map(&to_glyph/1)
  end

  defp to_glyph(columns) do
    {x0, _} = hd(columns)
    {x1, _} = List.last(columns)

    bitmap =
      columns
      |> Enum.map(fn {_cx, col} -> col end)
      |> transpose()
      |> trim_rows()

    %{x0: x0, x1: x1, bitmap: bitmap}
  end

  defp transpose(columns), do: columns |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  defp trim_rows(rows) do
    rows
    |> Enum.drop_while(&(not Enum.any?(&1)))
    |> Enum.reverse()
    |> Enum.drop_while(&(not Enum.any?(&1)))
    |> Enum.reverse()
    |> Enum.map(fn row -> Enum.map(row, &if(&1, do: 1, else: 0)) end)
  end

  @doc "The atlas key for a glyph bitmap: rows of 0/1, columns comma-joined, rows semicolon-joined."
  def signature(bitmap),
    do: bitmap |> Enum.map(&Enum.join(&1, ",")) |> Enum.join(";")

  @doc "The learned atlas (signature => character), cached in :persistent_term."
  def atlas do
    case :persistent_term.get(@atlas_key, nil) do
      nil ->
        atlas =
          Application.app_dir(:pokex, "priv/glyphs/atlas.json")
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("glyphs")

        :persistent_term.put(@atlas_key, atlas)
        atlas

      atlas ->
        atlas
    end
  end

  @doc "Drops the cached atlas (tests, and after `mix glyphs.learn`)."
  def clear, do: :persistent_term.erase(@atlas_key)

  @doc """
  Reads a line of text. `confidence` is the share of glyphs the atlas knew;
  an unknown glyph renders as `?` so the lexicon can still close the word.
  """
  def read_line(%Frame{} = frame, region, opts \\ []) do
    glyphs = segment(frame, region, opts)
    atlas = atlas()
    gap = space_gap(glyphs)

    {chars, known} =
      glyphs
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.reduce({[], 0}, fn [g, next], {acc, known} ->
        {char, known} =
          case Map.get(atlas, signature(g.bitmap)) do
            nil -> {"?", known}
            char -> {char, known + 1}
          end

        {[maybe_space(g, next, gap), char | acc], known}
      end)

    %{text: chars |> Enum.reverse() |> Enum.join(), confidence: confidence(known, glyphs)}
  end

  @doc "An integer, or nil when anything at all was uncertain — never a guess."
  def read_int(%Frame{} = frame, region, opts \\ []) do
    case read_line(frame, region, opts) do
      %{text: text, confidence: 1.0} ->
        if Regex.match?(~r/^\d+$/, text), do: String.to_integer(text), else: nil

      _uncertain ->
        nil
    end
  end

  @doc ~S'The minimap coordinate: "(337, 46107, 4)" -> {337, 46107, 4}, or nil.'
  def read_coord(%Frame{} = frame, region, opts \\ []) do
    case read_line(frame, region, opts) do
      %{text: text, confidence: 1.0} ->
        case Regex.run(~r/^\((\d+),\s?(\d+),\s?(\d+)\)$/, text) do
          [_all, x, y, z] -> {String.to_integer(x), String.to_integer(y), String.to_integer(z)}
          nil -> nil
        end

      _uncertain ->
        nil
    end
  end

  @doc """
  A pokémon name read from the screen, closed against the lexicon.

  This is why an unknown glyph renders `?` instead of failing: "Pi?geot" still
  resolves to Pidgeot, because only one name in the dex is within reach. An
  ambiguous read (two names equally close) returns nil — a wrong name is worse
  than no name, since combos and the shiny guard act on it.
  """
  def read_name(%Frame{} = frame, region, lexicon, opts \\ []) do
    frame |> read_line(region, opts) |> Map.fetch!(:text) |> closest_name(lexicon)
  end

  @doc "The lexicon entry a raw reading means, or nil when unknown or ambiguous."
  def closest_name(raw, lexicon) do
    down = raw |> String.trim() |> String.downcase()

    cond do
      exact = Enum.find(lexicon, &(String.downcase(&1) == down)) -> exact
      too_unknown?(down) -> nil
      true -> nearest(down, lexicon)
    end
  end

  # The lexicon closes small gaps; it must never invent a whole word. An
  # all-wildcard reading would otherwise "match" whatever name happens to have
  # the same length — a confident lie built from nothing.
  defp too_unknown?(down) do
    unknown = down |> String.graphemes() |> Enum.count(&(&1 == "?"))
    unknown > 2 or unknown * 2 > String.length(down)
  end

  defp nearest(_down, []), do: nil

  defp nearest(down, lexicon) do
    graphemes = String.graphemes(down)

    lexicon
    |> Enum.map(&{&1, distance(graphemes, String.graphemes(String.downcase(&1)))})
    |> Enum.filter(fn {_name, d} -> d <= 2 end)
    |> Enum.sort_by(&elem(&1, 1))
    |> case do
      [{name, d} | rest] ->
        if Enum.any?(rest, fn {_n, other} -> other == d end), do: nil, else: name

      [] ->
        nil
    end
  end

  # Levenshtein, with `?` (an unread glyph) matching any character for free.
  defp distance(a, b) do
    Enum.reduce(Enum.with_index(a, 1), Enum.to_list(0..length(b)), fn {ca, i}, previous ->
      {row, _} =
        Enum.reduce(Enum.with_index(b, 1), {[i], previous}, fn {cb, j}, {row, prev} ->
          cost = if ca == cb or ca == "?", do: 0, else: 1

          value =
            [hd(row) + 1, Enum.at(prev, j) + 1, Enum.at(prev, j - 1) + cost]
            |> Enum.min()

          {[value | row], prev}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end

  defp confidence(_known, []), do: 0.0
  defp confidence(known, glyphs), do: known / length(glyphs)

  # A gap wider than 1.6x the typical inter-glyph gap is a space. With fewer
  # than 3 glyphs there is no "typical" — never invent a space.
  defp space_gap(glyphs) when length(glyphs) < 3, do: nil

  defp space_gap(glyphs) do
    gaps =
      glyphs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b.x0 - a.x1 end)
      |> Enum.sort()

    Enum.at(gaps, div(length(gaps), 2)) * 1.6
  end

  defp maybe_space(_g, nil, _gap), do: ""
  defp maybe_space(_g, _next, nil), do: ""
  defp maybe_space(g, next, gap), do: if(next.x0 - g.x1 > gap, do: " ", else: "")

  defp ink?(%Frame{width: w, rgba: rgba}, x, y, floor) do
    <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
    lo = min(r, min(g, b))
    lo >= floor and max(r, max(g, b)) - lo <= @max_spread
  end
end
