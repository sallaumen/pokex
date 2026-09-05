defmodule Pokex.Bots.PokemonSprites do
  @moduledoc """
  His OWN pokémon, photographed from several angles, so the bot can find it on screen instead of
  assuming where it is.

  He asked to be able to calibrate his pokémon from every angle so the bot always tracks where
  it is on screen and can tell whether it is where it is expected to be. The reason it matters:
  he parks the pokémon with a middle click and the corpse sweep centres on that spot, so if the
  click never landed the sweep searches empty ground and nobody notices.

  ## A separate file, on purpose

  `~/.pokex/pokemon_sprites.json`, never the corpse library. The corpse library IS the Catcher's
  aim: a pokémon taught into it is something the bot throws Pokéballs at. Same machine
  (`Pokex.Vision.SpriteLibrary`), different file, and the separation is the safety.

  ## Angles are samples

  A pokémon facing north and one facing south are two palettes of the same creature, which is
  exactly what the sample list is for. Ten of them, because unlike a corpse (which lies still)
  this thing turns: four cardinals, the diagonals, and room for the frames an animation catches
  mid-step.

  The NAME is the pokémon's, matching `/time`, so the tracker can ask for the one that is on the
  field rather than for whatever scores best.
  """

  alias Pokex.Home
  alias Pokex.Vision.{Frame, SpriteLibrary}

  @max_samples 10

  def max_samples, do: @max_samples

  def file, do: Path.join(Home.dir(), "pokemon_sprites.json")

  @doc "The library handle — pass it to `Pokex.Vision.SpriteLibrary` or the Finder."
  def library, do: SpriteLibrary.new(file(), @max_samples)

  @doc "Every pokémon taught, newest first."
  def list, do: SpriteLibrary.list(library())

  def empty?, do: SpriteLibrary.empty?(library())

  @doc "Teaches one angle of `name`. Returns `{:ok, samples_kept}`."
  def add(name, %Frame{} = crop) when is_binary(name),
    do: SpriteLibrary.add(library(), name, crop)

  def delete(slug), do: SpriteLibrary.delete(library(), slug)
  def delete_sample(slug, index), do: SpriteLibrary.delete_sample(library(), slug, index)

  def set_enabled(slug, on?) when is_boolean(on?),
    do: SpriteLibrary.set_enabled(library(), slug, on?)

  defdelegate thumb(sample), to: SpriteLibrary
  defdelegate enabled?(entry), to: SpriteLibrary

  @doc "How many angles are taught for `name` (0 when it is not in the library)."
  @spec angles(String.t()) :: non_neg_integer
  def angles(name) when is_binary(name) do
    case Enum.find(list(), &(&1["name"] == name)) do
      nil -> 0
      entry -> length(entry["samples"])
    end
  end
end
