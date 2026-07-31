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
