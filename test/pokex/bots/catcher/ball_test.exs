defmodule Pokex.Bots.Catcher.BallTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Ball
  alias Pokex.Calibration
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash_keys!([
      :ball_key,
      :ball_needs_click,
      :capture_aim_settle_ms,
      :capture_hold_ms
    ])

    :ok
  end

  # The old version pressed the key at the same instant as the move; the rod (same shape)
  # waits 30ms and works.
  test "moves, waits for the settle, and only then presses the shortcut" do
    assert [
             {:move_checked, {500, 400}},
             {:wait, 30},
             {:press, "f1"},
             {:wait, _hold}
           ] = Ball.sequence({500, 400})
  end

  test "the ball key is configurable" do
    Pokex.Settings.put(:ball_key, "f3")

    assert [_move, _wait, {:press, "f3"} | _] = Ball.sequence({1, 2})
    assert Ball.key() == "f3"
  end

  test "ball_needs_click covers both game behaviors: direct shortcut vs aim awaiting a click" do
    Pokex.Settings.put(:ball_needs_click, true)

    actions = Ball.sequence({300, 200})

    assert {:click, :left, {300, 200}} in actions
    key_position = Enum.find_index(actions, &match?({:press, _}, &1))
    click_position = Enum.find_index(actions, &match?({:click, _, _}, &1))
    assert click_position > key_position
  end

  test "holds the cursor on the target before the Body takes it back" do
    Pokex.Settings.put(:capture_hold_ms, 250)

    assert List.last(Ball.sequence({1, 1})) == {:wait, 250}
  end

  # A MIRA NAO DESCE, E ISSO E UM RESULTADO. Duas correcoes foram tentadas e as
  # duas PIORARAM a captura: taxa de captura por bola no diario dele foi 36 %
  # com o ponto publicado cru (1098 bolas), 24 % com o `+70` do #657 (337) e
  # 5 % com o `-110` do #664 (111). A bola nao e jogada num bicho DE PE — e
  # jogada num CORPO deitado na tile, e as duas medicoes de quadro mediram o
  # sprite errado. Ver `Pokex.Screen.BarOffset`.
  describe "the aim goes to the point the eye published" do
    @tag :tmp_dir
    test "on his ultrawide, untouched", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(&Pokex.TestHome.restore/0)
      Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440})

      assert [{:move_checked, {1418, 768}} | _] = Ball.sequence({1418, 768})
    end

    @tag :tmp_dir
    test "and the click lands on the SAME point as the cursor", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(&Pokex.TestHome.restore/0)
      Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440})
      Pokex.Settings.put(:ball_needs_click, true)

      actions = Ball.sequence({1418, 768})

      assert {:move_checked, {1418, 768}} = List.first(actions)
      assert {:click, :left, {1418, 768}} in actions
    end

    @tag :tmp_dir
    test "on any other screen, untouched too", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(&Pokex.TestHome.restore/0)
      Calibration.save(%Calibration{scale: 1.0, screen_w: 1234, screen_h: 567})

      assert [{:move_checked, {1418, 768}} | _] = Ball.sequence({1418, 768})
    end
  end

  test "the settle wait is adjustable" do
    Pokex.Settings.put(:capture_aim_settle_ms, 120)

    assert [_move, {:wait, 120} | _] = Ball.sequence({1, 1})
  end
end
