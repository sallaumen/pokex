defmodule Pokex.Vision.PlayerHpTest do
  @moduledoc """
  A barra vermelha do painel "Pokémon" — a vida do PERSONAGEM — lida pelos
  MESMOS leitores da Pokebar, sobre o recorte da foto real dele (27/08, a barra
  escrevendo 683/720 = 94,9%).

  O que este arquivo pina: o preenchimento vermelho (211,52,53) é "quente" pro
  leitor de coluna como o verde é, o trilho vazio (56,71,71) é apagado, e o
  texto branco por cima já sai da conta por desenho. Nenhum leitor novo — se
  este teste quebrar, quebrou a leitura de TODAS as barras.
  """
  use ExUnit.Case, async: true

  alias Pokex.Vision.Frame

  @fixture "test/fixtures/player_hp_683_de_720.raw"

  defp frame! do
    {:ok, frame} = Frame.from_file(@fixture)
    frame
  end

  test "reads 95% where the game writes 683/720 (94.9%)" do
    assert Pokex.Vision.hp_fill_pct(frame!()) == 95
  end

  test "a barra do personagem passa na plausibilidade da barra de vida" do
    assert Pokex.Vision.hp_region_plausible?(frame!(),
             min_brightness: 45,
             min_saturation: 30,
             min_known_pct: 55,
             min_bright_pct: 10,
             max_track_brightness: 75
           )
  end
end
