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
end
