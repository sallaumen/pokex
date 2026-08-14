defmodule Pokex.PreflightTest do
  use ExUnit.Case, async: false
  alias Pokex.{Calibration, Preflight}

  @tag :tmp_dir
  test "fails without calibration, passes with it (non-mac rig skips OS checks)", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

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

  # THE REFUSAL THAT STOPPED EVERYTHING (2026-08-07). His calibration was saved
  # by ScreenCaptureKit, which answers in POINTS: 1512×982 with scale 1.0. The
  # old check captured with the CLI, which answers in PIXELS (3024×1964), and
  # compared it to `screen_w * scale` = 1512. It never matched, so `start_all`
  # refused every time and nothing ever ran.
  describe "screen_error/2" do
    @sck_calibration %Calibration{scale: 1.0, screen_w: 1512, screen_h: 982}

    test "the screen it was marked on does NOT refuse" do
      assert Preflight.screen_error(@sck_calibration, {:ok, {1512, 982}}) == []
    end

    test "a screen that cannot be measured is NO PROOF, never a refusal" do
      assert Preflight.screen_error(@sck_calibration, :unknown) == []
    end

    test "a genuinely different screen refuses, naming both and where to fix it" do
      assert [msg] = Preflight.screen_error(@sck_calibration, {:ok, {3440, 1440}})
      assert msg =~ "1512×982"
      assert msg =~ "3440×1440"
      assert msg =~ "/calibration"
    end
  end
end
