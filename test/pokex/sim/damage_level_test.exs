defmodule Pokex.Sim.DamageLevelTest do
  @moduledoc """
  Os quatro níveis que ele clica, e a unidade que faz o experimento dele existir.
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.DamageLevel

  test "os quatro, na ordem em que ele os disse" do
    assert DamageLevel.all() == [:padrao, :baixo, :medio, :muito]
  end

  test "as faixas são as dele, em HP" do
    # "skills que eu marcar baixo dano dão 10~20 de HP, skills de médio dano dão
    # 30~50 e skills de muito dano dão de 60~80" (26/08).
    assert DamageLevel.band(:baixo) == {10, 20}
    assert DamageLevel.band(:medio) == {30, 50}
    assert DamageLevel.band(:muito) == {60, 80}
  end

  test ":padrao não grava faixa — é a ausência de um nível, não um nível" do
    # Sem faixa o mundo cai no chute em porcentagem, que é o comportamento de
    # sempre. Ele fica na lista porque é preciso poder VOLTAR.
    assert DamageLevel.band(:padrao) == nil
  end

  describe "ler de volta o que está gravado" do
    test "uma faixa conhecida vira o clique que a fez" do
      assert DamageLevel.of({30, 50}) == :medio
    end

    test "faixa nenhuma é padrão" do
      assert DamageLevel.of(nil) == :padrao
    end

    test "uma faixa que ele digitou à mão NÃO é apagada por não ser um dos quatro" do
      # Um `sim_setup.json` de antes destes botões, ou um número que ele mediu:
      # some em silêncio seria pior do que oferecer um botão a menos.
      assert DamageLevel.of({28, 41}) == {:custom, {28, 41}}
    end
  end

  describe "a armadilha das duas unidades" do
    # Com `mob_hp` em 500 e SÓ ALGUMAS teclas em nível, as outras continuam
    # tirando 34% — 170 de HP, mais do que o dobro do "muito dano". A medida
    # deixa de ser a que ele configurou, sem nada na tela dizendo isso.
    test "algumas em nível e outras em padrão é mistura" do
      assert DamageLevel.mixed?(%{"3" => {60, 80}}, ~w(3 4 5))
    end

    test "todas em nível não é" do
      refute DamageLevel.mixed?(%{"3" => {60, 80}, "4" => {10, 20}}, ~w(3 4))
    end

    test "NENHUMA em nível também não é — é o comportamento de sempre" do
      # Avisar sobre uma barra inteira em padrão seria ruído: é o que o
      # simulador sempre fez, e é o que uma instalação nova encontra.
      refute DamageLevel.mixed?(%{}, ~w(3 4 5))
    end

    test "sem teclas de dano nenhuma não há o que misturar" do
      refute DamageLevel.mixed?(%{"3" => {60, 80}}, [])
    end
  end
end
