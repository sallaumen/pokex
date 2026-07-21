defmodule Pokex.Pokedex.ShinySignaturesTest do
  # async: false — scopes global env (:pokedex_path, :sprites_root) and the
  # signature cache per test
  use ExUnit.Case, async: false

  alias Pokex.Pokedex.ShinySignatures
  alias Pokex.{PngFixtures, Settings, SettingsStash}
  alias Pokex.Vision.Frame

  # a solid-color RGBA sprite/frame
  defp png!(dir, name, w, h, {r, g, b}) do
    rows = for _y <- 1..h, do: List.duplicate({r, g, b, 255}, w)
    PngFixtures.write!(Path.join(dir, name), rows)
  end

  # dark arena with an optional solid blob at {bx, by, bw, bh}
  defp arena_frame!(dir, blob \\ nil) do
    rows =
      for y <- 1..64 do
        for x <- 1..96 do
          case blob do
            {bx, by, bw, bh, color} when x >= bx and x < bx + bw and y >= by and y < by + bh ->
              Tuple.append(color, 255)

            _dark ->
              {20, 20, 20, 255}
          end
        end
      end

    path = PngFixtures.write!(Path.join(dir, "arena.png"), rows)
    {:ok, frame} = Frame.from_png_file(path)
    frame
  end

  setup %{tmp_dir: tmp} do
    # dex: Seadra (blue) + Shiny Seadra (white), sprites under a scoped root
    png!(tmp, "seadra.png", 20, 20, {40, 80, 200})
    png!(tmp, "shiny-seadra.png", 20, 20, {230, 230, 230})

    dataset = %{
      "species" => [
        %{
          "name" => "Seadra",
          "number" => 117,
          "sprite" => "seadra.png",
          "shiny_name" => "Shiny Seadra"
        },
        %{
          "name" => "Shiny Seadra",
          "number" => 117,
          "sprite" => "shiny-seadra.png",
          "shiny_of" => "Seadra"
        }
      ],
      "lures" => []
    }

    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(dataset))
    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :sprites_root, tmp)

    SettingsStash.stash!(shiny_watch_names: ["Seadra"])

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Application.delete_env(:pokex, :sprites_root)
      ShinySignatures.clear()
    end)

    %{tmp: tmp}
  end

  @tag :tmp_dir
  test "rebuild keeps only the colors EXCLUSIVE to the shiny sprite", %{tmp: _tmp} do
    assert {:ok, ["Shiny Seadra"]} = ShinySignatures.rebuild()

    [%{name: "Shiny Seadra", buckets: buckets}] = ShinySignatures.signatures()

    # white (230>>5 = 7) survives; the base's blue (40,80,200 >> 5 = {1,2,6}) never enters
    assert MapSet.member?(buckets, {7, 7, 7})
    refute MapSet.member?(buckets, {1, 2, 6})
  end

  @tag :tmp_dir
  test "a missing watched name is skipped, never a crash" do
    Settings.put(:shiny_watch_names, ["Seadra", "Naoexiste"])
    assert {:ok, ["Shiny Seadra"]} = ShinySignatures.rebuild()
  end

  @tag :tmp_dir
  test "scan finds a clustered white blob and reports the shiny; clean arena reads nil", %{
    tmp: tmp
  } do
    {:ok, _} = ShinySignatures.rebuild()

    # a 24×14 white blob — hundreds of matching px in one block
    with_shiny = arena_frame!(tmp, {30, 20, 24, 14, {230, 230, 230}})
    assert %{name: "Shiny Seadra", px: px} = ShinySignatures.scan(with_shiny, 12)
    assert px > 100

    clean = arena_frame!(tmp)
    assert ShinySignatures.scan(clean, 12) == nil

    # the BASE color never triggers the shiny signature
    blue = arena_frame!(tmp, {30, 20, 24, 14, {40, 80, 200}})
    assert ShinySignatures.scan(blue, 12) == nil
  end

  @tag :tmp_dir
  test "probe lists every watched signature with its score", %{tmp: tmp} do
    {:ok, _} = ShinySignatures.rebuild()
    clean = arena_frame!(tmp)
    assert [{"Shiny Seadra", 0}] = ShinySignatures.probe(clean)
  end

  @tag :tmp_dir
  test "learn_baseline subtracts the water colors so a shiny-colored blob stops firing", %{
    tmp: tmp
  } do
    {:ok, _} = ShinySignatures.rebuild()

    # the white the signature hunts ALSO fills this 'clean water' frame → learning
    # it as baseline must remove white from the signature
    watery = arena_frame!(tmp, {0, 0, 96, 64, {230, 230, 230}})
    assert {:ok, %{baseline: n}} = ShinySignatures.learn_baseline(watery)
    assert n > 0

    # now the same white blob no longer triggers (white left the signature)
    blob = arena_frame!(tmp, {30, 20, 24, 14, {230, 230, 230}})
    assert ShinySignatures.scan(blob, 12) == nil

    # forgetting the baseline widens the signature back — white returns
    ShinySignatures.forget_baseline()
    assert %{name: "Shiny Seadra"} = ShinySignatures.scan(blob, 12)
  end

  @tag :tmp_dir
  test "preview carries the sprites and color swatches the detector is hunting" do
    {:ok, _} = ShinySignatures.rebuild()

    assert [%{name: "Shiny Seadra", shiny_sprite: "shiny-seadra.png", swatches: swatches} = p] =
             ShinySignatures.preview()

    assert p.base_sprite == "seadra.png"
    assert p.bucket_count > 0
    # the white bucket center is near-white
    assert Enum.any?(swatches, fn {r, g, b} -> r > 200 and g > 200 and b > 200 end)
  end
end
