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
    SkillClock.wipe()
    SkillTruth.ensure_table()
    :ets.delete_all_objects(SkillTruth.table())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())
    on_exit(fn -> SkillClock.wipe() end)
    :ok
  end

  test "an unreadable bar disproves nobody" do
    SkillClock.pressed("4", @now - 10_000)
    assert SkillTruth.observe(%{ready_keys: nil}, @now) == []
    assert SkillClock.last_press("4")
  end

  test "the disagreement needs TWO frames: a single frame is a noisy photo" do
    SkillClock.pressed("4", @now - 10_000)

    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now) == []
    assert SkillClock.last_press("4")

    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + 400) == ["4"]
    refute SkillClock.last_press("4")
  end

  test "a hot stamp freed becomes news in the feed" do
    SkillClock.pressed("4", @now - 10_000)
    SkillTruth.observe(%{ready_keys: ["4"]}, @now)
    SkillTruth.observe(%{ready_keys: ["4"]}, @now + 400)

    assert_receive {:combat_log, :macro, text}
    assert text =~ "o jogo mostra a 4 pronta"
    assert text =~ "soltei"
  end

  test "a stamp younger than the grace stays: the effect takes ~1s to show on screen" do
    SkillClock.pressed("4", @now - 1_000)

    for frame <- 0..4 do
      assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + frame * 100) == []
    end

    assert SkillClock.last_press("4")
  end

  test "a key leaving ready between frames resets the streak" do
    SkillClock.pressed("4", @now - 10_000)

    SkillTruth.observe(%{ready_keys: ["4"]}, @now)
    # o frame seguinte mostra a 4 ESFRIANDO — a discordância morreu
    SkillTruth.observe(%{ready_keys: []}, @now + 400)
    # pronta de novo: recomeça do primeiro frame, não solta ainda
    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + 800) == []
    assert SkillClock.last_press("4")
  end

  test "a deaf key stays out: 'ready on screen' is exactly its lying state" do
    SkillClock.pressed("5", @now - 10_000)
    SkillClock.denied("5", @now - 5_000)

    SkillTruth.observe(%{ready_keys: ["5"]}, @now)
    assert SkillTruth.observe(%{ready_keys: ["5"]}, @now + 400) == []
    assert SkillClock.last_press("5")
  end

  test "an already expired stamp is silent housekeeping, not news" do
    SkillClock.pressed("4", @now - 60_000)

    SkillTruth.observe(%{ready_keys: ["4"]}, @now)
    assert SkillTruth.observe(%{ready_keys: ["4"]}, @now + 400) == ["4"]

    refute SkillClock.last_press("4")
    refute_receive {:combat_log, _level, _text}, 50
  end

  test "several keys freed at once: the signature of the revive the bot did not see" do
    for key <- ~w(3 4 5), do: SkillClock.pressed(key, @now - 10_000)

    SkillTruth.observe(%{ready_keys: ~w(3 4 5)}, @now)
    freed = SkillTruth.observe(%{ready_keys: ~w(3 4 5)}, @now + 400)

    assert Enum.sort(freed) == ~w(3 4 5)
    for key <- ~w(3 4 5), do: refute(SkillClock.last_press(key))
  end
end
