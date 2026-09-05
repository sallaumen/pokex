defmodule Pokex.Layout.Sentinel do
  @moduledoc """
  Keeps the layout honest without anyone touching a wizard.

  Feeds shout `{:layout_suspect, key}` when their captures start failing in a
  streak — the signature of panels that moved, a windowed client, or the game
  sitting on another display. This worker debounces those shouts and
  re-locates the HUD.

  It never actuates anything, so it stays alive with the app (Guardian
  pattern); the env flag `:layout_sentinel_active` keeps it inert in tests,
  which must never capture the real screen.
  """
  use GenServer
  require Logger

  alias Pokex.Layout

  @topic "layout"
  @relocate_cooldown_ms 30_000
  # While the HUD is MISSING nothing else will ever ask for a re-locate: the
  # feeds hold instead of failing (a nil region is not a capture error), so the
  # failure streaks that normally trigger this never arrive. Without a retry
  # the app stays blind until a restart — which is exactly what happened to
  # Lucas on 2026-07-22.
  @retry_ms 15_000

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      active?:
        Keyword.get(opts, :active, Application.get_env(:pokex, :layout_sentinel_active, true)),
      last_relocate_at: nil,
      located?: false
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "Announce that a feed suspects the layout moved (a capture-failure streak)."
  def suspect(key), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:layout_suspect, key})

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @topic)
    if state.active?, do: send(self(), :relocate)
    {:ok, state}
  end

  @impl true
  def handle_info({:layout_suspect, key}, state) do
    if state.active? and cooled_down?(state) do
      Logger.warning("Layout: feed #{key} falhando em série — re-localizando o HUD")
      {:noreply, relocate(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:relocate, state), do: {:noreply, relocate(state)}

  def handle_info(:retry, state) do
    if state.active? and not state.located? do
      {:noreply, relocate(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Judging the layout while the game is BEHIND something is judging the wrong picture. The
  # capture is of the DISPLAY, so with a single monitor every glance at the panel put the
  # browser in front of the HUD and the sentinel answered "HUD not found", a red alarm for the
  # most normal act there is. Not found and not looked at are different facts and now say
  # different things; `located?` is left alone, because nothing was learned.
  defp relocate(%{located?: located?} = state) do
    if game_in_front?() do
      locate(state)
    else
      broadcast(%{ok?: false, reason: :game_not_front, anchors: %{}})
      if state.active?, do: Process.send_after(self(), :retry, @retry_ms)
      %{state | last_relocate_at: System.monotonic_time(:millisecond), located?: located?}
    end
  end

  # The same fact the input gate runs on — the Focus poller writes it every
  # ~250ms. Unreachable (early boot, isolated test) reads as "in front" so a
  # missing poller can never be why the layout is never located.
  defp game_in_front? do
    Pokex.Bots.InputGate.state().focus_ok
  rescue
    _no_gate -> true
  catch
    :exit, _reason -> true
  end

  defp broadcast(payload),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:layout, payload})

  defp locate(state) do
    payload =
      case Layout.apply!() do
        {:ok, fix} ->
          %{ok?: true, reason: nil, anchors: fix.anchors}

        {:error, reason} ->
          Logger.warning(
            "Layout NÃO encontrado (#{inspect(reason)}) — o jogo está em tela cheia no monitor principal?"
          )

          %{ok?: false, reason: reason, anchors: %{}}
      end

    broadcast(payload)

    # keep trying while blind; stop once located (a moved panel comes back
    # through the feeds' failure streaks)
    if state.active? and not payload.ok?, do: Process.send_after(self(), :retry, @retry_ms)

    %{state | last_relocate_at: System.monotonic_time(:millisecond), located?: payload.ok?}
  end

  defp cooled_down?(%{last_relocate_at: nil}), do: true

  defp cooled_down?(%{last_relocate_at: at}),
    do: System.monotonic_time(:millisecond) - at > @relocate_cooldown_ms
end
