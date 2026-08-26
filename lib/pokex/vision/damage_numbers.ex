defmodule Pokex.Vision.DamageNumbers do
  @moduledoc """
  The orange numbers the game prints over whatever just took a hit.

  They answer a question nothing else could: HOW FAR an area skill actually
  reaches. The simulator has been resolving every area press with

      # invented — the fallback for a key he has neither named nor tuned
      aoe_radius: 4,

  and that invented 4 is load-bearing. A radius of 4 on a 15×11 screen covers 81
  of 165 tiles, so "are they close enough?" is nearly always yes — which is
  exactly why every positioning knob in `Pokex.Bots.Engine.Config` measured flat
  (24 seeds × 4 scenarios, 2026-08-26: none moved kills/min more than 5%). The
  last invented number in that file was an 8s cooldown; his own video measured
  45s, and correcting it changed what every earlier conclusion was worth.

  ## Told apart by the green channel

  MEASURED on his client: a damage number is ~(240, 118, 13). The two things it
  could be confused with sit on either side of its green — a hostile's red name
  has none (218, 0, 0), a yellow skill banner has far more (~255, 200, 30). So
  the middle band on green is what separates a hit from a name and from
  "AGILITY!".

  ## What it cannot tell you

  A damage number says something was hit; it does not say BY WHOM. Other players
  hunt the same floor, and their hits print the same orange. Nothing here
  guesses — `Pokex.Bots.AreaProbe` samples in a tight window after the bot's own
  press and reports the spread rather than one confident number, so a reader can
  see the contamination instead of inheriting it.
  """

  alias Pokex.Vision.{Frame, Ink}

  @doc """
  Every damage number in `frame`, in frame coordinates.

  Options: `:min_w` / `:max_w` / `:min_h` / `:max_h` / `:min_rows`, defaulting to
  the band a 2-to-5 digit number occupies on his display.
  """
  @spec find(Frame.t(), keyword) :: [Ink.shape()]
  def find(%Frame{} = frame, opts \\ []) do
    Ink.find(frame, &ink/3, %{
      min_w: Keyword.get(opts, :min_w, 14),
      max_w: Keyword.get(opts, :max_w, 90),
      min_h: Keyword.get(opts, :min_h, 6),
      max_h: Keyword.get(opts, :max_h, 22),
      min_rows: Keyword.get(opts, :min_rows, 2)
    })
  end

  defp ink(r, g, b) do
    if r > 180 and g > 80 and g < 165 and b < 90 and r - g > 60 and g - b > 50,
      do: :damage,
      else: nil
  end
end
