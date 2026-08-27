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
end
