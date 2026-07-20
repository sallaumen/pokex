defmodule Pokex.Bots.Body do
  @moduledoc """
  The bot's single hands: the ONLY process that drives the Rig's mouse/keyboard.
  Workers submit action sequences; the Body runs ONE sequence at a time (atomic,
  so a click→move→read is never split). High-priority work is preferred, but the
  queue gives a waiting normal request a turn after high work so fishing cannot
  starve behind repeated combat/loot clicks. Screen captures do NOT go through
  here — they are read-only and each worker senses on its own.
  """
  use GenServer
  alias Pokex.Bots.Perf
  alias Pokex.{Perception, Rig}

  @topic "body"

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @spec perform([tuple], :critical | :high | :normal, GenServer.server()) :: :ok | {:error, term}
  def perform(actions, priority \\ :normal, server \\ __MODULE__),
    do: GenServer.call(server, {:perform, actions, priority, now()}, :infinity)

  @spec cursor(GenServer.server()) :: {:ok, {integer, integer}} | {:error, term}
  def cursor(server \\ __MODULE__), do: GenServer.call(server, :cursor)

  @impl true
  def init(_opts),
    do:
      {:ok,
       %{
         busy?: false,
         critical: :queue.new(),
         high: :queue.new(),
         normal: :queue.new(),
         current: nil,
         last_priority: nil
       }}

  # Cursor reads bypass the input queue (read-only, needed live for the panic corner).
  # Guarded with a catch: the Guardian polls this on every tick for as long as
  # the bot exists, and its contract (see Guardian's moduledoc) is that a bad
  # read reschedules instead of crashing the poll loop — so a momentarily
  # unreachable Rig (e.g. its process restarting) must come back as
  # `{:error, _}`, not take the Body (and, transitively, the Guardian) down
  # with it.
  @impl true
  def handle_call(:cursor, _from, state) do
    {:reply, safe_cursor_position(), state}
  end

  def handle_call({:perform, actions, priority, requested_at}, from, %{busy?: false} = state) do
    {:noreply, run_next(state, actions, from, requested_at, priority)}
  end

  def handle_call({:perform, actions, priority, requested_at}, from, state) do
    q =
      case priority do
        :critical -> :critical
        :high -> :high
        _ -> :normal
      end

    state = Map.update!(state, q, &:queue.in({actions, from, requested_at, priority}, &1))
    broadcast_queue(:queued, state, actions, priority, requested_at)
    {:noreply, state}
  end

  @impl true
  def handle_info({:done, from, result}, state) do
    GenServer.reply(from, result)
    broadcast_done(state, result)
    {:noreply, dequeue(%{state | current: nil})}
  end

  # Pick the next sequence. :critical (the survival combo) always drains first — nothing gets
  # ahead of it. Otherwise high is preferred, but after a high action we let an already-waiting
  # normal action run once, so repeated combat clicks can't keep fishing off the mouse forever.
  defp dequeue(state) do
    case next_queued(state) do
      {:ok, actions, from, requested_at, priority, state} ->
        run_next(state, actions, from, requested_at, priority)

      :empty ->
        %{state | busy?: false, current: nil}
    end
  end

  defp next_queued(state) do
    case pop(:critical, state) do
      {:ok, _actions, _from, _requested_at, _priority, _state} = picked -> picked
      :empty -> next_high_normal(state)
    end
  end

  defp next_high_normal(%{last_priority: :high} = state) do
    case pop(:normal, state) do
      {:ok, _actions, _from, _requested_at, _priority, _state} = picked -> picked
      :empty -> high_then_normal(state)
    end
  end

  defp next_high_normal(state), do: high_then_normal(state)

  defp high_then_normal(state) do
    case pop(:high, state) do
      {:ok, _actions, _from, _requested_at, _priority, _state} = picked -> picked
      :empty -> pop(:normal, state)
    end
  end

  defp pop(key, state) do
    case :queue.out(Map.fetch!(state, key)) do
      {{:value, {actions, from, requested_at, priority}}, rest} ->
        {:ok, actions, from, requested_at, priority, %{state | key => rest}}

      {:empty, _queue} ->
        :empty
    end
  end

  defp run_next(state, actions, from, requested_at, priority) do
    state = %{
      state
      | busy?: true,
        current: %{
          actions: actions,
          priority: priority,
          requested_at: requested_at,
          started_at: now()
        },
        last_priority: priority
    }

    broadcast_queue(:start, state, actions, priority, requested_at)
    run(actions, from, requested_at, priority)
    state
  end

  # Execute the sequence off the GenServer loop so a slow input never blocks the
  # cursor read (the panic path). Report back via {:done, ...}.
  #
  # This executor must be uncrashable: {:done, from, result} is the ONLY
  # signal that dequeues the next sequence and unblocks the caller (who is
  # parked in `perform/3` with an :infinity timeout). If a single action
  # raises/throws/exits (e.g. Rig.Mac.Commands.press/1's Map.fetch!/2 on an
  # unknown modifier from a mis-keyed config) and that isn't caught here, this
  # spawned process dies silently, {:done} never arrives, the calling worker
  # blocks forever, and the Body never processes anything queued behind it —
  # including a :halt call, defeating the panic corner. So: always reply.
  defp run(actions, from, requested_at, priority) do
    server = self()
    queue_ms = now() - requested_at
    label = body_label(priority, actions)
    Perf.record("body.queue:#{label}", queue_ms)

    spawn(fn ->
      started_at = now()

      result =
        try do
          with_mouse_restore(actions, fn -> run_guarded(actions, priority) end)
        catch
          kind, reason -> {:error, {:crashed, kind, reason}}
        end

      Perf.record("body.run:#{label}", now() - started_at)
      send(server, {:done, from, result})
    end)
  end

  # Cursor setup/teardown: a sequence that USES the mouse captures where the pointer was and
  # puts it back afterwards, so bot actions stop teleporting the cursor around while Lucas
  # shares the computer with it. Costs one cursor read + one move (~65ms) per mouse-using
  # sequence; key-only sequences skip the whole thing. The restore goes through the gated
  # Rig.move — if a panic/defocus closed the gate mid-sequence it is suppressed with
  # everything else, so it can never fight the human's own hand (e.g. yank the cursor OUT of
  # the panic corner they just reached). A failed origin read skips the restore, never the run.
  defp with_mouse_restore(actions, fun) do
    if restore_mouse?() and Enum.any?(actions, &mouse_action?/1) do
      origin =
        case safe_cursor_position() do
          {:ok, point} -> point
          _ -> nil
        end

      result = fun.()
      if origin, do: execute({:move, origin})
      result
    else
      fun.()
    end
  end

  defp restore_mouse? do
    Pokex.Settings.get(:restore_mouse_after_actions)
  catch
    :exit, _reason -> false
  end

  defp mouse_action?({:move, _point}), do: true
  defp mouse_action?({:click, _button, _point}), do: true
  defp mouse_action?({:capture_sequence, _point}), do: true
  defp mouse_action?(_action), do: false

  # The survival combo (:critical) bypasses the mini-game gate entirely — recalling and
  # max-reviving the Pokémon must run even while the mini-game overlay is up.
  defp run_guarded(actions, :critical) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case execute(action) do
        :ok -> {:cont, :ok}
        {:error, r} -> {:halt, {:error, r}}
      end
    end)
  end

  defp run_guarded(actions, _priority) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      with :ok <- mini_game_gate(action),
           :ok <- execute(action),
           :ok <- mini_game_gate(action) do
        {:cont, :ok}
      else
        {:blocked, :mini_game_active} -> {:halt, :ok}
        {:error, r} -> {:halt, {:error, r}}
      end
    end)
  end

  defp safe_cursor_position do
    Rig.impl().cursor_position()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute({:press, key}), do: Rig.impl().press(key)
  defp execute({:click, button, point}), do: Rig.impl().click(button, point)
  defp execute({:move, point}), do: Rig.impl().move(point)
  defp execute({:capture_sequence, point}), do: Rig.impl().capture_sequence(point)
  # A pause WITHIN a sequence: lets one atomic perform hold a game-response gap
  # (e.g. between arming the rod and clicking the water) without releasing the Body
  # to a competing worker in between. Runs in the executor task, so the cursor read
  # (panic path) is never blocked.
  defp execute({:wait, ms}) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp execute({:wait, _ms}), do: :ok
  defp execute({:log, _}), do: :ok

  # Lock-free ETS read of the :mini_game blackboard fact — the input hot path never
  # blocks on the mini-game worker's mailbox (which is busy capturing). Checked before
  # AND after each input so a sequence already running when the game opens stops
  # between inputs instead of finishing.
  defp mini_game_gate(action) do
    if guarded_input?(action), do: Perception.mini_game_gate(), else: :ok
  end

  defp guarded_input?({:press, _key}), do: true
  defp guarded_input?({:click, _button, _point}), do: true
  defp guarded_input?({:capture_sequence, _point}), do: true
  defp guarded_input?(_action), do: false

  defp body_label(priority, actions), do: "#{priority}/#{first_action(actions)}"

  defp first_action([{:press, key} | _]), do: "press:#{key}"
  defp first_action([{:click, button, _point} | _]), do: "click:#{button}"
  defp first_action([{:move, _point} | _]), do: "move"
  defp first_action([{:capture_sequence, _point} | _]), do: "capture_sequence"
  defp first_action([{:wait, _ms} | _]), do: "wait"
  defp first_action([_other | _]), do: "other"
  defp first_action([]), do: "empty"

  defp broadcast_queue(event, state, actions, priority, requested_at) do
    text =
      case event do
        :queued ->
          "fila +#{priority_label(priority)} #{actions_label(actions)} h=#{queue_len(state.high)} n=#{queue_len(state.normal)}"

        :start ->
          wait_ms = max(now() - requested_at, 0)

          "fila >#{priority_label(priority)} #{actions_label(actions)} espera=#{wait_ms}ms h=#{queue_len(state.high)} n=#{queue_len(state.normal)}"
      end

    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:body_log, :debug, text})
  end

  defp broadcast_done(%{current: nil}, _result), do: :ok

  defp broadcast_done(%{current: current}, result) do
    elapsed_ms = max(now() - current.started_at, 0)

    text =
      "fila ✓#{priority_label(current.priority)} #{actions_label(current.actions)} #{elapsed_ms}ms #{result_label(result)}"

    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:body_log, :debug, text})
  end

  defp queue_len(queue), do: :queue.len(queue)

  defp priority_label(:critical), do: "C"
  defp priority_label(:high), do: "H"
  defp priority_label(_priority), do: "N"

  defp actions_label(actions) do
    actions
    |> Enum.map(&action_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "vazio"
      labels -> labels |> Enum.take(3) |> Enum.join("+") |> add_more(length(labels))
    end
  end

  defp add_more(text, count) when count > 3, do: text <> "+…"
  defp add_more(text, _count), do: text

  defp action_label({:press, key}), do: "key:#{key}"
  defp action_label({:click, button, _point}), do: "click:#{button}"
  defp action_label({:move, _point}), do: "move"
  defp action_label({:capture_sequence, _point}), do: "cap"
  defp action_label({:wait, ms}) when is_integer(ms), do: "wait:#{ms}"
  defp action_label({:wait, _ms}), do: "wait"
  defp action_label({:log, _msg}), do: nil
  defp action_label(_other), do: "?"

  defp result_label(:ok), do: "ok"
  defp result_label({:error, reason}), do: "erro:#{inspect(reason)}"
  defp result_label(other), do: inspect(other)

  defp now, do: System.monotonic_time(:millisecond)
end
