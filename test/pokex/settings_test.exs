defmodule Pokex.SettingsTest do
  # async: false — the ETS-mirror tests touch the GLOBAL instance.
  use ExUnit.Case, async: false
  alias Pokex.Settings

  @tag :tmp_dir
  test "a fresh install persists NO overrides; every value comes from the code seed", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "settings.json")
    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert path |> File.read!() |> JSON.decode!() == %{}

    assert Settings.get(:tick_ms_watching, server) == 150
    assert Settings.get(:skill_keys, server) == ["1", "2", "3"]
    assert Settings.get(:rod_key, server) == "shift+v"
    assert Settings.get(:wait_assess_ms, server) == 700
  end

  @tag :tmp_dir
  test "put persists ONLY the overridden keys, and they reload", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    {:ok, server} = Settings.start_link(name: nil, path: path)

    :ok = Settings.put(:glow_threshold, 22.5, server)
    :ok = Settings.put(:skill_keys, ["1", "2", "3", "4"], server)

    assert path |> File.read!() |> JSON.decode!() ==
             %{"glow_threshold" => 22.5, "skill_keys" => ["1", "2", "3", "4"]}

    {:ok, server2} = Settings.start_link(name: nil, path: path)
    assert Settings.get(:glow_threshold, server2) == 22.5
    assert Settings.get(:skill_keys, server2) == ["1", "2", "3", "4"]
    assert Settings.get(:tile_px, server2) == Settings.defaults()[:tile_px]
  end

  # A boolean turned OFF is the most common override there is; migrating values
  # on load with a plain `=` inside the comprehension would filter every `false`
  # away and quietly turn the setting back on.
  @tag :tmp_dir
  test "an override of false survives the reload", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    File.write!(path, ~s({"capture_enabled": false, "loot_enabled": false}))

    {:ok, server} = Settings.start_link(name: nil, path: path)

    refute Settings.get(:capture_enabled, server)
    refute Settings.get(:loot_enabled, server)

    assert path |> File.read!() |> JSON.decode!() ==
             %{"capture_enabled" => false, "loot_enabled" => false}
  end

  # Values written in Portuguese by an older build must arrive as today's
  # spelling — and the file must be rewritten, so this happens once.
  @tag :tmp_dir
  test "a settings file written in Portuguese is migrated on load and healed on disk", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "settings.json")

    File.write!(
      path,
      JSON.encode!(%{
        "player_mode" => "movimento",
        "shiny_action" => "fugir",
        "stop_after_action" => "deslogar",
        "alarm_muted_categories" => ["vida", "estoque", "captura"]
      })
    )

    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert Settings.get(:player_mode, server) == "moving"
    assert Settings.get(:shiny_action, server) == "escape"
    assert Settings.get(:stop_after_action, server) == "logout"
    assert Settings.get(:alarm_muted_categories, server) == ["hp", "stock", "capture"]

    assert path |> File.read!() |> JSON.decode!() == %{
             "player_mode" => "moving",
             "shiny_action" => "escape",
             "stop_after_action" => "logout",
             "alarm_muted_categories" => ["hp", "stock", "capture"]
           }
  end

  @tag :tmp_dir
  test "unknown keys are ignored and the file is healed to real overrides only", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    File.write!(path, ~s({"hacker": 1, "tile_px": 48}))
    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert Settings.get(:tile_px, server) == 48
    refute Settings.all(server) |> Map.has_key?(:hacker)

    assert path |> File.read!() |> JSON.decode!() == %{"tile_px" => 48}
  end

  @tag :tmp_dir
  # simulates the reverted materialize-all bug: keys equal to the seed must be
  # dropped so future default changes in code win again
  test "a materialized file (every key persisted) is healed down to genuine overrides", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "settings.json")

    full =
      Settings.defaults()
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.put("require_cooldowns", true)

    File.write!(path, JSON.encode!(full))
    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert path |> File.read!() |> JSON.decode!() == %{"require_cooldowns" => true}
    assert Settings.get(:require_cooldowns, server) == true
    assert Settings.get(:glow_threshold, server) == Settings.defaults().glow_threshold
  end

  @tag :tmp_dir
  test "putting a value back to the default drops the override", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    File.write!(path, ~s({"tile_px": 48}))
    {:ok, server} = Settings.start_link(name: nil, path: path)
    assert Settings.get(:tile_px, server) == 48

    :ok = Settings.put(:tile_px, Settings.defaults().tile_px, server)

    assert Settings.get(:tile_px, server) == Settings.defaults()[:tile_px]
    assert path |> File.read!() |> JSON.decode!() == %{}
  end

  @tag :tmp_dir
  # the parent of the settings path is a file, so mkdir_p!/write! deterministically
  # raise inside init's heal
  @tag :capture_log
  test "a non-writable settings path does not crash boot — runs off the code defaults", %{
    tmp_dir: tmp
  } do
    blocker = Path.join(tmp, "blocker")
    File.write!(blocker, "i am a file, not a directory")
    path = Path.join(blocker, "settings.json")

    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert Settings.get(:tick_ms_watching, server) == 150
    assert Settings.get(:rod_key, server) == "shift+v"
  end

  @tag :tmp_dir
  # the old normalize_loaded/2 migrations silently rewrote 6 -> 7 on write,
  # making those values impossible to select
  test "values a user deliberately sets are honored — no magic-value rewrite", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    {:ok, server} = Settings.start_link(name: nil, path: path)

    :ok = Settings.put(:skill_ready_min_vivid_pct, 6, server)
    :ok = Settings.put(:rod_key, "v", server)

    assert Settings.get(:skill_ready_min_vivid_pct, server) == 6
    assert Settings.get(:rod_key, server) == "v"

    {:ok, server2} = Settings.start_link(name: nil, path: path)
    assert Settings.get(:skill_ready_min_vivid_pct, server2) == 6
    assert Settings.get(:rod_key, server2) == "v"
  end

  # worker ticks call Settings.get/1 many times per 80ms tick across several
  # processes; global reads must be ETS lookups, not GenServer round-trips
  test "the GLOBAL server mirrors overrides into ETS so hot-loop reads skip the GenServer" do
    original = Settings.get(:glow_threshold)
    on_exit(fn -> Settings.put(:glow_threshold, original) end)

    :ok = Settings.put(:glow_threshold, 4321.0)
    assert :ets.lookup(:pokex_settings_overrides, :glow_threshold) == [{:glow_threshold, 4321.0}]
    assert Settings.get(:glow_threshold) == 4321.0

    :ok = Settings.put(:glow_threshold, Settings.defaults()[:glow_threshold])
    assert :ets.lookup(:pokex_settings_overrides, :glow_threshold) == []
    assert Settings.get(:glow_threshold) == Settings.defaults()[:glow_threshold]
  end

  @tag :tmp_dir
  test "a JSON null in the file is corruption, not an override", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    File.write!(path, ~s({"glow_threshold":null}))

    {:ok, server} = Settings.start_link(name: nil, path: path)
    assert Settings.get(:glow_threshold, server) == Settings.defaults()[:glow_threshold]
  end

  @tag :tmp_dir
  test "private instances (no name) keep working through GenServer calls", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    {:ok, server} = Settings.start_link(name: nil, path: path)

    :ok = Settings.put(:glow_threshold, 77.0, server)
    assert Settings.get(:glow_threshold, server) == 77.0
    assert :ets.lookup(:pokex_settings_overrides, :glow_threshold) == []
  end

  describe "the character layer" do
    # Its own instance per test, in a tmp: the character layer touches files and
    # the global Settings is shared by the whole suite.
    defp char_server(tmp) do
      {:ok, server} = Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))
      server
    end

    defp char_file(tmp, slug), do: Path.join([tmp, "chars", slug, "settings.json"])

    @tag :tmp_dir
    test "with no character, editing edits the BASE — as it always did", %{tmp_dir: tmp} do
      server = char_server(tmp)

      :ok = Settings.put(:skill_keys, ["8", "9"], server)

      assert Path.join(tmp, "settings.json") |> File.read!() |> JSON.decode!() ==
               %{"skill_keys" => ["8", "9"]}

      assert Settings.get(:skill_keys, server) == ["8", "9"]
    end

    @tag :tmp_dir
    test "with a character active, one of THEIR keys goes to THEIR file", %{tmp_dir: tmp} do
      server = char_server(tmp)

      :ok = Settings.put(:active_character, "lowbie", server)
      :ok = Settings.put(:skill_keys, ["8", "9"], server)

      assert char_file(tmp, "lowbie") |> File.read!() |> JSON.decode!() ==
               %{"skill_keys" => ["8", "9"]}

      # the base was not touched — only whoever is active changed
      assert Path.join(tmp, "settings.json") |> File.read!() |> JSON.decode!() ==
               %{"active_character" => "lowbie"}
    end

    @tag :tmp_dir
    test "two characters cannot see each other's configuration", %{tmp_dir: tmp} do
      server = char_server(tmp)

      :ok = Settings.put(:active_character, "main", server)
      :ok = Settings.put(:hook_skill_keys, ["4", "5"], server)
      :ok = Settings.put(:require_pokemon_hp, true, server)

      :ok = Settings.put(:active_character, "lowbie", server)
      :ok = Settings.put(:hook_skill_keys, ["1"], server)

      assert Settings.get(:hook_skill_keys, server) == ["1"]
      # the lowbie did not inherit the main's gate: never overrode it, so follows the base
      assert Settings.get(:require_pokemon_hp, server) == Settings.defaults()[:require_pokemon_hp]

      :ok = Settings.put(:active_character, "main", server)
      assert Settings.get(:hook_skill_keys, server) == ["4", "5"]
      assert Settings.get(:require_pokemon_hp, server) == true
    end

    @tag :tmp_dir
    test "a new character INHERITS the base and only diverges where they touch", %{tmp_dir: tmp} do
      server = char_server(tmp)

      # the base, built with no character selected
      :ok = Settings.put(:skill_keys, ["5", "6"], server)
      :ok = Settings.put(:hook_skill_keys, ["7"], server)

      :ok = Settings.put(:active_character, "novato", server)
      assert Settings.get(:skill_keys, server) == ["5", "6"]
      assert Settings.get(:hook_skill_keys, server) == ["7"]

      :ok = Settings.put(:hook_skill_keys, ["8"], server)
      assert Settings.get(:hook_skill_keys, server) == ["8"]
      # and what they did not touch keeps following the base
      assert Settings.get(:skill_keys, server) == ["5", "6"]
    end

    @tag :tmp_dir
    test "a character can take a key back to the CODE default", %{tmp_dir: tmp} do
      server = char_server(tmp)
      seed = Settings.defaults()[:skill_keys]

      :ok = Settings.put(:skill_keys, ["5", "6"], server)
      :ok = Settings.put(:active_character, "purista", server)
      :ok = Settings.put(:skill_keys, seed, server)

      # not "equal to the seed, therefore not an override": here the base is
      # ["5","6"], and wanting the code default IS a divergence worth storing
      assert Settings.get(:skill_keys, server) == seed

      assert char_file(tmp, "purista") |> File.read!() |> JSON.decode!() == %{
               "skill_keys" => seed
             }

      # and it survives a restart
      {:ok, reboot} = Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))
      assert Settings.get(:skill_keys, reboot) == seed
    end

    @tag :tmp_dir
    test "going back to the base's value CLEARS the character's override", %{tmp_dir: tmp} do
      server = char_server(tmp)

      :ok = Settings.put(:skill_keys, ["5", "6"], server)
      :ok = Settings.put(:active_character, "seguidor", server)
      :ok = Settings.put(:skill_keys, ["1"], server)
      :ok = Settings.put(:skill_keys, ["5", "6"], server)

      assert char_file(tmp, "seguidor") |> File.read!() |> JSON.decode!() == %{}

      # back to FOLLOWING the base: changing the base now reaches them
      :ok = Settings.put(:active_character, "", server)
      :ok = Settings.put(:skill_keys, ["9"], server)
      :ok = Settings.put(:active_character, "seguidor", server)
      assert Settings.get(:skill_keys, server) == ["9"]
    end

    @tag :tmp_dir
    test "what describes the MACHINE stays global even with a character active", %{tmp_dir: tmp} do
      server = char_server(tmp)

      :ok = Settings.put(:active_character, "main", server)
      :ok = Settings.put(:glow_threshold, 1234, server)

      assert Path.join(tmp, "settings.json") |> File.read!() |> JSON.decode!() ==
               %{"active_character" => "main", "glow_threshold" => 1234}

      refute File.exists?(char_file(tmp, "main"))

      # and the other character reads the same threshold — it is the same screen
      :ok = Settings.put(:active_character, "lowbie", server)
      assert Settings.get(:glow_threshold, server) == 1234
    end

    @tag :tmp_dir
    test "restarting comes back on the character that was active, with their values", %{
      tmp_dir: tmp
    } do
      server = char_server(tmp)

      :ok = Settings.put(:active_character, "main", server)
      :ok = Settings.put(:skill_keys, ["5", "6"], server)
      :ok = Settings.put(:pokemon_hp_fishing_pct, 42, server)

      {:ok, reboot} = Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))

      assert Settings.get(:active_character, reboot) == "main"
      assert Settings.get(:skill_keys, reboot) == ["5", "6"]
      assert Settings.get(:pokemon_hp_fishing_pct, reboot) == 42
    end

    @tag :tmp_dir
    test "all/1 shows the layer in force, not the base", %{tmp_dir: tmp} do
      server = char_server(tmp)

      :ok = Settings.put(:skill_keys, ["5", "6"], server)
      :ok = Settings.put(:active_character, "main", server)
      :ok = Settings.put(:skill_keys, ["1"], server)

      all = Settings.all(server)
      assert all.skill_keys == ["1"]
      assert all.glow_threshold == Settings.defaults()[:glow_threshold]
    end

    @tag :tmp_dir
    test "a corrupted character settings.json reads as 'no override'", %{tmp_dir: tmp} do
      server = char_server(tmp)
      File.mkdir_p!(Path.dirname(char_file(tmp, "quebrado")))
      File.write!(char_file(tmp, "quebrado"), "{ this is not json")

      :ok = Settings.put(:active_character, "quebrado", server)

      assert Settings.get(:skill_keys, server) == Settings.defaults()[:skill_keys]
    end

    @tag :tmp_dir
    test "a character's file only accepts CHARACTER keys — a stray one is ignored", %{
      tmp_dir: tmp
    } do
      server = char_server(tmp)
      File.mkdir_p!(Path.dirname(char_file(tmp, "invasor")))

      # a hand-edited file (or a key that LEFT character_keys) must not smuggle
      # a machine setting in through the character layer
      File.write!(
        char_file(tmp, "invasor"),
        JSON.encode!(%{"skill_keys" => ["3"], "glow_threshold" => 4321})
      )

      :ok = Settings.put(:active_character, "invasor", server)

      assert Settings.get(:skill_keys, server) == ["3"]
      assert Settings.get(:glow_threshold, server) == Settings.defaults()[:glow_threshold]
    end

    test "the character keys are chosen by hand, never derived from the presets" do
      # deriving one from the other is how :capture_enabled ended up with two
      # owners and cost 1015 kills with ZERO scans (2026-07-30)
      assert Settings.character_keys() == [
               :skill_keys,
               :hook_skill_keys,
               :require_cooldowns,
               :require_pokemon_hp,
               :pokemon_hp_fishing_pct
             ]

      refute :player_mode in Settings.character_keys()
      refute :capture_enabled in Settings.character_keys()

      for key <- Settings.character_keys() do
        assert is_map_key(Settings.defaults(), key), "#{key} is not a real setting"
      end
    end
  end

  describe "per-Pokémon presets" do
    defp preset_server(tmp) do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
      {:ok, server} = Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))
      server
    end

    @tag :tmp_dir
    test "save → apply round-trips the per-Pokémon keys", %{tmp_dir: tmp} do
      server = preset_server(tmp)

      :ok = Settings.put(:skill_keys, ["9", "0"], server)
      :ok = Settings.put(:potion_enabled, true, server)
      assert {:ok, "charizard"} = Settings.save_preset("Charizard!", server)

      :ok = Settings.put(:skill_keys, ["1"], server)
      :ok = Settings.put(:potion_enabled, false, server)

      assert {:ok, %{slug: "charizard", applied: applied}} =
               Settings.apply_preset("charizard", server)

      assert applied == length(Settings.preset_keys())
      assert Settings.get(:skill_keys, server) == ["9", "0"]
      assert Settings.get(:potion_enabled, server) == true
    end

    @tag :tmp_dir
    # 2026-07-30: :capture_enabled lived in presets AND in Modes; switching attack
    # presets silently killed capture (1015 kills, zero sweeps). Old preset files
    # on disk still carry the key — applying one must not touch it.
    test "a preset never turns capture off — the key has a single owner", %{tmp_dir: tmp} do
      server = preset_server(tmp)
      File.mkdir_p!(Path.join(tmp, "presets"))

      File.write!(
        Path.join(tmp, "presets/4attk.json"),
        JSON.encode!(%{"skill_keys" => ["3", "4"], "capture_enabled" => false})
      )

      :ok = Settings.put(:capture_enabled, true, server)

      assert {:ok, %{applied: 1}} = Settings.apply_preset("4attk", server)

      assert Settings.get(:skill_keys, server) == ["3", "4"]
      assert Settings.get(:capture_enabled, server) == true
      refute :capture_enabled in Settings.preset_keys()
    end

    @tag :tmp_dir
    test "apply ignores unknown keys, non-preset keys and wrong-shaped values", %{tmp_dir: tmp} do
      server = preset_server(tmp)

      File.mkdir_p!(Path.join(tmp, "presets"))

      File.write!(
        Path.join(tmp, "presets/misto.json"),
        JSON.encode!(%{
          "skill_keys" => ["7"],
          "potion_enabled" => "sim",
          "glow_threshold" => 1,
          "hacked" => true
        })
      )

      glow_before = Settings.get(:glow_threshold, server)
      assert {:ok, %{applied: 1}} = Settings.apply_preset("misto", server)

      assert Settings.get(:skill_keys, server) == ["7"]
      assert Settings.get(:potion_enabled, server) == Settings.defaults()[:potion_enabled]
      assert Settings.get(:glow_threshold, server) == glow_before
    end

    @tag :tmp_dir
    test "list/delete round-trip, missing preset and the invalid-name guard", %{tmp_dir: tmp} do
      server = preset_server(tmp)

      assert Settings.apply_preset("nada", server) == {:error, :not_found}
      assert Settings.save_preset("!!!", server) == {:error, :invalid_name}

      :ok = Settings.put(:hook_skill_keys, ["8"], server)
      assert {:ok, "mewtwo"} = Settings.save_preset("Mewtwo", server)

      assert [%{slug: "mewtwo", hook_skill_keys: ["8"], saved_at: saved_at}] =
               Settings.list_presets()

      assert is_integer(saved_at)

      :ok = Settings.delete_preset("mewtwo")
      assert Settings.list_presets() == []
    end
  end

  describe "the validating boundary: no impossible value reaches disk" do
    defp start_isolated(tmp),
      do: Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))

    @tag :tmp_dir
    test "a wrong type is rejected with an explanation", %{tmp_dir: tmp} do
      {:ok, server} = start_isolated(tmp)

      assert {:error, msg} = Settings.put(:tick_ms_watching, "rápido", server)
      assert msg =~ "esperava inteiro"

      assert {:error, _} = Settings.put(:capture_enabled, "sim", server)
      assert {:error, _} = Settings.put(:rod_key, 42, server)

      assert Settings.get(:tick_ms_watching, server) == Settings.defaults().tick_ms_watching
    end

    @tag :tmp_dir
    test "a closed enum rejects outside values and accepts the known ones", %{tmp_dir: tmp} do
      {:ok, server} = start_isolated(tmp)

      assert {:error, msg} = Settings.put(:stagnation_action, "explodir", server)
      assert msg =~ "alarm, stop, logout"

      assert :ok = Settings.put(:stagnation_action, "logout", server)
      assert Settings.get(:stagnation_action, server) == "logout"
    end

    @tag :tmp_dir
    test "the range catches the impossible, not taste", %{tmp_dir: tmp} do
      {:ok, server} = start_isolated(tmp)

      assert {:error, msg} = Settings.put(:logout_attempts, -1, server)
      assert msg =~ "fora da faixa"
      assert {:error, _} = Settings.put(:tick_ms_watching, 5, server)

      assert :ok = Settings.put(:tick_ms_watching, 5_000, server)
    end

    @tag :tmp_dir
    test "thresholds accept fractions (calibration suggests 45.0); similarity is 0..1", %{
      tmp_dir: tmp
    } do
      {:ok, server} = start_isolated(tmp)

      assert :ok = Settings.put(:glow_threshold, 45.5, server)
      assert :ok = Settings.put(:corpse_match_min_similarity, 0.9, server)
      assert {:error, msg} = Settings.put(:corpse_match_min_similarity, 1.5, server)
      assert msg =~ "0..1"
    end
  end
end
