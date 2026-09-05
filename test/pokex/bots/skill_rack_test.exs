defmodule Pokex.Bots.SkillRackTest do
  @moduledoc """
  A barra vista de fora, com as duas testemunhas lado a lado.

  Ele pediu isto depois de 27/08: "importante na tela de cavebot mostrar de
  forma clara (…) o que que tá em cooldown, o que que não tá, e quanto tempo
  falta em contagem regressiva (…) pra eu ir ajudando a debugar problemas de
  leitura do jogo".

  O caso que dá nome a tudo é o `disagree?`: a barra dizendo PRONTA enquanto o
  jogo escrevia 32 segundos em cima da tecla.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.{SkillClock, SkillRack}

  @loadout %{
    name: "Steelix",
    opening: ["3", "4", "5"],
    reserved: ["2"],
    buffs: ["1"],
    single: ["6", "7"],
    heal: [],
    cooldowns: %{"3" => 40_000, "4" => 50_000, "5" => 50_000}
  }

  setup do
    SkillClock.wipe()
    on_exit(&SkillClock.wipe/0)
    :ok
  end

  defp tile(tiles, key), do: Enum.find(tiles, &(&1.key == key))

  describe "a ordem da fileira" do
    test "is the bar's order, with zero last" do
      loadout = %{@loadout | opening: ["4", "0", "3"], reserved: ["2"], buffs: [], single: []}

      assert SkillRack.order(loadout) == ["2", "3", "4", "0"]
    end

    test "a key that is not a slot goes last instead of crashing the page" do
      assert SkillRack.order(%{opening: ["f4", "2"]}) == ["2", "f4"]
    end

    # `reserved` é a lista de EXCLUSÃO da rotação: controle E escudo. Numa tela
    # de diagnóstico, chamar o escudo de controle mente sobre a coisa exata que
    # ela existe pra mostrar.
    test "the shield is a shield, not a pocketed control" do
      loadout = Map.put(@loadout, :shield, ["2"])

      assert SkillRack.job_of("2", loadout) == "escudo"
      assert SkillRack.job_of("2", @loadout) == "controle (guardado pro revive)"
    end

    # A rotação não usa alvo único desde 27/08, e uma tecla que some da tela é
    # uma tecla que ele não sabe que tem.
    test "the single-target keys show up, with the job saying they are out" do
      tiles = SkillRack.build(@loadout, ["6"], 0)

      assert tile(tiles, "6").job == "alvo único (fora da rotação)"
    end
  end

  describe "o que a peça diz" do
    test "screen and clock agreeing is a ready key, without noise" do
      peca = SkillRack.build(@loadout, ~w(1 2 3 4 5), 0) |> tile("3")

      assert peca.state == :ready
      assert peca.screen == :ready
      assert peca.disagree? == false
      assert peca.left_ms == 0
    end

    test "pressed now, it counts its written cooldown down" do
      SkillClock.pressed("4", 0)

      peca = SkillRack.build(@loadout, ~w(1 2 3 5), 10_000) |> tile("4")

      assert peca.state == :cooling
      assert peca.left_ms == 40_000
      assert peca.written_ms == 50_000
      assert SkillRack.recovered_pct(peca) == 20
    end

    # O DEFEITO DE 27/08, agora visível: a barra oferecendo a tecla que o jogo
    # está contando na tela.
    test "the screen saying ready with the clock counting is a marked disagreement" do
      SkillClock.pressed("5", 0)

      peca = SkillRack.build(@loadout, ~w(1 2 3 4 5), 18_000) |> tile("5")

      assert peca.screen == :ready
      assert peca.clock == :cooling
      assert peca.disagree? == true
      # e quem manda é o relógio: é o mesmo `SkillClock.ready/4` do combate
      assert peca.state == :cooling
      assert peca.left_ms == 32_000
    end

    test "the key the game ignored shows up silenced, and says until when" do
      SkillClock.denied("6", 0)

      peca = SkillRack.build(@loadout, ~w(6), 5_000) |> tile("6")

      assert peca.muted? == true
      assert peca.state == :cooling
      # sem número escrito, o assumido é quem segura
      assert peca.left_ms == SkillClock.assumed_ms() - 5_000
    end

    test "without a written number and without a press, the clock says it does not know" do
      peca = SkillRack.build(@loadout, ~w(6 7), 0) |> tile("7")

      assert peca.clock == :unknown
      assert peca.state == :ready
      assert peca.disagree? == false
    end

    # Não saber e estar fria são fatos opostos, e não podem virar a mesma cor.
    test "an unreadable bar is unknown, not a disagreement" do
      SkillClock.pressed("3", 0)

      tiles = SkillRack.build(@loadout, nil, 1_000)

      assert tile(tiles, "3").screen == :unknown
      assert tile(tiles, "3").clock == :cooling
      assert tile(tiles, "3").disagree? == false
      # com a tela fora, o relógio responde sozinho — inclusive pelo assumido
      assert tile(tiles, "3").state == :cooling
      assert tile(tiles, "7").state == :ready
    end

    test "the revive returns the whole bar, and the row shows it" do
      SkillClock.pressed("4", 0)
      SkillClock.pressed("5", 0)
      SkillClock.reset()

      tiles = SkillRack.build(@loadout, ~w(1 2 3 4 5 6 7), 1_000)

      assert SkillRack.ready_count(tiles) == 7
    end
  end

  describe "o trilho que enche" do
    test "full when the key is ready" do
      assert SkillRack.recovered_pct(%{state: :ready, left_ms: 0}) == 100
    end

    # Uma fração inventada é pior que um traço: ela parece medida.
    test "absent when nobody wrote how long the key takes" do
      peca = %{state: :cooling, left_ms: 3_000, written_ms: nil, muted?: false}

      assert SkillRack.recovered_pct(peca) == nil
    end

    test "absent when the screen says cold and nobody knows how much is left" do
      assert SkillRack.recovered_pct(%{state: :cooling, left_ms: 0}) == nil
    end
  end

  test "without a chosen pokemon the row is empty, not an error" do
    assert SkillRack.build(nil, ~w(1 2), 0) == []
  end
end
