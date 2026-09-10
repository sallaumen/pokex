defmodule Pokex.Vision.CreatureFenceTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.PokemonSprites
  alias Pokex.SettingsStash
  alias Pokex.Vision.{CreatureFence, CreatureMarks, Frame}

  @moduletag :tmp_dir

  @tile 40
  @chao {224, 192, 128}
  @dele {20, 40, 220}
  # a barra do cliente: 27x4 pontos, e a foto do teste é 1 pixel por ponto
  @geo CreatureMarks.geometry(1.0)

  # a barra DELE à esquerda, a do bicho selvagem à direita, longe o bastante
  # pras duas janelas de 96 px não se tocarem
  @bar_dele {100, 60}
  @bar_selvagem {250, 60}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    SettingsStash.stash!(pokemon_sprite_box_px: 96, pokemon_track_min_similarity: 0.55)
    on_exit(fn -> Pokex.TestHome.restore() end)
    :ok
  end

  describe "bodies/3" do
    test "the body painted like his taught pokemon comes back with its name" do
      teach!("Shiny Venusaur")

      assert [dele, selvagem] = CreatureFence.bodies(cena(), @tile)

      assert dele.point == body_point(@bar_dele)
      assert dele.mine == "Shiny Venusaur"
      assert selvagem.point == body_point(@bar_selvagem)
      assert selvagem.mine == nil
    end

    test "with nothing taught nobody is his" do
      assert CreatureFence.bodies(cena(), @tile) |> Enum.map(& &1.mine) == [nil, nil]
    end

    # O DESLIGAR DO ACERVO É O INTERRUPTOR. "Não rastreie esse" e "esse não é
    # meu" são a mesma frase, e não vale inventar um segundo botão pra ela.
    test "an entry turned off in the collection stops being his" do
      teach!("Shiny Venusaur")
      [%{"slug" => slug}] = PokemonSprites.list()
      PokemonSprites.set_enabled(slug, false)

      assert CreatureFence.bodies(cena(), @tile) |> Enum.map(& &1.mine) == [nil, nil]
    end
  end

  describe "sort/3" do
    test "a blob on his pokemon is his, one on the wild creature is quarry" do
      teach!("Shiny Venusaur")
      corpos = CreatureFence.bodies(cena(), @tile)

      manchas = [
        mancha(body_point(@bar_dele)),
        mancha(body_point(@bar_selvagem)),
        mancha({20, 280})
      ]

      assert %{quarry: [caca], mine: [{meu, "Shiny Venusaur"}], bodyless: [longe]} =
               CreatureFence.sort(manchas, corpos, @tile)

      assert caca.point == body_point(@bar_selvagem)
      assert meu.point == body_point(@bar_dele)
      assert longe.point == {20, 280}
    end

    test "with the fence off everything is quarry" do
      manchas = [mancha({1, 1}), mancha({2, 2})]

      assert %{quarry: ^manchas, mine: [], bodyless: []} =
               CreatureFence.sort(manchas, :anywhere, @tile)
    end

    # O BICHO MAIS PERTO DECIDE. Com dois corpos colados, o primeiro da lista a
    # casar mandava — e o pokémon dele podia levar a mancha do vizinho.
    test "the nearest body decides, not the first that matches" do
      corpos = [
        %{point: {100, 100}, mine: "Shiny Venusaur"},
        %{point: {118, 100}, mine: nil}
      ]

      assert %{quarry: [_um], mine: []} =
               CreatureFence.sort([mancha({119, 100})], corpos, @tile)
    end

    test "a blob with no creature under it is neither quarry nor his" do
      corpos = [%{point: {100, 100}, mine: nil}]

      assert %{quarry: [], mine: [], bodyless: [_uma]} =
               CreatureFence.sort([mancha({300, 300})], corpos, @tile)
    end
  end

  defp teach!(name) do
    {r, g, b} = @dele

    crop = %Frame{
      width: 96,
      height: 96,
      rgba: :binary.copy(<<r, g, b, 255>>, 96 * 96),
      scale: 1.0
    }

    {:ok, _kept} = PokemonSprites.add(name, crop)
  end

  defp mancha(point), do: %{point: point, px: 1_000, box: {0, 0, 1, 1}}

  # o corpo fica UM TILE abaixo do centro da barra
  defp body_point({bx, by}),
    do: {bx + div(@geo.bar_w, 2), by + div(@geo.bar_h, 2) + @tile}

  # a arte do bicho é recortada MEIO tile abaixo da barra: é lá que a janela de
  # 96 px da sprite ensinada cai
  defp art_box({bx, by}) do
    {cx, cy} = {bx + div(@geo.bar_w, 2), by + div(@geo.bar_h, 2) + div(@tile, 2)}
    {cx - 48, cy - 48}
  end

  defp cena do
    w = 400
    h = 300
    bars = [@bar_dele, @bar_selvagem]
    arte = [{art_box(@bar_dele), @dele}]

    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        {r, g, b} = pixel(bars, arte, x, y)
        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  # a barra vem ANTES da arte: `frame` pinta o primeiro retalho que casa, e uma
  # barra tapada pela arte é uma barra que o olho não acha
  defp pixel(bars, arte, x, y) do
    case Enum.find(bars, &covers?(&1, x, y)) do
      nil -> arte_pixel(arte, x, y)
      bar -> if border?(bar, x, y), do: {0, 0, 0}, else: {0, 188, 0}
    end
  end

  defp arte_pixel(arte, x, y) do
    Enum.find_value(arte, @chao, fn {{ax, ay}, cor} ->
      x >= ax and x < ax + 96 and y >= ay and y < ay + 96 and cor
    end)
  end

  defp covers?({bx, by}, x, y),
    do: x >= bx and x < bx + @geo.bar_w and y >= by and y < by + @geo.bar_h

  defp border?({bx, by}, x, y),
    do: x == bx or x == bx + @geo.bar_w - 1 or y == by or y == by + @geo.bar_h - 1
end
