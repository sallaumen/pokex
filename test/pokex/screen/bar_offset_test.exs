defmodule Pokex.Screen.BarOffsetTest do
  use ExUnit.Case, async: true

  alias Pokex.Screen.BarOffset

  # O CAMPO DESMENTIU AS DUAS CORREÇÕES. Taxa de captura por bola no diário dele,
  # nos três trechos separados pelos merges: ponto publicado cru 36 % (1098
  # bolas), #657 `+70` 24 % (337), #664 `-110` 5 % (111). A bola não é jogada num
  # bicho de pé — é jogada num CORPO deitado na tile, e as duas medições de
  # quadro mediram o sprite errado.
  describe "with no screen measured IN THE FIELD" do
    test "the aim goes through untouched, on his ultrawide included" do
      assert :unknown = BarOffset.for_screen({3440, 1440})
      assert :unknown = BarOffset.for_screen({1512, 982})
      assert :unknown = BarOffset.for_screen({nil, nil})
    end

    test "the table is empty on purpose" do
      assert [] = BarOffset.known()
    end

    # A CERCA PRA QUEM VIER DEPOIS: se alguém repuser uma entrada, ela não pode
    # empurrar a bola PRA BAIXO. Foi o que o #657 fez, e custou 36 % → 24 %.
    test "any entry someone adds later must lift the aim, never lower it" do
      for {screen, {_dx, dy}} <- BarOffset.known() do
        assert dy < 0, "#{inspect(screen)} empurra a bola pra baixo: #{dy}"
      end
    end
  end
end
