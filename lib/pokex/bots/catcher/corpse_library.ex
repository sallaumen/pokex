defmodule Pokex.Bots.Catcher.CorpseLibrary do
  @moduledoc """
  TAUGHT corpses — since 2026-07-30 the library IS the aim (the guessing mode
  was retired): only candidates SIMILAR to a taught corpse get a Pokéball; empty
  library = no target. Lucas photographs the real on-screen corpse and names it.

  The mechanism lives in `Pokex.Vision.SpriteLibrary` — his own pokémon is
  taught the same way now, and the two are SEPARATE FILES on purpose: a pokémon
  in this library would be something the Catcher throws balls at.

  This module is what "the corpses" means: the file (`~/.pokex/corpses.json`)
  and the sample cap. Everything else is the shared machine.
  """

  alias Pokex.Home
  alias Pokex.Vision.{Frame, SpriteLibrary}

  @max_samples 3

  def max_samples, do: @max_samples

  def file, do: Path.join(Home.dir(), "corpses.json")

  @doc "The library handle — pass it to `Pokex.Vision.SpriteLibrary`."
  def library, do: SpriteLibrary.new(file(), @max_samples)

  @doc "All taught corpses, newest first."
  def list, do: SpriteLibrary.list(library())

  def empty?, do: SpriteLibrary.empty?(library())

  @doc """
  Teaches a corpse: the crop (Frame) joins the library under the given name.

  `painted?: true` marks the sample as a HAND-PAINTED stand-in — the ordinary
  species' corpse with its hue turned toward a shiny nobody has killed yet (see
  `Pokex.Vision.Recolor`). It aims exactly like any other sample; the flag
  exists so the library can say which entries are guesses, and so the day the
  real body drops he knows which one to replace.
  """
  def add(name, %Frame{} = crop, opts \\ []) when is_binary(name),
    do: SpriteLibrary.add(library(), name, crop, opts)

  def delete(slug), do: SpriteLibrary.delete(library(), slug)

  @doc """
  Enables/disables a corpse in the aim WITHOUT deleting it (2026-07-30 request):
  a false-positive corpse leaves the search with one click and comes back with
  another — before, deleting the samples and re-photographing was the only way.
  """
  def set_enabled(slug, on?) when is_boolean(on?),
    do: SpriteLibrary.set_enabled(library(), slug, on?)

  @doc "Deletes ONE sample (a bad photo); dropping the last sample removes the whole corpse."
  def delete_sample(slug, index), do: SpriteLibrary.delete_sample(library(), slug, index)

  @doc "A bola escolhida NESTA entrada — nil quando ele não escolheu nenhuma."
  @spec ball(map) :: String.t() | nil
  defdelegate ball(entry), to: SpriteLibrary

  @doc "Which ball this taught corpse asks for — nil means the default one."
  @spec set_ball(String.t(), String.t() | nil) :: :ok
  def set_ball(slug, key), do: SpriteLibrary.set_ball(library(), slug, key)

  @doc """
  A bola escolhida para o corpo chamado `name`, ou nil.

  Casa pelo NOME porque é o nome que a mira devolve (`best/1` → `%{name: …}`),
  o mesmo que chega em `Catcher.Balls.key_for/1`. Sem entrada, sem escolha.
  """
  @spec ball_for(String.t() | nil) :: String.t() | nil
  def ball_for(name) when is_binary(name) do
    alvo = String.downcase(String.trim(name))

    case Enum.find(list(), &(String.downcase(&1["name"]) == alvo)) do
      nil -> nil
      entry -> SpriteLibrary.ball(entry)
    end
  end

  def ball_for(_unrecognised), do: nil

  @doc "Sample thumbnail as a BMP data-URL."
  defdelegate thumb(sample), to: SpriteLibrary

  @doc "Renames a taught corpse, keeping its photographs and its switch."
  def rename(slug, new_name), do: SpriteLibrary.rename(library(), slug, new_name)

  @doc """
  Is this corpse a TARGET? (old entries without the field are). A corpse that is
  not aimed still competes for the match — winning while off is how he says "I
  know this creature and I do not want it".
  """
  defdelegate enabled?(entry), to: SpriteLibrary

  @doc """
  Best `%{name, score}` in the library for this crop — NO threshold; `nil` only
  when the library is empty. A FAILING score is still information: the old
  `:nomatch` hid whether it missed by 0.01 or by 0.40, and against which body
  (blind validation, 2026-07-30). Measured on real samples the score drops ~0.05
  per 7px of crop offset, so distance to the threshold IS the aim diagnostic.
  """
  def best(%Frame{} = crop), do: SpriteLibrary.best(library(), crop)

  @doc "The library resolved once, for a caller about to score many windows."
  def aimed, do: SpriteLibrary.aimed(library())
end
