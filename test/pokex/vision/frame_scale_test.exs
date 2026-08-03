defmodule Pokex.Vision.FrameScaleTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Calibration
  alias Pokex.Vision.Frame

  # MEASURED 2026-08-03 on his Mac: the SAME 196×215-point minimap region came
  # back 196×215 from ScreenCaptureKit and 392×430 from `screencapture`, while
  # the saved calibration said scale 1.0. Every point↔pixel conversion that
  # trusted the file was then wrong by 2× — the bot read the top-left quarter
  # of everything, which is what "it all ended up further left" looks like.
  describe "with_scale/2" do
    test "a frame twice the region's width was captured at 2x" do
      frame = %Frame{width: 392, height: 430, rgba: <<>>}

      assert Frame.with_scale(frame, 196).scale == 2.0
    end

    test "a frame the size of its region was captured at 1x" do
      frame = %Frame{width: 196, height: 215, rgba: <<>>}

      assert Frame.with_scale(frame, 196).scale == 1.0
    end

    test "an unknown region leaves the stamp alone" do
      frame = %Frame{width: 392, height: 430, rgba: <<>>, scale: 2.0}

      assert Frame.with_scale(frame, nil).scale == 2.0
      assert Frame.with_scale(frame, 0).scale == 2.0
    end

    test "a fresh frame defaults to 1x rather than to nil" do
      assert %Frame{width: 10, height: 10, rgba: <<>>}.scale == 1.0
    end
  end

  describe "SpotScan aim" do
    defp solid(w, h, scale) do
      %Frame{
        width: w,
        height: h,
        rgba: :binary.copy(<<20, 20, 20, 255>>, w * h),
        scale: scale
      }
    end

    defp calib do
      %Calibration{scale: 1.0, screen_w: 1512, screen_h: 982, player_point: {700, 500}}
    end

    # The aim is a SCREEN point: with a 2× frame the winning window's pixel
    # coordinates are twice the points, and dividing by the file's stale 1.0
    # would put the ball at double the distance from the region's origin.
    test "a 2x frame aims at the same screen point a 1x frame does" do
      calib = calib()
      {:ok, {_x, _y, w, h} = region} = SpotScan.region(calib)

      one_x = fn _region, _name -> {:ok, solid(w, h, 1.0)} end
      two_x = fn _region, _name -> {:ok, solid(w * 2, h * 2, 2.0)} end

      obs_1x = SpotScan.scan(calib, one_x)
      obs_2x = SpotScan.scan(calib, two_x)

      assert obs_1x.scanning?
      assert obs_2x.scanning?
      assert obs_1x.region == region
      assert obs_2x.region == region
    end
  end
end
