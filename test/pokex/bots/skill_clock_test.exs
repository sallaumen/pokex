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
    test "uma tecla apertada fica em cooldown pelo tempo escrito dela, e volta" do
      SkillClock.pressed("4", 0)

      assert SkillClock.cooling_ms("4", @cds, 1_000) == 39_000
      assert SkillClock.cooling_ms("4", @cds, 39_999) == 1
      assert SkillClock.cooling_ms("4", @cds, 40_000) == 0
      assert SkillClock.cooling_ms("4", @cds, 90_000) == 0
    end

    test "cada tecla tem o SEU tempo — era um número só pra barra inteira" do
      SkillClock.pressed("4", 0)
      SkillClock.pressed("5", 0)

      assert SkillClock.ready_by_clock(~w(4 5), @cds, 10_000) == ["5"]
    end

    # Um cooldown que ninguém escreveu não pode virar espera inventada: o bot
    # tem que seguir se comportando como antes desta tabela existir.
    test "tecla sem cooldown escrito não é vetada pelo relógio" do
      SkillClock.pressed("9", 0)

      assert SkillClock.cooling_ms("9", @cds, 1) == 0
      assert SkillClock.ready(["9"], ~w(9), @cds, 1) == ["9"]
    end
  end

  describe "a tela cruzada com o relógio" do
    test "a tela manda quando diz que NÃO — ela sabe de coisas que ninguém escreveu" do
      assert SkillClock.ready(["5"], ~w(4 5), @cds, 100_000) == ["5"]
      refute "4" in SkillClock.ready(["5"], ~w(4 5), @cds, 100_000)
    end

    # A foto tem idade (`skill_bar_fact_max_age_ms`): uma tecla que saiu agora
    # ainda aparece pronta nela, e era assim que a rajada re-apertava o que
    # acabou de gastar.
    test "o relógio manda quando diz que NÃO, mesmo com a tela dizendo que sim" do
      SkillClock.pressed("4", 0)

      assert SkillClock.ready(["4", "5"], ~w(4 5), @cds, 1_000) == ["5"]
    end

    test "com a tela ilegível o relógio responde sozinho, em vez de cegar o bot" do
      SkillClock.pressed("4", 0)

      assert SkillClock.ready(nil, ~w(4 5), @cds, 1_000) == ["5"]
    end

    test "sem tela e sem tecla conhecida, o desconhecido de sempre" do
      assert SkillClock.ready(["1", "2"], [], %{}, 0) == ["1", "2"]
      assert SkillClock.ready(nil, [], %{}, 0) == nil
    end
  end

  # "Na falta de configuração, faz ele assumir que o cooldown é 45 segundos"
  # (27/08). 45s é a média das duas famílias que o vídeo mediu: 40s nas teclas
  # 1-3 e 50s nas 4-6.
  describe "o cooldown assumido" do
    test "sem tela, uma tecla sem número escrito espera os 45 segundos" do
      SkillClock.pressed("7", 0)

      assert SkillClock.ready(nil, ~w(7), %{}, 44_999) == []
      assert SkillClock.ready(nil, ~w(7), %{}, 45_000) == ["7"]
    end

    test "o que ELE escreveu vence o assumido" do
      SkillClock.pressed("5", 0)

      assert SkillClock.ready(nil, ~w(5), @cds, 8_000) == ["5"]
    end

    # Palpite preenche buraco; não desmente observação. Se a skill volta em 8s e
    # a gente chuta 45, vetar a tela tiraria a tecla mais rápida da barra por 37
    # segundos — e ninguém veria por quê.
    test "o assumido NÃO derruba a tela: só o cooldown escrito faz isso" do
      SkillClock.pressed("7", 0)

      assert SkillClock.ready(["7"], ~w(7), %{}, 1_000) == ["7"]
    end
  end

  # R3: o revive devolve o pokémon com a barra inteira. Sem isto o relógio
  # seguraria por 40s teclas que o jogo acabou de liberar — e a decisão que MAIS
  # depende dele é justamente a de gastar um revive pra zerar a barra.
  test "o revive zera o relógio" do
    SkillClock.pressed("4", 0)
    assert SkillClock.cooling_ms("4", @cds, 1_000) > 0

    SkillClock.reset()

    assert SkillClock.cooling_ms("4", @cds, 1_000) == 0
  end

  describe "quando a tela mente" do
    # MEDIDO na captura dele de 27/08 19:07: o jogo escrevia 12, 32 e 32 em cima
    # das teclas 3, 4 e 5, e a leitura de prontidão respondia "3 e 5 prontas".
    test "a tecla que o jogo ignorou sai da lista mesmo com a tela oferecendo" do
      SkillClock.pressed("5", 0)
      SkillClock.denied("5", 1_300)

      assert SkillClock.ready(["3", "5"], [], @cds, 2_000) == ["3"]
    end

    test "ela volta quando o cooldown ESCRITO dela termina" do
      SkillClock.denied("5", 0)

      assert SkillClock.deaf_ms("5", @cds, 7_999) == 1
      assert SkillClock.ready(["5"], [], @cds, 7_999) == []
      assert SkillClock.ready(["5"], [], @cds, 8_000) == ["5"]
    end

    test "sem cooldown escrito, o assumido é quem devolve a tecla" do
      SkillClock.denied("9", 0)

      assert SkillClock.ready(["9"], [], %{}, 44_999) == []
      assert SkillClock.ready(["9"], [], %{}, 45_000) == ["9"]
    end

    test "a mentira é por tecla — nenhuma outra é calada junto" do
      SkillClock.denied("5", 0)

      assert SkillClock.ready(["3", "4", "5", "9"], [], %{}, 1_000) == ["3", "4", "9"]
    end

    test "o revive devolve tudo, inclusive a confiança na tela" do
      SkillClock.denied("5", 0)
      SkillClock.reset()

      assert SkillClock.ready(["5"], [], %{}, 1_000) == ["5"]
    end
  end
end
