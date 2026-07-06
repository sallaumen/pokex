defmodule Pokex.Rig.Mac do
  @moduledoc "Real Rig: shells out to cliclick and screencapture."
  @behaviour Pokex.Rig

  require Logger

  alias Pokex.Rig.Mac.Commands

  @impl true
  def press(combo), do: run(Commands.press(combo))

  @impl true
  def click(button, point), do: run(Commands.click(button, point))

  @impl true
  # Arm the base pokeball (Shift+1) as a real hotkey, then click the target.
  def capture_sequence(point) do
    with :ok <- press("shift+1") do
      click(:left, point)
    end
  end

  @impl true
  def cursor_position do
    with {:ok, out} <- run_capture_output(Commands.cursor_position()),
         {:ok, point} <- Commands.parse_point(out) do
      {:ok, point}
    else
      :error -> {:error, :unparseable_cursor}
      err -> err
    end
  end

  @impl true
  def capture(region, filename) do
    path = Path.join(Pokex.Home.captures_dir(), filename)

    case run(Commands.capture(region, path)) do
      :ok -> {:ok, path}
      err -> err
    end
  end

  @impl true
  def capture_screen do
    path = Path.join(Pokex.Home.captures_dir(), "screen.png")

    case run(Commands.capture_screen(path)) do
      :ok -> {:ok, path}
      err -> err
    end
  end

  defp run(cmd) do
    case run_capture_output(cmd) do
      {:ok, _out} -> :ok
      err -> err
    end
  end

  defp run_capture_output({exe, args}) do
    Logger.debug("rig: #{exe} #{Enum.join(args, " ")}")

    case System.cmd(exe, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {exe, code, String.trim(out)}}
    end
  rescue
    e in ErlangError -> {:error, {:executable_not_found, exe, e.original}}
  end
end
