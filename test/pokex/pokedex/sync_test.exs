defmodule Pokex.Pokedex.SyncTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Sync

  describe "incomplete/1 — o alvo do passe de completar" do
    test "entrada sem moves (dataset antigo) conta como incompleta" do
      assert [%{"name" => "Sceptile"}] =
               Sync.incomplete([
                 %{"name" => "Sceptile", "level" => 100},
                 %{"name" => "Seadra", "level" => 50, "moves" => [%{"slot" => "M1"}]}
               ])
    end

    test "moves: [] também é gap — foi assim que 202 entradas ficaram sem ataques" do
      assert [%{"name" => "Seadra"}] = Sync.incomplete([%{"name" => "Seadra", "moves" => []}])
    end

    test "página já lida NESTE run (moves: []) não é buscada de novo" do
      entries = [
        %{"name" => "Seadra", "moves" => [], "scraped_at" => "2026-07-22T10:00:00Z"},
        %{"name" => "Sceptile", "moves" => [], "scraped_at" => "2026-07-01T10:00:00Z"}
      ]

      assert [%{"name" => "Sceptile"}] = Sync.incomplete(entries, "2026-07-22T10:00:00Z")
    end

    test "shiny do fallback (moves: nil) é retentado no MESMO run" do
      entry = %{"name" => "Shiny Seadra", "moves" => nil, "scraped_at" => "2026-07-22T10:00:00Z"}

      assert [%{"name" => "Shiny Seadra"}] = Sync.incomplete([entry], "2026-07-22T10:00:00Z")
    end

    test "entrada colhida com movimentos não volta pro passe" do
      entry = %{"name" => "Seadra", "moves" => [%{"slot" => "M1", "name" => "Mud Shot"}]}
      assert Sync.incomplete([entry]) == []
    end

    test "aceita chaves atom (entradas recém-raspadas) além das de JSON" do
      assert [%{name: "Sceptile"}] =
               Sync.incomplete([
                 %{name: "Sceptile", moves: nil},
                 %{name: "Seadra", moves: [%{slot: "M1"}]}
               ])
    end
  end

  describe "download_sprite/3 — skip_sprites preserva, nunca esquece" do
    @tag :tmp_dir
    test "com skip_sprites, sprite já no disco mantém o path", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      File.write!(Path.join(tmp, "seadra.gif"), "gif")

      assert Sync.download_sprite("/images/f/f0/117_-_Seadra.gif", "Seadra", skip_sprites: true) ==
               "images/pokedex/seadra.gif"
    end

    @tag :tmp_dir
    test "com skip_sprites e NADA no disco, aí sim nil", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      assert Sync.download_sprite("/images/f/f0/117_-_Seadra.gif", "Seadra", skip_sprites: true) ==
               nil
    end

    test "sem URL não há sprite, com ou sem skip" do
      assert Sync.download_sprite(nil, "Seadra", skip_sprites: true) == nil
    end
  end
end
