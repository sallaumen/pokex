defmodule Pokex.Sim.WitnessTest do
  @moduledoc """
  A TESTEMUNHA QUE SÓ A BANCADA TEM.

  `special_asleep_left_ms` e `special_tiles` chegam à foto do cérebro vindos do
  mundo simulado, que sabe tudo. No jogo NINGUÉM os escreve: nenhum módulo fora
  de `lib/pokex/sim` põe essas chaves nos `inputs`, e `Engine.Situation` as lê
  como `nil` a noite inteira.

  Isso divide o ciclo do especial em dois braços — um com a testemunha
  (aritmética exata sobre o sono e a distância) e outro sem ela (o carimbo do
  próprio módulo) — e enquanto a bancada respondia sempre pelo primeiro, ela
  media um cérebro que não é o que roda na máquina dele. O knob
  `special_witness: false` cala a testemunha e deixa um cenário exercer o braço
  do jogo (`especial-combo-de-hoje`).

  Este teste guarda a PREMISSA do knob. No dia em que alguém ligar o canal de
  verdade no bot — um `CrowdScan` que meça o sono, digamos — ele fica vermelho,
  e aí o knob muda de sentido em vez de mentir em silêncio.
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  @channels ["special_asleep_left_ms", "special_tiles"]

  test "no module outside the simulator ever writes the special's witness" do
    producers =
      for path <- Path.wildcard("lib/**/*.ex"),
          not String.starts_with?(path, "lib/pokex/sim/"),
          line <- String.split(File.read!(path), "\n"),
          channel <- @channels,
          # a ESCRITA (`chave: valor`) é quem teria que produzi-la — nem a
          # leitura (`Map.get(inputs, :chave)`) nem a declaração do tipo em
          # `Engine.Situation`, que é justamente quem a lê como `nil`
          String.contains?(line, channel <> ":"),
          not String.contains?(line, "Map.get"),
          not String.contains?(line, "non_neg_integer"),
          do: "#{path}: #{String.trim(line)}"

    assert producers == [],
           "alguém passou a produzir a testemunha — o knob `special_witness` " <>
             "precisa mudar de sentido:\n  " <> Enum.join(producers, "\n  ")
  end

  test "and the knob that silences it is on by default, as the old scenarios measured" do
    world = World.new(Scenario.route(Scenario.get("especial-brando"), []), loadout: nil)

    assert world.knobs.special_witness == true
  end
end
