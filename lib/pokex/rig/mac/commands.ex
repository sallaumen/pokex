defmodule Pokex.Rig.Mac.Commands do
  @moduledoc "Pure builders for cliclick/screencapture invocations."

  def press("shift+" <> key), do: {"cliclick", ["kd:shift", "t:#{key}", "ku:shift"]}
  def press(key), do: {"cliclick", ["t:#{key}"]}

  def click(:left, {x, y}), do: {"cliclick", ["c:#{x},#{y}"]}
  def click(:right, {x, y}), do: {"cliclick", ["rc:#{x},#{y}"]}

  def capture_sequence({x, y}), do: {"cliclick", ["kd:shift", "t:1", "c:#{x},#{y}", "ku:shift"]}

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
