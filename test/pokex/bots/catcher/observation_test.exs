defmodule Pokex.Bots.Catcher.ObservationTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Observation
  alias Pokex.Perception.WorldState

  # A ÂNCORA FALA A LÍNGUA DA LÓGICA. Ela não é uma foto do chão: é onde a barra
  # de um shiny parou de ser lida (`Catcher.Trail`). Vestida no mesmo contrato,
  # a mesma fila, a mesma bola de cada vez e o mesmo juiz servem às duas lentes.
  describe "the anchors' observation" do
    test "speaks the Logic's contract, and says which lens it is" do
      cand = %{name: "Shiny (brilho)", px: 60, point: {117, 117}, in_frame: {117, 117}}

      assert %{
               scanning?: true,
               source: :anchor,
               corpses: [{117, 117}],
               known: %{{117, 117} => %{name: "Shiny (brilho)", px: 60}},
               captured_at: 5
             } = Observation.anchors([cand], 5)
    end

    test "carries the diagnosis it was given, and none when it was given none" do
      cand = %{name: "Shiny (brilho)", px: 60, point: {10, 10}, in_frame: {10, 10}}

      assert %{diag: %{anchor: true}} = Observation.anchors([cand], 5, %{anchor: true})
      assert %{diag: %{}} = Observation.anchors([cand], 5)
    end

    test "with nothing to claim it claims nothing" do
      assert %{corpses: [], known: %{}, candidates: []} = Observation.anchors([], 5)
    end
  end

  # NADA VIVO NA TELA (09/09, ordem dele): "quando tá vivo temos que matar e
  # quando tá morto temos que capturar". Vale pras DUAS lentes — a varredura
  # comum também confunde bicho de pé com corpo.
  describe "the screen has to be empty of the living" do
    setup do
      :ets.delete(:pokex_world, :situation)
      on_exit(fn -> :ets.delete(:pokex_world, :situation) end)
      :ok
    end

    defp now, do: System.monotonic_time(:millisecond)

    test "the brain's own count is what answers, and it is read from the blackboard" do
      WorldState.put(:situation, %{enemies: 0}, now())
      assert Observation.screen_clear(:ask, now()) == :ok

      WorldState.put(:situation, %{enemies: 3}, now())
      assert Observation.screen_clear(:ask, now()) == {:blocked, {:alive_on_screen, 3}}
    end

    # Sem quadro do cérebro não se sabe se há alguém de pé — e não saber aqui é
    # não jogar: a bola é mais cara que a foto.
    test "no picture at all is not a corpse either" do
      assert Observation.screen_clear(:ask, now()) == {:blocked, :no_picture}
    end

    test "a picture older than three ticks of the brain is no picture" do
      WorldState.put(:situation, %{enemies: 0}, now() - 10_000)
      assert Observation.screen_clear(:ask, now()) == {:blocked, :no_picture}
    end

    # a contagem dada na mão (o caminho da pesca, que não tem cérebro)
    test "a count handed in answers for itself" do
      assert Observation.screen_clear(0, now()) == :ok
      assert Observation.screen_clear(2, now()) == {:blocked, {:alive_on_screen, 2}}
    end
  end
end
