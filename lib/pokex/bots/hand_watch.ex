defmodule Pokex.Bots.HandWatch do
  @moduledoc """
  HIS hand becomes a fact: the presses he makes on the keyboard, read and stamped as if the bot
  had made them.

  His rule: a key he presses himself affects the game just the same, so an F4 from his hand must
  produce the WHOLE effect of a revive even though the bot did not send it, and in theory that
  holds for any key. Until this worker existed the native keyboard watcher
  (`Pokex.Rig.Mac.KeyEvents.key_watch/2`, an 8ms poll in the helper) was only armed while the
  panel RECORDED a route: during a hunt his hand was invisible, the panel reported
  desynchronisation, and a manual F4 reset no clock at all.

  This worker owns `key_watch` during the hunt: it arms the skill row (1-0) plus the rescue key,
  drains every 150ms, and for every press THAT WAS NOT THE BOT'S:

    * a skill key -> `SkillClock.pressed/2`, so the panel shows the cooldown the game
      is really counting;
    * the rescue key -> the WHOLE effect of a revive: `SkillClock.reset/0` (R3, the
      revive resets every cooldown) and `ReviveLedger.note/0` (an item left his pocket,
      and it is counted).

  ## How his hand is told from ours

  The helper sees EVERY press on the watched codes, including the CGEvents the Body itself posts
  (that is how `KeyProbe` checks ours). Attribution uses the stamp: a seen press of a key the
  `SkillClock` stamped less than `@own_window_ms` ago is OURS coming back through the window,
  and it is already counted. shift+key is a stance switch, not a skill, and stays out, exactly
  as `HandsRead` reads it.

  The stamp is read through `SkillClock.pressed_at/1` and not `last_press/1`, because a revive
  erases EVERY stamp (R3) and not only the F4's. Without the echo the reset leaves behind, each
  revive made the burst the bot had just fired arrive here orphaned and become "his hand" 340ms
  later, and the re-stamp undid the reset the revive had just paid for: 235 false attributions
  in 242 revives over one night, with R3b disarming 37 times because of them.

  And only with the GAME IN FOCUS (`InputGate.focus_ok?/0`): out of focus a "4" is him typing
  somewhere else, and stamping that would invent a cooldown. If one slips through, a number
  typed in the game's chat, `SkillTruth` frees the stamp in about a second, when the screen
  shows the key ready.

  ## One owner, two tenants

  `key_watch/2` is ONE global buffer: arming swaps the codes and draining empties it. Two
  simultaneous readers steal each other's events. So:

    * the HUNT turns this worker on. `Combat.Worker` calls `attach/0` on `:run` and
      `detach/0` on `:halt`; with no consumer the watcher disarms, because a watch
      armed forever competes with the game it is playing;
    * route RECORDING and the `/diagnostics` probe keep their own drain. They call
      `pause/0` before and `resume/0` after, and this worker steps aside. Whoever
      paused is monitored: a page that dies while paused gives the watcher back by
      itself.

  Inert in the suite (`:hand_watch_active`), like the feeds: a drain loop against the Fake rig
  would dirty the call list of any worker test.
  """

  use GenServer

  alias Pokex.Bots.{InputGate, ReviveLedger, SkillClock}
  alias Pokex.Bots.Cavebot.HandsRead
  alias Pokex.Bots.KeyProbe
  alias Pokex.Rig.Mac.Commands
  alias Pokex.Settings

  @drain_ms 150
  @error_backoff_ms 2_000
  # The Body stamps at dispatch and a burst takes ~35-500ms between keys: a press seen within
  # this of the stamp is our own CGEvent.
  @own_window_ms 700
  # The BOT's revive reset (`:rescue_done`) clears the stamp of its own F4: in a late drain
  # that sighting would be ownerless and read as his hand, counting the item twice and
  # re-resetting the fresh stamps of the post-revive burst. The ledger remembers the last
  # dispatch from either hand, which also keeps HIS repeated F4 within 5s from counting
  # twice (the item has an in-game cooldown anyway).
  @bot_revive_window_ms 5_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Turns the watcher on for the caller (the hunt). Idempotent; dies with the caller."
  def attach(server \\ __MODULE__), do: safe_call(server, :attach)

  @doc "Turns it off for the caller. The last one out disarms the watch."
  def detach(server \\ __MODULE__), do: safe_call(server, :detach)

  @doc "Steps aside: another reader (recording, probe) is going to arm the key_watch."
  def pause(server \\ __MODULE__), do: safe_call(server, :pause)

  @doc "O outro leitor terminou; volta a vigiar se houver consumidor."
  def resume(server \\ __MODULE__), do: safe_call(server, :resume)

  # Pages call this from outside the bot tree; a missing watcher (test suite, crash) must
  # never crash a caller that only wanted to announce a recording.
  defp safe_call(server, msg) do
    GenServer.call(server, msg)
  catch
    :exit, _vigia_ausente -> :ok
  end

  @impl true
  def init(_opts) do
    # `terminate/2` is the only chance to disarm the helper on a crash; without the trap the
    # 8ms poll would keep reading eleven keys forever.
    Process.flag(:trap_exit, true)
    {:ok, %{consumers: %{}, paused_by: %{}, timer: nil, armed?: false}}
  end

  @impl true
  def terminate(_reason, state) do
    settle(state)
    :ok
  end

  @impl true
  def handle_call(:attach, {pid, _tag}, state) do
    state = put_watcher(state, :consumers, pid)
    {:reply, :ok, poke(state)}
  end

  def handle_call(:detach, {pid, _tag}, state) do
    # Only the LAST consumer out turns off the light: disarming with another consumer alive
    # would leave the hunt unwatched because a page left.
    state = drop_watcher(state, :consumers, pid)
    {:reply, :ok, if(active?(state), do: poke(state), else: settle(state))}
  end

  def handle_call(:pause, {pid, _tag}, state) do
    state = put_watcher(state, :paused_by, pid)
    {:reply, :ok, settle(state)}
  end

  def handle_call(:resume, {pid, _tag}, state) do
    {:reply, :ok, drop_watcher(state, :paused_by, pid) |> poke()}
  end

  @impl true
  def handle_info(:drain, state) do
    state = %{state | timer: nil}

    if active?(state) do
      {:noreply, drain(state)}
    else
      {:noreply, settle(state)}
    end
  end

  # A consumer (or pauser) died without saying goodbye; a crashed recording must not leave the
  # watcher paused forever.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      state
      |> drop_watcher(:consumers, pid)
      |> drop_watcher(:paused_by, pid)

    {:noreply, if(active?(state), do: poke(state), else: settle(state))}
  end

  # With trap_exit on (for the terminate that disarms the helper) any :EXIT becomes a message,
  # and an unmatched message would crash the watcher for the wrong reason.
  def handle_info(_msg, state), do: {:noreply, state}

  # -- the loop ---------------------------------------------------------------

  defp drain(state) do
    case Pokex.Rig.impl().key_watch(codes()) do
      {:ok, events} ->
        # The FIRST drain is garbage on purpose: `key_watch/1` ARMS and EMPTIES in one
        # call, so the first result is whatever the helper accumulated since it was last
        # armed (up to 500 keys of unknown age). Stamping that would invent a whole bar
        # in cooldown the instant the hunt starts.
        if state.armed?, do: act(events)

        schedule(%{state | armed?: true}, @drain_ms)

      # Helper unavailable (no Accessibility, compiling, dead): the rig falls back to
      # osascript for KEYS, but there is no watch. Retry slowly; it may come back
      # (permission granted mid-session).
      {:error, _reason} ->
        schedule(state, @error_backoff_ms)
    end
  end

  defp act(events) do
    ctx = %{
      focus_ok?: InputGate.focus_ok?(),
      rescue_code: rescue_code(),
      # `pressed_at/1`, not `last_press/1`: the revive's `SkillClock.reset/0` clears the
      # stamps of EVERY key. Without the echo, the burst the bot just fired read as his
      # hand 340ms later and re-stamped what the revive had just reset (235 false
      # attributions in 242 revives one night).
      last_press: &SkillClock.pressed_at/1,
      revive_noted?: ReviveLedger.noted_within?(@bot_revive_window_ms),
      now: System.monotonic_time(:millisecond)
    }

    events
    |> judge(ctx)
    |> Enum.each(&apply_action/1)
  end

  @doc """
  The judgement of one drain, pure: every event becomes `{:stamp, key}`, `:revive` or nothing.
  `ctx` carries the focus, the rescue code, the clock (`last_press`), whether the ledger noted a
  revive recently (`revive_noted?`) and the current time, all injectable for the test bench.
  """
  @spec judge([map], map) :: [{:stamp, String.t()} | :revive]
  def judge(events, ctx) do
    if ctx.focus_ok? do
      events
      |> Enum.map(&verdict(&1, ctx))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    else
      []
    end
  end

  # shift+key is a stance (shift+1 attack, shift+3 back to luring), never a skill.
  defp verdict(%{shift?: true}, _ctx), do: nil

  defp verdict(%{code: code}, ctx) do
    cond do
      code == ctx.rescue_code -> rescue_verdict(ctx)
      key = hotbar_key(code) -> unless_own_press(key, {:stamp, key}, ctx)
      true -> nil
    end
  end

  # Two witnesses that the F4 was OURS: the press stamp (which the :rescue_done reset may have
  # cleared already) and the ledger note, which stays.
  defp rescue_verdict(%{revive_noted?: true}), do: nil
  defp rescue_verdict(ctx), do: unless_own_press(rescue_key(), :revive, ctx)

  # Our own CGEvent coming back through the window: the stamp already exists.
  defp unless_own_press(key, action, ctx) do
    case ctx.last_press.(key) do
      at when is_integer(at) and ctx.now - at <= @own_window_ms -> nil
      _mao_dele -> action
    end
  end

  defp apply_action({:stamp, key}) do
    SkillClock.pressed(key)
    narrate("🖐️ tecla #{key} da tua mão — carimbei o cooldown dela no painel")
  end

  defp apply_action(:revive) do
    # The WHOLE effect of a revive: R3 resets the clock (which also clears the deaf keys)
    # and the item leaves the ledger.
    SkillClock.reset()
    ReviveLedger.note()
    narrate("🖐️ #{rescue_key()} da tua mão — revive: zerei o relógio (R3) e anotei no estoque")
  end

  defp narrate(text) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Bots.Combat.Worker.topic(),
      {:combat_log, :macro, "combate: " <> text}
    )
  end

  # -- watched key codes ------------------------------------------------------

  defp codes, do: Enum.uniq(HandsRead.codes() ++ KeyProbe.codes([rescue_key()]))

  defp rescue_key, do: to_string(Settings.get(:rescue_key))

  defp rescue_code do
    case Commands.keycode(rescue_key()) do
      {:ok, code} -> code
      :error -> nil
    end
  end

  defp hotbar_key(code) do
    Enum.find(~w(1 2 3 4 5 6 7 8 9 0), fn key ->
      match?({:ok, ^code}, Commands.keycode(key))
    end)
  end

  # -- liga/desliga ------------------------------------------------------------

  defp active?(state) do
    enabled?() and state.consumers != %{} and state.paused_by == %{}
  end

  defp enabled?, do: Application.get_env(:pokex, :hand_watch_active, true)

  # Wakes the loop if it should be running and is not.
  defp poke(state) do
    if active?(state) and state.timer == nil, do: schedule(state, 0), else: state
  end

  # Quiets: cancels the loop and DISARMS the helper once. An empty watch list is the off
  # switch; otherwise it reads ten keys every 8ms forever, competing with the game.
  defp settle(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if state.armed? do
      try do
        Pokex.Rig.impl().key_watch([])
      catch
        _kind, _reason -> :ok
      end
    end

    %{state | timer: nil, armed?: false}
  end

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :drain, ms)}
  end

  defp put_watcher(state, field, pid) do
    watchers = Map.fetch!(state, field)

    if Map.has_key?(watchers, pid) do
      state
    else
      Map.put(state, field, Map.put(watchers, pid, Process.monitor(pid)))
    end
  end

  defp drop_watcher(state, field, pid) do
    case Map.pop(Map.fetch!(state, field), pid) do
      {nil, _watchers} ->
        state

      {ref, watchers} ->
        Process.demonitor(ref, [:flush])
        Map.put(state, field, watchers)
    end
  end
end
