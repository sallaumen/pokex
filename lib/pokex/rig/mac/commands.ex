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

  @doc """
  A real keystroke via System Events. Games listen for key EVENTS (a hotkey),
  not typed text. Digits go through `key code` (the top-row keys) so they're
  never mistaken for the numpad (which moves the character); other keys use
  `keystroke`. Modifiers are applied via `using {...}`.
  """
  def press(combo) do
    {mods, [key]} = combo |> String.split("+") |> Enum.split(-1)

    action =
      case Map.get(@digit_keycodes, key) do
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

  def cursor_position, do: {"cliclick", ["p"]}

  def capture({x, y, w, h}, path),
    do: {"screencapture", ["-x", "-R", "#{x},#{y},#{w},#{h}", path]}

  def capture_screen(path), do: {"screencapture", ["-x", path]}

  def parse_point(output) do
    case Regex.run(~r/(\d+),(\d+)/, output) do
      [_, x, y] -> {:ok, {String.to_integer(x), String.to_integer(y)}}
      _ -> :error
    end
  end
end
