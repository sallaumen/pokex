defmodule Pokex.Rig.Mac.CommandsTest do
  use ExUnit.Case, async: true
  alias Pokex.Rig.Mac.Commands

  test "press with shift modifier" do
    assert Commands.press("shift+z") == {"cliclick", ["kd:shift", "t:z", "ku:shift"]}
  end

  test "press plain key" do
    assert Commands.press("2") == {"cliclick", ["t:2"]}
  end

  test "left and right click" do
    assert Commands.click(:left, {812, 402}) == {"cliclick", ["c:812,402"]}
    assert Commands.click(:right, {10, 20}) == {"cliclick", ["rc:10,20"]}
  end

  test "capture sequence holds shift, presses 1, clicks" do
    assert Commands.capture_sequence({100, 200}) ==
             {"cliclick", ["kd:shift", "t:1", "c:100,200", "ku:shift"]}
  end

  test "cursor position command and parsing" do
    assert Commands.cursor_position() == {"cliclick", ["p"]}
    assert Commands.parse_point("428,259\n") == {:ok, {428, 259}}
    assert Commands.parse_point("Point: 428,259") == {:ok, {428, 259}}
    assert Commands.parse_point("garbage") == :error
  end

  test "screen region capture" do
    assert Commands.capture({10, 20, 30, 40}, "/tmp/x.png") ==
             {"screencapture", ["-x", "-R", "10,20,30,40", "/tmp/x.png"]}

    assert Commands.capture_screen("/tmp/s.png") == {"screencapture", ["-x", "/tmp/s.png"]}
  end
end
