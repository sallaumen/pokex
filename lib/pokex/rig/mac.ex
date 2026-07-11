defmodule Pokex.Rig.Mac do
  @moduledoc "Real Rig: shells out to cliclick and screencapture."
  @behaviour Pokex.Rig

  require Logger

  alias Pokex.Bots.{InputGate, Perf}
  alias Pokex.Rig.Mac.{Commands, KeyEvents, OsaBus}

  @impl true
  def press(combo), do: gated(fn -> do_press(combo) end)

  # Native CGEvent press first (~2ms, serialized inside KeyEvents, same focus guard) for
  # modifier-free mapped keys — the hot paths: combat digits, Tab, Space, potion. Fallback:
  # osascript through the OsaBus (see its moduledoc — System Events is one queue; concurrent
  # key scripts pile up and desync keys from the mouse moves they belong with).
  defp do_press(combo) do
    with false <- String.contains?(combo, "+"),
         {:ok, code} <- Commands.keycode(combo),
         :ok <- KeyEvents.key(:press, code, focus_app()) do
      :ok
    else
      _fallback -> run_key(Commands.press(combo, focus_app: focus_app()))
    end
  end

  @impl true
  def key_down(key), do: gated(fn -> hold(key, :down) end)

  @impl true
  def key_up(key), do: gated(fn -> hold(key, :up) end)

  # Native CGEvent helper first (~1-2ms per event; it carries the same focus
  # guard); osascript is the always-works fallback while the helper is
  # missing, untrusted or restarting.
  defp hold(key, action) do
    with {:ok, code} <- Commands.keycode(key),
         :ok <- KeyEvents.key(action, code, focus_app()) do
      :ok
    else
      _fallback -> run_key(Commands.hold(key, action, focus_app: focus_app()))
    end
  end

  @impl true
  def press_many([], _opts), do: :ok

  def press_many(combos, opts), do: gated(fn -> do_press_many(combos, opts) end)

  # All-native bursts compose the taps/gaps in Elixir (each key event ~2ms through the
  # serialized helper; the pacing sleeps happen HERE in the caller's task, holding nothing).
  # Any unmappable combo (a modifier like shift+v, an unmapped letter) or an unready helper
  # falls back to the single composed osascript, serialized by the OsaBus.
  defp do_press_many(combos, opts) do
    if Enum.all?(combos, &native_pressable?/1) and KeyEvents.status() == :ready do
      native_burst(combos, opts)
    else
      run_key(Commands.press_many(combos, Keyword.put(opts, :focus_app, focus_app())))
    end
  end

  defp native_pressable?(combo),
    do: not String.contains?(combo, "+") and match?({:ok, _}, Commands.keycode(combo))

  defp native_burst(combos, opts) do
    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)
    gap_ms = opts |> Keyword.get(:gap_ms, 0) |> max(0)
    jitter_ms = opts |> Keyword.get(:jitter_ms, 0) |> max(0)
    taps = Enum.flat_map(combos, fn combo -> List.duplicate(combo, tap_count) end)
    last = length(taps) - 1

    taps
    |> Enum.with_index()
    |> Enum.each(fn {combo, idx} ->
      {:ok, code} = Commands.keycode(combo)
      # per-key best effort: a mid-burst helper hiccup sends THAT key via the bus instead of
      # double-pressing the whole burst through the fallback
      case KeyEvents.key(:press, code, focus_app()) do
        :ok -> :ok
        _ -> run_key(Commands.press(combo, focus_app: focus_app()))
      end

      if idx < last do
        jitter = if jitter_ms > 0, do: :rand.uniform(jitter_ms + 1) - 1, else: 0
        Process.sleep(gap_ms + jitter)
      end
    end)

    :ok
  end

  defp run_key(cmd) do
    case OsaBus.run(cmd) do
      {:ok, _out} -> :ok
      {:error, _reason} = error -> error
    end
  end

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
  def click(button, point), do: gated(fn -> run(Commands.click(button, point)) end)

  @impl true
  def move(point), do: gated(fn -> run(Commands.move(point)) end)

  @impl true
  # Move the cursor onto the target, then press F1 — the in-game pokeball hotkey throws at the
  # CURSOR position, so no click is needed (Lucas rebound it this way). Order matters: position
  # first, then throw.
  def capture_sequence(point) do
    with :ok <- move(point) do
      press("f1")
    end
  end

  # The hard safety floor: no ACTUATION (key/click/move) leaves this process while the InputGate
  # is closed — the cursor is in the panic corner OR the game window isn't frontmost. Suppressed
  # calls return :ok (a no-op, not an error) so a worker never mistakes "held for safety" for a
  # real I/O failure. SENSING (capture/cursor) is never gated: we must keep reading the screen to
  # know when it's safe to act again.
  defp gated(fun) do
    if InputGate.allowed?(), do: fun.(), else: :ok
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
