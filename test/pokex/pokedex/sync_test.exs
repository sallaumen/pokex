defmodule Pokex.Pokedex.SyncTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Sync

  describe "incomplete/1 — o alvo do passe de completar" do
    test "entrada sem moves (dataset antigo) conta como incompleta" do
      assert [%{"name" => "Sceptile"}] =
               Sync.incomplete([
                 %{"name" => "Sceptile", "level" => 100},
                 %{"name" => "Seadra", "level" => 50, "moves" => []}
               ])
    end

    test "moves: [] é COMPLETA — a wiki simplesmente não tem tabela ali" do
      assert Sync.incomplete([%{"name" => "Seadra", "moves" => []}]) == []
    end

    test "entrada colhida com movimentos não volta pro passe" do
      entry = %{"name" => "Seadra", "moves" => [%{"slot" => "M1", "name" => "Mud Shot"}]}
      assert Sync.incomplete([entry]) == []
    end

    test "aceita chaves atom (entradas recém-raspadas) além das de JSON" do
      assert [%{name: "Sceptile"}] =
               Sync.incomplete([
                 %{name: "Sceptile", moves: nil},
                 %{name: "Seadra", moves: []}
               ])
    end
  end
end
