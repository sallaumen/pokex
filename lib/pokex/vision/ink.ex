defmodule Pokex.Vision.Ink do
  @moduledoc """
  Finding COLOURED TEXT on the game's own screen, by the shape its rows make.

  The client writes several things over the field, each in its own colour and
  each meaning something different: a hostile's name in red, his own pokémon's
  in green, a damage number in orange, a skill banner in yellow. Every one of
  them is the same problem — runs of one colour, a few pixels tall, letters
  separated by small gaps — so it is solved once here and asked different
  questions by `Pokex.Vision.NameLabels` and `Pokex.Vision.DamageNumbers`.

  ## Row runs, not a flood fill

  A per-pixel component search over a 1800px box is millions of `binary_part/3`
  calls. Letters of one word sit on the same rows, so the scan walks sampled
  ROWS collecting coloured runs (small gaps bridged) and merges runs that touch
  across rows. Measured 14-31ms on a full screen with 40 labels; the capture
  that feeds it costs ten times that.

  A run carries its COLOUR through the merge, so a red name touching a green one
  stays two things. Letting them fuse would have made the target and the anchor
  the same object.
  """

  alias Pokex.Vision.Frame

  # A 10px-tall label survives sampling every other row, and halves the work.
  @row_step 2
  # Letter spacing, in px, that still belongs to one word.
  @gap 6

  @type shape :: %{
          kind: atom,
          x: integer,
          y: integer,
          w: pos_integer,
          h: pos_integer,
          rows: pos_integer
        }

  @doc """
  Every coloured shape in `frame`, in frame coordinates.

  `ink` classifies one pixel: `(r, g, b) -> kind | nil`. `bounds` is the shape
  band a run must fall inside — `%{min_w:, max_w:, min_h:, max_h:, min_rows:}`.
  """
  @spec find(Frame.t(), (byte, byte, byte -> atom | nil), map) :: [shape]
  def find(%Frame{} = frame, ink, bounds) when is_function(ink, 3) do
    0..(frame.height - 1)//@row_step
    |> Enum.flat_map(&runs(frame, &1, ink, bounds))
    |> Enum.reduce([], &merge/2)
    |> Enum.filter(&fits?(&1, bounds))
    |> Enum.sort_by(&{&1.y, &1.x})
  end

  defp fits?(s, b) do
    s.rows >= b.min_rows and s.w >= b.min_w and s.w <= b.max_w and s.h >= b.min_h and
      s.h <= b.max_h
  end

  defp runs(frame, y, ink, bounds) do
    row = binary_part(frame.rgba, y * frame.width * 4, frame.width * 4)
    scan(row, 0, nil, y, {ink, bounds}, [])
  end

  # `run` is `{kind, start, last}` or nil.
  defp scan(<<r, g, b, _a, rest::binary>>, x, run, y, {ink, _} = ctx, acc) do
    case {ink.(r, g, b), run} do
      {nil, nil} ->
        scan(rest, x + 1, nil, y, ctx, acc)

      {nil, {_kind, _start, last}} when x - last > @gap ->
        scan(rest, x + 1, nil, y, ctx, close(acc, run, y, ctx))

      {nil, _still_open} ->
        scan(rest, x + 1, run, y, ctx, acc)

      {kind, {kind, start, _last}} ->
        scan(rest, x + 1, {kind, start, x}, y, ctx, acc)

      {kind, _other_colour_or_none} ->
        scan(rest, x + 1, {kind, x, x}, y, ctx, close(acc, run, y, ctx))
    end
  end

  defp scan(<<>>, _x, run, y, ctx, acc), do: close(acc, run, y, ctx)

  defp close(acc, nil, _y, _ctx), do: acc

  defp close(acc, {kind, start, last}, y, {_ink, bounds}) do
    w = last - start + 1
    if w >= bounds.min_w and w <= bounds.max_w, do: [{kind, y, start, last} | acc], else: acc
  end

  # A run joins a shape when it is of the SAME colour, on the next sampled row
  # (or the one after — compression eats whole rows of thin text) and overlaps
  # it horizontally.
  defp merge({kind, y, a, b}, shapes) do
    case Enum.split_with(shapes, &touches?(&1, kind, y, a, b)) do
      {[], rest} ->
        [%{kind: kind, x: a, y: y, w: b - a + 1, h: @row_step, rows: 1} | rest]

      {[hit | _] = hits, rest} ->
        grown = %{
          kind: kind,
          x: min(hit.x, a),
          y: min(hit.y, y),
          w: max(hit.x + hit.w, b + 1) - min(hit.x, a),
          h: max(hit.y + hit.h, y + @row_step) - min(hit.y, y),
          rows: hit.rows + 1
        }

        [grown | rest ++ tl(hits)]
    end
  end

  defp touches?(s, kind, y, a, b) do
    s.kind == kind and y >= s.y and y - (s.y + s.h) <= @row_step and
      not (b < s.x - 8 or a > s.x + s.w + 8)
  end

  @doc "The centre of a shape, in frame coordinates."
  @spec centre(shape) :: {integer, integer}
  def centre(s), do: {s.x + div(s.w, 2), s.y + div(s.h, 2)}
end
