# On CI (2-core runner) the vision tests chewing the real-capture fixtures take
# 3-6x the local Apple Silicon time — three modules already blew the 60s default
# there, one per round. The slack applies only on CI: locally, a test past 60s
# is still a hang to investigate, not a slow test to tolerate.
timeout = if System.get_env("CI"), do: 300_000, else: 60_000
ExUnit.start(timeout: timeout)

# The InputGate is FAIL-CLOSED: it starts blocked and the pollers open it
# (Guardian every 100ms, Focus every ~250ms) — deliberately disabled in the
# suite (:focus_auto_monitor etc.). Opening it here, once, simulates the steady
# state production reaches in ~250ms. Tests that need the gate closed write
# false and restore it in on_exit — the pattern the files already follow.
Pokex.Bots.InputGate.set_corner_ok(true)
Pokex.Bots.InputGate.set_focus_ok(true)

# A log line that reaches the console is a log NOBODY claimed. The tests that
# provoke one on purpose say so with `@tag :capture_log`, and ExUnit takes the
# :default handler off while that tag is in force — so a captured log never
# reaches this filter, and an escaped one always does. Counting there and
# failing the suite is what keeps the output at "só o resultado" without
# lowering a single log level: nothing is hidden, escaping is just fatal now.
#
# Before this, 57 lines per run belonged to 36 tests and nobody could say which
# — the reason the real ones went unread for so long (measured 2026-08-14).
escaped_logs = :counters.new(1, [:atomics])

:logger.add_handler_filter(
  :default,
  :pokex_escaped_log,
  {fn event, _args ->
     :counters.add(escaped_logs, 1, 1)
     event
   end, nil}
)

ExUnit.after_suite(fn _results ->
  case :counters.get(escaped_logs, 1) do
    0 ->
      :ok

    n ->
      IO.puts(
        :stderr,
        "\nERRO: #{n} linha(s) de log escaparam da captura e foram impressas.\n" <>
          "Um teste que provoca log de propósito leva `@tag :capture_log`.\n" <>
          "Um log que ninguém esperava é um achado — leia antes de calar."
      )

      System.halt(1)
  end
end)
