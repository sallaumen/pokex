defmodule Pokex.Rig.Mac.Commands do
  @moduledoc "Pure builders for osascript/cliclick/screencapture invocations."

  @modifiers %{
    "shift" => "shift down",
    "ctrl" => "control down",
    "cmd" => "command down",
    "alt" => "option down"
  }

  @doc """
  A real keystroke via System Events. Games listen for key EVENTS (Shift+Z as a
  hotkey), not typed text — `cliclick t:z` typed the character and dropped the
  modifier, opening menus instead of equipping the rod.
  """
  def press(combo) do
    {mods, [key]} = combo |> String.split("+") |> Enum.split(-1)

    {"osascript",
     ["-e", ~s(tell application "System Events" to keystroke "#{key}"#{using(mods)})]}
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
