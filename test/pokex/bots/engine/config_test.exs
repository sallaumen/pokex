defmodule Pokex.Bots.Engine.ConfigTest do
  @moduledoc """
  A lista de ajustes existia três vezes e as três discordaram. Este arquivo é o
  que impede a quarta cópia de nascer.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Config
  alias Pokex.Settings

  test "todo ajuste do cérebro existe no Settings" do
    seeds = Settings.defaults()

    for {knob, setting} <- Config.knobs() do
      assert Map.has_key?(seeds, setting),
             "#{knob} aponta pra #{setting}, que não é um ajuste que existe"
    end
  end

  test "as sementes e o que está em vigor têm exatamente as mesmas chaves" do
    assert Config.defaults() |> Map.keys() |> Enum.sort() ==
             Config.in_force() |> Map.keys() |> Enum.sort()
  end

  test "as sementes são as do Settings, não uma cópia com vida própria" do
    seeds = Settings.defaults()
    config = Config.defaults()

    for {knob, setting} <- Config.knobs() do
      assert config[knob] == seeds[setting], "#{knob} divergiu de #{setting}"
    end
  end

  test "merge devolve o mapa INTEIRO, não só o que foi pedido" do
    merged = Config.merge(%{engage_from: 9})

    assert merged.engage_from == 9
    assert Map.keys(merged) |> Enum.sort() == Config.defaults() |> Map.keys() |> Enum.sort()
  end

  # O piso entre dois resgates é do PlayerSupport, não do cérebro — ele só
  # precisa saber que existe, senão planeja em cima de uma prensa que a mão não
  # pode dar (R5).
  test "o piso do resgate vem do ajuste do suporte" do
    assert Config.knobs()[:rescue_cooldown_ms] == :rescue_cooldown_ms
  end
end
