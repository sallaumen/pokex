defmodule Pokex.Vision.NameLabels do
  @moduledoc """
  Where the creatures ARE, read from the name the game itself draws over each
  one — and WHOSE each one is, read from the colour it draws it in.

  ## Why the name and not the sprite

  "eu teria que calibrar cada sprite de monstro acredito" (Lucas, 2026-08-26) —
  he would not, and the reason is worth writing down. A sprite is a different
  picture per species, per animation frame and per facing; a name label is the
  SAME picture always: text the client draws above every creature, fixed colour,
  fixed height, whatever the species. One rule covers the Pikachus he farms and
  the Ratatas he has never managed to kill, with nothing to teach.

  ## Two colours, two meanings

  MEASURED on a crop of his own client: a hostile's name is drawn in pure red,
  HIS OWN pokémon's in green (5, 166, 67). That single fact does two jobs — it
  keeps his own pokémon out of the pile being counted, and it says where that
  pokémon is standing.

  The second job matters more than it looks. An area skill leaves the POKÉMON,
  not the trainer, and on his screen the two are routinely two tiles apart, so
  distances measured from the character are wrong by however far it has
  wandered. Reading the green label costs nothing on top of the red pass and
  needs no sprite taught — `Pokex.Bots.PokemonTracker` can only find pokémon he
  has photographed, and on 2026-08-26 his library held two he no longer uses.

  ## Honest about its blind spot

  Measured on his recording, and again on his own screen in the field: a bright
  spell effect paints over the labels of precisely the creatures it is hitting,
  and a yellow skill banner ("QUICK ATTACK!", "AGILITY!") lands in the same band
  as the names. In one field screenshot four hostiles were on screen and only
  the two whose names were not covered came back.

  That blind spot is why this counts DOWN and never up: a hidden label reads as
  one creature fewer, so a rule that requires a pile fires LESS often under
  effects, never more.

  ## Row runs, not a flood fill

  A per-pixel component search over a 1800px box is millions of `binary_part/3`
  calls. Letters of one word sit on the same rows, so the scan walks sampled
  ROWS collecting coloured runs (small gaps bridged — the space between letters)
  and merges runs that touch across rows. Measured 14-31ms on a full screen with
  40 labels; the capture that feeds it costs ten times that.
  """

  alias Pokex.Vision.{Frame, Ink}

  # Compression darkens the text's edges, so the tests are RATIOS (one channel
  # dominates) rather than floors on absolute values: sampled from his
  # recording, red label pixels ran 124..231 red with green/blue near zero.
  @min_ink 110
  @min_margin 60
  # In red text green and blue stay together; they diverge in orange damage
  # numbers ("1889") and yellow skill banners ("AGILITY!"), which sit in the
  # same places and must not be counted as creatures.
  @max_channel_split 40

  @type kind :: :hostile | :own
  @type label :: %{
          kind: kind,
          x: integer,
          y: integer,
          w: pos_integer,
          h: pos_integer,
          rows: pos_integer
        }

  @doc """
  Every name label in `frame`, in frame coordinates, each tagged with whose it
  is.

  Options (all measured defaults; exposed because a different client zoom moves
  them together):

    * `:min_w` / `:max_w` — label width band in px (default 22/150)
    * `:min_h` / `:max_h` — label height band in px (default 6/20)
    * `:min_rows` — how many sampled rows must agree (default 2)
  """
  @spec find(Frame.t(), keyword) :: [label]
  def find(%Frame{} = frame, opts \\ []) do
    Ink.find(frame, &ink/3, %{
      min_w: Keyword.get(opts, :min_w, 22),
      max_w: Keyword.get(opts, :max_w, 150),
      min_h: Keyword.get(opts, :min_h, 6),
      max_h: Keyword.get(opts, :max_h, 20),
      min_rows: Keyword.get(opts, :min_rows, 2)
    })
  end

  # Red is a hostile, green is his. Everything else — orange damage, yellow
  # banners, white "MISS!" — is not a name.
  defp ink(r, g, b) do
    cond do
      r > @min_ink and r - g > @min_margin and r - b > @min_margin and
          abs(g - b) < @max_channel_split ->
        :hostile

      g > @min_ink and g - r > @min_margin and g - b > @min_margin ->
        :own

      true ->
        nil
    end
  end

  @doc "Only the hostiles — the pile a rule would count."
  @spec hostiles([label]) :: [label]
  def hostiles(labels), do: Enum.filter(labels, &(&1.kind == :hostile))

  @doc """
  His own pokémon's label, when the green name was readable — the point an area
  skill actually leaves from. `nil` when it was covered or off the frame, and a
  caller that gets `nil` must say which anchor it fell back to rather than
  quietly measuring from somewhere else.
  """
  @spec own([label]) :: label | nil
  def own(labels), do: Enum.find(labels, &(&1.kind == :own))
end
