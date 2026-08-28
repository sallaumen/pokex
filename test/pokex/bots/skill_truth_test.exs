defmodule Pokex.Bots.SkillTruthTest do
  @moduledoc """
  A tela corrigindo o relógio: um carimbo que o jogo desmente (tecla PRONTA na
  tela com carimbo quente no relógio) é solto — depois de dois frames e da
  carência do efeito. É o conserto da caçada de 28/08: "a IA acha que usou uma
  skill e marca o cooldown, mas na verdade ela não saiu".
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.{SkillClock, SkillTruth}

  # Tudo em cima do MESMO relógio dos módulos: monotônico, ms.
  @now System.monotonic_time(:millisecond)

  setup do
    SkillClock.reset()
    SkillTruth.ensure_table()
    :ets.delete_all_objects(SkillTruth.table())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())
    on_exit(fn -> SkillClock.reset() end)
    :ok
  end

  test "barra ilegível não desmente ninguém" do
    SkillClock.pressed("4", @now - 10_000)
    assert SkillTruth.observe(%{ready_keys: nil}, @now) == []
    assert SkillClock.last_press("4")
  end

  test "a discordância precisa de DOIS frames — um frame só é foto com ruído" do
    SkillClock.pressed("4", @now - 10_000)

    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now) == []
    assert SkillClock.last_press("4")

    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + 400) == ["4"]
    refute SkillClock.last_press("4")
  end

  test "carimbo quente solto vira notícia no feed" do
    SkillClock.pressed("4", @now - 10_000)
    SkillTruth.observe(%{ready_keys: ["4"]}, @now)
    SkillTruth.observe(%{ready_keys: ["4"]}, @now + 400)

    assert_receive {:combat_log, :macro, text}
    assert text =~ "o jogo mostra a 4 pronta"
    assert text =~ "soltei"
  end

  test "carimbo mais novo que a carência fica — o efeito leva ~1s pra aparecer na tela" do
    SkillClock.pressed("4", @now - 1_000)

    for frame <- 0..4 do
      assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + frame * 100) == []
    end

    assert SkillClock.last_press("4")
  end

  test "a tecla que sai de pronta entre os frames zera o streak" do
    SkillClock.pressed("4", @now - 10_000)

    SkillTruth.observe(%{ready_keys: ["4"]}, @now)
    # o frame seguinte mostra a 4 ESFRIANDO — a discordância morreu
    SkillTruth.observe(%{ready_keys: []}, @now + 400)
    # pronta de novo: recomeça do primeiro frame, não solta ainda
    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + 800) == []
    assert SkillClock.last_press("4")
  end

  test "tecla surda fica fora — 'pronta na tela' é exatamente o estado mentiroso dela" do
    SkillClock.pressed("5", @now - 10_000)
    SkillClock.denied("5", @now - 5_000)

    SkillTruth.observe(%{ready_keys: ["5"]}, @now)
    assert SkillTruth.observe(%{ready_keys: ["5"]}, @now + 400) == []
    assert SkillClock.last_press("5")
  end

  test "carimbo já expirado é faxina silenciosa, não notícia" do
    SkillClock.pressed("4", @now - 60_000)

    SkillTruth.observe(%{ready_keys: ["4"]}, @now)
    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + 400) == ["4"]

    refute SkillClock.last_press("4")
    refute_receive {:combat_log, _level, _text}, 50
  end

  test "várias teclas soltas de uma vez — a assinatura do revive que o bot não viu" do
    for key <- ~w(3 4 5), do: SkillClock.pressed(key, @now - 10_000)

    SkillTruth.observe(%{ready_keys: ~w(3 4 5)}, @now)
    freed = SkillTruth.observe(%{ready_keys: ~w(3 4 5)}, @now + 400)

    assert Enum.sort(freed) == ~w(3 4 5)
    for key <- ~w(3 4 5), do: refute(SkillClock.last_press(key))
  end
end
