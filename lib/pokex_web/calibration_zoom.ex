defmodule PokexWeb.CalibrationZoom do
  @moduledoc """
  The magnifier over the calibration screenshot — pure CSS, pure arithmetic.

  Two clicks mark a point: the first is rough and magnifies around it, the
  second is precise. This module owns the transform that magnifies, and it
  lives on its own because it was SUSPECTED TWICE of misplacing marks
  (2026-08-06) and could not be checked: it had no test, only a derivation on
  paper. The clicks turned out fine both times — a hand-marked minimap cross
  landed ~4px from its target — so the arithmetic below is now pinned instead
  of re-argued.

  ## Why translate-and-clamp instead of transform-origin

  `transform-origin` at the clicked point PINS it where it already was, leaving
  only `(1-f)/factor` of visible margin beyond it. For a target near an edge
  that margin vanishes: the skill bar sits at the BOTTOM, and its bottom-right
  corner fell OUTSIDE the zoom window (measured: corner at 92.85% of the height
  against a window ending at 91.9%), which read as "não consigo clicar na
  última skill" (Lucas, 2026-07-20). Scaling from the top-left and translating
  so the point lands mid-container fixes that, and the clamp keeps the scaled
  image flush with the edges so no blank gutter ever appears.

  ## Why the click still maps back

  The hook reads `getBoundingClientRect` AFTER the transform, so the clicked
  fraction is `(clientX - rect.left) / rect.width` — the translate cancels out
  of both terms and the scale divides out. The page needs no inverse transform,
  which is why none exists here.
  """

  @doc """
  The `style` for the transformed container, or `nil` when nothing is zoomed
  (and when the screen has no size — a transform against a zero box would put
  the image somewhere undefined).
  """
  def style(zoom_at, screen, factor)

  def style(nil, _screen, _factor), do: nil

  def style({x, y}, %{w: w, h: h}, factor) when w > 0 and h > 0 and factor > 0 do
    "transform: translate(#{translate_pct(x / w, factor)}%, #{translate_pct(y / h, factor)}%) " <>
      "scale(#{factor}); transform-origin: 0 0"
  end

  def style(_zoom_at, _screen, _factor), do: nil

  @doc """
  The translate (in % of the container) that centres fraction `f` at `factor`,
  clamped into `[1 - factor, 0]` so the window never runs past the image.
  """
  def translate_pct(f, factor) do
    Float.round(100 * min(max(0.5 - f * factor, 1.0 - factor), 0.0), 2)
  end

  @doc """
  Where fraction `f` of the image ends up inside the container, as a fraction
  of the container — the property the marking flow depends on and the one worth
  asserting: whatever you zoom on must be VISIBLE (between 0 and 1).
  """
  def visible_at(f, factor), do: f * factor + translate_pct(f, factor) / 100
end
