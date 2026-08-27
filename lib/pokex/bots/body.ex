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
  alias Pokex.Bots.{InputGate, Perf}
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

  @doc """
  HOLDS a set of keys (0, 1 or 2 arrows), releasing whatever else was held.

  Walking by tapping one arrow per tile is the client's slowest gear: Lucas
  measured his character crawling while the log filled with press/release
  pairs (2026-08-10). A held arrow walks continuously, and two held arrows walk
  the DIAGONAL — one tile of progress on both axes at once.

  The set REPLACES the previous one, so the caller never has to remember what
  it asked for: `hold(["up", "left"])` after `hold(["up"])` presses left and
  keeps up down; `hold([])` releases everything.

  A hold is refreshed by every new call and dies on its own after
  `hold_max_ms` without one — the watchdog that keeps a crashed or wedged
  caller from leaving an arrow down forever.
  """
  @spec hold([String.t()], GenServer.server()) :: :ok | {:error, term}
  def hold(keys, server \\ __MODULE__) when is_list(keys),
    do: GenServer.call(server, {:hold, keys})

  @doc "Lets go of everything held. Safe to call when nothing is."
  @spec release(GenServer.server()) :: :ok
  def release(server \\ __MODULE__), do: hold([], server)

  @doc "What is held right now — the panel's proof that nothing is stuck down."
  @spec held(GenServer.server()) :: [String.t()]
  def held(server \\ __MODULE__), do: GenServer.call(server, :held)

  @doc """
  Walks by clicking the minimap: `dx`/`dy` are TILES from where he stands.

  The minimap is the cheapest way to move in this game — the client walks the
  character there itself, around obstacles, without the bot having to
  understand the map. Arrival is confirmed by the `:minimap` fact, since PokeTibia
  prints the position as text.

  The click is clamped inside the map area: a click on the frame does nothing,
  and a click outside it lands on whatever is behind. Returns `{:error,
  :no_layout}` rather than guessing when the HUD has not been located, and
  `{:error, :input_gate_closed}` when the safety gate would swallow the click.

  `{:ok, point}` therefore means the click was REALLY emitted — see the gate
  note below for why walking, alone among the primitives, needs that promise.
  """
  def minimap_step(dx, dy, opts \\ [])

  def minimap_step(dx, dy, opts) when is_integer(dx) and is_integer(dy) do
    server = Keyword.get(opts, :server, __MODULE__)
    calib = step_calib(opts)

    with {x, y, w, h} <- calib && Pokex.Calibration.minimap_map_region(calib),
         {px, py} <- Pokex.Calibration.minimap_player_point(calib) do
      scale = Pokex.Settings.get(:minimap_px_per_tile)
      # The step starts from the character's calibrated CROSS (fixed — the map
      # slides under it), not the rect's geometric center: an off-center marker
      # biased EVERY step (2026-07-30). With no cross marked,
      # minimap_player_point/1 falls back to the center.
      point = clamp({px + dx * scale, py + dy * scale}, {x, y, w, h})

      # Rig.Mac.gated/1 SWALLOWS a suppressed input and answers `:ok` — the global
      # contract every other worker relies on ("held for safety" is not an I/O
      # failure). For walking that answer is a lie with teeth: the cavebot confirms
      # each step by watching the position change, so a suppressed click reported as
      # taken makes it believe in progress that never happened (2026-07-23: Iniciar
      # was clicked in the BROWSER → game lost focus → gate shut → every step came
      # back `:ok` → position frozen → `:stuck` → panic latch → whole fleet dead in
      # silence). So we ask the gate ourselves and refuse out loud.
      #
      # Best effort by nature: the gate can still shut between this read and the
      # click. That race costs one wasted step, not a false `:ok` every time.
      walk_click(point, server)
    else
      _no_region -> {:error, :no_layout}
    end
  end

  @doc """
  Walks ONE tile by pressing an arrow key — Lucas's direction (2026-08-10):
  one press = one sqm in the right direction, no minimap click near the
  hover controls, and the position CHANGE makes the coordinate label render,
  so movement begets sight. Picks the dominant axis; y grows SOUTH in the
  game, so dy < 0 presses "up".

  Same out-loud gate refusal as `minimap_step/3`, for the same reason: the
  cavebot confirms every step by watching the position change, and a
  suppressed press reported as `:ok` reads as progress that never happened.
  """
  def arrow_step(dx, dy, opts \\ [])

  def arrow_step(0, 0, _opts), do: {:error, :no_direction}

  def arrow_step(dx, dy, opts) when is_integer(dx) and is_integer(dy) do
    server = Keyword.get(opts, :server, __MODULE__)
    key = arrow_key(dx, dy)

    if InputGate.allowed?() do
      case perform([{:press, key}], :normal, server) do
        :ok -> {:ok, key}
        error -> error
      end
    else
      {:error, :input_gate_closed}
    end
  end

  defp arrow_key(dx, dy) when abs(dx) >= abs(dy), do: if(dx > 0, do: "right", else: "left")
  defp arrow_key(_dx, dy), do: if(dy > 0, do: "down", else: "up")

  defp walk_click(point, server) do
    if InputGate.allowed?() do
      case perform([{:click, :left, point}], :normal, server) do
        :ok -> {:ok, point}
        error -> error
      end
    else
      {:error, :input_gate_closed}
    end
  end

  # Step geometry comes from the CALIBRATION (hand-marked minimap regions since
  # PR #119; reloaded from disk each step, so a recalibration applies without a
  # restart — same contract as PlayerSupport). The :calib opt injects directly;
  # the :layout opt (step tests) builds a layout-only calibration WITHOUT touching
  # disk — a test without home_dir must not fall through to the real ~/.pokex.
  defp step_calib(opts) do
    cond do
      calib = Keyword.get(opts, :calib) ->
        calib

      Keyword.has_key?(opts, :layout) ->
        %Pokex.Calibration{
          scale: 1.0,
          layout: Keyword.get(opts, :layout) || Pokex.Layout.current()
        }

      true ->
        case Pokex.Calibration.load() do
          {:ok, calib} -> calib
          _no_calibration -> %Pokex.Calibration{scale: 1.0, layout: Pokex.Layout.current()}
        end
    end
  end

  # Hovering the minimap slides CONTROLS over its edges — clock/lock/book bar
  # on top, floor arrows left, zoom right, buttons bottom (Lucas's screenshots,
  # 2026-08-10) — and every walk click happens WITH the cursor hovering, so a
  # click clamped to an edge would press a control instead of walking (the
  # top-right ones toggle client state). The clamp stays clear of the whole
  # control ring, not just the frame's antialiasing.
  @minimap_margin_x 28
  @minimap_margin_top 32
  @minimap_margin_bottom 28

  defp clamp({px, py}, {x, y, w, h}) do
    {
      px |> max(x + @minimap_margin_x) |> min(x + w - 1 - @minimap_margin_x),
      py |> max(y + @minimap_margin_top) |> min(y + h - 1 - @minimap_margin_bottom)
    }
  end

  @impl true
  def init(_opts),
    do:
      {:ok,
       %{
         # ONE LANE PER ACTUATOR. The body had a single slot, so a potion —
         # which never touches the mouse — waited behind a ball throw or a
         # minimap step for no physical reason. Priority only reorders the
         # QUEUE: `dequeue/1` is reached when the running sequence ENDS, so not
         # even `:critical` cuts into what is already running.
         #
         # A sequence takes every lane its actions actuate, and takes them
         # together — a `move → wait → press` (the rod, the ball) must never be
         # split in two, so it holds both until it is done.
         lanes: %{keys: nil, mouse: nil},
         critical: :queue.new(),
         high: :queue.new(),
         normal: :queue.new(),
         last_priority: nil,
         # keys currently held down, and the watchdog that outlives their caller
         held: [],
         hold_timer: nil
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

  # Held keys are handled INLINE, not through the action queue: a key_down is
  # ~2ms (native CGEvent) and, more importantly, the set of held keys is STATE
  # — the queue's executor runs in a throwaway process and could not own it.
  def handle_call({:hold, []}, _from, state), do: {:reply, :ok, apply_hold(state, [])}

  def handle_call({:hold, keys}, _from, state) do
    # Refuses OUT LOUD, like every other walking primitive: the gate SWALLOWS a
    # suppressed input and answers :ok, and a hunt told "held" while nothing is
    # held believes in progress that never happens. Whatever was down is let go
    # on the way out — a shut gate must not leave an arrow pressed.
    if InputGate.allowed?() do
      {:reply, :ok, apply_hold(state, Enum.uniq(keys))}
    else
      {:reply, {:error, :input_gate_closed}, apply_hold(state, [])}
    end
  end

  def handle_call(:held, _from, state), do: {:reply, state.held, state}

  def handle_call({:perform, actions, priority, requested_at}, from, state) do
    item = %{
      actions: actions,
      from: from,
      requested_at: requested_at,
      priority: priority,
      lanes: lanes_of(actions),
      started_at: nil
    }

    if free?(state, item.lanes) do
      {:noreply, run_next(state, item)}
    else
      state = Map.update!(state, queue_for(priority), &:queue.in(item, &1))
      broadcast_queue(:queued, state, actions, priority, requested_at)
      {:noreply, state}
    end
  end

  defp queue_for(:critical), do: :critical
  defp queue_for(:high), do: :high
  defp queue_for(_normal), do: :normal

  # Which actuator does each action drive? By ACTUATOR, never by tuple shape:
  # the MIDDLE click is the one click with no `cliclick` — it goes out through
  # the same native key helper every keystroke uses (`Rig.Mac.click/2`) AND it
  # moves the pointer, so it holds both lanes. A sequence of pure waits/logs
  # actuates nothing and takes the key lane, which is where the old single slot
  # would have put it.
  defp lanes_of(actions) do
    case actions |> Enum.flat_map(&actuators/1) |> Enum.uniq() do
      [] -> [:keys]
      lanes -> lanes
    end
  end

  defp actuators({:press, _key}), do: [:keys]
  defp actuators({:tap, _combo}), do: [:keys]
  defp actuators({:click, :middle, _point}), do: [:keys, :mouse]
  defp actuators({:click, _button, _point}), do: [:mouse]
  defp actuators({:move, _point}), do: [:mouse]
  defp actuators({:focus_click, _point}), do: [:mouse]
  defp actuators({:capture_sequence, _point}), do: [:mouse, :keys]
  defp actuators(_not_actuation), do: []

  defp free?(state, lanes), do: Enum.all?(lanes, &is_nil(state.lanes[&1]))

  @impl true
  # The watchdog: whoever was holding stopped refreshing (crashed, wedged,
  # halted). Let go — a held arrow with nobody watching is the character
  # walking away on its own.
  def handle_info(:release_hold, state) do
    {:noreply, apply_hold(%{state | hold_timer: nil}, [])}
  end

  def handle_info({:done, item, result}, state) do
    GenServer.reply(item.from, result)
    broadcast_done(item, result)

    lanes = Enum.reduce(item.lanes, state.lanes, &Map.put(&2, &1, nil))
    {:noreply, dequeue(%{state | lanes: lanes})}
  end

  # Pick the next sequence. :critical (the survival combo) always drains first — nothing gets
  # ahead of it. Otherwise high is preferred, but after a high action we let an already-waiting
  # normal action run once, so repeated combat clicks can't keep fishing off the mouse forever.
  defp dequeue(state) do
    case next_runnable(state) do
      {:ok, item, state} -> state |> run_next(item) |> dequeue()
      :empty -> state
    end
  end

  defp next_runnable(state) do
    case pop_fit(:critical, state) do
      {:ok, _item, _state} = picked -> picked
      :empty -> next_high_normal(state)
    end
  end

  defp next_high_normal(%{last_priority: :high} = state) do
    case pop_fit(:normal, state) do
      {:ok, _item, _state} = picked -> picked
      :empty -> high_then_normal(state)
    end
  end

  defp next_high_normal(state), do: high_then_normal(state)

  defp high_then_normal(state) do
    case pop_fit(:high, state) do
      {:ok, _item, _state} = picked -> picked
      :empty -> pop_fit(:normal, state)
    end
  end

  # The first item in this queue whose lanes are FREE; the order of the rest is
  # kept. A mouse sequence waiting on a busy pointer must not hold up the
  # key-only one behind it — that head-of-line block is what two lanes exist to
  # remove.
  defp pop_fit(key, state) do
    case first_fitting(:queue.to_list(Map.fetch!(state, key)), state, []) do
      {item, rest} -> {:ok, item, %{state | key => :queue.from_list(rest)}}
      :none -> :empty
    end
  end

  defp first_fitting([], _state, _passed), do: :none

  defp first_fitting([item | rest], state, passed) do
    if free?(state, item.lanes),
      do: {item, Enum.reverse(passed) ++ rest},
      else: first_fitting(rest, state, [item | passed])
  end

  defp run_next(state, item) do
    item = %{item | started_at: now()}

    state = %{
      state
      | lanes: Enum.reduce(item.lanes, state.lanes, &Map.put(&2, &1, item)),
        last_priority: item.priority
    }

    broadcast_queue(:start, state, item.actions, item.priority, item.requested_at)
    run(item)
    state
  end

  # Execute the sequence off the GenServer loop so a slow input never blocks the
  # cursor read (the panic path). Report back via {:done, ...}.
  #
  # This executor must be uncrashable: {:done, item, result} is the ONLY signal
  # that frees the item's lanes and unblocks the caller (who is parked in
  # `perform/3` with an :infinity timeout). If a single action
  # raises/throws/exits (e.g. Rig.Mac.Commands.press/1's Map.fetch!/2 on an
  # unknown modifier from a mis-keyed config) and that isn't caught here, this
  # spawned process dies silently, {:done} never arrives, the calling worker
  # blocks forever, and the lane stays taken forever — including against a
  # :halt call, defeating the panic corner. So: always reply.
  defp run(item) do
    server = self()
    label = body_label(item.priority, item.actions)
    Perf.record("body.queue:#{label}", now() - item.requested_at)

    spawn(fn ->
      started_at = now()

      result =
        try do
          with_mouse_restore(item, fn -> run_guarded(item.actions, item.priority) end)
        catch
          kind, reason -> {:error, {:crashed, kind, reason}}
        end

      Perf.record("body.run:#{label}", now() - started_at)
      send(server, {:done, item, result})
    end)
  end

  # Cursor setup/teardown: a sequence that USES the mouse captures where the pointer was and
  # puts it back afterwards, so bot actions stop teleporting the cursor around while Lucas
  # shares the computer with it. Costs one cursor read + one move (~65ms) per mouse-using
  # sequence; key-only sequences skip the whole thing. The restore goes through the gated
  # Rig.move — if a panic/defocus closed the gate mid-sequence it is suppressed with
  # everything else, so it can never fight the human's own hand (e.g. yank the cursor OUT of
  # the panic corner they just reached). A failed origin read skips the restore, never the run.
  defp with_mouse_restore(item, fun) do
    if restore_mouse?() and :mouse in item.lanes do
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

  # Diff, never a blind re-press: pressing a key that is already down repeats
  # it, and releasing one that is not is noise the game can misread.
  defp apply_hold(state, keys) do
    rig = Rig.impl()
    Enum.each(state.held -- keys, &rig.key_up/1)
    Enum.each(keys -- state.held, &rig.key_down/1)

    if state.held != keys,
      do:
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:body_log, :debug, "segurando #{inspect(keys)}"}
        )

    %{state | held: keys, hold_timer: reschedule_release(state.hold_timer, keys)}
  end

  defp reschedule_release(timer, keys) do
    if timer, do: Process.cancel_timer(timer)
    if keys != [], do: Process.send_after(self(), :release_hold, hold_max_ms())
  end

  defp hold_max_ms do
    Pokex.Settings.get(:hold_max_ms)
  catch
    :exit, _reason -> 1_500
  end

  @impl true
  # Nothing may outlive this process holding a key down.
  def terminate(_reason, state) do
    rig = Rig.impl()
    Enum.each(state.held, &rig.key_up/1)
    :ok
  end

  defp safe_cursor_position do
    Rig.impl().cursor_position()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute({:press, key}), do: Rig.impl().press(key)
  defp execute({:click, button, point}), do: Rig.impl().click(button, point)
  defp execute({:move, point}), do: Rig.impl().move(point)
  defp execute({:tap, combo}), do: Rig.impl().tap(combo)
  defp execute({:focus_click, point}), do: Rig.impl().focus_click(point)
  defp execute({:capture_sequence, point}), do: Rig.impl().capture_sequence(point)
  # A pause WITHIN a sequence: lets one atomic perform hold a game-response gap
  # (e.g. between arming the rod and clicking the water) without releasing the Body
  # to a competing worker in between. Runs in the executor task, so the cursor read
  # (panic path) is never blocked.
  defp execute({:wait, ms}) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp execute({:wait, _ms}), do: :ok
  defp execute({:log, _}), do: :ok
  # Alarms ride the action list like logs: the worker plays them, not the Body.
  defp execute({:alarm, _}), do: :ok

  # Lock-free ETS read of the :mini_game blackboard fact — the input hot path never
  # blocks on the mini-game worker's mailbox (which is busy capturing). Checked before
  # AND after each input so a sequence already running when the game opens stops
  # between inputs instead of finishing.
  defp mini_game_gate(action) do
    if guarded_input?(action), do: Perception.mini_game_gate(), else: :ok
  end

  defp guarded_input?({:press, _key}), do: true
  defp guarded_input?({:tap, _combo}), do: true
  defp guarded_input?({:focus_click, _point}), do: true
  defp guarded_input?({:click, _button, _point}), do: true
  defp guarded_input?({:capture_sequence, _point}), do: true
  defp guarded_input?(_action), do: false

  defp body_label(priority, actions), do: "#{priority}/#{first_action(actions)}"

  defp first_action([{:press, key} | _]), do: "press:#{key}"
  defp first_action([{:click, button, _point} | _]), do: "click:#{button}"
  defp first_action([{:move, _point} | _]), do: "move"
  defp first_action([{:tap, combo} | _]), do: "tap:#{combo}"
  defp first_action([{:focus_click, _point} | _]), do: "focus_click"
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

  defp broadcast_done(item, result) do
    elapsed_ms = max(now() - item.started_at, 0)

    text =
      "fila ✓#{priority_label(item.priority)} #{actions_label(item.actions)} #{elapsed_ms}ms #{result_label(result)}"

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
  defp action_label({:tap, combo}), do: "tap:#{combo}"
  defp action_label({:focus_click, _point}), do: "focus_click"
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
