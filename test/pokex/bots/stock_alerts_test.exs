defmodule Pokex.Bots.StockAlertsTest do
  # async: false — stashes global Settings
  use ExUnit.Case, async: false

  alias Pokex.Bots.StockAlerts
  alias Pokex.{Settings, SettingsStash}

  setup do
    SettingsStash.stash!(
      stock_alerts_enabled: true,
      stock_alert_f1: 30,
      stock_alert_f2: 10,
      stock_alert_e: 5,
      stock_alert_s_q: 0
    )

    {:ok, alerts} = StockAlerts.start_link(name: nil, active: true)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")
    Phoenix.PubSub.subscribe(Pokex.PubSub, StockAlerts.topic())
    %{alerts: alerts}
  end

  # Deliver exactly like the feed does — a PubSub broadcast on the world topic.
  defp hud(slots) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Perception.topic(),
      {:world, :hud, %{level: 90, food: 1525, fishing: 96, slots: slots}}
    )
  end

  defp settle(alerts), do: StockAlerts.status(alerts)

  test "alarms ONCE when a stock crosses below, then stays quiet", %{alerts: alerts} do
    hud(%{f1: 28, f2: 36, e: 7, s_q: 43})

    assert_receive {:rule_alarm, :stock, reason}, 500
    assert reason =~ "F1 com 28"
    assert reason =~ "limiar 30"
    assert_receive {:stock, %{slot: :f1, low?: true}}, 500

    hud(%{f1: 27, f2: 36, e: 7, s_q: 43})
    refute_receive {:rule_alarm, _, _}, 200
    settle(alerts)
  end

  test "re-arms on restock — after 3 consecutive reads above the threshold", %{alerts: alerts} do
    hud(%{f1: 10, f2: 36, e: 7, s_q: 43})
    assert_receive {:rule_alarm, :stock, _}, 500

    hud(%{f1: 200, f2: 36, e: 7, s_q: 43})
    hud(%{f1: 200, f2: 36, e: 7, s_q: 43})
    hud(%{f1: 200, f2: 36, e: 7, s_q: 43})
    assert_receive {:stock, %{slot: :f1, low?: false}}, 500

    hud(%{f1: 9, f2: 36, e: 7, s_q: 43})
    assert_receive {:rule_alarm, :stock, reason}, 500
    assert reason =~ "F1 com 9"
    settle(alerts)
  end

  # Journal 2026-07-30: F2 stuck at 0 fired 56 times — a wrong OCR frame read high,
  # re-armed, and the next correct read alarmed again; 322 alarms in 9.7h muted 10 of 11
  # sectors.
  test "a single spurious read above the threshold does not re-arm — no machine-gun alarm",
       %{alerts: alerts} do
    hud(%{f1: 10, f2: 36, e: 7, s_q: 43})
    assert_receive {:rule_alarm, :stock, _}, 500

    for _ <- 1..5 do
      hud(%{f1: 150, f2: 36, e: 7, s_q: 43})
      hud(%{f1: 9, f2: 36, e: 7, s_q: 43})
    end

    refute_receive {:rule_alarm, :stock, _}, 300
    settle(alerts)
  end

  # Field: 404 potions, but a rect sized for one digit read "2" and alarmed — a reading the
  # eye cannot fully resolve must arrive as nil, and nil must be silent.
  test "an unread slot is never an alarm — a misread must not cry wolf", %{alerts: alerts} do
    hud(%{f1: nil, f2: nil, e: nil, s_q: nil})

    refute_receive {:rule_alarm, _, _}, 200
    assert %{low: []} = StockAlerts.status(alerts)
  end

  test "a slot with threshold 0 is off", %{alerts: alerts} do
    hud(%{f1: 322, f2: 36, e: 7, s_q: 0})

    refute_receive {:rule_alarm, _, _}, 200
    settle(alerts)
  end

  test "the whole watcher can be switched off", %{alerts: alerts} do
    Settings.put(:stock_alerts_enabled, false)

    hud(%{f1: 1, f2: 1, e: 1, s_q: 1})

    refute_receive {:rule_alarm, _, _}, 200
    assert %{enabled?: false} = StockAlerts.status(alerts)
  end

  test "each of the four slots alarms with its own label", %{alerts: alerts} do
    hud(%{f1: 322, f2: 3, e: 2, s_q: 43})

    assert_receive {:rule_alarm, :stock, first}, 500
    assert_receive {:rule_alarm, :stock, second}, 500
    labels = Enum.map([first, second], &(String.split(&1, " ") |> Enum.at(2)))

    assert "F2" in labels
    assert "E" in labels
    settle(alerts)
  end
end
