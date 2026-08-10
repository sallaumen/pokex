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

  # A SUGESTÃO, medida na marca dele (2026-08-10): ele calibrou a faixa à mão,
  # jogou com ela e pediu que virasse o padrão — "tu pode fazer essa config ser
  # sempre sugerida como padrão nesse tamanho atual de monitor?".
  describe "faixa sugerida a partir do personagem" do
    # os números REAIS do perfil dele: região {1707, 673, 24, 474} contra um
    # player_point de {1707, 689}
    defp his_screen do
      %Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        player_point: {1707, 689},
        skill_bar_region: {1536, 1292, 423, 40}
      }
    end

    test "reproduz EXATAMENTE a faixa que ele marcou e validou" do
      assert Calibration.derived_mini_game_region(his_screen()) == {1707, 673, 24, 474}
    end

    test "sem marca à mão é ela que o bot observa — a página não precisa mediar" do
      assert Calibration.mini_game_region(his_screen()) == {1707, 673, 24, 474}
    end

    test "a mão continua ganhando da sugestão" do
      marcada = %Calibration{his_screen() | mini_game_region: {10, 20, 30, 40}}

      assert Calibration.mini_game_region(marcada) == {10, 20, 30, 40}
      # e a sugestão segue sendo a das âncoras: oferecer de volta a marca que
      # ele já tem não diria nada
      assert Calibration.derived_mini_game_region(marcada) == {1707, 673, 24, 474}
    end

    test "acompanha o personagem — é isso que sobrevive à troca de resolução" do
      andou = %Calibration{his_screen() | player_point: {900, 400}}

      assert Calibration.derived_mini_game_region(andou) == {900, 384, 24, 474}
    end

    # Dois palpites de faixa já falharam no campo (a caixa de meia-tela e a
    # caixa por tiles, que leu tronco escuro + flores azuis como "barra +
    # cápsula"). O centro da TELA como âncora seria o terceiro.
    test "sem personagem MARCADO não há sugestão: nil, e o vigia fica cego" do
      sem_personagem = %Calibration{his_screen() | player_point: nil}

      assert Calibration.derived_mini_game_region(sem_personagem) == nil
      assert Calibration.mini_game_region(sem_personagem) == nil
    end
  end
end
