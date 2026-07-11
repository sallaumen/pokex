defmodule Pokex.Bots.Focus do
  @moduledoc """
  Ties actuation to the game window having focus. Polls the frontmost macOS app on a timer and,
  the instant the game is NOT frontmost, closes the `InputGate` (so no key/click can leak into
  whatever stole focus) AND halts the automated workers; when the game is frontmost again it
  reopens the gate and resumes whatever was running before.

  This is the safety net for the overnight failure mode: a menu/dialog opened by itself, the
  game lost focus, the old "re-front then fire" guard could not re-front it, and the bot typed
  hundreds of stray keystrokes into random windows. Here the model is fail-safe — unfocused
  means DON'T ACT, no attempt to force focus back.

  The frontmost reader is injected (`:frontmost_fun`, default: an osascript one-liner) so it is
  trivially testable. Auto-start is gated by `:focus_auto_monitor` (false in test) so the poll
  never shells out during unrelated tests. `pause_when_unfocused` (a setting) is the live
  master switch: off → the gate stays open and workers are never touched.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.{BotSupervisor, InputGate}
  alias Pokex.Settings

  @topic "focus"

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      frontmost_fun: Keyword.get(opts, :frontmost_fun, &default_frontmost/0),
      stop_all: Keyword.get(opts, :stop_all, &BotSupervisor.stop_all/0),
      start_all: Keyword.get(opts, :start_all, &BotSupervisor.start_all/0),
      running_fun: Keyword.get(opts, :running_fun, &default_running?/0),
      poll_ms: Keyword.get(opts, :poll_ms, nil),
      # tests inject their own frontmost reader, so they opt into polling explicitly rather than
      # via the env gate that keeps the app-wide instance quiet during unrelated tests.
      auto_start: Keyword.get(opts, :auto_start, nil),
      focused?: true,
      # remembers whether the bot was running when focus was lost, so refocus resumes only what
      # the user actually had going (never auto-starts a bot they never started).
      resume?: false
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "Current focus verdict + whether pausing is enabled — for the panel."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    start? =
      case state.auto_start do
        nil -> Application.get_env(:pokex, :focus_auto_monitor, true)
        override -> override
      end

    if start?, do: {:ok, schedule(state, 0)}, else: {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, %{focused?: state.focused?, enabled?: enabled?()}, state}

  @impl true
  def handle_info(:poll, state) do
    state =
      if enabled?() do
        evaluate(state)
      else
        # Master switch off: never hold input for focus. Leave the gate open and forget any
        # pending resume so flipping the switch on later starts from a clean slate.
        InputGate.set_focus_ok(true)
        %{state | focused?: true, resume?: false}
      end

    {:noreply, schedule(state, Settings.get(:focus_poll_ms))}
  end

  # An uncrashable poll: a flaky osascript read must not take the safety monitor down. On an
  # unreadable frontmost, HOLD the last verdict (don't flap the gate on a transient error).
  defp evaluate(state) do
    case read_frontmost(state) do
      {:ok, frontmost} -> apply_focus(state, game?(frontmost))
      :error -> state
    end
  end

  defp apply_focus(%{focused?: true} = state, false) do
    # focus just LOST → shut the gate, halt the workers, remember to resume them.
    InputGate.set_focus_ok(false)
    running? = safe_running?(state)
    state.stop_all.()
    broadcast(false)
    Logger.info("focus lost — input suppressed and workers halted")
    %{state | focused?: false, resume?: running?}
  end

  defp apply_focus(%{focused?: false} = state, true) do
    # focus just REGAINED → open the gate, resume what was running — UNLESS a panic order
    # stands. The panic latch outranks every remembered intention: resuming over a human's
    # mouse-to-corner is exactly the incident that killed Lucas's Pokémon (2026-07-11). The
    # pending resume is DROPPED, not deferred — after a panic only Iniciar bot restarts.
    resume? = state.resume? and not InputGate.panic_latched?()
    InputGate.set_focus_ok(true)
    if resume?, do: safe_resume(state)
    broadcast(true)

    Logger.info(
      "focus regained — input allowed" <> if(resume?, do: " and workers resumed", else: "")
    )

    %{state | focused?: true, resume?: false}
  end

  # steady state (no edge): keep the gate consistent with the verdict, nothing else.
  defp apply_focus(state, focused?) do
    InputGate.set_focus_ok(focused?)
    state
  end

  defp read_frontmost(state) do
    state.frontmost_fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_running?(state) do
    state.running_fun.()
  catch
    _kind, _reason -> false
  end

  defp safe_resume(state) do
    state.start_all.()
  catch
    _kind, _reason -> :ok
  end

  defp game?(frontmost) when is_binary(frontmost),
    do: String.downcase(frontmost) == String.downcase(Settings.get(:game_app_name))

  defp game?(_frontmost), do: false

  defp enabled?, do: Settings.get(:pause_when_unfocused) == true

  defp broadcast(focused?),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:focus, %{focused?: focused?}})

  # `state.poll_ms` (injected) overrides the cadence in tests; otherwise use the caller's delay
  # (0 for the first poll, the setting thereafter).
  defp schedule(state, delay_ms) do
    ms = state.poll_ms || delay_ms || 250
    Process.send_after(self(), :poll, max(ms, 20))
    state
  end

  # Frontmost process name via System Events. `{:ok, name}` or `:error` (unreadable → hold).
  defp default_frontmost do
    case System.cmd(
           "osascript",
           ["-e", ~s(tell application "System Events" to name of first application process whose frontmost is true)],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp default_running? do
    %{fishing: f, combat: c, catcher: cat} = BotSupervisor.status()
    active?(f) or active?(c) or active?(cat)
  catch
    _kind, _reason -> false
  end

  defp active?(%{state: state}), do: state not in [:idle, :error, :manual, nil]
  defp active?(_), do: false
end
