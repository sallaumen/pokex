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
    "f12" => 111,
    # `keystroke "tab"` would TYPE t-a-b; target cycling needs the real Tab key EVENT.
    "tab" => 48
  }

  # Keys the mini-game holds. `key down`/`key up` only accept the CHARACTER form
  # ("key down \" \"") — a nested `key code` executes as a full press first
  # (measured live 2026-07-10) — so named keys must map to their character here.
  @hold_chars %{"space" => " "}

  @doc """
  A real keystroke via System Events. Games listen for key EVENTS (a hotkey),
  not typed text. Digits go through `key code` (the top-row keys) so they're
  never mistaken for the numpad (which moves the character); other keys use
  `keystroke`. Modifiers are applied via `using {...}`.
  """
  def press(combo, opts \\ []) do
    build_key_script(["  #{key_action(combo)}"], opts)
  end

  @doc """
  Hold or release a key — a real `key down` / `key up` event pair split across
  two calls, for keys the game expects HELD (the mini-game raises its bar while
  Space stays down). Plain single characters pass through; named keys need a
  mapping in @hold_chars.
  """
  def hold(key, direction, opts \\ []) when direction in [:down, :up] do
    build_key_script([~s(  key #{direction} "#{hold_char(key)}")], opts)
  end

  defp hold_char(key) do
    case Map.get(@hold_chars, String.downcase(key)) do
      nil when byte_size(key) == 1 -> key
      nil -> raise ArgumentError, "no hold-character mapping for #{inspect(key)}"
      char -> char
    end
  end

  def press_many(combos, opts \\ []) do
    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)
    gap_ms = opts |> Keyword.get(:gap_ms, 0) |> max(0)
    jitter_ms = opts |> Keyword.get(:jitter_ms, 0) |> max(0)

    actions =
      combos
      |> Enum.flat_map(fn combo -> List.duplicate(combo, tap_count) end)
      |> Enum.map(&key_action/1)

    lines =
      actions
      |> Enum.with_index()
      |> Enum.flat_map(fn {action, idx} ->
        if idx == length(actions) - 1 do
          ["  #{action}"]
        else
          ["  #{action}", "  delay #{delay_expr(gap_ms, jitter_ms)}"]
        end
      end)

    build_key_script(lines, opts)
  end

  # A single guardless action keeps the battle-tested one-liner form; anything more (multiple
  # actions and/or the focus guard) becomes a tell-block script.
  defp build_key_script([action], opts) do
    case Keyword.get(opts, :focus_app) do
      nil ->
        {"osascript", ["-e", ~s(tell application "System Events" to #{String.trim(action)})]}

      app ->
        block(focus_guard(app) ++ [action])
    end
  end

  defp build_key_script(action_lines, opts) do
    block(focus_guard(Keyword.get(opts, :focus_app)) ++ action_lines)
  end

  defp block(lines) do
    {"osascript",
     ["-e", Enum.join(["tell application \"System Events\"" | lines] ++ ["end tell"], "\n")]}
  end

  # System Events keystrokes land in the FRONTMOST app — if the user is on the panel (browser)
  # while a bot presses, the key types into Chrome and the game never sees it. (The old
  # click-targeting combat masked this: every select-click re-focused the game by accident;
  # keyboard-only Tab combat removed the mask.) This guard runs INSIDE the same osascript (no
  # extra process): re-front the game before the keys whenever something else is focused. The
  # `try` swallows a missing game process, so the keys still fire with the old behavior instead
  # of erroring the whole press.
  defp focus_guard(nil), do: []

  defp focus_guard(app_name) do
    [
      "  try",
      ~s(    if name of first application process whose frontmost is true is not "#{app_name}" then),
      ~s(      set frontmost of application process "#{app_name}" to true),
      "      delay 0.05",
      "    end if",
      "  end try"
    ]
  end

  defp key_action(combo) do
    {mods, [key]} = combo |> String.split("+") |> Enum.split(-1)

    action =
      case Map.get(@digit_keycodes, key) || Map.get(@named_keycodes, String.downcase(key)) do
        nil -> ~s(keystroke "#{key}")
        code -> "key code #{code}"
      end

    action <> using(mods)
  end

  defp using([]), do: ""

  defp using(mods),
    do: " using {" <> Enum.map_join(mods, ", ", &Map.fetch!(@modifiers, &1)) <> "}"

  defp format_delay(seconds) do
    if seconds == trunc(seconds),
      do: Integer.to_string(trunc(seconds)),
      else: :erlang.float_to_binary(seconds, decimals: 3)
  end

  defp delay_expr(gap_ms, 0), do: format_delay(gap_ms / 1000)
  defp delay_expr(0, jitter_ms), do: "(random number from 0 to #{format_delay(jitter_ms / 1000)})"

  defp delay_expr(gap_ms, jitter_ms),
    do:
      "(#{format_delay(gap_ms / 1000)} + (random number from 0 to #{format_delay(jitter_ms / 1000)}))"

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
