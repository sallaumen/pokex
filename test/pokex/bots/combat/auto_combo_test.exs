defmodule Pokex.Bots.Combat.AutoComboTest do
  @moduledoc """
  UMA TECLA, e a janela em que nada mais sai.

  As duas metades do modo: o plano (qual tecla) e a testemunha (por quanto
  tempo). A cerca que USA a testemunha é cobrada no `worker_test.exs`, e a
  regra que impede o revive no meio do combo, no `engine/logic_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Combat.{Combo, Loadout, Plan}
  alias Pokex.Bots.SkillClock
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash!(auto_combo_key: "r", auto_combo_window_ms: 4_000)
    SkillClock.wipe()
    on_exit(&SkillClock.wipe/0)
    :ok
  end

  defp loadout do
    %Loadout{name: "Vespiquen", aoe: ["3", "4"], single: ["7"], crowd: ["1"], buffs: ["2"]}
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(%{enemies: 3, ready_keys: nil, config: %{}}, overrides)
  end

  describe "o plano" do
    test "toda pergunta de ataque responde a MESMA tecla" do
      assert Plan.AutoCombo.opening(loadout(), ctx()) == ["r"]
      assert Plan.AutoCombo.sustained(loadout(), ctx()) == ["r"]
      assert Plan.AutoCombo.small(loadout(), ctx()) == ["r"]
    end

    # "Não pressionar skills ofensivas individualmente."
    test "não sobra tecla solta pra apertar" do
      assert Plan.AutoCombo.single(loadout(), ctx()) == []
    end

    # O stun é a última metade da corrente do jogo: gastá-lo por fora seria
    # pagar duas vezes pelo mesmo sono.
    test "o cérebro não tem controle pra gastar" do
      assert Plan.AutoCombo.crowd(loadout(), ctx()) == []
    end

    test "não usa Tab" do
      refute Plan.AutoCombo.tab?(ctx())
    end

    # O BOLSO. A corrente gasta a ÁREA; o alvo único e o controle ficam de fora
    # da rotação por regra dele — e por isso são exatamente o que sobra quando a
    # área acabou. Sem eles, com a barra gasta, a única saída do cérebro era o
    # revive: recolher o pokémon no meio da mobada. Foi assim que o personagem
    # morreu em 03/09.
    test "o alvo único e o controle ficam guardados pra emergência" do
      assert Plan.AutoCombo.reserve(loadout(), ctx()) == ~w(7 1)
    end

    test "sem pokémon não há bolso" do
      assert Plan.AutoCombo.reserve(nil, ctx()) == []
    end

    # `spent?` mede contra a BARRA, porque é a barra que a corrente gasta — e é
    # ela que o revive devolve. Reportar a tecla do combo aqui faria a pergunta
    # ser sobre uma tecla que a barra não mostra.
    test "o que conta como barra gasta é a ÁREA do pokémon" do
      assert Plan.AutoCombo.damage_keys(loadout(), ctx()) == ["3", "4"]
    end

    # As de alvo único voltam em 10-20s contra 35-60s da área, e uma delas
    # pronta sozinha segurava `spent?` em falso: a corrida de 23:04 de 01/09
    # apertou o combo cinco vezes com "1 de 8 pronta" e nunca reviveu.
    test "as de alvo único ficam de fora mesmo com a chave ligada" do
      ligada = ctx(%{config: %{single_target: true, combat_single_target: true}})

      assert Plan.AutoCombo.damage_keys(loadout(), ligada) == ["3", "4"]
    end

    test "uma tecla barata pronta não segura a corrente com a área toda gasta" do
      so_a_barata = ctx(%{ready_keys: ["7"], config: %{combat_single_target: true}})

      assert Plan.AutoCombo.sustained(loadout(), so_a_barata) == []
    end

    test "a tecla não depende do pokémon — ela é do cliente" do
      assert Plan.AutoCombo.opening(nil, ctx()) == ["r"]
    end

    test "sem tecla configurada não há o que apertar" do
      SettingsStash.stash!(auto_combo_key: "")

      assert Plan.AutoCombo.opening(loadout(), ctx()) == []
    end
  end

  describe "a testemunha da corrente" do
    test "sem a tecla ter saído, não há corrente" do
      refute Combo.running?(:auto_combo)
      assert Combo.left_ms(:auto_combo) == 0
    end

    test "depois da prensa, a corrente ocupa a janela inteira" do
      agora = now()
      SkillClock.pressed("r", agora)

      assert Combo.running?(:auto_combo, agora)
      assert Combo.left_ms(:auto_combo, agora) == 4_000
      assert Combo.left_ms(:auto_combo, agora + 1_500) == 2_500
    end

    test "passada a janela, a corrente acabou" do
      agora = now()
      SkillClock.pressed("r", agora)

      refute Combo.running?(:auto_combo, agora + 4_000)
      assert Combo.left_ms(:auto_combo, agora + 9_000) == 0
    end

    # A MÃO DELE CONTA IGUAL: o `HandWatch` carimba o R que ele apertou, e a
    # corrente está rodando do mesmo jeito.
    test "um R apertado por ele também abre a janela" do
      agora = now()
      SkillClock.pressed("r", agora)

      assert Combo.running?(:auto_combo, agora + 100)
    end

    test "fora do Auto Combo não existe corrente pra esperar" do
      SkillClock.pressed("r", now())

      assert Combo.left_ms(:economy) == nil
      refute Combo.running?(:economy)
      refute Combo.running?(nil)
    end

    test "janela zerada é o modo sem cerca nenhuma" do
      SettingsStash.stash!(auto_combo_window_ms: 500)
      SkillClock.pressed("r", now())

      assert Combo.running?(:auto_combo)
      refute Combo.running?(:auto_combo, now() + 600)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
