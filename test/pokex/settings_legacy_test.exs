defmodule Pokex.Settings.LegacyTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.AlarmCategories
  alias Pokex.Settings.Legacy

  describe "value/2" do
    test "translates a Portuguese value into the canonical English one" do
      assert Legacy.value(:player_mode, "parado") == "still"
      assert Legacy.value(:player_mode, "movimento") == "moving"
      assert Legacy.value(:player_mode, "caçada") == "hunt"
      assert Legacy.value(:stop_after_action, "parar") == "stop"
      assert Legacy.value(:stop_after_action, "deslogar") == "logout"
      assert Legacy.value(:stagnation_action, "deslogar") == "logout"
    end

    test "a canonical value passes through untouched" do
      assert Legacy.value(:player_mode, "still") == "still"
      assert Legacy.value(:stop_after_action, "stop") == "stop"
    end

    test "a key with no legacy spelling is returned as it came" do
      assert Legacy.value(:corpse_match_min_similarity, 0.72) == 0.72
      assert Legacy.value(:ball_key, "f2") == "f2"
      assert Legacy.value(:unknown_key, "parado") == "parado"
    end

    test "an unknown value on a translated key survives — a hand-edited file is not data loss" do
      assert Legacy.value(:player_mode, "voando") == "voando"
    end

    test "the muted-alarm list translates element by element, keeping order and English ones" do
      muted = ["vida", "cavebot", "logout", "estoque", "pesca", "captura", "comando", "sessao"]

      assert Legacy.value(:alarm_muted_categories, muted) ==
               ["hp", "cavebot", "logout", "stock", "fishing", "capture", "command", "session"]
    end
  end

  describe "map/1" do
    test "translates every value of a whole settings map" do
      legacy = %{
        player_mode: "caçada",
        stop_after_action: "deslogar",
        alarm_muted_categories: ["erro", "fuga"],
        corpse_max_balls: 2
      }

      assert Legacy.map(legacy) == %{
               player_mode: "hunt",
               stop_after_action: "logout",
               alarm_muted_categories: ["error", "escape"],
               corpse_max_balls: 2
             }
    end
  end

  # His real file on 2026-07-31: ten sectors muted, only shiny left ringing.
  # Losing this list means every alarm he silenced comes screaming back.
  test "the muted sectors of a real legacy file survive the migration whole" do
    real = [
      "vida",
      "cavebot",
      "logout",
      "estoque",
      "pesca",
      "captura",
      "comando",
      "sessao",
      "fuga",
      "erro"
    ]

    migrated = Legacy.value(:alarm_muted_categories, real)

    assert length(migrated) == length(real)

    # HIS ten, spelled out: "todos menos shiny" was a shortcut that only held
    # while the sector list had exactly these — adding a sector later must not
    # silence it retroactively for him.
    assert Enum.sort(migrated) ==
             Enum.sort(~w(hp cavebot logout stock fishing capture command session escape error))

    assert Enum.all?(migrated, &(AlarmCategories.from_string(&1) != nil)),
           "a migração produziu um setor que não existe"
  end
end
