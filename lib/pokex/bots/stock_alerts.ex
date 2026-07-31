defmodule Pokex.Bots.StockAlerts do
  @moduledoc """
  Screams before the character dies of an empty slot.

  A low slot must keep screaming until he acts — an empty slot gets the
  character killed mid-hunt. So this watches the four slots that keep him
  alive and hunting — F1 and F2 (balls), E (potion) and S+Q — and fires ONE
  alarm per crossing, re-arming only when the stock climbs back above its
  threshold. An alarm that repeats every 500ms
  is an alarm he learns to ignore.

  A slot that could not be READ is never an alarm. A misread would either cry
  wolf or, worse, teach him to distrust the one alarm that matters.

  Always-on like the Guardian and the ShinyGuard: running dry is dangerous
  during manual play too. It attaches the `:hud` feed while enabled and — the
  lesson of the silent shiny — SUBSCRIBES to the world topic, because
  attaching only creates demand; the observations arrive by PubSub.
  """
  use GenServer
  require Logger

  alias Pokex.Perception
  alias Pokex.Perception.Feed
  alias Pokex.Settings

  @combat_topic "combat"
  @topic "stock"
  @poll_ms 1_000

  @slots [
    {:f1, "F1", :stock_alert_f1},
    {:f2, "F2", :stock_alert_f2},
    {:e, "E", :stock_alert_e},
    {:s_q, "S+Q", :stock_alert_s_q}
  ]

  def topic, do: @topic
  def slots, do: @slots

  def start_link(opts \\ []) do
    state = %{
      active?:
        Keyword.get(opts, :active, Application.get_env(:pokex, :stock_alerts_active, true)),
      attached?: false,
      feed_ref: nil,
      # slots currently below their threshold — the re-arm memory
      low: MapSet.new(),
      # CONSECUTIVE re-reads above the threshold per slot — the re-arm hysteresis
      acima: %{}
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.active? and Settings.get(:stock_alerts_enabled),
       attached?: state.attached?,
       low: MapSet.to_list(state.low)
     }, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = sync_attachment(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info({:world, :hud, obs}, state) do
    if state.active? and Settings.get(:stock_alerts_enabled) do
      {:noreply, check(state, Map.get(obs, :slots, %{}))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state),
    do: {:noreply, %{state | attached?: false, feed_ref: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  # Consecutive above-threshold re-reads before RE-ARMING an already-alarmed
  # slot. Without this, ONE spurious HUD read (OCR on the wrong frame) re-armed
  # and the next correct read alarmed AGAIN — journal 2026-07-30: F2 stuck at 0
  # fired 56 times; 322 alarms in 9.7h got 10 of the 11 bell sectors muted.
  # Not a knob: 3 reads is OCR-noise physics, not taste.
  @rereads_to_rearm 3

  defp check(state, slots) do
    Enum.reduce(@slots, state, fn {key, label, setting}, acc ->
      threshold = Settings.get(setting)
      count = Map.get(slots, key)

      cond do
        # 0 disables a slot; nil is an unread count, never an alarm
        threshold == nil or threshold <= 0 or count == nil -> acc
        count <= threshold -> acc |> zerar_acima(key) |> maybe_fire(key, label, count, threshold)
        true -> contar_acima(acc, key, count)
      end
    end)
  end

  defp zerar_acima(state, key), do: %{state | acima: Map.delete(state.acima, key)}

  defp contar_acima(state, key, count) do
    if MapSet.member?(state.low, key) do
      vezes = Map.get(state.acima, key, 0) + 1

      if vezes >= @rereads_to_rearm,
        do: rearm(zerar_acima(state, key), key, count),
        else: %{state | acima: Map.put(state.acima, key, vezes)}
    else
      state
    end
  end

  defp maybe_fire(state, key, label, count, threshold) do
    if MapSet.member?(state.low, key) do
      state
    else
      reason = "estoque baixo: #{label} com #{count} (limiar #{threshold})"
      Logger.warning("StockAlerts: #{reason}")
      Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, :stock, reason})
      broadcast(key, count, true)
      %{state | low: MapSet.put(state.low, key)}
    end
  end

  defp rearm(state, key, count) do
    if MapSet.member?(state.low, key) do
      broadcast(key, count, false)
      %{state | low: MapSet.delete(state.low, key)}
    else
      state
    end
  end

  defp broadcast(slot, count, low?),
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:stock, %{slot: slot, count: count, low?: low?}}
      )

  defp sync_attachment(%{active?: false} = state), do: state

  defp sync_attachment(state) do
    enabled? = Settings.get(:stock_alerts_enabled)

    cond do
      enabled? and not state.attached? ->
        Perception.attach(:hud)
        %{state | attached?: true, feed_ref: Process.monitor(Feed.name(:hud))}

      not enabled? and state.attached? ->
        safe_detach()
        if state.feed_ref, do: Process.demonitor(state.feed_ref, [:flush])
        %{state | attached?: false, feed_ref: nil, low: MapSet.new(), acima: %{}}

      true ->
        state
    end
  end

  defp safe_detach do
    Perception.detach(:hud)
  catch
    _kind, _reason -> :ok
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)
end
