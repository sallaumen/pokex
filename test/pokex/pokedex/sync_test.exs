defmodule Pokex.Pokedex.SyncTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Sync

  describe "incomplete/1 — the completion pass's target" do
    test "an entry without moves (old dataset) counts as incomplete" do
      assert [%{"name" => "Sceptile"}] =
               Sync.incomplete([
                 %{"name" => "Sceptile", "level" => 100},
                 %{"name" => "Seadra", "level" => 50, "moves" => [%{"slot" => "M1"}]}
               ])
    end

    # an empty list once passed as complete and left 202 entries without moves
    test "moves: [] is also a gap" do
      assert [%{"name" => "Seadra"}] = Sync.incomplete([%{"name" => "Seadra", "moves" => []}])
    end

    test "a page already read in this run (moves: []) is not fetched again" do
      entries = [
        %{"name" => "Seadra", "moves" => [], "scraped_at" => "2026-07-22T10:00:00Z"},
        %{"name" => "Sceptile", "moves" => [], "scraped_at" => "2026-07-01T10:00:00Z"}
      ]

      assert [%{"name" => "Sceptile"}] = Sync.incomplete(entries, "2026-07-22T10:00:00Z")
    end

    test "a fallback shiny (moves: nil) is retried in the same run" do
      entry = %{"name" => "Shiny Seadra", "moves" => nil, "scraped_at" => "2026-07-22T10:00:00Z"}

      assert [%{"name" => "Shiny Seadra"}] = Sync.incomplete([entry], "2026-07-22T10:00:00Z")
    end

    test "an entry harvested with moves does not return to the pass" do
      entry = %{"name" => "Seadra", "moves" => [%{"slot" => "M1", "name" => "Mud Shot"}]}
      assert Sync.incomplete([entry]) == []
    end

    test "accepts atom keys (freshly scraped entries) besides JSON string keys" do
      assert [%{name: "Sceptile"}] =
               Sync.incomplete([
                 %{name: "Sceptile", moves: nil},
                 %{name: "Seadra", moves: [%{slot: "M1"}]}
               ])
    end
  end

  describe "download_sprite/3 — skip_sprites preserves, never forgets" do
    @tag :tmp_dir
    test "with skip_sprites, a sprite already on disk keeps its path", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      File.write!(Path.join(tmp, "seadra.gif"), "gif")

      assert Sync.download_sprite("/images/f/f0/117_-_Seadra.gif", "Seadra", skip_sprites: true) ==
               "images/pokedex/seadra.gif"
    end

    @tag :tmp_dir
    test "with skip_sprites and nothing on disk, returns nil", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      assert Sync.download_sprite("/images/f/f0/117_-_Seadra.gif", "Seadra", skip_sprites: true) ==
               nil
    end

    test "no URL means no sprite, with or without skip" do
      assert Sync.download_sprite(nil, "Seadra", skip_sprites: true) == nil
    end
  end
end
