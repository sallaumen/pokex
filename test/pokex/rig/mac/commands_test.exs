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

  test "press sends named keys (arrows/space) as key codes, not typed letters" do
    assert Commands.press("up") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 126)]}

    assert Commands.press("down") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 125)]}

    assert Commands.press("left") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 123)]}

    assert Commands.press("right") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 124)]}

    assert Commands.press("space") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 49)]}
  end

  test "named keys compose with modifiers like digits do" do
    assert Commands.press("shift+space") ==
             {"osascript",
              ["-e", ~s(tell application "System Events" to key code 49 using {shift down})]}
  end

  test "press_many batches top-row skill keys into one System Events script" do
    assert Commands.press_many(["1", "2", "shift+space"], tap_count: 1, gap_ms: 25) ==
             {"osascript",
              [
                "-e",
                Enum.join(
                  [
                    ~s(tell application "System Events"),
                    "  key code 18",
                    "  delay 0.025",
                    "  key code 19",
                    "  delay 0.025",
                    "  key code 49 using {shift down}",
                    "end tell"
                  ],
                  "\n"
                )
              ]}
  end

  test "press_many can repeat each skill tap inside the same script" do
    assert Commands.press_many(["1", "2"], tap_count: 2, gap_ms: 0) ==
             {"osascript",
              [
                "-e",
                Enum.join(
                  [
                    ~s(tell application "System Events"),
                    "  key code 18",
                    "  delay 0",
                    "  key code 18",
                    "  delay 0",
                    "  key code 19",
                    "  delay 0",
                    "  key code 19",
                    "end tell"
                  ],
                  "\n"
                )
              ]}
  end

  test "press_many can add random jitter to the delay between skills" do
    assert Commands.press_many(["1", "2"], tap_count: 1, gap_ms: 35, jitter_ms: 20) ==
             {"osascript",
              [
                "-e",
                Enum.join(
                  [
                    ~s(tell application "System Events"),
                    "  key code 18",
                    "  delay (0.035 + (random number from 0 to 0.020))",
                    "  key code 19",
                    "end tell"
                  ],
                  "\n"
                )
              ]}
  end

  test "tab is a key EVENT (code 48), never the typed letters t-a-b" do
    assert Commands.press("tab") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 48)]}
  end

  test "function keys send the real key code, not the typed letters (case-insensitive)" do
    # `keystroke "f1"` would TYPE f then 1 — F-keys need the key EVENT (F1 = 122).
    assert Commands.press("f1") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 122)]}

    assert Commands.press("F1") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 122)]}
  end

  test "focus_app prepends the re-front guard inside the SAME keystroke script" do
    {"osascript", ["-e", script]} = Commands.press("shift+v", focus_app: "wine")

    assert script ==
             Enum.join(
               [
                 ~s(tell application "System Events"),
                 "  try",
                 ~s(    if name of first application process whose frontmost is true is not "wine" then),
                 ~s(      set frontmost of application process "wine" to true),
                 "      delay 0.05",
                 "    end if",
                 "  end try",
                 ~s(  keystroke "v" using {shift down}),
                 "end tell"
               ],
               "\n"
             )
  end

  test "focus_app guards a press_many burst too, before the first key" do
    {"osascript", ["-e", script]} =
      Commands.press_many(["1", "2"], tap_count: 1, gap_ms: 0, focus_app: "wine")

    assert script =~ ~s(set frontmost of application process "wine" to true)
    # the guard comes BEFORE any key event
    assert :binary.match(script, "frontmost") < :binary.match(script, "key code 18")
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

  test "screen region capture (main display only, for speed)" do
    assert Commands.capture({10, 20, 30, 40}, "/tmp/x.png") ==
             {"screencapture", ["-x", "-m", "-R", "10,20,30,40", "/tmp/x.png"]}

    assert Commands.capture_screen("/tmp/s.png") == {"screencapture", ["-x", "-m", "/tmp/s.png"]}
  end
end
