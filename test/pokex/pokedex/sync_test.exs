defmodule Pokex.Pokedex.SyncTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Sync

  describe "download_sprite/2 — skip_sprites preserves, never forgets" do
    @tag :tmp_dir
    test "with skip_sprites, a sprite already on disk keeps its path", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      File.write!(Path.join(tmp, "001.png"), "png")

      assert Sync.download_sprite("/pokemon/001.png", skip_sprites: true) ==
               "images/pokedex/001.png"
    end

    @tag :tmp_dir
    test "a shiny's sprite keeps the variant suffix the wiki serves it under", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      File.write!(Path.join(tmp, "001.1.png"), "png")

      assert Sync.download_sprite("/pokemon/001.1.png", skip_sprites: true) ==
               "images/pokedex/001.1.png"
    end

    @tag :tmp_dir
    test "with skip_sprites and nothing on disk, returns nil", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      assert Sync.download_sprite("/pokemon/001.png", skip_sprites: true) == nil
    end

    test "no URL means no sprite, with or without skip" do
      assert Sync.download_sprite(nil, skip_sprites: true) == nil
    end
  end
end
