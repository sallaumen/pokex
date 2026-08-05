defmodule Pokex.CalibrationMiniGameTest do
  @moduledoc """
  Mini-game region: MANUAL ONLY — no mark, no guess.

  The history, because every ghost here bit in the field: the auto-layout strip
  assumed the game window never moved (it did — same root as the y=-132
  minimap) and silently vetoed manual calibration; the half-screen central box
  was "aquela área grandona" nobody recognised; and the character-anchored tile
  box read a dark trunk column + bright-blue flowers as "bar + capsule" at a
  rocky spot (2026-08-05), flapping enter/exit once a second and holding the
  whole fleet. Scenery is too creative to out-guess. Without a hand-marked
  strip the resolver answers nil and the watcher goes blind AND SAYS SO.
  """
  use ExUnit.Case, async: false

  alias Pokex.{Calibration, Layout}
  alias Pokex.Perception.WorldState

  @measured {3067, 800, 28, 479}

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    on_exit(fn -> WorldState.forget(:layout) end)
    {:ok, fix} = Layout.locate(Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full"))
    %{fix: fix}
  end

  test "the layout still carries the measured strip (data, not authority)", %{fix: fix} do
    assert Layout.region(:mini_game, fix) == @measured
  end

  test "a FIXED region ignores where the anchors landed — anchored ones do not" do
    profile = Layout.profile()
    frame = Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full")

    higher = put_in(profile, ["anchors", "battle_header", "measured_at"], [3184, 287])

    {:ok, now} = Layout.locate(frame, profile)
    {:ok, then_} = Layout.locate(frame, higher)

    assert Layout.region(:battle_list, now) == Layout.region(:battle_list, then_)
    assert Layout.region(:mini_game, now) == @measured
    assert Layout.region(:mini_game, then_) == @measured
  end

  test "a manual mark is the ONLY authority — layout strip never resolves", %{fix: fix} do
    hand_marked = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      mini_game_region: {2976, 555, 113, 773},
      layout: fix
    }

    assert Calibration.mini_game_region(hand_marked) == {2976, 555, 113, 773}
  end

  # A imagem anotada dele (2026-08-05): "ele está sempre ali bem pertinho do meu
  # personagem e vai até quase lá na barra de skills". As duas âncoras já são
  # calibradas, então a faixa se DERIVA delas — e re-deriva sozinha quando a
  # resolução muda, que era a queixa real.
  describe "faixa derivada das âncoras (personagem + barra de skills)" do
    defp anchored do
      %Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        player_point: {1688, 697},
        skill_bar_region: {1532, 1290, 430, 43}
      }
    end

    test "nasce do personagem e para antes da barra de skills" do
      # meia-largura 50 em volta do personagem; topo 60px acima dele; fundo 20px
      # acima do topo da barra de skills
      assert Calibration.mini_game_region(anchored()) == {1638, 637, 100, 633}
    end

    test "CONTÉM a faixa que ele marcou à mão no mesmo perfil" do
      # perfil 2-moni-8skill-baixo: a marcação caprichada dele, medida
      {bx, by, bw, bh} = Calibration.mini_game_region(anchored())
      {x, y, w, h} = {1674, 648, 29, 471}

      assert x >= bx and x + w <= bx + bw, "a faixa marcada escapa em x"
      assert y >= by and y + h <= by + bh, "a faixa marcada escapa em y"
    end

    test "acompanha a barra de skills — é isso que sobrevive à troca de resolução" do
      subiu = %Calibration{anchored() | skill_bar_region: {1532, 1000, 430, 43}}
      {_x, _y, _w, h} = Calibration.mini_game_region(anchored())
      {_x2, _y2, _w2, h2} = Calibration.mini_game_region(subiu)

      assert h2 < h
    end

    test "sem barra de skills não há de onde derivar: nil, e o vigia fica cego" do
      sem_barra = %Calibration{anchored() | skill_bar_region: nil}
      assert Calibration.mini_game_region(sem_barra) == nil

      assert Calibration.mini_game_region(%Calibration{scale: 1.0}) == nil
    end

    test "a marcação manual continua ganhando da derivação" do
      marcada = %Calibration{anchored() | mini_game_region: {2976, 555, 113, 773}}
      assert Calibration.mini_game_region(marcada) == {2976, 555, 113, 773}
    end
  end
end
