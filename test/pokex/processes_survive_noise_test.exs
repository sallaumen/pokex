defmodule Pokex.ProcessesSurviveNoiseTest do
  @moduledoc """
  A STRAY MESSAGE MUST NEVER KILL A PROCESS.

  Every LiveView here is mounted through `HeaderState`, which subscribes the
  page to the worker topics and passes on whatever it does not recognise; every
  GenServer here can receive a late `:DOWN`, a timer that fired after its own
  cancel, or PubSub chatter from a topic a neighbour subscribed it to. A module
  with `handle_info/2` clauses and no final catch-all dies on all of it.

  It has bitten twice, in the same shape: on 2026-07-30 a fishing log took the
  calibration page down, and on 2026-09-07 `{:panic, "kill corner"}` — the
  message the panic corner broadcasts, which is exactly the moment nothing may
  break — took the diagnostics page down (`FunctionClauseError` in
  `handle_info/2`).

  Neither Credo nor Dialyzer can see this: `handle_info/2` receives `term()`,
  so an unmatched message is a runtime fact, not a type error. This test is the
  ratchet that stands in for them.
  """
  use ExUnit.Case, async: true

  @catch_all ~r/def handle_info\(\s*(_[a-zA-Z0-9_]*|_)\s*,/

  test "every LiveView that handles messages tolerates one it does not know" do
    assert unguarded(Path.wildcard("lib/pokex_web/live/**/*.ex")) == []
  end

  test "every GenServer that handles messages tolerates one it does not know" do
    assert unguarded(Path.wildcard("lib/pokex/**/*.ex")) == []
  end

  defp unguarded(files) do
    for path <- files,
        source = File.read!(path),
        String.contains?(source, "def handle_info("),
        not Regex.match?(@catch_all, source),
        do: path
  end
end
