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

    assert_receive {:rule_alarm, :estoque, reason}, 500
    assert reason =~ "F1 com 28"
    assert reason =~ "limiar 30"
    assert_receive {:stock, %{slot: :f1, low?: true}}, 500

    # an alarm that repeats every 500ms is one he learns to ignore
    hud(%{f1: 27, f2: 36, e: 7, s_q: 43})
    refute_receive {:rule_alarm, _, _}, 200
    settle(alerts)
  end

  test "re-arms when he restocks", %{alerts: alerts} do
    hud(%{f1: 10, f2: 36, e: 7, s_q: 43})
    assert_receive {:rule_alarm, :estoque, _}, 500

    hud(%{f1: 200, f2: 36, e: 7, s_q: 43})
    assert_receive {:stock, %{slot: :f1, low?: false}}, 500

    hud(%{f1: 9, f2: 36, e: 7, s_q: 43})
    assert_receive {:rule_alarm, :estoque, reason}, 500
    assert reason =~ "F1 com 9"
    settle(alerts)
  end

  test "an unread slot is never an alarm — a misread must not cry wolf", %{alerts: alerts} do
    # This is the safety property behind every "?" in the panel. Lucas had 404
    # potions; a rect sized for a single digit read "2" and alarmed. A reading
    # the eye cannot fully resolve must arrive as nil, and nil must be silent —
    # a wrong number is far worse than a missing one.
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

    assert_receive {:rule_alarm, :estoque, first}, 500
    assert_receive {:rule_alarm, :estoque, second}, 500
    labels = Enum.map([first, second], &(String.split(&1, " ") |> Enum.at(2)))

    assert "F2" in labels
    assert "E" in labels
    settle(alerts)
  end
end
