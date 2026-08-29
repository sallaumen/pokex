defmodule Pokex.Bots.SoAreaTest do
  @moduledoc """
  A CAÇADA NÃO APERTA ALVO ÚNICO — em caminho nenhum.

  "A skill 6 é de alvo único, por isso não tá saindo. Skills de alvo único não
  funcionam mais, de propósito; a meta é só usarmos skills em área. Se o código
  tá tentando usar skill de alvo único, tá errado" (29/08).

  O ajuste `combat_single_target` já dizia isso pra ROTAÇÃO, e a varredura de
  29/08 achou QUATRO caminhos que apertavam alvo único assim mesmo. Cada um
  tinha um argumento próprio e razoável na época; nenhum sobrevive à frase
  acima. Este arquivo cobra os quatro de uma vez, porque a regra é uma só e
  quem a reabrir vai reabrir por um caminho, não por todos.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.{Loadout, Strategy}
  alias Pokex.Bots.Engine.Inputs
  alias Pokex.Bots.PlayerSupport

  # Um pokémon SEM área classificada: é ele que expõe todo recuo escondido,
  # porque é a única forma de "não sobrou nada" que o código conhecia.
  defp so_alvo, do: Loadout.resolve("Sem Área", %{"7" => :single, "8" => :single})

  defp com_area,
    do: Loadout.resolve("Com Área", %{"3" => :aoe, "4" => :aoe, "7" => :single})

  defp picture(ready \\ ~w(3 4 7 8)) do
    %{enemies: 4, ready_keys: ready, own_hp: 100, spent?: false}
  end

  describe "a rotação" do
    test "não abre com alvo único, nem quando ele é tudo que existe" do
      assert Strategy.opening(so_alvo()) == []
      assert Strategy.skill_order(so_alvo(), enemies: 4) == []
    end

    test "e a abertura de quem tem área ignora a de alvo único" do
      assert Strategy.opening(com_area()) == ~w(3 4)
    end
  end

  describe "as mãos que o cérebro entrega" do
    test "a mão de alvo único vem vazia, com ou sem área" do
      assert Inputs.hands(so_alvo(), picture()).single == []
      assert Inputs.hands(com_area(), picture()).single == []
    end

    test "a mão pequena não cai no alvo único" do
      assert Inputs.hands(so_alvo(), picture()).small == []
      assert Inputs.hands(com_area(), picture()).small == ["3"]
    end

    test "a abertura também não" do
      refute "7" in Inputs.hands(com_area(), picture()).opening
      assert Inputs.hands(so_alvo(), picture()).opening == []
    end
  end

  describe "a escalação do resgate" do
    @kit %{crowd: ["1"], aoe: ["3"], single: ["7"]}

    test "aperta controle e área, nunca alvo único" do
      assert PlayerSupport.Logic.last_resort_keys(@kit, [], nil) == ["1", "3"]
    end

    test "e sem área sobra só o controle" do
      assert PlayerSupport.Logic.last_resort_keys(%{crowd: ["1"], single: ["7"]}, [], nil) == [
               "1"
             ]
    end
  end

  # A regra é do JOGO dele, não uma verdade sobre todo pokémon: quem tiver alvo
  # único que machuque liga o ajuste e recupera os quatro caminhos.
  describe "e o ajuste devolve tudo, porque a regra é dele" do
    test "rotação, mãos e resgate voltam a usar alvo único" do
      assert Strategy.skill_order(so_alvo(), enemies: 4, single_target?: true) == ~w(7 8)

      hands = Inputs.hands(so_alvo(), picture(), %{single_target: true})
      assert hands.single == ~w(7 8)
      assert hands.small == ["7"]

      assert PlayerSupport.Logic.last_resort_keys(@kit, [], nil, true) == ["1", "3", "7"]
    end
  end
end
