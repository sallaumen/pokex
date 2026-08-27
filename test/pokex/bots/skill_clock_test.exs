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

      assert SkillClock.ready_by_clock(@cds, 10_000) == ["5"]
    end

    # Um cooldown que ninguém escreveu não pode virar espera inventada: o bot
    # tem que seguir se comportando como antes desta tabela existir.
    test "tecla sem cooldown escrito conta como pronta" do
      SkillClock.pressed("9", 0)

      assert SkillClock.cooling_ms("9", @cds, 1) == 0
      assert SkillClock.ready(["9"], @cds, 1) == ["9"]
    end
  end

  describe "a tela cruzada com o relógio" do
    test "a tela manda quando diz que NÃO — ela sabe de coisas que ninguém escreveu" do
      assert SkillClock.ready(["5"], @cds, 100_000) == ["5"]
      refute "4" in SkillClock.ready(["5"], @cds, 100_000)
    end

    # A foto tem idade (`skill_bar_fact_max_age_ms`): uma tecla que saiu agora
    # ainda aparece pronta nela, e era assim que a rajada re-apertava o que
    # acabou de gastar.
    test "o relógio manda quando diz que NÃO, mesmo com a tela dizendo que sim" do
      SkillClock.pressed("4", 0)

      assert SkillClock.ready(["4", "5"], @cds, 1_000) == ["5"]
    end

    test "com a tela ilegível o relógio responde sozinho, em vez de cegar o bot" do
      SkillClock.pressed("4", 0)

      assert SkillClock.ready(nil, @cds, 1_000) == ["5"]
    end

    test "sem cooldown nenhum escrito, tudo é como era antes: a tela, ou o desconhecido" do
      assert SkillClock.ready(["1", "2"], %{}, 0) == ["1", "2"]
      assert SkillClock.ready(nil, %{}, 0) == nil
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
end
