defmodule Pokex.Combos.Runner do
  @moduledoc """
  Plays a combo when a fight starts, one key at a time.

  It is a PEER of the combat worker, not a change to it: it listens to the same
  broadcasts and presses through the same Body. Combat is the most dangerous
  code in this bot to disturb, and a feature that can be switched off should
  not be able to break the thing that keeps his pokémon alive.

  Two rules come from what the panel actually does:

    * A swap is what REORDERS the rows, so every swap key is looked up against
      a FRESH reading of the team at the instant it is pressed — never against
      the reading the combo was planned with, which by then describes a panel
      that no longer exists.
    * A row is only a target when both its portrait and its "C+N" label were
      read. An unnamed row could be anyone; an unlabelled row has no key.

  It gives up loudly and completely: on the fight ending, on the enemy dying,
  on a step that can no longer be resolved, or on the Body refusing a press
  (panic latched, game not focused). A half-played combo leaves whoever it
  just sent out standing alone.

  One combo per engagement — re-arming only when the next fight begins — so a
  long fight can never turn into a swap loop.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Body
  alias Pokex.Bots.Catcher.Worker, as: Catcher
  alias Pokex.Bots.Combat
  alias Pokex.Combos
  alias Pokex.Combos.Store
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.Settings
  alias Pokex.World

  @topic "combos"

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :combos_active, true)),
      body: Keyword.get(opts, :body, Body),
      engaged?: false,
      running: nil,
      # the last combo that matched and could NOT run — the panel's answer to
      # "liguei os combos e não aconteceu nada"
      last_skip: nil
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Combat.Worker.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Catcher.kill_topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.active? and Settings.get(:combos_enabled),
       engaged?: state.engaged?,
       running: state.running && %{combo: state.running.combo.name, step: state.running.index},
       last_skip: state.last_skip
     }, state}
  end

  @impl true
  def handle_info({:combat, %{state: combat_state}}, state) do
    engaged? = combat_state in [:tabbing, :fighting]

    cond do
      # only the ENGAGE EDGE starts a combo, which is what keeps a long fight
      # from turning into a swap loop — no counter needed
      engaged? and not state.engaged? ->
        {:noreply, maybe_start(%{state | engaged?: true})}

      not engaged? and state.engaged? ->
        {:noreply, abort(%{state | engaged?: false}, :fight_ended)}

      true ->
        {:noreply, state}
    end
  end

  # The enemy died: whatever the combo was building towards is moot.
  def handle_info(kill, state) when kill in [{:kill}, {:kill, nil}],
    do: {:noreply, abort(state, :enemy_died)}

  def handle_info({:kill, _corpse}, state), do: {:noreply, abort(state, :enemy_died)}

  def handle_info({:combo_step, ref}, %{running: %{ref: ref}} = state),
    do: {:noreply, advance(state)}

  def handle_info({:combo_step, _stale}, state), do: {:noreply, state}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # -- starting ----------------------------------------------------------------

  defp maybe_start(%{active?: false} = state), do: state

  defp maybe_start(state) do
    if Settings.get(:combos_enabled), do: start(state), else: state
  end

  defp start(state) do
    world = World.snapshot()

    with {:ok, enemy} <- enemy_name(world),
         %Combos.Combo{} = combo <- Combos.match(Store.all(), enemy, current_dungeon()) do
      case Combos.plan(combo, enemy, world.team) do
        {:ok, steps} -> begin(state, combo, enemy, steps)
        {:skip, reason} -> refuse(state, combo, enemy, reason)
      end
    else
      # No enemy name read, or no combo describes this enemy: nothing to say.
      # "Nenhum combo casou" is the normal case, not an event.
      _nothing_to_run -> state
    end
  end

  defp begin(state, combo, enemy, steps) do
    Logger.info("Combos: #{combo.name} contra #{enemy} (#{length(steps)} passos)")
    broadcast({:combo_started, %{combo: combo.name, enemy: enemy}})

    %{
      state
      | last_skip: nil,
        running: %{combo: combo, enemy: enemy, steps: steps, index: 0, ref: make_ref()}
    }
    |> perform_current()
  end

  # A combo MATCHED and could not run. This used to be a Logger.debug, which made
  # it indistinguishable from "no combo applied" — he would flip the switch, fight
  # all night and never learn that the sing wanted a pokémon his hotkeys do not
  # have. It is kept in state too, so a panel opened afterwards still sees it.
  defp refuse(state, combo, enemy, reason) do
    skip = %{combo: combo.name, enemy: enemy, reason: reason}
    Logger.info("Combos: #{combo.name} não rodou contra #{enemy} (#{inspect(reason)})")
    broadcast({:combo_skipped, skip})
    %{state | last_skip: skip}
  end

  # The :dungeon fact is CONFIGURATION published by the cavebot (run publishes,
  # halt forgets), not an observation — hence max_age :infinity: it never goes
  # stale, it disappears. Absent = not hunting a dungeon = only global combos.
  defp current_dungeon do
    case WorldState.get(:dungeon, :infinity, System.monotonic_time(:millisecond)) do
      {:ok, %{id: id}} -> id
      _no_dungeon -> nil
    end
  end

  defp enemy_name(%{enemies: enemies}) do
    case Enum.find(enemies, &is_binary(&1[:name])) do
      nil -> {:skip, :no_enemy_name}
      enemy -> {:ok, enemy.name}
    end
  end

  # -- stepping ----------------------------------------------------------------

  defp perform_current(%{running: %{steps: steps, index: index}} = state)
       when index >= length(steps) do
    Logger.info("Combos: #{state.running.combo.name} completo")
    broadcast({:combo_done, %{combo: state.running.combo.name}})
    %{state | running: nil}
  end

  defp perform_current(%{running: running} = state) do
    case Enum.at(running.steps, running.index) do
      {:wait, ms} ->
        Process.send_after(self(), {:combo_step, running.ref}, ms)
        state

      step ->
        press(state, step)
    end
  end

  # The team is re-read HERE, not at planning time: the previous swap is
  # exactly what moved everyone around.
  defp press(state, step) do
    running = state.running
    rows = World.snapshot().team

    case Combos.key_for(step, running.enemy, rows) do
      {:ok, key} ->
        case state.body.perform([{:press, key}], :high) do
          :ok ->
            Process.send_after(
              self(),
              {:combo_step, running.ref},
              Settings.get(:combo_press_gap_ms)
            )

            state

          refused ->
            abort(state, {:body_refused, refused})
        end

      {:skip, reason} ->
        abort(state, reason)
    end
  end

  defp advance(%{running: running} = state),
    do: perform_current(%{state | running: %{running | index: running.index + 1}})

  # -- giving up ---------------------------------------------------------------

  defp abort(%{running: nil} = state, _reason), do: state

  defp abort(%{running: running} = state, reason) do
    Logger.warning(
      "Combos: #{running.combo.name} abortado no passo #{running.index} (#{inspect(reason)})"
    )

    broadcast({:combo_aborted, %{combo: running.combo.name, reason: reason}})
    %{state | running: nil}
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)
end
