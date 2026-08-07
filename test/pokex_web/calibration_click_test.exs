defmodule PokexWeb.CalibrationClickTest do
  use ExUnit.Case, async: true

  alias PokexWeb.CalibrationClick

  # THE CRASH OF 2026-08-07, verbatim from the terminating LiveView's log:
  # the browser sends INTEGERS whenever a click lands on an exact pixel, and
  # `Float.round(166, 1)` has no clause for that. The page died on the FIRST
  # click of the wizard — calibration was broken since the trace shipped, and
  # its test never caught it because it only ever sent floats.
  @crash_payload %{
    "x" => 166,
    "y" => 433,
    "cw" => 750,
    "ch" => 487.1015625,
    "nw" => 1512,
    "nh" => 982
  }

  test "the exact integer payload that killed the page converts cleanly" do
    assert {:ok, point, trace} = CalibrationClick.read(@crash_payload, 1.0, false)

    # 166/750 of a 1512-wide screenshot; 433/487.1 of a 982-tall one
    assert point == {335, 873}
    assert trace.raw == {166.0, 433.0}
    assert trace.box == {750.0, 487.1}
    assert trace.natural == {1512, 982}
    refute trace.recorded?
  end

  test "float payloads (the shape the old test used) still convert the same" do
    params = %{"x" => 25.0, "y" => 15.0, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}

    assert {:ok, {100, 60}, trace} = CalibrationClick.read(params, 1.0, true)
    assert trace.zoomed?
    assert trace.recorded?
  end

  test "retina scale divides the pixel point into screen points" do
    params = %{"x" => 25, "y" => 15, "cw" => 50, "ch" => 37.5, "nw" => 200, "nh" => 150}

    assert {:ok, {50, 30}, _trace} = CalibrationClick.read(params, 2.0, true)
  end

  # An <img> that has not finished loading reports 0×0: dividing would crash,
  # and a point computed from it would be garbage saved into the calibration.
  test "a zero-sized box is an error, never a crash and never a point" do
    for broken <- [%{"cw" => 0}, %{"ch" => 0}, %{"nw" => 0}, %{"nh" => 0}] do
      params = Map.merge(@crash_payload, broken)
      assert CalibrationClick.read(params, 1.0, false) == {:error, :empty_box}
    end
  end
end
