defmodule Pokex.Rig.Mac.Commands do
  @moduledoc "Pure builders for osascript/cliclick/screencapture invocations."

  @modifiers %{
    "shift" => "shift down",
    "ctrl" => "control down",
    "cmd" => "command down",
    "alt" => "option down"
  }

  # macOS virtual key codes for the TOP-ROW number keys (1..0). Skills are bound
  # to these; the numpad numbers are movement keys in the game, so pressing them
  # walks the character. `keystroke "1"` can land on the numpad, so send the
  # exact top-row key code instead.
  @digit_keycodes %{
    "1" => 18,
    "2" => 19,
    "3" => 20,
    "4" => 21,
    "5" => 23,
    "6" => 22,
    "7" => 26,
    "8" => 28,
    "9" => 25,
    "0" => 29
  }

  # macOS virtual key codes for NAMED keys. `keystroke "up"` would TYPE the
  # letters u-p into the game; movement/loot/function keys need the real key EVENT
  # (`keystroke "f1"` types the characters f-1, it does NOT press the F1 key).
  @named_keycodes %{
    "up" => 126,
    "down" => 125,
    "left" => 123,
    "right" => 124,
    "space" => 49,
    "f1" => 122,
    "f2" => 120,
    "f3" => 99,
    "f4" => 118,
    "f5" => 96,
    "f6" => 97,
    "f7" => 98,
    "f8" => 100,
    "f9" => 101,
    "f10" => 109,
    "f11" => 103,
    "f12" => 111
  }

  @doc """
  A real keystroke via System Events. Games listen for key EVENTS (a hotkey),
  not typed text. Digits go through `key code` (the top-row keys) so they're
  never mistaken for the numpad (which moves the character); other keys use
  `keystroke`. Modifiers are applied via `using {...}`.
  """
  def press(combo) do
    {mods, [key]} = combo |> String.split("+") |> Enum.split(-1)

    action =
      case Map.get(@digit_keycodes, key) || Map.get(@named_keycodes, String.downcase(key)) do
        nil -> ~s(keystroke "#{key}")
        code -> "key code #{code}"
      end

    {"osascript", ["-e", ~s(tell application "System Events" to #{action}#{using(mods)})]}
  end

  defp using([]), do: ""

  defp using(mods),
    do: " using {" <> Enum.map_join(mods, ", ", &Map.fetch!(@modifiers, &1)) <> "}"

  def click(:left, {x, y}), do: {"cliclick", ["c:#{x},#{y}"]}
  def click(:right, {x, y}), do: {"cliclick", ["rc:#{x},#{y}"]}

  # Move the pointer WITHOUT clicking (cliclick "m:"). Used to slide the cursor off
  # a just-clicked Battle row: the game paints a selected row PINK while hovered and
  # RED when not — and the lock reader only knows red, so the cursor must leave.
  def move({x, y}), do: {"cliclick", ["m:#{x},#{y}"]}

  def cursor_position, do: {"cliclick", ["p"]}

  # `-m` = capture ONLY the main display. MEASURED on Lucas's multi-monitor Mac (2026-07-09):
  # without it, `screencapture` syncs every display and takes ~1.7-2.9s PER call (even a 1×1
  # region), which — at 2 captures per fighting tick — made skills fire ~5s apart. With `-m` the
  # exact same region comes back in ~0.2-0.35s (byte-identical output). The game must be on the
  # main display anyway (see calibration), so this is pure speedup.
  def capture({x, y, w, h}, path),
    do: {"screencapture", ["-x", "-m", "-R", "#{x},#{y},#{w},#{h}", path]}

  def capture_screen(path), do: {"screencapture", ["-x", "-m", path]}

  def parse_point(output) do
    case Regex.run(~r/(\d+),(\d+)/, output) do
      [_, x, y] -> {:ok, {String.to_integer(x), String.to_integer(y)}}
      _ -> :error
    end
  end
end
