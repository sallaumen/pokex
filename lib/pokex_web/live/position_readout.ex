defmodule PokexWeb.PositionReadout do
  @moduledoc """
  The character's position, told honestly — the SAME reading on the panel,
  /world and /cavebot.

  A mute "?" hid the only question that matters when the bot doesn't walk:
  am I not reading the minimap, or am I reading it and you really are there?
  The two causes looked identical on screen and have opposite fixes (browser
  window covering the minimap vs lost HUD vs one doubtful glyph in a single
  read).

  The age comes from the `:minimap` fact's stamp in `WorldState`, and NOT
  from the cavebot snapshot's `pos_age_ms`, on purpose: the fact exists with
  the hunt off (and /world doesn't even know the cavebot), so one source
  answers the same on all three pages. The cavebot's `pos_age_ms` stays its
  own — there it answers "how long has the LOGIC not seen a position", which
  is a different question.
  """

  alias Pokex.World

  @doc """
  Where the coordinate read stands:

    * `:ok` — read (fresh fact, with a position)
    * `:illegible` — the minimap IS being read right now, but the coordinate
      came out unreadable: `Glyphs.read_coord/2` is all-or-nothing, so one
      doubtful glyph drops the whole coordinate
    * `:stale` — reads stopped arriving (feed stopped, or nobody attached)
    * `:never` — nothing was ever published
  """
  @spec status({integer, integer, integer} | nil, non_neg_integer | nil) ::
          :ok | :illegible | :stale | :never
  def status(pos, age_ms)
  def status({_x, _y, _z}, _age_ms), do: :ok

  def status(nil, age_ms) when is_integer(age_ms) do
    if age_ms <= World.max_age_ms(), do: :illegible, else: :stale
  end

  def status(nil, _never), do: :never

  @doc ~S'The coordinate itself — an em-dash, never "?", when there is nothing to show.'
  @spec coords({integer, integer, integer} | nil) :: String.t()
  def coords(nil), do: "—"
  def coords({x, y, z}), do: "#{x}, #{y} · andar #{z}"

  @doc """
  The phrase accompanying the coordinate. It is what distinguishes "not
  reading" from "reading, and you are there" — the rest of the screen only
  shows the number.
  """
  @spec note({integer, integer, integer} | nil, non_neg_integer | nil) :: String.t()
  def note(pos, age_ms) do
    case status(pos, age_ms) do
      :ok ->
        "lendo tua posição · #{age_text(age_ms)}"

      :illegible ->
        "estou lendo o minimapa, mas a coordenada saiu ilegível"

      :stale ->
        "NÃO estou lendo tua posição — última leitura #{age_text(age_ms)}"

      :never ->
        "ainda não li tua posição"
    end
  end

  @doc "The read-status color, in the panel's tokens."
  @spec note_class({integer, integer, integer} | nil, non_neg_integer | nil) :: String.t()
  def note_class(pos, age_ms) do
    case status(pos, age_ms) do
      :ok -> "text-pk-text-3"
      :illegible -> "text-pk-warn"
      :stale -> "text-pk-danger"
      :never -> "text-pk-text-3"
    end
  end

  @doc "Age in words. Ages come from the monotonic clock, so they are never dates."
  @spec age_text(integer | nil) :: String.t()
  def age_text(nil), do: "—"
  def age_text(ms) when ms < 1_000, do: "agora"
  def age_text(ms) when ms < 60_000, do: "há #{div(ms, 1000)}s"
  def age_text(ms) when ms < 3_600_000, do: "há #{div(ms, 60_000)}min"
  def age_text(_ms), do: "há 1h+"

  @doc """
  How much of the coordinate is coming out legible. The read is
  all-or-nothing, so a miss here and there is normal; what matters is the
  RATIO — if almost everything fails, the bot walks blind (and /cavebot
  records a route full of holes).
  """
  @spec read_health(non_neg_integer, non_neg_integer) :: String.t()
  def read_health(0, 0), do: "aguardando a primeira leitura…"

  def read_health(reads, misses) do
    pct = round(reads * 100 / (reads + misses))

    cond do
      pct >= 80 -> "leitura boa — #{pct}% (#{reads} ok, #{misses} falhas)"
      pct >= 40 -> "leitura instável — #{pct}% (#{reads} ok, #{misses} falhas)"
      true -> "leitura ruim — #{pct}% (#{reads} ok, #{misses} falhas)"
    end
  end
end
