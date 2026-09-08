defmodule Pokex.Bots.Watchman do
  @moduledoc """
  THE WATCHMAN: while the bot hunts, it asks every ten seconds whether the bot
  can still SEE, and rings a native sound when it cannot.

  His ask (2026-09-07, after a week of dying to readings he could not know
  were broken): "tinha que ter um alarme que toque na hora que eu ligar o bot
  e tiver uma configuração errada (…) a cada 1 min, com outro som". A
  single-screen notebook shows him the game, never the panel; the panel's
  chirps and warnings are in a tab he is not looking at. So:

    * the first check comes `watchman_grace_ms` after the bot starts, once
      the feeds have had a few ticks;
    * a NEW problem rings at once (`{:rule_alarm, :setup, _}` — the sector
      `Pokex.Bots.Siren` plays through the Mac's own speaker, with no mute
      button), and the same problems ring again every `watchman_repeat_ms`
      while they last;
    * a problem that goes away is said once in the feed, without a sound;
    * with the game out of focus nothing is judged: he is in the panel, and
      every region reads the browser.

  It measures nothing itself: `Pokex.Bots.Watchman.Checks` reads the
  blackboard and the files. Stopping the bot forgets everything, so the next
  start shouts again.
  """
  use GenServer

  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.Focus
  alias Pokex.Bots.Watchman.Checks
  alias Pokex.Settings

  @alarm_topic "combat"
  @feed_topic "engine"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active?, &default_active?/0),
      focused?: Keyword.get(opts, :focused?, &default_focused?/0),
      checks: Keyword.get(opts, :checks, &Checks.run/1),
      clock: Keyword.get(opts, :clock, &now/0),
      poll_ms: Keyword.get(opts, :poll_ms, nil),
      auto_start: Keyword.get(opts, :auto_start, nil),
      running_since: nil,
      problems: %{},
      shouted_at: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "The problems standing right now, as the texts he would hear about."
  @spec problems(GenServer.server()) :: [String.t()]
  def problems(server \\ __MODULE__), do: GenServer.call(server, :problems)

  @doc "One check now, grace or not (tests and the page's button)."
  @spec check_now(GenServer.server()) :: [String.t()]
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now)

  @impl true
  def init(state) do
    start? =
      case state.auto_start do
        nil -> Application.get_env(:pokex, :watchman_auto, true)
        override -> override
      end

    if start?, do: schedule(state, 0)
    {:ok, state}
  end

  @impl true
  def handle_call(:problems, _from, state), do: {:reply, texts(state.problems), state}

  def handle_call(:check_now, _from, state) do
    state = judge(%{state | running_since: -1_000_000}, state.clock.())
    {:reply, texts(state.problems), state}
  end

  @impl true
  def handle_info(:check, state) do
    state = watch(state)
    schedule(state, Settings.get(:watchman_every_ms))
    {:noreply, state}
  end

  # A stray message must never take the watchman down.
  def handle_info(_msg, state), do: {:noreply, state}

  # -- one round ------------------------------------------------------------------

  defp watch(state) do
    now = state.clock.()

    cond do
      Settings.get(:watchman_enabled) != true -> forget(state)
      not safe?(state.active?) -> forget(state)
      state.running_since == nil -> %{state | running_since: now}
      now - state.running_since < Settings.get(:watchman_grace_ms) -> state
      not safe?(state.focused?, true) -> state
      true -> judge(state, now)
    end
  end

  defp judge(state, now) do
    found = safe_checks(state, now)
    gone = Map.drop(state.problems, Map.keys(found))
    fresh = Map.drop(found, Map.keys(state.problems))

    Enum.each(gone, fn {_key, text} -> feed("✅ vigia: voltou — #{first_clause(text)}") end)

    cond do
      found == %{} ->
        %{state | problems: %{}, shouted_at: nil}

      fresh != %{} or repeat_due?(state, now) ->
        shout(found)
        %{state | problems: found, shouted_at: now}

      true ->
        %{state | problems: found}
    end
  end

  # A check that raises (a file mid-write, a fact of an unexpected shape) keeps
  # the standing verdict: the watchman must outlive what it reads.
  defp safe_checks(state, now) do
    Map.new(state.checks.(now))
  catch
    _kind, _reason -> state.problems
  end

  defp repeat_due?(%{shouted_at: nil}, _now), do: true
  defp repeat_due?(%{shouted_at: at}, now), do: now - at >= Settings.get(:watchman_repeat_ms)

  defp shout(found) do
    text = "🩺 vigia: " <> Enum.join(texts(found), " · ")
    Phoenix.PubSub.broadcast(Pokex.PubSub, @alarm_topic, {:rule_alarm, :setup, text})
  end

  defp feed(text),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @feed_topic, {:engine_log, :macro, text})

  defp forget(state), do: %{state | running_since: nil, problems: %{}, shouted_at: nil}

  defp texts(problems), do: problems |> Enum.sort() |> Enum.map(&elem(&1, 1))

  defp first_clause(text), do: text |> String.split(" — ", parts: 2) |> hd()

  # -- the world ---------------------------------------------------------------------

  defp default_active? do
    status = BotSupervisor.status()
    BotSupervisor.any_active?([status.fishing, status.combat, status.cavebot, status.mini_game])
  end

  defp default_focused?, do: Focus.status().focused?

  defp safe?(fun, default \\ false) do
    fun.() == true
  catch
    _kind, _reason -> default
  end

  defp schedule(state, delay_ms) do
    Process.send_after(self(), :check, max(state.poll_ms || delay_ms || 0, 20))
    state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
