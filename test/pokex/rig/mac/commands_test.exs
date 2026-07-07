defmodule Pokex.Rig.Mac.CommandsTest do
  use ExUnit.Case, async: true
  alias Pokex.Rig.Mac.Commands

  test "press sends a letter as a keystroke with the modifier" do
    assert Commands.press("shift+z") ==
             {"osascript",
              ["-e", ~s(tell application "System Events" to keystroke "z" using {shift down})]}
  end

  test "press sends a digit as the TOP-ROW key code (not the numpad, which walks)" do
    assert Commands.press("2") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 19)]}
  end

  test "press keeps digits on the top row even with a modifier" do
    assert Commands.press("ctrl+1") ==
             {"osascript",
              ["-e", ~s(tell application "System Events" to key code 18 using {control down})]}
  end

  test "left and right click" do
    assert Commands.click(:left, {812, 402}) == {"cliclick", ["c:812,402"]}
    assert Commands.click(:right, {10, 20}) == {"cliclick", ["rc:10,20"]}
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
