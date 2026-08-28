defmodule Pokex.Sim.VerdictTest do
  @moduledoc """
  A promessa de um cenário, cobrada da corrida.

  Metade destes testes existe por causa de um erro que cometi três vezes
  seguidas escrevendo o módulo: julgar um revive pela vara da REGRA ERRADA. A
  caçada tem três motivos diferentes pra gastar um revive — preparar numa tela
  limpa (R11), comprar a barra de volta na pilha (R3b) e salvar o pokémon no
  vermelho — e cada acusação escrita sem as três em mente reprovava o bot
  exatamente onde ele estava obedecendo.
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.Verdict

  defp report(overrides) do
    metrics =
      %{deaths: [], revives: [], ms_stalled: 0, ms: 60_000}
      |> Map.merge(Map.get(overrides, :metrics, %{}))

    outcome =
      %{killed: 10, left_alive: 0}
      |> Map.merge(Map.get(overrides, :outcome, %{}))

    %{metrics: metrics, outcome: outcome}
  end

  defp revive(overrides) do
    Map.merge(
      %{
        accepted?: true,
        phase: :engaged,
        enemies: 4,
        spent?: true,
        since_stun_ms: 800,
        control_ready?: true
      },
      overrides
    )
  end

  defp cumpriu?(report, promessa) do
    [%{cumpriu?: cumpriu?}] = Verdict.judge(report, [promessa])
    cumpriu?
  end

  describe "não cai" do
    test "sem quedas, cumpre" do
      assert cumpriu?(report(%{}), :nao_cai)
    end

    test "uma queda reprova e diz quando" do
      [v] = Verdict.judge(report(%{metrics: %{deaths: [12_400]}}), [:nao_cai])

      refute v.cumpriu?
      assert v.porque =~ "12.4s"
    end
  end

  describe "mata e limpa" do
    test "zero mortos reprova" do
      refute cumpriu?(report(%{outcome: %{killed: 0}}), :mata)
    end

    test "sobrou bicho de pé reprova o limpa" do
      refute cumpriu?(report(%{outcome: %{left_alive: 3}}), :limpa)
    end
  end

  describe "anda" do
    test "parada em menos da metade da corrida cumpre" do
      assert cumpriu?(report(%{metrics: %{ms_stalled: 20_000, ms: 60_000}}), :anda)
    end

    test "parada na maior parte reprova" do
      refute cumpriu?(report(%{metrics: %{ms_stalled: 40_000, ms: 60_000}}), :anda)
    end

    test "corrida de duração zero não acusa ninguém" do
      assert cumpriu?(report(%{metrics: %{ms_stalled: 0, ms: 0}}), :anda)
    end
  end

  describe "revive só com a barra gasta" do
    test "revive na pilha com tecla pronta é desperdício" do
      r = report(%{metrics: %{revives: [revive(%{spent?: false})]}})

      refute cumpriu?(r, :revive_util)
    end

    # A R11: "eu sempre uso um revive antes de matar o próximo grupo, mesmo que
    # nem tenha acabado todos os cooldowns" — com a tela limpa, meia barra é a
    # regra, não o desperdício.
    test "revive de preparação na tela limpa cumpre, mesmo com meia barra" do
      r = report(%{metrics: %{revives: [revive(%{spent?: false, enemies: 0})]}})

      assert cumpriu?(r, :revive_util)
    end

    test "revive de emergência cumpre, mesmo com meia barra na pilha" do
      r = report(%{metrics: %{revives: [revive(%{spent?: false, phase: :emergency})]}})

      assert cumpriu?(r, :revive_util)
    end

    test "barra ilegível não vira acusação" do
      r = report(%{metrics: %{revives: [revive(%{spent?: nil})]}})

      assert cumpriu?(r, :revive_util)
    end

    test "revive recusado não conta" do
      r = report(%{metrics: %{revives: [revive(%{spent?: false, accepted?: false})]}})

      assert cumpriu?(r, :revive_util)
    end
  end

  describe "controle antes do revive (R10)" do
    test "stun na janela cumpre" do
      assert cumpriu?(
               report(%{metrics: %{revives: [revive(%{since_stun_ms: 800})]}}),
               :revive_no_prazo
             )
    end

    test "controle pronto na mão, sem stun, com bicho na frente reprova" do
      r =
        report(%{metrics: %{revives: [revive(%{since_stun_ms: nil, control_ready?: true})]}})

      refute cumpriu?(r, :revive_no_prazo)
    end

    # A ordem dele, em maiúsculas: "se não tiver livre, usar o que tem de
    # cooldown e usa o revive, não perde tempo fugindo".
    test "controle FRIO sem stun cumpre — é a ordem dele" do
      r =
        report(%{metrics: %{revives: [revive(%{since_stun_ms: nil, control_ready?: false})]}})

      assert cumpriu?(r, :revive_no_prazo)
    end

    test "pokémon sem controle classificado não tem escolha a cobrar" do
      r = report(%{metrics: %{revives: [revive(%{since_stun_ms: nil, control_ready?: nil})]}})

      assert cumpriu?(r, :revive_no_prazo)
    end

    test "tela limpa não precisa de controle" do
      r =
        report(%{
          metrics: %{revives: [revive(%{since_stun_ms: nil, enemies: 0, control_ready?: true})]}
        })

      assert cumpriu?(r, :revive_no_prazo)
    end

    test "stun velho demais, com controle pronto, reprova" do
      r = report(%{metrics: %{revives: [revive(%{since_stun_ms: 9_000})]}})

      refute cumpriu?(r, :revive_no_prazo)
    end
  end

  describe "sem gastar revive" do
    test "nenhum revive cumpre" do
      assert cumpriu?(report(%{}), :sem_revive)
    end

    test "um revive reprova" do
      refute cumpriu?(report(%{metrics: %{revives: [revive(%{})]}}), :sem_revive)
    end
  end

  describe "o selo" do
    test "sem promessa nenhuma o cenário é de OBSERVAR, não de passar" do
      assert Verdict.seal(Verdict.judge(report(%{}), [])) == :sem_promessa
    end

    test "todas cumpridas é ok" do
      assert report(%{}) |> Verdict.judge([:nao_cai, :mata]) |> Verdict.seal() == :ok
    end

    test "uma quebrada derruba o selo inteiro" do
      seal =
        %{outcome: %{killed: 0}}
        |> report()
        |> Verdict.judge([:nao_cai, :mata])
        |> Verdict.seal()

      assert seal == :falhou
    end
  end

  test "uma promessa desconhecida é ignorada, não estoura" do
    assert Verdict.judge(report(%{}), [:promessa_que_nao_existe]) == []
  end

  test "todas as promessas têm nome e frase" do
    for promessa <- Verdict.all() do
      assert Verdict.label(promessa) != ""
      assert Verdict.note(promessa) != ""
    end
  end
end
