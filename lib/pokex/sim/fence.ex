defmodule Pokex.Sim.Fence do
  @moduledoc """
  The one owner of "the simulator is armed", and the order in which it happens.

  Arming points the fleet's eyes and hands at a world that is not the game. That
  is three global switches (`:rig`, `:perception_feeds_active`, `:journal_persist`),
  and the danger is never the switches themselves — it is the window where half
  of them are flipped.

  So the order is copied from the panic path, where the same lesson was already
  paid for: the latch goes UP before anything is stopped, and comes DOWN only
  after everything is. Here that reads:

    * **Arming** — the flag first (nothing can start the real fleet any more),
      then the simulated hands (whatever was already in flight lands in the fake
      world), then the eyes, then the journal.
    * **Disarming** — the fleet stops first, and the real hands come back only
      after it has. The flag falls LAST, so it keeps guarding through the whole
      restore.

  ## Why the state lives outside the process

  `armed?/0` is read from inside `BotSupervisor.start_all/0`, which runs in the
  Guardian's Task and in `Focus` — processes that must not `GenServer.call`
  anything. So the answer lives in `:persistent_term`, the same shape
  `InputGate` uses for the panic latch: readable by anyone, costing no message.

  It also has to SURVIVE this process dying. A `Process.exit(pid, :kill)` skips
  `terminate/2`, and a replacement that could not tell what to restore would
  leave the fleet with simulated hands and nobody simulating. So what was
  swapped is stored there too, and the recovery reads it: fleet halted first,
  hands returned after.

  Never the LiveView's job. A closed browser tab must never be able to hand the
  keyboard back to the game with a fleet still walking.
  """
  use GenServer

  require Logger

  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.InputGate
  alias Pokex.Sim.Runner

  @pt {__MODULE__, :arm_state}
  @arm_timeout_ms 15_000

  # A KEYWORD LIST, not a map: the order is the fence. The hands go first so
  # anything already in flight lands in the fake world; the eyes and the journal
  # follow. A map would iterate in whatever order the runtime likes.
  # …and a fourth: a BAR for the engine to fight with. The eyes and the hands
  # were swapped and the loadout was not, so arming with no team configured gave
  # the brain no keys — and a brain with no keys orders nothing, which looked
  # exactly like a simulator that does not work. `Combat.Loadout.current/0`
  # reads it as a last resort, after the real team.
  @swaps [
    rig: Pokex.Rig.Sim,
    perception_feeds_active: false,
    journal_persist: false,
    simulated_loadout: Pokex.Sim.Loadout.fallback()
  ]

  def start_link(opts \\ []) do
    state = %{
      status: Keyword.get(opts, :status, &BotSupervisor.status/0),
      watched: Keyword.get(opts, :watched, &Pokex.Perception.watched_keys/0),
      stop_all: Keyword.get(opts, :stop_all, &BotSupervisor.stop_all/1)
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Arms the simulator, or refuses naming the workers that are running.

  Never stops a hunt on its own: interrupting eight hours of hunting is too
  expensive to be the side effect of a click meant for something else. The
  caller offers "stop everything and arm" as a separate, explicit action.
  """
  @spec arm(GenServer.server()) :: :ok | {:error, [atom | String.t()]}
  def arm(server \\ __MODULE__), do: GenServer.call(server, :arm, @arm_timeout_ms)

  @spec disarm(GenServer.server()) :: :ok
  def disarm(server \\ __MODULE__), do: GenServer.call(server, :disarm, @arm_timeout_ms)

  @doc "Is the simulator armed? Reads no process — see the moduledoc."
  @spec armed?() :: boolean
  def armed?, do: :persistent_term.get(@pt, nil) != nil

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    case :persistent_term.get(@pt, nil) do
      nil ->
        {:noreply, state}

      saved ->
        Logger.warning(
          "cerca do simulador reiniciou armada — parando a frota e devolvendo as mãos"
        )

        restore(state, saved, "a cerca do simulador reiniciou")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:arm, _from, state) do
    if armed?() do
      {:reply, :ok, state}
    else
      {:reply, do_arm(state), state}
    end
  end

  def handle_call(:disarm, _from, state) do
    case :persistent_term.get(@pt, nil) do
      nil -> {:reply, :ok, state}
      saved -> {:reply, restore(state, saved, "simulação desarmada"), state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    case :persistent_term.get(@pt, nil) do
      nil -> :ok
      saved -> restore(state, saved, "a cerca do simulador saiu")
    end
  end

  defp do_arm(state) do
    case running(state) do
      [] ->
        env = Map.new(@swaps, fn {key, _to} -> {key, Application.get_env(:pokex, key)} end)
        gate = Map.take(InputGate.state(), [:corner_ok, :focus_ok])
        :persistent_term.put(@pt, %{env: env, gate: gate})

        Enum.each(@swaps, fn {key, to} -> Application.put_env(:pokex, key, to) end)
        open_gate()
        :ok

      names ->
        {:error, names}
    end
  end

  # `Body.hold/1` refuses unless `InputGate.allowed?()`, which is
  # `corner_ok and focus_ok` and FAILS CLOSED — a missing key reads as false. Both
  # flags are written only by `Focus` and `Guardian`, the two this fence just
  # halted, so with the game window not in front the character would never take a
  # step and nothing would say why. The simulator would be born dead, and mute.
  #
  # Opened only AFTER the fake hands are installed: a gate opened first would be a
  # window in which the real rig still answers. The panic latch is untouched —
  # that brake is his, not mine.
  defp open_gate do
    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)
  end

  # Quem ainda mexe na tela: os workers da frota E as abas que estão OLHANDO.
  #
  # A segunda metade não era contada, e desligar `perception_feeds_active` não
  # cobre: a flag só torna inertes os attaches NOVOS, e o laço do Feed nunca a
  # consulta. Uma aba /panel aberta noutra janela segue fotografando a tela real
  # contra as MESMAS chaves que o `Sim.Runner` publica — os dois com
  # `:ets.insert` cru, último a escrever vence. O motor está rodando durante a
  # simulação e lê essas chaves, então a régua sai errada e calada, que é o
  # único produto do /sim. Recusar nomeando é melhor que medir errado.
  defp running(state) do
    workers =
      state.status.()
      |> Enum.filter(fn {_name, snapshot} -> BotSupervisor.active?(snapshot) end)
      |> Enum.map(&elem(&1, 0))

    # SÓ as chaves que o simulador escreve. Contar qualquer feed com consumidor
    # recusava para sempre: o `StockAlerts` é semeado ligado, vive no supervisor
    # da aplicação e mantém o `:hud` attachado — um fato que o `Sim.Runner` não
    # publica. A cerca nasceu, então, impossível de armar em qualquer VM real,
    # com zero abas abertas (medido em 27/08, na config dele).
    watching =
      state.watched.()
      |> Enum.filter(&(&1 in Runner.published_keys()))
      |> Enum.map(&"aba olhando #{inspect(&1)}")

    Enum.sort(workers ++ watching)
  end

  # The fleet stops FIRST and the hands come back after: a worker still deciding
  # with the real rig restored under it is the one outcome this module exists to
  # make impossible. The flag falls LAST, so it guards through the whole restore.
  defp restore(state, saved, reason) do
    state.stop_all.(reason)
    close_gate(saved[:gate])
    Enum.each(saved[:env] || %{}, &put_env/1)
    :persistent_term.erase(@pt)
    :ok
  end

  # Mirror of `open_gate/0`: the gate goes back to what it was BEFORE the real
  # hands return, so there is never a moment where the real rig answers through
  # a door this fence propped open.
  defp close_gate(nil), do: :ok

  defp close_gate(gate) do
    InputGate.set_corner_ok(Map.get(gate, :corner_ok, false))
    InputGate.set_focus_ok(Map.get(gate, :focus_ok, false))
  end

  defp put_env({key, nil}), do: Application.delete_env(:pokex, key)
  defp put_env({key, value}), do: Application.put_env(:pokex, key, value)
end
