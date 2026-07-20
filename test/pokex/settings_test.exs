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

    # the file holds only overrides — a fresh install has none
    assert path |> File.read!() |> JSON.decode!() == %{}

    # reads fall back to the seed defaults
    assert Settings.get(:tick_ms_watching, server) == 100
    assert Settings.get(:skill_keys, server) == ["1", "2", "3"]
    assert Settings.get(:rod_key, server) == "shift+v"
    assert Settings.get(:wait_assess_ms, server) == 1500
  end

  @tag :tmp_dir
  test "put persists ONLY the overridden keys, and they reload", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    {:ok, server} = Settings.start_link(name: nil, path: path)

    :ok = Settings.put(:glow_threshold, 22.5, server)
    :ok = Settings.put(:skill_keys, ["1", "2", "3", "4"], server)

    # the file is the two overrides — NOT a full snapshot of every key
    assert path |> File.read!() |> JSON.decode!() ==
             %{"glow_threshold" => 22.5, "skill_keys" => ["1", "2", "3", "4"]}

    {:ok, server2} = Settings.start_link(name: nil, path: path)
    assert Settings.get(:glow_threshold, server2) == 22.5
    assert Settings.get(:skill_keys, server2) == ["1", "2", "3", "4"]
    # a non-overridden key still comes from the seed
    assert Settings.get(:tile_px, server2) == 88
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
  test "a materialized file (every key persisted) is healed down to genuine overrides", %{
    tmp_dir: tmp
  } do
    # Simulate the reverted behavior that wrote ALL keys to disk: only require_cooldowns is a
    # real override; every other key equals the seed default and must be dropped so future
    # default changes in code win again.
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

    assert Settings.get(:tile_px, server) == 88
    assert path |> File.read!() |> JSON.decode!() == %{}
  end

  @tag :tmp_dir
  test "a non-writable settings path does not crash boot — runs off the code defaults", %{
    tmp_dir: tmp
  } do
    # make the parent of the settings path a FILE, so File.mkdir_p!/File.write! deterministically
    # raise inside init's heal — the app must still boot instead of crash-looping.
    blocker = Path.join(tmp, "blocker")
    File.write!(blocker, "i am a file, not a directory")
    path = Path.join(blocker, "settings.json")

    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert Settings.get(:tick_ms_watching, server) == 100
    assert Settings.get(:rod_key, server) == "shift+v"
  end

  @tag :tmp_dir
  test "values a user deliberately sets are honored — no magic-value rewrite", %{tmp_dir: tmp} do
    # The old normalize_loaded/2 migrations silently rewrote 6 -> 7 etc. on write, so those
    # values were impossible to select. They must round-trip now.
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

  test "the GLOBAL server mirrors overrides into ETS so hot-loop reads skip the GenServer" do
    # The app-booted global instance owns the mirror table. Worker ticks call
    # Settings.get/1 many times per 80ms tick across several processes; those
    # reads must be ETS lookups, not GenServer round-trips.
    original = Settings.get(:glow_threshold)
    on_exit(fn -> Settings.put(:glow_threshold, original) end)

    :ok = Settings.put(:glow_threshold, 4321.0)
    assert :ets.lookup(:pokex_settings_overrides, :glow_threshold) == [{:glow_threshold, 4321.0}]
    assert Settings.get(:glow_threshold) == 4321.0

    # putting the seed value back is NOT an override — the mirror row disappears
    # and the read falls back to the code seed
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
    # tmp-scoped instances used by tests must not touch the global mirror
    path = Path.join(tmp, "settings.json")
    {:ok, server} = Settings.start_link(name: nil, path: path)

    :ok = Settings.put(:glow_threshold, 77.0, server)
    assert Settings.get(:glow_threshold, server) == 77.0
    assert :ets.lookup(:pokex_settings_overrides, :glow_threshold) == []
  end

  describe "presets por Pokémon" do
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
    test "apply ignores unknown keys, non-preset keys and wrong-shaped values", %{tmp_dir: tmp} do
      server = preset_server(tmp)

      File.mkdir_p!(Path.join(tmp, "presets"))

      File.write!(
        Path.join(tmp, "presets/misto.json"),
        JSON.encode!(%{
          "skill_keys" => ["7"],
          # wrong shape: a string where a boolean lives
          "potion_enabled" => "sim",
          # known Settings key that is NOT a preset key
          "glow_threshold" => 1,
          # unknown key
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
end
