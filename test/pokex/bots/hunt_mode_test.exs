defmodule Pokex.Bots.HuntModeTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Engine.Config
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

  test "engine_overrides/1 only names knobs the decision actually has" do
    for mode <- HuntMode.all(), {knob, _value} <- HuntMode.engine_overrides(mode) do
      assert Map.has_key?(Config.knobs(), knob),
             "#{mode} sobrepõe #{knob}, que não é um knob do cérebro"
    end
  end

  # Um modo decide COMO se luta, nunca se o personagem está protegido.
  test "engine_overrides/1 never touches a safety knob" do
    for mode <- HuntMode.all(), {knob, _value} <- HuntMode.engine_overrides(mode) do
      refute knob in HuntMode.forbidden_knobs(),
             "#{mode} sobrepõe #{knob}, que é uma trava de segurança"
    end
  end

  # Tab e alvo único não são knobs: são o que um modo É (`Combat.Plan`). Uma
  # chave que pudesse contradizer o modo é a combinação inválida que toda esta
  # separação existe pra tornar impossível.
  test "engine_overrides/1 leaves the fight's own hand alone" do
    for mode <- HuntMode.all() do
      refute Map.has_key?(HuntMode.engine_overrides(mode), :single_target)
    end
  end

  test "engine_overrides/1 answers empty for the mode that runs the bot as it is" do
    assert HuntMode.engine_overrides(:auto_combo) == %{}
  end

  test "forbidden_knobs/0 names knobs that exist" do
    for knob <- HuntMode.forbidden_knobs() do
      assert Map.has_key?(Config.knobs(), knob), "#{knob} não é um knob do cérebro"
    end
  end

  test "source/1 says where the answer came from" do
    assert HuntMode.source(:economy) == :route
    assert HuntMode.source(nil) == :global
    assert HuntMode.source("nada disso") == :global
  end
end
