defmodule Pokex.CalibrationScreenCheckTest do
  @moduledoc """
  A saved calibration belongs to the screen it was marked on. Telling "another
  screen" apart from "the same screen measured with a bad ruler" is what decides
  between a full recalibration and a one-click repair.
  """
  use ExUnit.Case, async: true

  alias Pokex.Calibration

  defp saved(w, h, extra \\ %{}) do
    struct!(
      %Calibration{
        scale: 1.0,
        screen_w: w,
        screen_h: h,
        player_point: {1700, 690},
        water_point: {1199, 736},
        glow_region: {1167, 704, 64, 64},
        battle_region: {3173, 317, 253, 335}
      },
      extra
    )
  end

  test "the same screen is silent" do
    assert Calibration.screen_check(saved(3440, 1440), {:ok, {3440, 1440}}) == :same
  end

  test "an unmeasurable display never accuses" do
    assert Calibration.screen_check(saved(3440, 1440), :unknown) == :unknown
  end

  test "a calibration with no screen recorded cannot be judged" do
    assert Calibration.screen_check(saved(nil, nil), {:ok, {3440, 1440}}) == :unknown
  end

  test "a different shape of screen is another screen — recalibrate" do
    assert Calibration.screen_check(saved(3440, 1440), {:ok, {1512, 982}}) ==
             {:another_screen, {3440, 1440}, {1512, 982}}
  end

  # 2026-08-04, two monitors: the wizard divided a 3440×1440 screenshot by the
  # window server's union of both displays and wrote 4952×2073 — the same
  # picture, the same shape, a ruler 1.44× too long.
  test "the same shape at a different size is a pure scale error — repairable" do
    assert Calibration.screen_check(saved(4952, 2073), {:ok, {3440, 1440}}) ==
             {:rescalable, {4952, 2073}, {3440, 1440}}
  end

  test "rescaling puts every point and region back where he clicked" do
    repaired = Calibration.rescale(saved(4952, 2073, %{scale: 0.6946688206785138}), {3440, 1440})

    assert {repaired.screen_w, repaired.screen_h} == {3440, 1440}
    assert_in_delta repaired.scale, 1.0, 0.001
    assert repaired.player_point == {1181, 479}
    assert repaired.glow_region == {811, 489, 44, 44}
  end

  test "rescaling leaves unmarked fields alone and keeps the skill colours" do
    refs = [[10, 20, 30], nil]

    repaired =
      Calibration.rescale(
        saved(4952, 2073, %{water_point: nil, skill_slot_refs: refs, skill_bar_count: 9}),
        {3440, 1440}
      )

    assert repaired.water_point == nil
    assert repaired.skill_slot_refs == refs
    assert repaired.skill_bar_count == 9
  end

  test "a round trip through the same size changes nothing" do
    calib = saved(3440, 1440)

    assert Calibration.rescale(calib, {3440, 1440}) == calib
  end
end
