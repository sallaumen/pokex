defmodule Pokex.Bots.Engine.NarrationTest do
  @moduledoc """
  Quando o cérebro FALA. A regra morava dentro do tique do worker e só dava pra
  testar subindo um GenServer e escutando um tópico.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Narration

  defp picture(overrides \\ %{}) do
    Map.merge(
      %{enemies: 3, rows: 3, named: [], own_row_seen?: nil, own_hp: 90},
      overrides
    )
  end

  defp orders(why), do: %{why: why, revive: :hold, fire: :hold, route: :go}

  defp tick(picture \\ nil, orders \\ nil), do: %{picture: picture, orders: orders}

  describe "a contagem" do
    test "só fala quando muda" do
      assert Narration.lines(tick(picture()), tick(picture())) == []
    end

    test "e diz quantos são, com os nomes que leu" do
      atual = picture(%{enemies: 2, named: [%{name: "Rattata"}, %{name: nil}]})

      assert [linha] = Narration.lines(tick(picture(%{enemies: 5})), tick(atual))
      assert linha == "2 inimigos na tela — Rattata, ?"
    end

    test "sem layout localizado, diz que não tem nomes" do
      assert ["1 inimigo na tela (sem nomes — layout não localizado)"] =
               Narration.lines(tick(picture(%{enemies: 0})), tick(picture(%{enemies: 1})))
    end

    # `nil` e zero são fatos OPOSTOS, e o feed tem que saber diferenciar.
    test "perder a lista é uma frase própria, não uma contagem de zero" do
      assert ["perdi a lista de batalha — não sei quantos são"] =
               Narration.lines(tick(picture(%{enemies: 4})), tick(picture(%{enemies: nil})))
    end

    test "e não se repete enquanto segue perdida" do
      cega = tick(picture(%{enemies: nil}))

      assert Narration.lines(cega, cega) == []
    end
  end

  describe "a linha própria" do
    test "é dita quando passa a ser conhecível, com o nome do pokémon" do
      antes = tick(picture(%{own_row_seen?: nil}))
      agora = tick(picture(%{own_row_seen?: true}))

      assert [_contagem_igual_nao_fala | _] = linhas = Narration.lines(antes, agora, "o Dugtrio")
      assert Enum.any?(linhas, &(&1 =~ "o Dugtrio ocupa uma linha"))
    end

    test "e um desconto feito por AUSÊNCIA nunca se parece com um feito por nome" do
      antes = tick(picture(%{own_row_seen?: true}))
      agora = tick(picture(%{own_row_seen?: :unnamed}))

      assert [linha] = Narration.lines(antes, agora, "o Dugtrio")
      assert linha =~ "nome saiu ilegível"
      assert linha =~ "Ensine os glifos"
    end

    test "e não se repete" do
      igual = tick(picture(%{own_row_seen?: false}))

      assert Narration.lines(igual, igual) == []
    end
  end

  describe "a sombra" do
    test "uma linha por MUDANÇA de ideia, não por tique" do
      antes = tick(picture(), orders("andando a rota"))
      igual = tick(picture(), orders("andando a rota"))

      assert Narration.lines(antes, igual) == []
    end

    test "e o que ela mudaria vem no fim, do mais caro pro mais barato" do
      antes = tick(picture(), orders("andando a rota"))

      reviveria = %{orders("vermelho") | revive: :now, fire: :free, route: :hold}
      assert [linha] = Narration.lines(antes, tick(picture(), reviveria))
      assert linha =~ "[reviveria agora]"

      atacaria = %{orders("matando") | fire: :free, route: :hold}
      assert [linha] = Narration.lines(antes, tick(picture(), atacaria))
      assert linha =~ "[liberaria o fogo]"

      pararia = %{orders("contando") | route: :hold}
      assert [linha] = Narration.lines(antes, tick(picture(), pararia))
      assert linha =~ "[seguraria a rota]"
    end

    test "e um tique que só observa não ganha colchete nenhum" do
      antes = tick(picture(), orders("andando a rota"))

      assert [linha] = Narration.lines(antes, tick(picture(), orders("limpando o chão")))
      refute linha =~ "["
    end
  end

  test "o primeiro tique da noite não tem nada com que comparar, e fala" do
    linhas = Narration.lines(tick(), tick(picture(%{own_row_seen?: false}), orders("andando")))

    assert length(linhas) == 3
  end
end
