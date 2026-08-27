defmodule Pokex.Sim.ContratoTest do
  @moduledoc """
  A bancada CHAMA as decisões do bot, nunca deriva as próprias.

  É a forma de defeito que este repositório já pagou quatro vezes: a abertura
  reimplementada em vez de chamar `Strategy` (#358), o mundo montado de duas
  chaves ignorando a mesa (#358), a rajada de seis teclas tratada como um evento
  instantâneo (#367), o `luring?` cravado em `false`. Toda vez o sintoma foi o
  mesmo — um número que ninguém conseguia explicar, porque descrevia um bot que
  não existe.

  Um teste de texto, e não de comportamento, porque a pergunta é literalmente
  "de onde isto sai?". Mesmo molde do guarda em
  `test/pokex/perception/display_feeds_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.Bench

  @bench "lib/pokex/sim/bench.ex"

  test "a bancada monta as mãos chamando a produção" do
    fonte = File.read!(@bench)

    assert fonte =~ "Inputs.hands(",
           "a bancada voltou a derivar as mãos em vez de chamar Engine.Inputs"
  end

  test "e não constrói um mapa de mãos próprio" do
    fonte = File.read!(@bench)

    refute fonte =~ "hands: %{",
           "um literal `hands: %{...}` aqui é a cópia que diverge — o campo tem que vir de Engine.Inputs"
  end

  # A ORDEM DA BARRA É A DO JOGO, e o `"0"` é a DÉCIMA tecla. `keys_of_kind/2`
  # percorria um MAPA, então por ordem de termo o `"0"` saía PRIMEIRO na bancada
  # e por último no bot, onde `SkillProfile.keys/2` filtra
  # `~w(1 2 3 4 5 6 7 8 9 0)`. E `Strategy.skill_order/2` preserva a ordem das
  # listas, então é literalmente outra rajada — invisível enquanto todo dano era
  # igual, e mensurável no instante em que deixa de ser.
  #
  # Mesma armadilha do preflight que recusava o arranque procurando a tecla
  # "10" (#346): num lugar novo, pelo mesmo motivo.
  test "a barra da bancada sai na ordem do jogo, com o 0 no fim" do
    loadout = %Pokex.Bots.Combat.Loadout{
      name: "Dez teclas",
      aoe: ["0", "3"],
      single: ["7", "9"],
      buffs: [],
      shield: [],
      heal: [],
      crowd: []
    }

    rota = %Pokex.Bots.Cavebot.Route{
      name: "reta",
      dungeon: nil,
      waypoints: [%{x: 1000, y: 1000, z: 7, action: :walk, note: nil}]
    }

    world = Pokex.Sim.World.new(rota, seed: 1, loadout: loadout, knobs: %{nest_size: 0})

    assert Bench.loadout_of(world).aoe == ["3", "0"]
    assert Bench.loadout_of(world).single == ["7", "9"]
  end
end
