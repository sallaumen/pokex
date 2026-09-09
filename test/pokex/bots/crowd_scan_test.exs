defmodule Pokex.Bots.CrowdScanTest do
  @moduledoc """
  Marks on the screen become tiles from HIM and from his pokemon.
  """
  # async: false — scopes the global :home_dir env per test.
  use ExUnit.Case, async: false

  alias Pokex.Bots.CrowdScan
  alias Pokex.{Calibration, SettingsStash}
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  @tile 100
  @screen 1600
  @me {800, 800}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    # radius 3: the painted capture is 600×600 instead of 1200×1200; the
    # geometry under test is the same and the test runs in a blink.
    SettingsStash.stash!(crowd_scan_radius_tiles: 3)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: @screen,
      screen_h: @screen,
      tile_px: @tile,
      player_point: @me
    })

    :ok
  end

  # A mark whose BODY stands `{dx, dy}` tiles from him: the bar is one tile up.
  defp mark({dx, dy}, opts \\ []) do
    {px, py} = @me

    %{
      point: {px + dx * @tile, py + dy * @tile - @tile},
      hp_pct: Keyword.get(opts, :hp, 100),
      skull?: Keyword.get(opts, :skull?, false),
      pet?: Keyword.get(opts, :pet?, false)
    }
  end

  describe "placing marks" do
    test "a creature two right and two down is two tiles from him" do
      placed = CrowdScan.place([mark({2, 2})], @me, @tile)

      assert placed.read?
      assert placed.pet == nil

      assert [%{dx: 2, dy: 2, from_me: 2, from_pet: nil, hp_pct: 100, skull?: false}] =
               placed.hostiles
    end

    test "distance is Chebyshev in whole tiles" do
      assert [%{from_me: 3, dx: 0, dy: 3}] = CrowdScan.place([mark({0, 3})], @me, @tile).hostiles

      assert [%{from_me: 3, dx: -3, dy: 1}] =
               CrowdScan.place([mark({-3, 1})], @me, @tile).hostiles
    end

    test "hostiles come nearest to him first" do
      placed = CrowdScan.place([mark({5, 0}), mark({1, 1}), mark({-3, 0})], @me, @tile)
      assert Enum.map(placed.hostiles, & &1.from_me) == [1, 3, 5]
    end

    test "the mark standing on his own tile is him, not a hostile" do
      placed = CrowdScan.place([mark({0, 0}), mark({2, 0})], @me, @tile)
      assert length(placed.hostiles) == 1
    end

    # On his notebook the tile was still calibrated at 151 (it is 36), and his
    # own bar, 36 px over his head, read as a hostile one tile away all day.
    # A bar straight over his head with his own health is him, whatever the tile.
    test "a bar straight above him with his health is him even when the tile is wrong" do
      {px, py} = @me
      own = %{point: {px + 6, py - 36}, hp_pct: 100, skull?: false, pet?: false}
      other = %{point: {px + 6, py - 36}, hp_pct: 40, skull?: false, pet?: false}

      assert CrowdScan.place([own], @me, 151, me_hp: 100).hostiles == []
      assert [%{hp_pct: 40}] = CrowdScan.place([other], @me, 151, me_hp: 100).hostiles
    end
  end

  describe "his pokemon" do
    test "is the number-boxed mark nearest to him, and every hostile is also measured from it" do
      placed =
        CrowdScan.place([mark({0, 2}, pet?: true), mark({1, 3}), mark({-4, 2})], @me, @tile)

      assert %{dx: 0, dy: 2, tiles: 2, hp_pct: 100} = placed.pet
      assert [%{from_me: 3, from_pet: 1}, %{from_me: 4, from_pet: 4}] = placed.hostiles
    end

    test "another boxed creature farther away is a hostile, not a second pet" do
      placed = CrowdScan.place([mark({0, 2}, pet?: true), mark({5, 5}, pet?: true)], @me, @tile)

      assert placed.pet.dx == 0
      assert [%{dx: 5, dy: 5}] = placed.hostiles
    end

    test "without a boxed mark there is no pet and from_pet is nil" do
      placed = CrowdScan.place([mark({1, 1})], @me, @tile)
      assert placed.pet == nil
      assert [%{from_pet: nil}] = placed.hostiles
    end

    # On his notebook no box is drawn under the pet's bar; what the Pokebar
    # reads (39% for the Torterra) is what the bar on the field shows (36%).
    test "without a box, the mark whose health matches the Pokebar is the pet" do
      marks = [mark({0, 2}, hp: 36), mark({1, 3}, hp: 32), mark({-4, 2}, hp: 100)]
      placed = CrowdScan.place(marks, @me, @tile, pet_hp: 39)

      assert %{dx: 0, dy: 2, hp_pct: 36} = placed.pet
      assert Enum.map(placed.hostiles, & &1.hp_pct) == [32, 100]
    end

    test "two marks within a column of the Pokebar: the nearest to him is the pet" do
      marks = [mark({4, 4}, hp: 40), mark({0, 2}, hp: 36)]
      assert %{dx: 0, dy: 2} = CrowdScan.place(marks, @me, @tile, pet_hp: 39).pet
    end

    test "the number box wins over a health match" do
      marks = [mark({3, 3}, pet?: true, hp: 100), mark({0, 2}, hp: 39)]
      assert %{dx: 3, dy: 3} = CrowdScan.place(marks, @me, @tile, pet_hp: 39).pet
    end

    test "no bar within a column of the Pokebar means no pet, not a guess" do
      marks = [mark({0, 2}, hp: 32), mark({1, 3}, hp: 100)]
      assert CrowdScan.place(marks, @me, @tile, pet_hp: 39).pet == nil
    end

    # THE TAUGHT SPRITE WINS (09/09): "ele muitas vezes troca qual é o pokémon
    # que ele acha que é o meu". The mark whose body the taught library
    # recognised is the pet, whatever box or health the others show.
    test "the mark the taught sprites named is the pet, over the box and the health" do
      marks = [mark({3, 3}, pet?: true, hp: 100), mark({0, 2}, hp: 39), mark({-2, 1}, hp: 70)]
      taught = mark({-2, 1}).point

      placed =
        CrowdScan.place(marks, @me, @tile,
          pet_hp: 39,
          sprite: %{point: taught, score: 0.87}
        )

      assert %{dx: -2, dy: 1, hp_pct: 70} = placed.pet
      assert Enum.map(placed.hostiles, & &1.hp_pct) == [39, 100]
    end

    # A NOTA VIAJA JUNTO DO PONTO. Ela decidia e era jogada fora: o card do
    # cerco não tinha como dizer o quanto ele acredita que aquele quadrado é o
    # pokémon dele, e caía no "não se sabe por qual caminho" justamente quando
    # a sprite ensinada era quem tinha decidido.
    test "the sprite's score travels with the point, all the way to the reading" do
      marks = [mark({-2, 1}, hp: 70)]

      placed =
        CrowdScan.place(marks, @me, @tile, sprite: %{point: mark({-2, 1}).point, score: 0.94})

      assert %{by: :sprite, score: 0.94} = placed.pet
    end

    test "a taught point matching no mark falls back to the box" do
      marks = [mark({3, 3}, pet?: true), mark({0, 2})]

      placed = CrowdScan.place(marks, @me, @tile, sprite: %{point: {1, 1}, score: 0.9})

      assert %{dx: 3, dy: 3, by: :box, score: nil} = placed.pet
    end
  end

  # …AND ON THE SCREEN: the library is his own three or four angles of the
  # Torterra; the eye scores every body against them and takes his by name.
  describe "his pokemon by its taught sprite" do
    @pet_blue <<20, 40, 220, 255>>

    defp teach!(name, color) do
      crop = %Frame{width: 96, height: 96, rgba: :binary.copy(color, 96 * 96), scale: 1.0}
      {:ok, _} = Pokex.Bots.PokemonSprites.add(name, crop)
    end

    test "the body painted like the taught Torterra is the pet, not the boxed one" do
      SettingsStash.stash!(pokemon_sprite_box_px: 96, pokemon_track_min_similarity: 0.55)
      teach!("Torterra", @pet_blue)

      reading =
        look_at([{2, 2}, {-2, 1}],
          listed: 2,
          pet_name: "Torterra",
          body_color: {{-2, 1}, @pet_blue}
        )

      assert %{dx: -2, dy: 1, by: :sprite} = reading.pet
      assert [%{dx: 2, dy: 2, from_pet: 4}] = reading.hostiles

      # A NOTA CHEGA NA LEITURA. Ela era calculada, decidia, e morria no
      # caminho entre `look/1` e `place/4`: `pet.score` voltava nil em toda
      # leitura de verdade, e o card do cerco dizia "não se sabe por qual
      # caminho" sobre o único caminho que sabia.
      assert is_float(reading.pet.score)
      assert reading.pet.score >= 0.55
    end

    test "a taught body of ANOTHER pokemon is not his" do
      SettingsStash.stash!(pokemon_sprite_box_px: 96, pokemon_track_min_similarity: 0.55)
      teach!("Shiny Venusaur", @pet_blue)

      reading =
        look_at([{2, 2}, {-2, 1}],
          listed: 2,
          pet_name: "Torterra",
          body_color: {{-2, 1}, @pet_blue}
        )

      assert reading.pet == nil
      assert length(reading.hostiles) == 2
    end

    # In one of the 34 frames measured on 09/09 the pokémon was not in the
    # picture and two monsters tied at 0.554 and 0.552 against the taught
    # Torterra. Picking the winner of a coin toss IS the flipping he sees.
    test "two bodies that look the same are no answer: the box and the health decide" do
      SettingsStash.stash!(pokemon_sprite_box_px: 96, pokemon_track_min_similarity: 0.55)
      teach!("Torterra", @pet_blue)

      reading =
        look_at([{2, 2}, {-2, 1}],
          listed: 2,
          pet_name: "Torterra",
          body_color: [{{-2, 1}, @pet_blue}, {{2, 2}, @pet_blue}]
        )

      assert reading.pet == nil
      assert length(reading.hostiles) == 2
    end

    test "with nothing taught the eye reads as before" do
      reading = look_at([{2, 2}, {-2, 1}], listed: 2, pet_name: "Torterra")

      assert reading.pet == nil
      assert length(reading.hostiles) == 2
    end
  end

  # HIS OWN SCREEN, NOT A PAINTED ONE (09/09). Every real-capture test until now
  # stopped at the BARS — `creature_marks_test` cobra where they are, and there
  # it ended. Nothing asked a real picture the question that matters: WHICH of
  # these is his pokémon, and how far is each monster from it. That gap is where
  # the two defects of this morning lived, and both passed every test.
  #
  # The reason it was never asked is in the old fixtures themselves: they are
  # hand-cut pieces of the screen, and the cut threw away the character's
  # position, which is what turns pixels into tiles. This one is a whole capture
  # box with the anchor kept: his Torterra two tiles above him and two Magnetons,
  # taken while he hunted (his own frame of 09/09, his own taught sprites, his
  # own name painted out).
  describe "his ultrawide, his Torterra and two Magnetons" do
    @shot "test/fixtures/crowd/ultrawide_torterra_e_magnetons.png"
    @taught "test/fixtures/crowd/sprites_ensinadas.json"
    @him {226, 464}

    defp his_screen! do
      Calibration.save(%Calibration{
        scale: 1.0,
        screen_w: 642,
        screen_h: 664,
        tile_px: 151,
        player_point: @him
      })

      SettingsStash.stash!(pokemon_sprite_box_px: 96, pokemon_track_min_similarity: 0.55)
      {:ok, frame} = Frame.from_png_file(@shot)
      frame
    end

    defp his_look(frame, opts) do
      CrowdScan.look([capture: fn _box, _name -> {:ok, frame} end, listed: 4] ++ opts)
    end

    test "the taught sprite finds his Torterra, and the two Magnetons fall where they stand" do
      frame = his_screen!()

      reading =
        his_look(frame,
          pet_name: "Torterra",
          sprites: Pokex.Vision.SpriteLibrary.new(@taught, 10)
        )

      assert %{dx: 0, dy: -2, tiles: 2, hp_pct: 100} = reading.pet

      assert [
               %{dx: -1, dy: 0, from_me: 1, from_pet: 1},
               %{dx: 2, dy: -1, from_me: 2, from_pet: 2}
             ] = reading.hostiles
    end

    # The proof that it was the SPRITE that answered: this client draws no
    # number box under his pokémon (measured over 40 of his frames that morning:
    # not one mark carried one), and no Pokebar reading is offered here. Take the
    # taught photos away and the eye has nothing left to name him with.
    test "with nobody taught, the same picture yields no pokemon at all" do
      frame = his_screen!()

      reading = his_look(frame, pet_name: "Torterra", sprites: empty_library())

      assert reading.pet == nil
      assert length(reading.hostiles) == 3
    end

    test "the taught photos of ANOTHER pokemon do not name his" do
      frame = his_screen!()

      reading =
        his_look(frame,
          pet_name: "Arcanine",
          sprites: Pokex.Vision.SpriteLibrary.new(@taught, 10)
        )

      assert reading.pet == nil
    end

    # "Muitas vezes a caçada está tão lenta que os monstros que eu matei
    # começam a renascer aqui ao meu redor (…) eles já renasceram com esse nome
    # rosa, o que quer dizer que eles não são agressivos para a gente. No seu
    # detector de quantidade de inimigos, você não sabe disso." His own capture
    # of 09/09 11:58, with one Magneton back on its feet next to his Torterra.
    test "the one that respawned is not an enemy, and is counted apart" do
      Calibration.save(%Calibration{
        scale: 1.0,
        screen_w: 400,
        screen_h: 460,
        tile_px: 151,
        player_point: {108, 46}
      })

      SettingsStash.stash!(pokemon_sprite_box_px: 96, pokemon_track_min_similarity: 0.55)
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/ultrawide_magneton_renascido.png")

      reading =
        CrowdScan.look(
          capture: fn _box, _name -> {:ok, frame} end,
          listed: 0,
          pet_name: "Torterra",
          sprites: Pokex.Vision.SpriteLibrary.new(@taught, 10)
        )

      assert %{dx: 0, dy: 3} = reading.pet
      assert reading.hostiles == []
      assert reading.passive == 1
    end

    defp empty_library do
      file = Path.join(System.tmp_dir!(), "vazia-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(file) end)
      Pokex.Vision.SpriteLibrary.new(file, 10)
    end
  end

  describe "looking at the screen" do
    test "a capture that fails says so instead of reporting an empty field" do
      reading = CrowdScan.look(capture: fn _region, _name -> {:error, :no_display} end)
      assert reading == %{read?: false, reason: :no_display}
    end

    test "no calibration is a reason, not a zero" do
      File.rm!(Pokex.Home.calibration_file())

      assert %{read?: false, reason: :not_calibrated} =
               CrowdScan.look(capture: fn _r, _n -> {:error, :never_called} end)
    end

    test "a bar painted on the captured box comes back placed, with the box and the clock" do
      reading = look_at([{2, 2}], listed: 3)

      assert reading.read?
      assert reading.listed == 3
      assert is_integer(reading.at)
      assert {500, 500, 600, 600} = reading.box
      assert [%{dx: 2, dy: 2, from_me: 2, hp_pct: 100}] = reading.hostiles
      assert reading.evidence == nil
    end

    test "asked for, the evidence is a picture a browser can draw" do
      reading = look_at([{2, 2}], evidence: true)

      assert "data:image/bmp;base64," <> b64 = reading.evidence
      assert {:ok, <<"BM", _rest::binary>>} = Base.decode64(b64)
    end
  end

  # Paints a full green health bar, sized by the ruler for this tile, one tile
  # above each body point inside the box the scan asks for, and hands it to
  # `look/1` as the capture.
  defp look_at(bodies, opts) do
    {px, py} = @me
    # the bar is a UI element: 27×4 points at 1 pixel per point, whatever the tile
    %{bar_w: bw, bar_h: bh} = geo = Pokex.Vision.CreatureMarks.geometry(1.0)
    {body_opt, opts} = Keyword.pop(opts, :body_color)

    capture = fn {rx, ry, w, h}, _name ->
      bars =
        Enum.map(bodies, fn {dx, dy} ->
          {px + dx * @tile - div(bw, 2) - rx, py + dy * @tile - @tile - div(bh, 2) - ry}
        end)

      # A body painted one colour, 96×96 around the middle of its ART — HALF a
      # tile under the bar, which is where the client draws it (measured on his
      # own frames 09/09). Its SQUARE is a whole tile under the bar; the picture
      # overlaps upward.
      body =
        Enum.map(List.wrap(body_opt), fn {{dx, dy}, color} ->
          {{px + dx * @tile - 48 - rx, py + dy * @tile - div(@tile, 2) - 48 - ry}, color}
        end)

      rgba = for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>>, do: pixel(bars, geo, body, x, y)
      {:ok, %Frame{width: w, height: h, rgba: rgba, scale: 1.0}}
    end

    CrowdScan.look(Keyword.put(opts, :capture, capture))
  end

  # Green inside a bar, black on its border, the body's colour where one is
  # painted, sand everywhere else.
  defp pixel(bars, geo, body, x, y) do
    case Enum.find(bars, &covers?(&1, geo, x, y)) do
      nil -> body_pixel(body, x, y)
      bar -> if border?(bar, geo, x, y), do: <<0, 0, 0, 255>>, else: <<0, 188, 0, 255>>
    end
  end

  defp body_pixel(bodies, x, y) do
    Enum.find_value(bodies, <<224, 192, 128, 255>>, fn {{bx, by}, color} ->
      x >= bx and x < bx + 96 and y >= by and y < by + 96 and color
    end)
  end

  defp covers?({bx, by}, %{bar_w: bw, bar_h: bh}, x, y),
    do: x >= bx and x < bx + bw and y >= by and y < by + bh

  defp border?({bx, by}, %{bar_w: bw, bar_h: bh}, x, y),
    do: x == bx or x == bx + bw - 1 or y == by or y == by + bh - 1

  # A JUNÇÃO QUE FALTAVA (09/09): a guarda acha o shiny pela COR e o olho acha
  # os corpos pela BARRA, e nada dizia QUAL dos corpos é o shiny. Os dois falam
  # em pontos de tela, então a distância responde.
  describe "which body the special colour is sitting on" do
    defp reading(hostiles) do
      %{
        read?: true,
        me: {500, 500},
        hostiles: Enum.map(hostiles, &%{point: &1, dx: 0, dy: 0, from_me: 1, hp_pct: 100})
      }
    end

    test "a blob on a body marks that body, with the px that made the claim" do
      vistos = [%{name: "Charizard preto", px: 12_605, point: {620, 505}}]

      assert %{hostiles: [um, dois]} =
               CrowdScan.mark_special(reading([{600, 500}, {900, 900}]), vistos, 151)

      assert um.special? == true
      assert um.special_name == "Charizard preto"
      assert um.special_px == 12_605
      refute Map.has_key?(dois, :special?)
    end

    test "a blob farther than a tile marks nobody" do
      vistos = [%{name: "Charizard preto", px: 900, point: {1_000, 1_000}}]
      assert %{hostiles: [um]} = CrowdScan.mark_special(reading([{600, 500}]), vistos, 151)
      refute Map.has_key?(um, :special?)
    end

    test "an unread reading is handed back untouched" do
      assert %{read?: false} = CrowdScan.mark_special(%{read?: false, reason: :x}, [], 151)
    end
  end
end
