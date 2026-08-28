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

  defp picture(ready \\ nil, enemies \\ nil), do: %{ready_keys: ready, enemies: enemies}

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
    assert Inputs.hands(nil, picture()) == %{opening: [], small: [], single: [], crowd: []}
  end

  # `single` É O QUE A FASE `:skipping` GASTA nas teclas baratas — e desde 27/08
  # a caçada não usa as de alvo único por padrão: "o que dá dano é a skill em
  # área, praticamente exclusivamente". Uma tecla que não machuca não é barata,
  # é perdida.
  test "single é a barra de alvo único quando ela está ligada" do
    assert Inputs.hands(loadout(), picture(), %{single_target: true}).single == ["7", "8"]
  end

  test "e some quando ela está desligada, que é o padrão" do
    assert Inputs.hands(loadout(), picture()).single == []
  end

  test "…mas volta pra quem não tem área: ficar mudo é pior que bater fraco" do
    so_alvo = loadout(%{aoe: []})

    assert Inputs.hands(so_alvo, picture()).single == ["7", "8"]
  end

  # A exclusão continua sendo `reserved/1` — o que muda é quem a usa. A abertura
  # nunca gasta o controle, e só gasta o escudo quando a régua dele manda.
  test "a abertura não gasta nem controle nem escudo" do
    opening = Inputs.hands(loadout(), picture()).opening

    refute "1" in opening
    refute "2" in opening
  end

  # A RÉGUA DO ESCUDO (27/08): "a de defesa vale sempre que tem já uns 2
  # pokémons atacando ele pelo menos". Dois é o padrão e é knob; em 1 ela vira a
  # regra da aura de dano — sai em toda luta com a tecla pronta.
  describe "a aura de defesa" do
    test "com dois em cima e a tecla pronta, ela lidera a abertura" do
      opening = Inputs.hands(loadout(), picture(~w(2 3 4), 2), %{shield_from: 2}).opening

      assert hd(opening) == "2"
    end

    test "com um só, não — ela não é a aura de dano" do
      opening = Inputs.hands(loadout(), picture(~w(2 3 4), 1), %{shield_from: 2}).opening

      refute "2" in opening
    end

    test "sem leitura da barra ela não sai, mesmo com a tela cheia" do
      opening = Inputs.hands(loadout(), picture(nil, 9), %{shield_from: 2}).opening

      refute "2" in opening
    end

    test "e a aura de DANO sai atrás dela, nunca na frente" do
      opening = Inputs.hands(loadout(), picture(~w(2 9 3 4), 4), %{shield_from: 2}).opening

      assert Enum.take(opening, 2) == ["2", "9"]
    end
  end

  # A mão pequena é a primeira tecla de DANO — escudo e aura ficam de fora, e
  # não por descuido: o bicho bobo que a paciência obriga a limpar não merece a
  # invulnerabilidade nem o multiplicador, merece uma tecla que o mate.
  test "small é a primeira tecla de dano, sem escudo e sem aura" do
    hands = Inputs.hands(loadout(), picture(~w(2 3 4 9), 1))

    assert hands.small == ["3"]
  end

  test "small respeita o modo alvo-único e a área vazia" do
    so_single = loadout(%{aoe: []})

    assert Inputs.hands(so_single, picture()).small == ["7"]
  end
end
