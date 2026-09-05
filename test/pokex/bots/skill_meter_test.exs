defmodule Pokex.Bots.SkillMeterTest do
  @moduledoc """
  Quanto cada tecla tira, e quanto tempo leva pra tirar.

  A ideia é dele por inteiro: "ele e um inimigo de vida cheia, o sistema
  identifica que o inimigo de vida cheia, usa uma skill e calcula a diferença e
  salva essa diferença e associa a essa skill... se ele se identificar aqui com
  a skill 4 sozinha, ele já mata" (26/08).
  """
  # async: false — escopa :home_dir por teste.
  use ExUnit.Case, async: false

  alias Pokex.Bots.SkillMeter

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    :ok
  end

  # Uma sequência de leituras da lista de batalha, uma por poll, e um relógio
  # que anda 100ms por leitura — o mesmo passo do medidor.
  defp scripted(readings) do
    {:ok, agent} = Agent.start_link(fn -> {readings, 0} end)

    read = fn ->
      Agent.get_and_update(agent, fn
        {[last], n} -> {last, {[last], n}}
        {[head | tail], n} -> {head, {tail, n}}
      end)
    end

    now = fn -> Agent.get(agent, fn {_r, n} -> n end) end

    sleep = fn _ms -> Agent.update(agent, fn {r, n} -> {r, n + 100} end) end

    [read: read, now: now, sleep: sleep]
  end

  defp bar(count), do: %{locked_row: 0, hp: [count]}

  describe "uma tecla, uma medida" do
    test "the locked bar's drop is the damage, as a fraction" do
      # 100 → 60 é 40% da barra.
      opts = scripted([bar(100), bar(100), bar(60)])

      assert {:ok, shot} = SkillMeter.watch("4", opts)
      assert shot.key == "4"
      assert shot.took_pct == 40.0
    end

    test "WHEN it drops is the delay: the number he saw before measuring" do
      # "a spell 4 leva tipo 1s para realmente dar dano e às vezes ele sai
      # apertando 4, 5, 6. Na prática a spell 4 já mataria mas parece que ele
      # não sabe." Dez polls de 100ms é o segundo que ele descreveu.
      opts = scripted(List.duplicate(bar(100), 11) ++ [bar(40)])

      assert {:ok, %{delay_ms: delay}} = SkillMeter.watch("4", opts)
      assert delay >= 1_000
    end

    test "a bar still until the end is :no_drop, never zero damage" do
      # Zero é uma medida; "não vi" não é. Guardar zero ensinaria que a tecla
      # não faz nada, que é o oposto do que uma leitura perdida quer dizer.
      opts = scripted([bar(100)])

      assert {:error, :no_drop} = SkillMeter.watch("4", opts)
    end

    test "a reading tremor is not damage" do
      # A barra é contada em pixels; um ou dois a menos é ruído do quadro.
      opts = scripted([bar(100), bar(99)])

      assert {:error, :no_drop} = SkillMeter.watch("4", opts)
    end

    test "o alvo trocando de linha invalida a medida" do
      # A lista andou porque o anterior morreu: a queda que vier agora é de
      # outra barra, e essa medida seria pior que nenhuma.
      opts = scripted([bar(100), %{locked_row: 1, hp: [100, 30]}])

      assert {:error, :target_changed} = SkillMeter.watch("4", opts)
    end

    test "without a locked target there is nothing to measure" do
      opts = scripted([%{locked_row: nil, hp: [100]}])

      assert {:error, :no_target} = SkillMeter.watch("4", opts)
    end
  end

  describe "o que as amostras dizem" do
    test "with nothing measured, the summary is empty, not a guess" do
      assert SkillMeter.summary() == %{}
    end

    test "a mediana, e quantas amostras a sustentam" do
      file("4", [30.0, 34.0, 90.0])

      assert %{"4" => %{shots: 3, took_pct: 34.0}} = SkillMeter.summary()
    end

    test "it is the MEDIAN because another player's damage enters the count" do
      # Uma média com o 90 dentro diria 51% e nunca mais largaria esse dano
      # alheio; a mediana o ignora.
      file("4", [30.0, 34.0, 90.0])

      assert SkillMeter.summary()["4"].took_pct == 34.0
    end

    test "how many shots to kill: his whole question" do
      # "se ele se identificar aqui com a skill 4 sozinha, ele já mata, ele não
      # precisa ficar usando 4, 5, 6 sempre"
      file("4", [100.0])
      file("5", [26.0])

      assert SkillMeter.summary()["4"].to_kill == 1
      assert SkillMeter.summary()["5"].to_kill == 4
    end

    test "reset forgets everything: another pokemon has other keys" do
      file("4", [50.0])
      SkillMeter.clear()

      assert SkillMeter.summary() == %{}
    end
  end

  test "the mode is OFF until he turns it on" do
    refute SkillMeter.on?()
    Pokex.SettingsStash.stash!(skill_meter_enabled: true)
    assert SkillMeter.on?()
  end

  describe "a tecla que MATA" do
    test "the bar hitting zero is 100%, not an error" do
      # É a medida mais valiosa que existe aqui, e a que mais fácil se perderia
      # por parecer falha: um bicho morto sai da lista.
      opts = scripted([bar(100), bar(0)])

      assert {:ok, %{took_pct: 100.0}} = SkillMeter.watch("4", opts)
    end

    test "the locked row leaving the list too" do
      opts = scripted([bar(100), %{locked_row: 0, hp: []}])

      assert {:ok, %{took_pct: 100.0}} = SkillMeter.watch("4", opts)
    end

    test "but LOSING the target is not killing" do
      # A lista pode andar por qualquer motivo. Chamar isso de morte inventaria
      # um 100% — exatamente o tipo de número que este módulo existe pra apagar.
      opts = scripted([bar(100), %{locked_row: nil, hp: [100]}])

      assert {:error, :target_gone} = SkillMeter.watch("4", opts)
    end
  end

  defp file(key, pcts) do
    for pct <- pcts do
      opts = scripted([bar(100), bar(round(100 - pct))])
      :ok = SkillMeter.file(key, opts)
    end
  end
end
