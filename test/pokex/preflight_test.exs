defmodule Pokex.PreflightTest do
  use ExUnit.Case, async: false
  alias Pokex.{Calibration, Preflight}

  @tag :tmp_dir
  test "fails without calibration, passes with it (non-mac rig skips OS checks)", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    assert {:error, [msg]} = Preflight.run(Pokex.Rig.Fake)
    assert msg =~ "calibração"

    calib = %Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {0, 0, 8, 8},
      neutral_point: {1, 1}
    }

    Calibration.save(calib)
    assert Preflight.run(Pokex.Rig.Fake) == :ok
  end
end
