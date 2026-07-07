defmodule Pokex.SettingsTest do
  use ExUnit.Case, async: true
  alias Pokex.Settings

  @tag :tmp_dir
  test "starts with defaults, put persists and reloads", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert Settings.get(:tick_ms_watching, server) == 100
    assert Settings.get(:skill_keys, server) == ["1", "2", "3"]

    :ok = Settings.put(:glow_threshold, 22.5, server)
    :ok = Settings.put(:skill_keys, ["1", "2", "3", "4"], server)

    {:ok, server2} = Settings.start_link(name: nil, path: path)
    assert Settings.get(:glow_threshold, server2) == 22.5
    assert Settings.get(:skill_keys, server2) == ["1", "2", "3", "4"]
    assert Settings.get(:tile_size, server2) == 32
  end

  @tag :tmp_dir
  test "unknown keys in the file are ignored", %{tmp_dir: tmp} do
    path = Path.join(tmp, "settings.json")
    File.write!(path, ~s({"hacker": 1, "tile_size": 48}))
    {:ok, server} = Settings.start_link(name: nil, path: path)
    assert Settings.get(:tile_size, server) == 48
    assert Settings.all(server) |> Map.has_key?(:hacker) == false
  end

  @tag :tmp_dir
  test "a partial file overrides only its keys — the rest track current defaults", %{tmp_dir: tmp} do
    # A file that only pins tile_size must NOT freeze every other key at whatever
    # value an older build wrote; unlisted keys follow the code's @defaults.
    path = Path.join(tmp, "settings.json")
    File.write!(path, ~s({"tile_size": 99}))
    {:ok, server} = Settings.start_link(name: nil, path: path)

    assert Settings.get(:tile_size, server) == 99
    assert Settings.get(:tick_ms_fighting, server) == Settings.defaults().tick_ms_fighting
    assert Settings.get(:humanize_max_ms, server) == Settings.defaults().humanize_max_ms
  end
end
