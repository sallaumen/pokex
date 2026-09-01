defmodule Pokex.Bots.HuntModeTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.HuntMode
  alias Pokex.Settings
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash_keys!([:hunt_mode])
    :ok
  end

  test "all/0 lists both modes with auto combo first" do
    assert HuntMode.all() == [:auto_combo, :economy]
    assert HuntMode.default() == :auto_combo
  end

  test "label/1 answers in pt-BR" do
    assert HuntMode.label(:auto_combo) == "Auto Combo"
    assert HuntMode.label(:economy) == "Econômico"
  end

  test "label/1 answers the value itself when it names no mode" do
    assert HuntMode.label(:invented) == "invented"
  end

  test "parse/1 accepts the stored string and the atom" do
    assert HuntMode.parse("economy") == :economy
    assert HuntMode.parse(:economy) == :economy
  end

  test "parse/1 answers nil for anything that is not a mode" do
    assert HuntMode.parse("mobbed") == nil
    assert HuntMode.parse("") == nil
    assert HuntMode.parse(nil) == nil
    assert HuntMode.parse(7) == nil
  end

  test "parse/1 refuses a value this build does not know" do
    assert HuntMode.parse("modo_inventado_no_arquivo") == nil
  end

  test "in_force/1 obeys the route above the setting" do
    Settings.put(:hunt_mode, "auto_combo")
    assert HuntMode.in_force(:economy) == :economy
  end

  test "in_force/1 falls back to the setting when the route chose none" do
    Settings.put(:hunt_mode, "economy")
    assert HuntMode.in_force(nil) == :economy
  end

  test "in_force/1 falls back to the default when the setting is unreadable" do
    Settings.put(:hunt_mode, "auto_combo")
    assert HuntMode.in_force(:mobbed) == :auto_combo
  end

  test "source/1 says where the answer came from" do
    assert HuntMode.source(:economy) == :route
    assert HuntMode.source(nil) == :global
    assert HuntMode.source("nada disso") == :global
  end
end
