defmodule Pokex.Vision.SkillDigitsTest do
  @moduledoc """
  A contagem que o jogo escreve na tecla, lida nas capturas REAIS dele.

  As três barras são fotos do cliente na noite de 27→28/08 — a mesma noite em
  que a leitura por referência disse "pronta" 2.372 vezes pra teclas com `32`
  escrito em cima.
  """
  use ExUnit.Case, async: true

  alias Pokex.Vision.{Frame, SkillDigits}

  defp frame!(name) do
    {:ok, frame} = Frame.from_file("test/fixtures/skill_bar/#{name}")
    frame
  end

  # A captura do fim da noite: 32/33/43/44 escritos nas teclas 1, 3, 4 e 5.
  test "finds the four keys counting, and only them" do
    assert frame!("quatro_contando.raw") |> SkillDigits.counting(9) |> Enum.sort() ==
             [0, 2, 3, 4]
  end

  # A de 27/08 19:07 — 12/32/32 nas teclas 3, 4 e 5, a barra que mentia.
  test "finds the three from yesterday's capture" do
    assert frame!("tres_contando_ontem.raw") |> SkillDigits.counting(9) |> Enum.sort() ==
             [2, 3, 4]
  end

  # A barra da manhã, tudo pronto — inclusive o ícone com a explosão BRANCA no
  # slot 8, que é o falso positivo clássico: branco em quantidade, mas 15×20 de
  # caixa e sem o contorno preto de texto (medido: 8% contra 100% dos dígitos).
  test "a ready bar has no count at all, not even in the white art" do
    assert frame!("manha.raw") |> SkillDigits.counting(9) |> Enum.sort() == []
  end

  # O rótulo da tecla (1-9) usa a MESMA fonte, embaixo. Se a zona deixar de
  # separar os dois, toda tecla passa a "contar" pra sempre.
  test "the key labels do not count as a count" do
    counting = frame!("manha.raw") |> SkillDigits.counting(9)

    assert MapSet.size(counting) == 0
  end
end
