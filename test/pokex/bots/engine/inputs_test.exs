defmodule Pokex.Bots.Engine.InputsTest do
  @moduledoc """
  O que a decisão recebe sobre as mãos — montado UMA vez, para todo chamador.

  O mapa era construído duas vezes (worker e bancada) e as duas cópias
  divergiram em dois campos. Aqui se prova o significado de cada um; o guarda de
  que a bancada CHAMA em vez de derivar está em `test/pokex/sim/contrato_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.Engine.Inputs

  defp loadout(overrides \\ %{}) do
    Map.merge(
      %Loadout{
        name: "Testado",
        aoe: ["3", "4"],
        single: ["7", "8"],
        buffs: ["9"],
        shield: ["2"],
        heal: [],
        crowd: ["1"]
      },
      overrides
    )
  end

  defp picture(ready \\ nil), do: %{ready_keys: ready}

  # `crowd` É O QUE O CÉREBRO GASTA. Vinha de `Strategy.reserved/1`, que é a
  # lista de EXCLUSÃO — controle MAIS escudo, "um botão cujo valor inteiro é não
  # ter sido gasto quando a encrenca chega", pela doc dela mesma. Com o controle
  # em cooldown e o escudo pronto, `Logic.control_ready?/1` respondia SIM, a R10
  # carimbava `:stunned` e mandava o revive dentro da janela — e o escudo não
  # bota ninguém pra dormir. O revive caía num bolo acordado, que é exatamente o
  # que o `rescue_stun_first` existe pra impedir.
  test "crowd é o controle, e o escudo não entra" do
    hands = Inputs.hands(loadout(), picture())

    assert hands.crowd == ["1"]
  end

  test "sem pokémon em campo não há mão nenhuma" do
    assert Inputs.hands(nil, picture()) == %{opening: [], single: [], crowd: []}
  end

  test "single é a barra de alvo único, tal e qual" do
    assert Inputs.hands(loadout(), picture()).single == ["7", "8"]
  end

  # A exclusão continua sendo `reserved/1` — o que muda é quem a usa. A abertura
  # nunca gasta controle nem escudo.
  test "a abertura não gasta nem controle nem escudo" do
    opening = Inputs.hands(loadout(), picture()).opening

    refute "1" in opening
    refute "2" in opening
  end
end
