defmodule Pokex.SkillBarFixtures do
  @moduledoc """
  A barra de skills sintética que PASSA no portão do leitor: `count` slots de
  30×12 com o rótulo da tecla (glifo branco 2×6 na metade de baixo) em cada
  um — é o que faz o quadro ser a barra —, os `ready` primeiros com cinco
  linhas de amarelo vivo (prontas) e os demais só o painel escuro (frias).
  """

  @slot_w 30
  @height 12

  @doc "A região da barra de `count` slots, no canto da tela sintética."
  def region(count), do: {0, 0, count * @slot_w, @height}

  @doc "As linhas de pixels `{r, g, b, a}` para `Pokex.PngFixtures.write!/2`."
  def rows(count, ready) do
    for y <- 0..(@height - 1),
        do: for(slot <- 0..(count - 1), x <- 0..(@slot_w - 1), do: pixel(slot, x, y, ready))
  end

  defp pixel(_slot, x, y, _ready) when x in 12..13 and y in 6..11, do: {240, 240, 240, 255}
  defp pixel(slot, _x, y, ready) when slot < ready and y < 5, do: {200, 200, 0, 255}
  defp pixel(_slot, _x, _y, _ready), do: {20, 20, 20, 255}
end
