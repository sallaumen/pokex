# On CI (2-core runner) the vision tests chewing the real-capture fixtures take
# 3-6x the local Apple Silicon time — three modules already blew the 60s default
# there, one per round. The slack applies only on CI: locally, a test past 60s
# is still a hang to investigate, not a slow test to tolerate.
timeout = if System.get_env("CI"), do: 300_000, else: 60_000
ExUnit.start(timeout: timeout)

# Read before any test can erase it: this is the home the suite may touch.
Pokex.TestHome.remember()

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
#
# Counting them was not enough: on 2026-08-14 CI went red saying "1 linha
# escapou" and the line itself was 200 lines up the log, with nothing tying the
# two together. A red run has to point at ONE thing, so the escapee is recorded
# here with who emitted it — the whole reason the filter is at this layer.
describe_escaped = fn event ->
  try do
    text =
      case event.msg do
        {:string, chars} ->
          IO.iodata_to_binary(chars)

        {format, args} when is_list(args) ->
          format |> :io_lib.format(args) |> IO.iodata_to_binary()

        other ->
          inspect(other)
      end

    where =
      case event.meta do
        %{mfa: {m, f, a}} -> "  <- #{inspect(m)}.#{f}/#{a}"
        _ -> ""
      end

    String.slice(text, 0, 180) <> where
  rescue
    _ -> "<linha de log que nem formatar deu>"
  end
end

:ets.new(:pokex_escaped_logs, [:public, :named_table, :duplicate_bag])

:logger.add_handler_filter(
  :default,
  :pokex_escaped_log,
  {fn event, _args ->
     :ets.insert(:pokex_escaped_logs, {:escaped, describe_escaped.(event)})
     event
   end, nil}
)

ExUnit.after_suite(fn _results ->
  case :ets.lookup(:pokex_escaped_logs, :escaped) do
    [] ->
      :ok

    escaped ->
      lines =
        escaped
        |> Enum.map(fn {:escaped, text} -> text end)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_text, count} -> -count end)
        |> Enum.map_join("\n", fn {text, count} -> "  #{count}x #{text}" end)

      IO.puts(
        :stderr,
        "\nERRO: #{length(escaped)} linha(s) de log escaparam da captura e foram impressas:\n\n" <>
          lines <>
          "\n\nUm teste que provoca log de propósito leva `@tag :capture_log`.\n" <>
          "Um log sem dono é um achado — leia antes de calar. Se veio de um timer,\n" <>
          "o teste tem um processo logando fora da janela de captura: faça o sweep\n" <>
          "ser pedido pelo teste, não esperado por tempo."
      )

      System.halt(1)
  end
end)
