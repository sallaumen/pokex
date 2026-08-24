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

  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.InputGate
  alias Pokex.Bots.Session
  alias Pokex.Settings

  @topic "focus"

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      frontmost_fun: Keyword.get(opts, :frontmost_fun, &default_frontmost/0),
      # The pause is a HOLD with identity: halts the fleet and returns the
      # order's generation — kept in resume_generation.
      hold_fun: Keyword.get(opts, :hold_fun, &BotSupervisor.hold_for_focus/0),
      start_all: Keyword.get(opts, :start_all, &BotSupervisor.start_all/0),
      running_fun: Keyword.get(opts, :running_fun, &default_running?/0),
      generation_fun: Keyword.get(opts, :generation_fun, &Session.generation/0),
      poll_ms: Keyword.get(opts, :poll_ms, nil),
      # tests inject their own frontmost reader, so they opt into polling explicitly rather than
      # via the env gate that keeps the app-wide instance quiet during unrelated tests.
      auto_start: Keyword.get(opts, :auto_start, nil),
      focused?: true,
      # MY pause's generation, or nil (nothing to resume). A boolean here once
      # re-armed the fleet over a manual Stop given between focus loss and
      # return — the human's order couldn't invalidate the pending resume. Now
      # any later order changes the generation, and the resume only applies if
      # the current generation is still the pause's.
      resume_generation: nil
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
        %{state | focused?: true, resume_generation: nil}
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
    # The memory carries the pause's GENERATION: only a fleet that was running
    # deserves a resume, and only if no order lands in between.
    InputGate.set_focus_ok(false)
    running? = safe_running?(state)
    generation = safe_hold(state)
    broadcast(false)
    Logger.info("focus lost — input suppressed and workers halted")
    %{state | focused?: false, resume_generation: if(running?, do: generation)}
  end

  defp apply_focus(%{focused?: false} = state, true) do
    # focus just REGAINED → open the gate, resume what was running — IF the
    # resume still HOLDS. Two things invalidate it, both from real incidents:
    #
    #   * the panic latch (2026-07-11): resuming over mouse-in-corner killed
    #     the Pokémon. The latch stays here as belt AND suspenders, even though
    #     panic also changes the generation;
    #   * ANY order between focus loss and return: a manual panel Stop, a
    #     logout, a cavebot brake — all change the generation, and the resume
    #     only re-arms its OWN pause's generation. A boolean used to forget the
    #     human's order and re-arm over it.
    #
    # An invalid resume is DISCARDED, never postponed.
    resume? =
      state.resume_generation != nil and
        safe_generation(state) == state.resume_generation and
        not InputGate.panic_latched?()

    InputGate.set_focus_ok(true)
    if resume?, do: safe_resume(state)
    broadcast(true)

    Logger.info(
      "focus regained — input allowed" <> if(resume?, do: " and workers resumed", else: "")
    )

    %{state | focused?: true, resume_generation: nil}
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

  # The pause must never fail to STOP because of the generation — if the hold
  # breaks midway, return nil and the resume simply doesn't exist (safe side).
  defp safe_hold(state) do
    state.hold_fun.()
  catch
    _kind, _reason -> nil
  end

  # Unreadable generation → resume discarded (compares against :unavailable,
  # never equal to a stored generation). Fail toward NOT re-arming.
  defp safe_generation(state) do
    state.generation_fun.()
  catch
    _kind, _reason -> :unavailable
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

  @doc """
  Bring the GAME to the front NOW (System Events), for deliberate flows that
  must act while something else holds focus — the emergency escape is the
  first: its click/keys would be swallowed by the Rig's focus gate otherwise
  (Lucas, live 2026-07-20: "quando ta fora do foco no jogo nao vai").
  Env-gated off in tests (`:front_game_cmd`) so suites never shell out.
  """
  def front_game do
    if Application.get_env(:pokex, :front_game_cmd, true), do: Pokex.GameFocus.front_game()

    :ok
  rescue
    _oascript_unavailable -> :ok
  end

  @doc """
  Ensures the game can receive a DELIBERATE key sequence: refuses if the panic
  corner is engaged (the human order beats everything), passes straight through
  if the game is already frontmost, otherwise fronts the game and opens the
  gate immediately.

  Opening the gate here, rather than waiting for the poller to notice, is the
  point: the poller would take a tick, and meanwhile the Rig would swallow the
  key IN SILENCE. If fronting truly fails, the poller shuts the gate back on
  the next tick and the Rig swallows again — the safety net still applies.
  """
  @spec ensure_front() :: :ok | {:error, :panic_corner}
  def ensure_front do
    cond do
      not InputGate.state().corner_ok ->
        {:error, :panic_corner}

      InputGate.state().focus_ok ->
        :ok

      true ->
        front_game()
        Process.sleep(Settings.get(:calibration_front_delay_ms))
        InputGate.set_focus_ok(true)
        :ok
    end
  end

  # Frontmost process name via System Events. `{:ok, name}` or `:error` (unreadable → hold).
  defp default_frontmost do
    case System.cmd(
           "osascript",
           [
             "-e",
             ~s(tell application "System Events" to name of first application process whose frontmost is true)
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The SAME "is it running?" rule the header and panel use — this module had
  # its own list, and two truths for one question is how a green pill and an
  # "Iniciar" button appear on the same screen. Kept difference, on purpose:
  # :busy (unknown status) counts as STOPPED here too — never schedule a
  # resume for what wasn't proven alive.
  defp default_running? do
    %{fishing: f, combat: c, catcher: cat, cavebot: cv} = BotSupervisor.status()
    BotSupervisor.any_active?([f, c, cat, cv])
  catch
    _kind, _reason -> false
  end
end
