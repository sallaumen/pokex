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
  # Hysteresis: a pixel is ink when it is strong on its own, OR merely weak but
  # CONNECTED to something strong. Lucas spotted why this matters — "acho que o
  # 0 está sendo quebrado em 2": a zero's vertical strokes are bright while its
  # curves fade over a busy background, so a single floor keeps the two bars and
  # drops the arcs that join them, and the glyph segments as two fragments. The
  # dark outline the client draws around its text is what keeps the weak pass
  # from leaking into the sprite behind it.
  # Measured: 20 is where every labelled region still segments correctly AND
  # the "404" that broke into five fragments over the potion sprite becomes
  # three digits. At 30 the weak pass starts welding neighbouring characters
  # together; at 0 the arcs are lost again.
  @weak_drop 20
  @atlas_key {:pokex, :glyph_atlas}
  @index_key {:pokex, :glyph_atlas_index}
  # A glyph drawn over a red pokeball and the SAME glyph over a yellow one
  # differ at their anti-aliased edges. Exact matching alone therefore loses
  # characters the instant an item sprite changes — which is what made Lucas's
  # stock counts and HP flicker to "?". Accept the closest known glyph of the
  # same shape when it is both close enough and clearly better than the
  # runner-up; anything else stays unknown.
  @max_diff_ratio 0.12
  @min_diff_slack 2

  @doc """
  Splits a region into glyphs, left to right.

  A glyph is a maximal run of columns containing ink; one fully empty column
  separates two glyphs. Each glyph carries its tight bitmap (rows trimmed) —
  the signature the atlas is keyed by.
  """
  def segment(%Frame{} = frame, {x, y, w, h}, opts \\ []) do
    # A region can outrun its frame — a battle row past the end of the list, a
    # layout located while the panel was mid-resize. Clamping keeps a bad rect
    # from taking a whole feed down; reading nothing is the honest answer.
    x = max(x, 0)
    y = max(y, 0)
    w = min(w, frame.width - x)
    h = min(h, frame.height - y)

    if w <= 0 or h <= 0 do
      []
    else
      do_segment(frame, {x, y, w, h}, opts)
    end
  end

  defp do_segment(%Frame{} = frame, {x, y, w, h}, opts) do
    strong = Keyword.get(opts, :ink, @default_ink)
    drop = Keyword.get(opts, :weak_drop, @weak_drop)
    cells = ink_cells(frame, {x, y, w, h}, strong, max(strong - drop, 40))

    0..(w - 1)//1
    |> Enum.map(fn i -> {x + i, Enum.filter(0..(h - 1)//1, &MapSet.member?(cells, {i, &1}))} end)
    |> Enum.chunk_by(fn {_cx, rows} -> rows != [] end)
    |> Enum.filter(fn [{_cx, rows} | _] -> rows != [] end)
    |> Enum.map(&to_glyph(&1, h))
  end

  # Strong pixels seed; weak pixels join only when they touch the growing blob.
  defp ink_cells(frame, {x, y, w, h}, strong_floor, weak_floor) do
    {strong, weak} =
      for j <- 0..(h - 1)//1, i <- 0..(w - 1)//1, reduce: {MapSet.new(), MapSet.new()} do
        {s, k} ->
          {r, g, b} = Frame.at(frame, x + i, y + j)
          lo = min(r, min(g, b))

          cond do
            max(r, max(g, b)) - lo > @max_spread -> {s, k}
            lo >= strong_floor -> {MapSet.put(s, {i, j}), k}
            lo >= weak_floor -> {s, MapSet.put(k, {i, j})}
            true -> {s, k}
          end
      end

    grow(MapSet.to_list(strong), strong, weak)
  end

  defp grow([], ink, _weak), do: ink

  defp grow([{i, j} | rest], ink, weak) do
    {joined, weak} =
      for di <- -1..1//1, dj <- -1..1//1, reduce: {[], weak} do
        {acc, remaining} ->
          neighbour = {i + di, j + dj}

          if MapSet.member?(remaining, neighbour),
            do: {[neighbour | acc], MapSet.delete(remaining, neighbour)},
            else: {acc, remaining}
      end

    grow(joined ++ rest, Enum.reduce(joined, ink, &MapSet.put(&2, &1)), weak)
  end

  defp to_glyph(columns, height) do
    {x0, _} = hd(columns)
    {x1, _} = List.last(columns)
    filled = Map.new(columns, fn {cx, rows} -> {cx, MapSet.new(rows)} end)

    bitmap =
      for row <- 0..(height - 1)//1 do
        for {cx, _} <- columns, do: if(MapSet.member?(filled[cx], row), do: 1, else: 0)
      end

    %{x0: x0, x1: x1, bitmap: trim_rows(bitmap)}
  end

  defp trim_rows(rows) do
    rows
    |> Enum.drop_while(&(Enum.sum(&1) == 0))
    |> Enum.reverse()
    |> Enum.drop_while(&(Enum.sum(&1) == 0))
    |> Enum.reverse()
  end

  @doc "The atlas key for a glyph bitmap: rows of 0/1, columns comma-joined, rows semicolon-joined."
  def signature(bitmap),
    do: bitmap |> Enum.map(&Enum.join(&1, ",")) |> Enum.join(";")

  @doc """
  The atlas in force: the shipped one, plus whatever Lucas has taught this
  install on top of it.

  The shipped atlas can only ever contain the characters that happened to be
  on screen when captures were taken — a digit he has never had in a slot is a
  digit the bot has never seen. Rather than wait for a new capture to reach a
  developer, the learned file lets him close the gap himself in seconds, and it
  survives updates because it is merged OVER the shipped atlas, never into it.
  """
  def atlas do
    case :persistent_term.get(@atlas_key, nil) do
      nil ->
        atlas = Map.merge(shipped_atlas(), learned_atlas())
        :persistent_term.put(@atlas_key, atlas)
        atlas

      atlas ->
        atlas
    end
  end

  defp shipped_atlas do
    Application.app_dir(:pokex, "priv/glyphs/atlas.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("glyphs")
  end

  defp learned_atlas do
    case File.read(learned_path()) do
      {:ok, body} -> body |> Jason.decode!() |> Map.get("glyphs", %{})
      _no_file -> %{}
    end
  end

  defp learned_path, do: Path.join(Pokex.Home.dir(), "glyphs_learned.json")

  @doc """
  Teaches this install one character. Returns the number of glyphs known.

  Refuses a signature the atlas already reads: silently redefining a known
  glyph is how a typo turns every future "8" into a "3".
  """
  def teach(signature, character)
      when is_binary(signature) and is_binary(character) and character != "" do
    if Map.has_key?(atlas(), signature) do
      {:error, :already_known}
    else
      learned = Map.put(learned_atlas(), signature, character)
      File.mkdir_p!(Pokex.Home.dir())
      File.write!(learned_path(), Jason.encode!(%{glyphs: learned}, pretty: true))
      clear()
      {:ok, map_size(atlas())}
    end
  end

  @doc """
  The glyphs in `region` this install cannot read — each with its bitmap, so a
  human can look at it and say what it is.
  """
  def unknown_in(%Frame{} = frame, region, opts \\ []) do
    atlas = atlas()

    frame
    |> segment(region, opts)
    |> Enum.filter(fn glyph -> lookup(glyph.bitmap, atlas) == nil end)
    |> Enum.map(fn glyph -> %{bitmap: glyph.bitmap, signature: signature(glyph.bitmap)} end)
    |> Enum.uniq_by(& &1.signature)
  end

  @doc "Drops the cached atlas (tests, and after `mix glyphs.learn`)."
  def clear do
    :persistent_term.erase(@atlas_key)
    :persistent_term.erase(@index_key)
  end

  # Glyphs grouped by shape, decoded once: the nearest-match pass only ever
  # compares bitmaps of identical dimensions.
  defp index do
    case :persistent_term.get(@index_key, nil) do
      nil ->
        index =
          Enum.group_by(
            Enum.map(atlas(), fn {sig, char} -> {decode(sig), char} end),
            fn {bitmap, _char} -> {length(bitmap), length(hd(bitmap))} end
          )

        :persistent_term.put(@index_key, index)
        index

      index ->
        index
    end
  end

  defp decode(signature) do
    signature
    |> String.split(";")
    |> Enum.map(fn row -> row |> String.split(",") |> Enum.map(&String.to_integer/1) end)
  end

  @doc false
  def lookup(bitmap, atlas) do
    case Map.get(atlas, signature(bitmap)) do
      nil -> nearest(bitmap)
      char -> char
    end
  end

  defp nearest(bitmap) do
    shape = {length(bitmap), length(hd(bitmap))}
    cells = elem(shape, 0) * elem(shape, 1)
    ceiling = max(@min_diff_slack, round(cells * @max_diff_ratio))

    index()
    |> Map.get(shape, [])
    |> Enum.map(fn {candidate, char} -> {char, difference(bitmap, candidate)} end)
    |> Enum.sort_by(&elem(&1, 1))
    |> case do
      [{char, best} | rest] ->
        # a near tie means two glyphs explain the pixels equally well — refuse
        runner_up = rest |> Enum.map(&elem(&1, 1)) |> List.first()

        if best <= ceiling and (runner_up == nil or runner_up > best + @min_diff_slack),
          do: char,
          else: nil

      [] ->
        nil
    end
  end

  defp difference(a, b) do
    Enum.zip(a, b)
    |> Enum.reduce(0, fn {row_a, row_b}, acc ->
      acc + Enum.count(Enum.zip(row_a, row_b), fn {x, y} -> x != y end)
    end)
  end

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
          case lookup(g.bitmap, atlas) do
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
end
