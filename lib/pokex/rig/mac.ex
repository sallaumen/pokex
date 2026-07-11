defmodule Pokex.Rig.Mac do
  @moduledoc "Real Rig: shells out to cliclick and screencapture."
  @behaviour Pokex.Rig

  require Logger

  alias Pokex.Bots.Perf
  alias Pokex.Rig.Mac.Commands

  @impl true
  def press(combo), do: run(Commands.press(combo, focus_app: focus_app()))

  @impl true
  def key_down(key), do: run(Commands.hold(key, :down, focus_app: focus_app()))

  @impl true
  def key_up(key), do: run(Commands.hold(key, :up, focus_app: focus_app()))

  @impl true
  def press_many([], _opts), do: :ok

  def press_many(combos, opts),
    do: run(Commands.press_many(combos, Keyword.put(opts, :focus_app, focus_app())))

  # Keystrokes only reach the game while it is FRONTMOST; the guard re-fronts it inside the
  # keystroke script when the user is off on the panel/browser. Settings-driven so it can be
  # turned off (ensure_game_focus) or renamed if the game ever leaves Wine (game_app_name).
  # Fail-open: if Settings isn't up (early boot), skip the guard rather than block the press.
  defp focus_app do
    if Pokex.Settings.get(:ensure_game_focus), do: Pokex.Settings.get(:game_app_name)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def click(button, point), do: run(Commands.click(button, point))

  @impl true
  def move(point), do: run(Commands.move(point))

  @impl true
  # Move the cursor onto the target, then press F1 — the in-game pokeball hotkey throws at the
  # CURSOR position, so no click is needed (Lucas rebound it this way). Order matters: position
  # first, then throw.
  def capture_sequence(point) do
    with :ok <- move(point) do
      press("f1")
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
    # Namespace the capture file by the CALLING process, so two workers reading the SAME
    # region (e.g. the skill bar: fishing's cooldown gate AND combat's ready-skills, plus the
    # panel's live cooldown poll) never write the same path concurrently. A shared path let one
    # screencapture truncate/overwrite the file another was decoding → a corrupt/partial frame
    # → a wrong reading (e.g. a ready skill misread as cooldown, so the gate never releases the
    # fish). Each process reuses its own file, so nothing accumulates.
    path = Path.join(Pokex.Home.captures_dir(), per_process(filename))

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

  # "skillbar.png" → "skillbar-<caller-hash>.png": a per-process filename so concurrent readers
  # of the same region don't clobber each other's capture file.
  defp per_process(filename) do
    ext = Path.extname(filename)
    base = Path.basename(filename, ext)
    "#{base}-#{:erlang.phash2(self())}#{ext}"
  end

  defp run(cmd) do
    case run_capture_output(cmd) do
      {:ok, _out} -> :ok
      err -> err
    end
  end

  defp run_capture_output({exe, args}) do
    if Application.get_env(:pokex, :rig_debug, false) do
      Logger.debug("rig: #{exe} #{Enum.join(args, " ")}")
    end

    started_at = System.monotonic_time(:millisecond)

    result =
      case System.cmd(exe, args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, code} -> {:error, {exe, code, String.trim(out)}}
      end

    Perf.record(
      "rig.cmd:#{command_label(exe, args)}",
      System.monotonic_time(:millisecond) - started_at
    )

    result
  rescue
    e in ErlangError -> {:error, {:executable_not_found, exe, e.original}}
  end

  defp command_label("cliclick", ["p"]), do: "cursor"
  defp command_label("cliclick", ["m:" <> _]), do: "move"
  defp command_label("cliclick", ["c:" <> _]), do: "click_left"
  defp command_label("cliclick", ["rc:" <> _]), do: "click_right"
  defp command_label("screencapture", _args), do: "screencapture"
  defp command_label("osascript", _args), do: "osascript"
  defp command_label(exe, _args), do: exe
end
