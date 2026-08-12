defmodule Pokex.Vision.Finder do
  @moduledoc """
  Finds ONE taught sprite inside a captured region: slides the teach-sized box
  over it and returns the best window.

  Same two-phase search the corpse scan uses — a coarse step over the whole
  region, then a fine pass around the best peaks — because the fine phase alone
  costs ~40× the windows for the same answer. And no lattice: sliding removes
  grid phase entirely, so the winning framing is by construction the closest to
  what was taught.

  The difference from the corpse scan is what it is FOR. That one asks "what is
  lying around here?" and answers with every peak; this one asks "where is this
  ONE thing?" and answers with the best window and how sure it is. A caller that
  already knows roughly where to look hands a small region, and the search costs
  almost nothing — which is the whole point of tracking something continuously.
  """

  alias Pokex.Vision.{Frame, SpriteLibrary}

  @type hit :: %{
          name: String.t(),
          score: float,
          point: {integer, integer},
          in_frame: {integer, integer},
          windows: non_neg_integer
        }

  @default_box 88
  @default_step 8
  @default_refine 2
  @default_peaks 3

  @doc """
  The best match in `frame`, or `nil` when the library is empty or the frame is
  smaller than one box.

  Options:

    * `:box` — the teach-sized square, px in the FRAME's scale (default #{@default_box})
    * `:step` / `:refine` — coarse and fine strides (default #{@default_step} / #{@default_refine})
    * `:peaks` — how many coarse peaks get refined (default #{@default_peaks})
    * `:region` — `{x, y, w, h}` on SCREEN that this frame is of, so the hit can
      report a screen point. Without it `:point` equals `:in_frame`.

  `:score` is returned WITHOUT a threshold, deliberately: whether 0.62 is a
  find or a miss depends on the caller, and a number that failed still says by
  how much (the corpse work measured ~0.05 lost per 7px of offset).
  """
  @spec find(SpriteLibrary.t(), Frame.t(), keyword) :: hit | nil
  def find(lib, %Frame{} = frame, opts \\ []) do
    box = Keyword.get(opts, :box, @default_box)
    step = max(Keyword.get(opts, :step, @default_step), 1)
    refine = max(Keyword.get(opts, :refine, @default_refine), 1)

    if SpriteLibrary.empty?(lib) or frame.width < box or frame.height < box do
      nil
    else
      coarse = score_all(lib, frame, windows(frame, box, step), box)

      fine =
        coarse
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(Keyword.get(opts, :peaks, @default_peaks))
        |> Enum.flat_map(&around(&1, frame, box, step, refine))
        |> Enum.uniq()

      all = coarse ++ score_all(lib, frame, fine, box)

      best(all, box, frame.scale, Keyword.get(opts, :region), length(all))
    end
  end

  defp best([], _box, _scale, _region, _count), do: nil

  defp best(scored, box, scale, region, count) do
    %{x: x, y: y, name: name, score: score} = Enum.max_by(scored, & &1.score)
    half = div(box, 2)
    in_frame = {x + half, y + half}

    %{
      name: name,
      score: score,
      in_frame: in_frame,
      point: on_screen(in_frame, scale, region),
      windows: count
    }
  end

  # The window's CENTER is the answer: teaching centers on his click over the
  # creature, so the winning window's center is the point he chose himself.
  defp on_screen(point, _scale, nil), do: point

  defp on_screen({fx, fy}, scale, {rx, ry, _w, _h}),
    do: {rx + round(fx / scale), ry + round(fy / scale)}

  defp score_all(lib, frame, positions, box) do
    for {x, y} <- positions,
        info = SpriteLibrary.best_in(lib, frame, {x, y, box, box}),
        info != nil,
        do: %{x: x, y: y, name: info.name, score: info.score}
  end

  defp windows(%Frame{width: w, height: h}, box, step) do
    for y <- 0..max(h - box, 0)//step, x <- 0..max(w - box, 0)//step, do: {x, y}
  end

  defp around(%{x: x, y: y}, %Frame{width: w, height: h}, box, step, refine) do
    for dy <- -step..step//refine,
        dx <- -step..step//refine,
        nx = x + dx,
        ny = y + dy,
        nx >= 0 and ny >= 0 and nx + box <= w and ny + box <= h,
        do: {nx, ny}
  end
end
