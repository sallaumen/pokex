defmodule Pokex.Vision.CreatureFence do
  @moduledoc """
  Which colour blobs are standing on a LIVE creature, and which of those creatures are HIS.

  Two questions the shiny watcher has to answer about every blob, and both already had an
  answer somewhere else in the code.

  **Is there a creature under it?** The client paints a health bar over every living creature
  and `CreatureMarks` finds them. A blob with no bar above it is scenery by definition — the
  ground, a crate, a CORPSE (which has no bar). That was the fence born in #583.

  **Is that creature his own pokémon?** `PokemonSprites` is the "Meu pokémon (rastreio)"
  collection: the angles he taught of the pokémon that walks with him. `CrowdScan` has read it
  since #553 to know where his pet is; the watcher never did, so his own SHINY VENUSAUR —
  taught, listed, on the panel — was announced as a shiny to hunt. He was right: the pieces
  existed and were not connected.

  Turning an entry OFF in that collection is the off switch, and it is the honest one: "não
  rastreie esse" and "esse não é meu" are the same sentence.

  Everything here speaks FRAME PIXELS, the frame the blobs were read in. The caller converts to
  screen points afterwards — comparing a screen point with a frame pixel is two different
  rulers.
  """

  alias Pokex.Bots.PokemonSprites
  alias Pokex.Settings
  alias Pokex.Vision.{CreatureMarks, Frame, SpriteLibrary}

  @type body :: %{point: {integer, integer}, mine: String.t() | nil}
  @type sorted :: %{quarry: [map], mine: [{map, String.t()}], bodyless: [map]}

  @doc """
  The live bodies in `frame`, each tagged with the name of HIS pokémon when the tracking
  collection recognises it.

  `tile_frame` is one game tile in frame pixels. `opts[:sprites]` and `opts[:floor]` are the
  test seams.
  """
  @spec bodies(Frame.t(), pos_integer, keyword) :: [body]
  def bodies(%Frame{} = frame, tile_frame, opts \\ []) do
    lib = Keyword.get_lazy(opts, :sprites, &PokemonSprites.library/0)
    floor = Keyword.get_lazy(opts, :floor, fn -> Settings.get(:pokemon_track_min_similarity) end)
    box = Settings.get(:pokemon_sprite_box_px)
    aimed = if SpriteLibrary.empty?(lib), do: nil, else: SpriteLibrary.aimed(lib)

    frame
    |> CreatureMarks.find()
    |> Enum.map(fn %{point: {x, y}} ->
      # DOIS PONTOS, DE PROPÓSITO. A cerca mede do corpo inteiro, um tile abaixo
      # da barra; a sprite ensinada foi recortada MEIO tile abaixo dela (#553:
      # mirando um tile inteiro o quadrado caía no chão, embaixo do bicho).
      %{
        point: {x, y + tile_frame},
        mine: mine(aimed, frame, {x, y + div(tile_frame, 2)}, box, floor)
      }
    end)
  end

  @doc """
  Splits `manchas` into what the watcher may hunt, what is standing on HIS pokémon, and what
  has no creature under it at all.

  `bodies` is `bodies/3`'s answer, or `:anywhere` when the fence is off — then everything is
  quarry and the other two buckets are empty.
  """
  @spec sort([map], [body] | :anywhere, pos_integer) :: sorted
  def sort(manchas, :anywhere, _tile_frame),
    do: %{quarry: manchas, mine: [], bodyless: []}

  def sort(manchas, bodies, tile_frame) do
    meio = div(tile_frame, 2)

    Enum.reduce(manchas, %{quarry: [], mine: [], bodyless: []}, fn mancha, acc ->
      case under(mancha, bodies, meio) do
        %{mine: name} when is_binary(name) -> %{acc | mine: acc.mine ++ [{mancha, name}]}
        %{} -> %{acc | quarry: acc.quarry ++ [mancha]}
        nil -> %{acc | bodyless: acc.bodyless ++ [mancha]}
      end
    end)
  end

  # O bicho MAIS PERTO, não o primeiro da lista: com dois bichos colados, o
  # primeiro a casar decidia se a mancha era caça ou era dele.
  defp under(%{point: {mx, my}}, bodies, meio) do
    bodies
    |> Enum.filter(fn %{point: {bx, by}} -> abs(mx - bx) <= meio and abs(my - by) <= meio end)
    |> Enum.min_by(fn %{point: {bx, by}} -> abs(mx - bx) + abs(my - by) end, fn -> nil end)
  end

  defp mine(nil, _frame, _center, _box, _floor), do: nil

  defp mine(aimed, frame, {cx, cy}, box, floor) do
    meia = div(box, 2)

    case SpriteLibrary.best_in(aimed, frame, {cx - meia, cy - meia, box, box}) do
      %{name: name, score: score, aimed?: true} when score >= floor -> name
      _not_his -> nil
    end
  end
end
