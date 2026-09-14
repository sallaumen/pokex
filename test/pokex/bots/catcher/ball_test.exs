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

  # A MIRA DESCE PRO CORPO — e sem isto a bola errava mais do que acertava.
  #
  # Cada ponto que o bot tem de um bicho nasce da BARRA de vida, que flutua acima
  # da cabeça — e `CrowdScan.place/4` soma UM TILE a ela antes de publicar. No
  # ultrawide dele a barra flutua 69 px, não 151: o tile a mais joga o ponto 82
  # px ABAIXO do bicho, e a bola caía no chão entre duas fileiras. Medido no
  # quadro de 14/09 contra o único ponto marcado à mão, o personagem dele.
  describe "the aim leaves the published point and lands on the body" do
    @tag :tmp_dir
    test "on the measured ultrawide the cursor climbs the tile the eye added",
         %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(&Pokex.TestHome.restore/0)
      Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440})

      assert [{:move_checked, {1418, 686}} | _] = Ball.sequence({1418, 768})
    end

    @tag :tmp_dir
    test "and the click lands on the SAME point as the cursor", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(&Pokex.TestHome.restore/0)
      Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440})
      Pokex.Settings.put(:ball_needs_click, true)

      actions = Ball.sequence({1418, 768})

      assert {:move_checked, {1418, 686}} = List.first(actions)
      assert {:click, :left, {1418, 686}} in actions
    end

    # Palpite aqui erraria a bola de um jeito NOVO. O que não foi medido não
    # entra: numa tela desconhecida a mira continua onde sempre esteve.
    @tag :tmp_dir
    test "on a screen nobody measured the point goes through untouched", %{tmp_dir: tmp} do
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
