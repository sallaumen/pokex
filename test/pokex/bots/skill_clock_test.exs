defmodule Pokex.Bots.SkillClockTest do
  @moduledoc """
  O relógio das teclas: o que o bot apertou, e o que isso implica.

  Ele descreveu o buraco em 27/08: "é muito importante esse cérebro ter noção de
  quando ele rodou uma skill e ter certeza de que ele rodou (…) não precisa
  ficar rechecando a tela". Até então a ÚNICA fonte era a barra na tela, que
  falha OPEN — leitura ruim virava rotação cega.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.SkillClock

  @cds %{"4" => 40_000, "5" => 8_000}

  setup do
    SkillClock.reset()
    on_exit(&SkillClock.reset/0)
    :ok
  end

  describe "o que ele apertou" do
    test "a pressed key cools for its written time, and comes back" do
      SkillClock.pressed("4", 0)

      assert SkillClock.cooling_ms("4", @cds, 1_000) == 39_000
      assert SkillClock.cooling_ms("4", @cds, 39_999) == 1
      assert SkillClock.cooling_ms("4", @cds, 40_000) == 0
      assert SkillClock.cooling_ms("4", @cds, 90_000) == 0
    end

    test "each key has ITS OWN time: it used to be one number for the whole bar" do
      SkillClock.pressed("4", 0)
      SkillClock.pressed("5", 0)

      assert SkillClock.ready_by_clock(~w(4 5), @cds, 10_000) == ["5"]
    end

    # Um cooldown que ninguém escreveu não pode virar espera inventada: o bot
    # tem que seguir se comportando como antes desta tabela existir.
    test "a key without a written cooldown is not vetoed by the clock" do
      SkillClock.pressed("9", 0)

      assert SkillClock.cooling_ms("9", @cds, 1) == 0
      assert SkillClock.ready(["9"], ~w(9), @cds, 1) == ["9"]
    end
  end

  describe "a tela cruzada com o relógio" do
    test "the screen rules when it says NO: it knows things nobody wrote" do
      assert SkillClock.ready(["5"], ~w(4 5), @cds, 100_000) == ["5"]
      refute "4" in SkillClock.ready(["5"], ~w(4 5), @cds, 100_000)
    end

    # A foto tem idade (`skill_bar_fact_max_age_ms`): uma tecla que saiu agora
    # ainda aparece pronta nela, e era assim que a rajada re-apertava o que
    # acabou de gastar.
    test "the clock rules when it says NO, even with the screen saying yes" do
      SkillClock.pressed("4", 0)

      assert SkillClock.ready(["4", "5"], ~w(4 5), @cds, 1_000) == ["5"]
    end

    test "with the screen unreadable the clock answers alone instead of blinding the bot" do
      SkillClock.pressed("4", 0)

      assert SkillClock.ready(nil, ~w(4 5), @cds, 1_000) == ["5"]
    end

    test "no screen and no known key: the usual unknown" do
      assert SkillClock.ready(["1", "2"], [], %{}, 0) == ["1", "2"]
      assert SkillClock.ready(nil, [], %{}, 0) == nil
    end
  end

  # "Na falta de configuração, faz ele assumir que o cooldown é 45 segundos"
  # (27/08). 45s é a média das duas famílias que o vídeo mediu: 40s nas teclas
  # 1-3 e 50s nas 4-6.
  describe "o cooldown assumido" do
    test "no screen, a key without a written number waits the 45 seconds" do
      SkillClock.pressed("7", 0)

      assert SkillClock.ready(nil, ~w(7), %{}, 44_999) == []
      assert SkillClock.ready(nil, ~w(7), %{}, 45_000) == ["7"]
    end

    test "what HE wrote beats the assumed" do
      SkillClock.pressed("5", 0)

      assert SkillClock.ready(nil, ~w(5), @cds, 8_000) == ["5"]
    end

    # Palpite preenche buraco; não desmente observação. Se a skill volta em 8s e
    # a gente chuta 45, vetar a tela tiraria a tecla mais rápida da barra por 37
    # segundos — e ninguém veria por quê.
    test "the assumed does NOT overrule the screen: only a written cooldown does" do
      SkillClock.pressed("7", 0)

      assert SkillClock.ready(["7"], ~w(7), %{}, 1_000) == ["7"]
    end
  end

  # R3: o revive devolve o pokémon com a barra inteira. Sem isto o relógio
  # seguraria por 40s teclas que o jogo acabou de liberar — e a decisão que MAIS
  # depende dele é justamente a de gastar um revive pra zerar a barra.
  test "the revive resets the clock" do
    SkillClock.pressed("4", 0)
    assert SkillClock.cooling_ms("4", @cds, 1_000) > 0

    SkillClock.reset()

    assert SkillClock.cooling_ms("4", @cds, 1_000) == 0
  end

  describe "quando a tela mente" do
    # MEDIDO na captura dele de 27/08 19:07: o jogo escrevia 12, 32 e 32 em cima
    # das teclas 3, 4 e 5, e a leitura de prontidão respondia "3 e 5 prontas".
    test "the key the game ignored leaves the list even with the screen offering it" do
      SkillClock.pressed("5", 0)
      SkillClock.denied("5", 1_300)

      assert SkillClock.ready(["3", "5"], [], @cds, 2_000) == ["3"]
    end

    test "it comes back when its WRITTEN cooldown ends" do
      SkillClock.denied("5", 0)

      assert SkillClock.deaf_ms("5", @cds, 7_999) == 1
      assert SkillClock.ready(["5"], [], @cds, 7_999) == []
      assert SkillClock.ready(["5"], [], @cds, 8_000) == ["5"]
    end

    test "without a written cooldown, the assumed is what returns the key" do
      SkillClock.denied("9", 0)

      assert SkillClock.ready(["9"], [], %{}, 44_999) == []
      assert SkillClock.ready(["9"], [], %{}, 45_000) == ["9"]
    end

    test "the lie is per key: no other key is silenced along" do
      SkillClock.denied("5", 0)

      assert SkillClock.ready(["3", "4", "5", "9"], [], %{}, 1_000) == ["3", "4", "9"]
    end

    test "the revive returns everything, including trust in the screen" do
      SkillClock.denied("5", 0)
      SkillClock.reset()

      assert SkillClock.ready(["5"], [], %{}, 1_000) == ["5"]
    end
  end

  # O ECO: O REVIVE APAGA O COOLDOWN, NÃO O FATO DE A TECLA TER SIDO APERTADA.
  #
  # A noite de 29/08 rodou assim: o bot disparava 3, 4 e 5, pagava um revive
  # pra zerar a barra, o `reset/0` apagava os carimbos, e o `HandWatch` drenava
  # os apertos que o PRÓPRIO BOT tinha acabado de fazer, não achava carimbo e
  # concluía "foi a mão do Lucas" — recarimbando o cooldown 340ms depois do
  # revive. A barra voltava fria e o R3b dizia "paguei um revive e a barra não
  # voltou". 235 atribuições falsas em 242 revives, 97% delas em cima de uma
  # rajada do bot na mesma tecla.
  describe "o eco que sobrevive ao reset" do
    test "after the reset the key is READY: the echo is not a cooldown" do
      SkillClock.reset()
      SkillClock.pressed("4")
      SkillClock.reset()

      assert SkillClock.last_press("4") == nil
      assert SkillClock.cooling_ms("4", %{"4" => 50_000}) == 0
    end

    test "…and the press is still OURS" do
      SkillClock.reset()
      agora = System.monotonic_time(:millisecond)
      SkillClock.pressed("4", agora)
      SkillClock.reset()

      assert SkillClock.pressed_at("4") == agora,
             "o reset apagou a prova de que fomos nós que apertamos a 4"
    end

    test "a key nobody pressed gets no echo" do
      SkillClock.reset()
      SkillClock.pressed("4")
      SkillClock.reset()

      assert SkillClock.pressed_at("5") == nil
    end

    test "a new press is worth more than the echo" do
      SkillClock.reset()
      SkillClock.pressed("4", 1_000)
      SkillClock.reset()
      SkillClock.pressed("4", 9_000)

      assert SkillClock.pressed_at("4") == 9_000
    end

    test "o reset seguinte troca o eco em vez de acumular" do
      SkillClock.reset()
      SkillClock.pressed("4", 1_000)
      SkillClock.reset()
      SkillClock.pressed("5", 2_000)
      SkillClock.reset()

      assert SkillClock.pressed_at("5") == 2_000
      assert SkillClock.pressed_at("4") == nil
    end
  end
end
