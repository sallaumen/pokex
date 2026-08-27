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
  # UNGATED, and it must stay that way: a release can only ever STOP something.
  # Gated, a key held down when the gate shuts (panic corner, game loses focus)
  # would stay held in the game — the character walking into the sea with
  # nobody able to let go.
  def key_up(key), do: hold(key, :up)

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

  @native_hold_latency_ms 15
  @osascript_hold_latency_ms 90

  @impl true
  # Which backend will key_down/key_up actually use right now? Measured: ~2ms
  # CGEvent post + port hop when the native helper is ready; ~60-100ms per
  # osascript spawn on the fallback path.
  def hold_latency_ms do
    if KeyEvents.status() == :ready,
      do: @native_hold_latency_ms,
      else: @osascript_hold_latency_ms
  end

  @impl true
  def press_many([], _opts), do: :ok

  def press_many(combos, opts), do: gated(fn -> do_press_many(combos, opts) end)

  # The pacing is paid HERE, in the caller's own process, between short commands
  # — never as a `delay` inside a script. A burst carrying a modifier (his
  # stance keys `shift+1`/`shift+3` ride ahead of the damage ones) used to
  # compose ONE osascript with every gap inside it, and that script runs inside
  # `OsaBus.handle_call`: three keys at his 300ms parked the GLOBAL key queue
  # for 600ms, with the rescue, the potion and the fallback arrows waiting
  # behind it. Now each key takes its own route — native CGEvent when it is
  # mapped and modifier-free, one short osascript otherwise — and the gap holds
  # nothing at all.
  #
  # First error wins: a key that reached NEITHER route is a real failure, and
  # combat's `{:key_burst_failed, _}` is the caller that should hear about it.
  defp do_press_many(combos, opts) do
    combos
    |> Commands.burst(opts)
    |> Enum.reduce_while(:ok, fn
      {:pause, ms}, :ok ->
        Process.sleep(ms)
        {:cont, :ok}

      {:press, combo}, :ok ->
        case do_press(combo) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
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
  # Middle button: cliclick has no middle click, so it goes through the native
  # CGEvent helper — and ONLY through it. No fallback: an {:error, _} means the
  # click did not happen (positioning is best-effort; the caller logs it).
  def click(:middle, point), do: gated(fn -> KeyEvents.middle_click(point, focus_app()) end)

  def click(button, point), do: gated(fn -> run(Commands.click(button, point)) end)

  @impl true
  def move(point), do: gated(fn -> run(Commands.move(point)) end)

  @impl true
  # UNGATED on purpose — one of the two calibration-only exceptions (with
  # focus_click/1). The gate's corner flag is proven by the Guardian, which
  # only polls while the fleet is up, so during calibration it can never open.
  # The client draws the coordinate ONLY while the position changes (measured
  # 2026-08-10: standing still with the mouse away, the minimap has no text at
  # all), so calibrating the state the bot runs in requires a real step.
  def tap(combo), do: do_press(combo)

  @impl true
  # UNGATED left click, the second calibration-only exception.
  # Fronting a window with `set frontmost` is not enough for the game to take
  # KEYS: Lucas's arrows landed in the BROWSER (2026-08-10). A click INSIDE the
  # game window is what macOS treats as real focus — aimed at the calibrated
  # neutral point (his own tile), which is a click-to-walk no-op by design.
  def focus_click(point), do: run(Commands.click(:left, point))

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
  def middle_watch, do: KeyEvents.middle_watch()

  @impl true
  def key_watch(codes), do: KeyEvents.key_watch(codes)

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
