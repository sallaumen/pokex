defmodule Pokex.Bots.Cooldowns do
  @moduledoc """
  The combat cooldown manager: a GenServer that polls the calibrated `skill_bar_region`
  and tracks which skills are READY vs on COOLDOWN, so combat fires only the ready
  skills and fishing can hold a bite until the kill-skills are up.

  It reads the skill bar with `Vision.skill_slots/2` every `cooldown_poll_ms`, maps
  slot i (0-based, left→right) to hotbar key `to_string(i + 1)`, and broadcasts
  `{:cooldowns, snapshot}` on the `"cooldowns"` PubSub topic whenever the readiness
  changes. It moves no mouse/keyboard — a screen read only — so it never contends with
  the Body actuator.

  Starts idle; `run/1` begins polling, `halt/1` stops it. The query API is FAIL-OPEN:
  with no reading yet (poller down, skill bar not calibrated), `all_ready?/2` returns
  `true` so `require_cooldowns` can never softlock fishing on a misconfigured setup.
  """
  use GenServer
  require Logger

  alias Pokex.{Calibration, Rig, Settings, Vision}
  alias Pokex.Vision.Frame

  @topic "cooldowns"
  def topic, do: @topic

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)

  def snapshot(server \\ __MODULE__),
    do: safe_call(server, :snapshot, %{running?: false, states: nil, slots: []})

  @doc """
  Are ALL of `keys` (hotbar strings like "4") ready? FAIL-OPEN: `true` when there's no
  reading yet, so `require_cooldowns` never softlocks fishing on a misconfigured setup.
  """
  def all_ready?(keys, server \\ __MODULE__) do
    case snapshot(server).states do
      nil -> true
      states -> Enum.all?(keys, &(slot_state(states, &1) == :ready))
    end
  end

  @doc """
  The ready hotbar keys in ascending slot order, or `nil` when there's NO reading
  (skill bar not calibrated / poller down). Combat treats `nil` as "fall back to blind
  rotation" so it never stops using skills on a missing/uncalibrated skill bar.
  """
  def ready_skills(server \\ __MODULE__) do
    case snapshot(server).states do
      nil -> nil
      states -> for {:ready, i} <- Enum.with_index(states), do: to_string(i + 1)
    end
  end

  defp slot_state(states, key) do
    case Integer.parse(to_string(key)) do
      {n, _} -> Enum.at(states, n - 1, :cooldown)
      :error -> :cooldown
    end
  end

  # A query must never crash its caller (fishing/combat/panel): if the poller isn't
  # alive or is mid-restart, hand back the default instead of raising/exiting.
  defp safe_call(server, msg, default) do
    case GenServer.whereis(server) do
      nil -> default
      pid -> GenServer.call(pid, msg)
    end
  catch
    :exit, _ -> default
  end

  # --- server ---------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{running?: false, states: nil, slots: [], timer: nil}}

  @impl true
  def handle_call(:run, _from, state),
    do: {:reply, :ok, %{state | running?: true} |> reschedule(0)}

  def handle_call(:halt, _from, state),
    do: {:reply, :ok, %{cancel_timer(state) | running?: false, states: nil, slots: []}}

  def handle_call(:snapshot, _from, state),
    do: {:reply, %{running?: state.running?, states: state.states, slots: state.slots}, state}

  @impl true
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    {states, slots} = read_skill_bar()
    if states != state.states, do: broadcast(states, slots)
    {:noreply, %{state | states: states, slots: slots} |> reschedule(poll_ms())}
  end

  # Reloads calibration each tick so calibrating the skill bar mid-run takes effect
  # within one poll. No skill_bar_region (or an unreadable capture) → no reading (nil),
  # which the query API treats as fail-open.
  defp read_skill_bar do
    with {:ok, %Calibration{skill_bar_region: region}} when is_tuple(region) <- Calibration.load(),
         {:ok, path} <- Rig.impl().capture(region, "skillbar.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      slots =
        Vision.skill_slots(frame,
          count: Settings.get(:skill_bar_count),
          min_brightness: Settings.get(:skill_ready_min_brightness),
          min_saturation: Settings.get(:skill_ready_min_saturation)
        )

      {Enum.map(slots, & &1.state), slots}
    else
      _ -> {nil, []}
    end
  end

  defp poll_ms, do: Settings.get(:cooldown_poll_ms) || 500

  defp broadcast(states, slots),
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:cooldowns, %{states: states, slots: slots}}
      )

  defp reschedule(state, delay_ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, delay_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end
end
