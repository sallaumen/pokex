defmodule Pokex.CalibrationMiniGameTest do
  @moduledoc """
  A região do mini-game: a MÃO manda (inversão de 2026-07-30).

  A faixa do layout parecia a autoridade certa: "fixed" na tela, provada
  estável quando os painéis do jogo se mexiam (perfil 2-moni-8skill). Mas a
  prova assumia que a JANELA do jogo nunca mudava de lugar — e ela mudou (a
  mesma raiz do minimapa calibrado em y=-132). Resultado no campo: a faixa
  apontando pro lugar errado E vetando silenciosamente a calibração manual
  do Lucas ("me mostra calibrado num ponto que não fui eu que calibrei").

  Agora o valor marcado à mão vence sempre; sem ele, a busca padrão é uma
  caixa CENTRAL (metade × metade, centrada na arena — o meio do jogo — ou na
  tela), não a faixa colada na battle list. O layout continua carregando a
  faixa medida (caracterizado abaixo), mas ela não participa mais da
  resolução.
  """
  use ExUnit.Case, async: false

  alias Pokex.{Calibration, Layout}
  alias Pokex.Perception.WorldState

  @measured {3067, 800, 28, 479}

  setup do
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

    # pretend the battle panel sits 173px higher (where it was in 2-moni-8skill)
    higher = put_in(profile, ["anchors", "battle_header", "measured_at"], [3184, 287])

    {:ok, now} = Layout.locate(frame, profile)
    {:ok, then_} = Layout.locate(frame, higher)

    # anchored regions follow the panel — the strip does not
    assert Layout.region(:battle_list, now) == Layout.region(:battle_list, then_)
    assert Layout.region(:mini_game, now) == @measured
    assert Layout.region(:mini_game, then_) == @measured
  end

  test "a marcação manual VENCE a faixa do layout", %{fix: fix} do
    hand_marked = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      # o valor que o Lucas marcou — antes da inversão, o layout o vetava
      mini_game_region: {2976, 555, 113, 773},
      layout: fix
    }

    assert Calibration.mini_game_region(hand_marked) == {2976, 555, 113, 773}
  end

  test "sem marcação manual, a busca padrão é a caixa CENTRAL — nunca a faixa do layout", %{
    fix: fix
  } do
    unmarked = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: fix}

    # metade × metade, centrada na tela (sem arena calibrada)
    assert Calibration.mini_game_region(unmarked) == {860, 360, 1720, 720}
  end

  test "a caixa central prefere o meio da ARENA (o meio do jogo) ao meio da tela" do
    arena_only = %Calibration{scale: 1.0, arena_region: {1000, 100, 2000, 1200}, layout: nil}
    assert Calibration.mini_game_region(arena_only) == {1500, 400, 1000, 600}

    whole_screen = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: nil}
    assert Calibration.mini_game_region(whole_screen) == {860, 360, 1720, 720}

    blind = %Calibration{scale: 1.0, mini_game_region: {1, 2, 3, 4}, layout: nil}
    assert Calibration.mini_game_region(blind) == {1, 2, 3, 4}

    assert Calibration.mini_game_region(%Calibration{scale: 1.0}) == nil
  end
end
