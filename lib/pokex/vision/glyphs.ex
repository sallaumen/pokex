defmodule Pokex.Vision.Glyphs do
  @moduledoc """
  Deterministic bitmap-font reader — the eye that turns pixels into text.

  The PokeTibia client draws every label, name and number with a fixed bitmap font:
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

  ## What counts as BACKGROUND

  "Bright AND neutral" is not enough over the MINIMAP. Measured on the real
  captures: the minimap is drawn in greyscale (saturation 0 on nearly every
  pixel of the coordinate band), so the colour test filters nothing there, and
  9-10% of the map's pixels — the lit walkable floor, measured at 140..159 —
  clear the 120 floor and count as ink. The `minimap_coord` band is 30px tall
  for 20px of text, so its margin rows are pure map: walk onto lit ground and
  those rows fill with ink, no column of the band is empty any more, and the
  "one empty column separates two glyphs" rule finds no separator at all. The
  whole coordinate then comes out as ONE glyph — the giant rectangle Lucas found
  on the teach screen, flanked by a few 2-3 pixel crumbs.

  What the client does give us is a dark outline (measured at 14..17) around
  every character, so leaked map NEVER touches the text — it is a blob of its
  own. `segment/3` therefore drops background blobs BEFORE projecting onto
  columns; see `drop_background/1`.
  """

  alias Pokex.Vision.Frame

  @default_ink 120
  @max_spread 60
  # Hysteresis: a pixel is ink when it is strong on its own, OR merely weak but
  # CONNECTED to something strong. Lucas spotted why this matters — "the 0 is
  # getting broken into 2": a zero's vertical strokes are bright while its
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
  # A character rendered over BRIGHT terrain loses columns the taught shape
  # had: measured 2026-08-10 on Lucas's screen, the "0" of 30439 came out 15x10
  # against the atlas's 15x12 — its curves fade first, straight strokes do not.
  # Comparing across widths costs pixels by construction (every padded column
  # is a difference), so those comparisons get a wider ceiling AND must beat
  # the nearest OTHER character by a clear margin — measured on that very "0":
  # 20 against its own shape, 43 against the closest stranger.
  @padded_diff_ratio 0.2
  @runner_up_factor 1.8
  @max_width_slack 2
  # Measured over the whole atlas: the smallest character the client draws is
  # the comma, at 14 ink pixels. The crumbs the minimap leaves behind are 1-3.
  # Anything under this is not a character in any font we read.
  @min_glyph_ink 4

  @doc """
  Splits a region into glyphs, left to right.

  A glyph is a maximal run of columns containing ink; one fully empty column
  separates two glyphs. Each glyph carries its tight bitmap (rows trimmed) —
  the signature the atlas is keyed by.

  Background that leaked in (see the moduledoc) is discarded first, so a strip
  of lit map cannot bridge one character into the next.
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

    cells =
      frame
      |> ink_cells({x, y, w, h}, strong, max(strong - drop, 40))
      |> drop_background()

    0..(w - 1)//1
    |> Enum.map(fn i -> {x + i, Enum.filter(0..(h - 1)//1, &MapSet.member?(cells, {i, &1}))} end)
    |> Enum.chunk_by(fn {_cx, rows} -> rows != [] end)
    |> Enum.filter(fn [{_cx, rows} | _] -> rows != [] end)
    |> Enum.map(&to_glyph(&1, h))
  end

  # Throws away the ink that is not text, so the column projection above sees
  # the separators again. Deliberately conservative: when nothing is dropped the
  # cells come back untouched and segmentation is bit-for-bit what it always
  # was — every HUD, HP and battle-list reading is unaffected by construction.
  #
  # Three rules, all measured:
  #
  #   1. a blob under `@min_glyph_ink` pixels is a crumb, never a character;
  #   2. a blob larger than any character CAN be is background by
  #      IMPOSSIBILITY, whatever rows it shares with the text. The tallest
  #      glyph in any atlas is 21 rows and a welded pair runs ~25 columns; a
  #      blob far beyond either is terrain. The 2026-08-10 field case: the
  #      hover label rendered half over GREY unexplored map (140-159 — bright
  #      AND neutral, so it IS ink), and the terrain formed one huge blob
  #      sharing the text's rows — the band rule below cannot touch those, so
  #      "(2396, 30621," welded into a single 35x134 "glyph".
  #   3. a blob that sits OUTSIDE the text band is only kept while it cannot
  #      BRIDGE two characters. The band is the rows the characters share, which
  #      the map cannot fake: a line of text puts many blobs on the same rows,
  #      while leaked map is alone on the margin rows it arrived in.
  #
  # Rule 3 discards nothing but bridges. A blob outside the band that lives over
  # a single character is kept — that is what the dot of an "i" looks like, and
  # dropping it would silently redraw a glyph the atlas already knows. The test
  # is applied one blob at a time against what has been accepted so far, because
  # two crumbs that are each innocent alone can close a gap together.
  defp drop_background(cells) do
    blobs =
      cells
      |> blobs()
      |> Enum.reject(&(MapSet.size(&1) < @min_glyph_ink or impossible_glyph?(&1)))

    band = text_band(blobs)

    {text, stray} =
      blobs
      |> Enum.reject(&overhangs?(&1, band))
      |> Enum.split_with(&in_band?(&1, band))

    (text ++ admit(stray, columns_of(text)))
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1))
  end

  # A character pokes past the band only a little: digits dominate the band's
  # rows and the parentheses — the tallest thing on a coordinate line — stick
  # out ~2 rows per side; the dot of an "i" sits fully outside (the stray case
  # below, untouched here). Terrain that touches the text's rows dodges the
  # stray rule entirely, but it stretches FAR beyond the band — the 2026-08-10
  # remnant welded "621" while overshooting the band by ~12 rows. More than 6
  # rows of total overshoot is nothing a character ever does.
  @max_band_overhang 6

  defp overhangs?(_blob, nil), do: false

  defp overhangs?(blob, {top, bottom}) do
    {blob_top, blob_bottom} = span(blob, 1)
    max(top - blob_top, 0) + max(blob_bottom - bottom, 0) > @max_band_overhang
  end

  # Caps sit ABOVE every real shape with margin (atlas max: 21 rows, ~16 cols;
  # welded pairs ~25 cols), so no readable character is ever near them. If a
  # 2x-scale era ever comes, the atlas gets re-taught and these move with it.
  @max_glyph_rows 26
  @max_glyph_cols 40

  defp impossible_glyph?(blob) do
    {top, bottom} = span(blob, 1)
    {left, right} = span(blob, 0)
    bottom - top + 1 > @max_glyph_rows or right - left + 1 > @max_glyph_cols
  end

  # Accepts the strays that leave the number of column runs unchanged. Biggest
  # first, so the blob most likely to be part of a character wins the gap.
  defp admit(strays, columns) do
    strays
    |> Enum.sort_by(fn blob -> {-MapSet.size(blob), elem(span(blob, 0), 0)} end)
    |> Enum.reduce({[], columns}, fn blob, {kept, columns} ->
      if bridges?(blob, columns),
        do: {kept, columns},
        else: {[blob | kept], MapSet.union(columns, columns_of([blob]))}
    end)
    |> elem(0)
  end

  defp bridges?(blob, columns) do
    {left, right} = span(blob, 0)
    columns |> runs() |> Enum.count(fn {a, b} -> a <= right + 1 and left - 1 <= b end) > 1
  end

  defp columns_of(blobs) do
    for blob <- blobs, {column, _row} <- blob, into: MapSet.new(), do: column
  end

  # The contiguous column ranges — the very runs the projection below turns into
  # glyphs. One empty column between them is what keeps two characters apart.
  defp runs(columns) do
    case Enum.sort(columns) do
      [] ->
        []

      [first | rest] ->
        rest
        |> Enum.reduce([{first, first}], &extend_run/2)
        |> Enum.reverse()
    end
  end

  # A column touching the previous one extends that run; a gap starts a new one.
  defp extend_run(column, [{a, b} | acc]) do
    if column == b + 1, do: [{a, column} | acc], else: [{column, column}, {a, b} | acc]
  end

  # The rows carrying at least half as many blobs as the busiest row does — and
  # never fewer than two blobs, so a region holding a single glyph yields NO
  # band at all and nothing is ever filtered out of it.
  defp text_band(blobs) do
    coverage =
      for blob <- blobs, row <- blob |> Enum.map(&elem(&1, 1)) |> Enum.uniq(), reduce: %{} do
        acc -> Map.update(acc, row, 1, &(&1 + 1))
      end

    busiest = coverage |> Map.values() |> Enum.max(&>=/2, fn -> 0 end)
    shared = for {row, n} <- coverage, n >= max(2, div(busiest + 1, 2)), do: row

    case shared do
      [] -> nil
      rows -> {Enum.min(rows), Enum.max(rows)}
    end
  end

  defp in_band?(_blob, nil), do: true

  defp in_band?(blob, {top, bottom}) do
    rows = Enum.map(blob, &elem(&1, 1))
    Enum.min(rows) <= bottom and Enum.max(rows) >= top
  end

  defp span(blob, index) do
    values = Enum.map(blob, &elem(&1, index))
    {Enum.min(values), Enum.max(values)}
  end

  # 8-connected groups of ink. The client's dark outline is what makes this
  # trustworthy: text is never connected to whatever is drawn behind it.
  defp blobs(cells), do: blobs(MapSet.to_list(cells), cells, [])

  defp blobs([], _left, acc), do: acc

  defp blobs([cell | rest], left, acc) do
    if MapSet.member?(left, cell) do
      {blob, left} = flood([cell], MapSet.delete(left, cell), MapSet.new([cell]))
      blobs(rest, left, [blob | acc])
    else
      blobs(rest, left, acc)
    end
  end

  defp flood([], left, blob), do: {blob, left}

  defp flood([{i, j} | rest], left, blob) do
    {found, left} =
      for di <- -1..1//1, dj <- -1..1//1, reduce: {[], left} do
        {acc, remaining} ->
          neighbour = {i + di, j + dj}

          if MapSet.member?(remaining, neighbour),
            do: {[neighbour | acc], MapSet.delete(remaining, neighbour)},
            else: {acc, remaining}
      end

    flood(found ++ rest, left, Enum.reduce(found, blob, &MapSet.put(&2, &1)))
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

    bitmap = for row <- 0..(height - 1)//1, do: bitmap_row(columns, filled, row)
    tight = trim_rows(bitmap)
    y0 = Enum.count(Enum.take_while(bitmap, &(Enum.sum(&1) == 0)))

    %{x0: x0, x1: x1, y0: y0, y1: y0 + length(tight) - 1, bitmap: tight}
  end

  defp bitmap_row(columns, filled, row) do
    for {cx, _} <- columns, do: if(MapSet.member?(filled[cx], row), do: 1, else: 0)
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
    do: Enum.map_join(bitmap, ";", &Enum.join(&1, ","))

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
  The glyphs in `region` this install is not SURE of — each with its bitmap, so
  a human can look at it and say what it is, and with the character it would
  have guessed.

  It used to list only the ones that could not be read at all, and that hid the
  failure this exists to fix. Measured on Lucas's own minimap (2026-08-12): the
  coordinate band read `(3418, 30963, 3)` where the screen said
  `(3415, 30964, 2)` — three digits wrong — and NOT ONE glyph was an atlas hit.
  Every one came from `nearest/1`, whose slack is wide enough to confuse 5 with
  8 and 2 with 3 at this render. The teach page had nothing to offer him,
  because by its old question everything was "known".

  A guess is not knowledge. `guessed?` says which is which, so the page can
  offer the guesses first: teaching them is what turns a render the atlas has
  never seen into one it reads exactly.
  """
  def uncertain_in(%Frame{} = frame, region, opts \\ []) do
    atlas = atlas()
    glyphs = segment(frame, region, opts)
    band = line_band(glyphs)

    glyphs
    |> Enum.map(&describe_glyph(&1, atlas, band))
    |> Enum.reject(& &1.exact?)
    |> Enum.uniq_by(& &1.signature)
  end

  # `guess_glyph` is part of the answer, not an afterthought: a pair welded by
  # the background, or a digit welded to a sprite, reads perfectly once cut, and
  # calling either illegible is what broke the fused-pair tests the moment this
  # was rewritten.
  defp describe_glyph(glyph, atlas, band) do
    signature = signature(glyph.bitmap)

    %{
      bitmap: glyph.bitmap,
      signature: signature,
      guess: Map.get(atlas, signature) || guess_glyph(glyph, atlas, band),
      exact?: Map.has_key?(atlas, signature)
    }
  end

  @doc """
  The glyphs in `region` this install cannot read AT ALL. Kept for callers that
  want only the blanks; `uncertain_in/3` is what a teach page should ask for.
  """
  def unknown_in(%Frame{} = frame, region, opts \\ []) do
    frame
    |> uncertain_in(region, opts)
    |> Enum.filter(&(&1.guess == nil))
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

  # The SAME background-tolerant match the split halves use, and for the same
  # measured reason: a character's stroke gains or loses a column of
  # anti-aliasing with the background behind it. Lucas's 2026-08-10 coordinate
  # over bright terrain segmented perfectly — 11 glyphs, the right count — and
  # read NOTHING: its digits came out 15x11 where the atlas knows 15x12, and a
  # one-column difference used to land in an empty shape bucket, so there was
  # not even a candidate to score. Candidates one column wider or narrower are
  # compared padded on whichever side fits best; the ceiling and the
  # different-character runner-up rule keep the answer honest.
  defp nearest(bitmap), do: nearest_within(bitmap)

  defp difference(a, b) do
    Enum.zip(a, b)
    |> Enum.reduce(0, fn {row_a, row_b}, acc ->
      acc + Enum.count(Enum.zip(row_a, row_b), fn {x, y} -> x != y end)
    end)
  end

  # -- fused pairs -------------------------------------------------------------

  # An unknown glyph WIDER THAN TALL is usually two characters welded by a
  # background bridge — the field's learned "04"/"70" pairs are the proof: over
  # the minimap's lit ground, a 2-pixel crumb hangs off one digit's blob and no
  # column between the digits is ever empty, so the projection welds them.
  # Teaching the PAIR works but never ends (100 combinations).
  #
  # Cut at the faintest interior columns (the bridge) and read each half on its
  # own. A half comes out ±1 column from its standalone self — the weld eats an
  # anti-aliased edge — so halves match with one column of width tolerance,
  # padded on whichever side fits best. BOTH halves must resolve, each
  # unambiguously. Measured on the real pairs: a true half lands 0-5 pixels
  # from its character while the nearest OTHER character is 35+ away, so the
  # shared @max_diff_ratio ceiling keeps a false weld far out of reach.
  defp split_fused(bitmap) do
    width = length(hd(bitmap))

    if width > length(bitmap) and width >= 6 do
      ink = bitmap |> transpose() |> Enum.map(&Enum.sum/1)
      interior = 2..(width - 3)//1
      faintest = interior |> Enum.map(&Enum.at(ink, &1)) |> Enum.min()

      interior
      |> Enum.filter(&(Enum.at(ink, &1) == faintest))
      |> Enum.find_value(&read_halves(bitmap, &1))
    end
  end

  # The cut column itself is dropped: it is the bridge, part of neither glyph.
  defp read_halves(bitmap, cut) do
    with left when left != nil <- half_char(Enum.map(bitmap, &Enum.take(&1, cut))),
         right when right != nil <- half_char(Enum.map(bitmap, &Enum.drop(&1, cut + 1))) do
      left <> right
    else
      _unresolved -> nil
    end
  end

  defp half_char(half) do
    case tighten(half) do
      [] -> nil
      tight -> Map.get(atlas(), signature(tight)) || nearest_half(tight)
    end
  end

  # Tight like a segmented glyph: rows AND columns trimmed to the ink.
  defp tighten(bitmap) do
    bitmap |> trim_rows() |> transpose() |> trim_rows() |> transpose()
  end

  defp transpose([]), do: []
  defp transpose(rows), do: Enum.zip_with(rows, & &1)

  defp nearest_half(bitmap), do: nearest_within(bitmap)

  # The runner-up that forces a refusal must be a DIFFERENT character: two
  # atlas variants of the same digit agreeing is confirmation, not ambiguity.
  defp nearest_within(bitmap) do
    rows = length(bitmap)
    width = length(hd(bitmap))
    cells = rows * width

    candidates =
      for delta <- -@max_width_slack..@max_width_slack//1,
          shape_width = width + delta,
          shape_width > 0,
          {candidate, char} <- Map.get(index(), {rows, shape_width}, []) do
        {char, aligned_difference(bitmap, candidate), delta}
      end

    case Enum.sort_by(candidates, &elem(&1, 1)) do
      [{char, best, delta} | rest] ->
        other = Enum.find(rest, fn {c, _diff, _d} -> c != char end)
        if accepted?(best, other, delta, cells), do: char, else: nil

      [] ->
        nil
    end
  end

  defp accepted?(best, other, 0, cells) do
    best <= max(@min_diff_slack, round(cells * @max_diff_ratio)) and
      (other == nil or elem(other, 1) > best + @min_diff_slack)
  end

  defp accepted?(best, other, _delta, cells) do
    best <= max(@min_diff_slack, round(cells * @padded_diff_ratio)) and
      (other == nil or
         (elem(other, 1) > best + @min_diff_slack and elem(other, 1) >= best * @runner_up_factor))
  end

  # Every horizontal alignment within the width slack — the narrower bitmap is
  # padded on both sides in turn, so a stroke that lost its left edge and one
  # that lost its right both find their shape.
  defp aligned_difference(bitmap, candidate) do
    width = length(hd(bitmap))
    candidate_width = length(hd(candidate))

    cond do
      candidate_width == width -> difference(bitmap, candidate)
      candidate_width > width -> best_alignment(bitmap, candidate, candidate_width - width)
      true -> best_alignment(candidate, bitmap, width - candidate_width)
    end
  end

  defp best_alignment(narrow, wide, gap) do
    Enum.min(for left <- 0..gap//1, do: difference(pad_sides(narrow, left, gap - left), wide))
  end

  defp pad_sides(rows, left, right) do
    Enum.map(rows, &(List.duplicate(0, left) ++ &1 ++ List.duplicate(0, right)))
  end

  @doc """
  Reads a line of text. `confidence` is the share of glyphs the atlas knew;
  an unknown glyph renders as `?` so the lexicon can still close the word.
  """
  def read_line(%Frame{} = frame, region, opts \\ []) do
    glyphs = segment(frame, region, opts)
    atlas = atlas()
    gap = space_gap(glyphs)
    band = line_band(glyphs)

    {chars, known, guessed} =
      glyphs
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.reduce({[], 0, 0}, fn [g, next], {acc, known, guessed} ->
        {char, hit, guess} = read_glyph(g, atlas, band)
        {[maybe_space(g, next, gap), char | acc], known + hit, guessed + guess}
      end)

    # `guessed` is reported and NOT folded into the confidence: a reader that
    # suddenly refused every guessed line would stop the hunt of anyone whose
    # render the atlas has never seen — which is exactly the person who needs
    # it working while he teaches it. Callers that care can ask.
    %{
      text: chars |> Enum.reverse() |> Enum.join(),
      confidence: confidence(known, glyphs),
      guessed: guessed
    }
  end

  # {character, counts-as-read, counts-as-guessed}. An atlas signature hit is
  # knowledge; anything `nearest/1` or the fused split produced is a guess that
  # happened to land — see `uncertain_in/3` for why that distinction matters.
  defp read_glyph(glyph, atlas, band) do
    case Map.get(atlas, signature(glyph.bitmap)) do
      nil ->
        case guess_glyph(glyph, atlas, band) do
          nil -> {"?", 0, 0}
          char -> {char, 1, 1}
        end

      char ->
        {char, 1, 0}
    end
  end

  defp guess_glyph(glyph, atlas, band) do
    lookup(glyph.bitmap, atlas) || split_fused(glyph.bitmap) || unwelded(glyph, atlas, band)
  end

  # The rows this line's characters agree on, measured from the glyphs
  # themselves: the rows at least half the busiest row carries, and never fewer
  # than two glyphs — so a region holding a single glyph yields NO band and
  # nothing inside it is ever reshaped.
  defp line_band(glyphs) do
    coverage =
      for glyph <- glyphs, row <- glyph.y0..glyph.y1//1, reduce: %{} do
        acc -> Map.update(acc, row, 1, &(&1 + 1))
      end

    busiest = coverage |> Map.values() |> Enum.max(&>=/2, fn -> 0 end)

    case for {row, n} <- coverage, n >= max(2, div(busiest + 1, 2)), do: row do
      [] -> nil
      rows -> {Enum.min(rows), Enum.max(rows)}
    end
  end

  # A glyph that resolves to NOTHING and pokes outside its line's band is asked
  # again without the rows that are not the line's. Measured 2026-08-17 while he
  # hunted beside a town: a minimap sprite shared the "1"'s columns — never
  # touching it, but the projection is onto COLUMNS — and the pair came out as
  # one 17-row glyph where every digit on that line is 15, landing in a shape
  # bucket with no candidate to score at all. Cut at the band, the same pixels
  # answer "1" at a distance of 1, with the runner-up at 12.
  #
  # Only a glyph that ALREADY failed takes this road. That is what keeps it from
  # reshaping anything real: the parentheses overhang the digits by ~2 rows per
  # side and the dot of an "i" sits fully outside, and all of them resolve — a
  # resolved glyph is never retried.
  defp unwelded(_glyph, _atlas, nil), do: nil

  defp unwelded(glyph, atlas, {top, bottom}) do
    above = max(top - glyph.y0, 0)
    below = max(glyph.y1 - bottom, 0)

    if above + below > 0 do
      case glyph.bitmap |> Enum.drop(above) |> Enum.drop(-below) |> tighten() do
        [] -> nil
        cut -> Map.get(atlas, signature(cut)) || lookup(cut, atlas)
      end
    end
  end

  @doc """
  Whether the region has NO ink at all — confidently blank, not merely unread.

  `read_int/3` answers nil both for "there is nothing here" and for "there is
  something here I could not read", and those mean opposite things to a caller:
  an empty hotbar slot genuinely holds zero items, while an unreadable one holds
  an unknown number that must NEVER be reported as zero — a bad read of 561
  potions turning into 0 would fire a false low-stock alarm.
  """
  def blank?(%Frame{} = frame, region, opts \\ []),
    do: segment(frame, region, opts) == []

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
    |> unambiguous_best()
  end

  # A tie between two candidates is not a reading — it is a coin toss.
  defp unambiguous_best([{name, d} | rest]) do
    if Enum.any?(rest, fn {_n, other} -> other == d end), do: nil, else: name
  end

  defp unambiguous_best([]), do: nil

  defp distance_cell({cb, j}, {row, prev}, ca) do
    cost = if ca == cb or ca == "?", do: 0, else: 1
    value = Enum.min([hd(row) + 1, Enum.at(prev, j) + 1, Enum.at(prev, j - 1) + cost])

    {[value | row], prev}
  end

  # Levenshtein, with `?` (an unread glyph) matching any character for free.
  defp distance(a, b) do
    Enum.reduce(Enum.with_index(a, 1), Enum.to_list(0..length(b)), fn {ca, i}, previous ->
      {row, _} = Enum.reduce(Enum.with_index(b, 1), {[i], previous}, &distance_cell(&1, &2, ca))

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
