defmodule Pokex.Bots.InputGate do
  @moduledoc """
  The hard safety floor for ACTUATION. A single named public ETS table holds three independent
  boolean flags; `allowed?/0` is their AND. `Rig.Mac` consults it before EVERY key/click/move
  (never before a capture or a cursor read — sensing must keep working so we can tell when it's
  safe to act again), so no input reaches the OS while the gate is closed.

  Three owners, one flag each, so none clobbers the others:
    * `:corner_ok` — the `Guardian` clears it while the cursor sits in the panic corner.
    * `:focus_ok`  — the `Focus` poller clears it while the game window is not frontmost.
    * `:owner_ok`  — `Pokex.Machine.Owner` clears it while ANOTHER Pokex VM holds the machine.

  That third flag exists because focus and the panic corner are conditions of the SCREEN, and
  every VM running on this Mac reads the same screen. On 2026-08-12 a `mix phx.server` opened in
  a worktree only to review the UI started fishing on its own: nobody clicked Iniciar — the
  Guardian's COMMAND CORNER (a mouse dwell: a machine-global input) is obeyed by every live VM
  at once. The journal caught two beams toggling 18ms apart with independent session
  generations while the real server was hunting. The Mac has exactly one keyboard, so it gets
  exactly one owner.

  Why this exists: with only the "re-front the game then fire the key" guard, a modal menu that
  stole focus (and could not be re-fronted) still received hundreds of stray keystrokes/clicks
  overnight. The gate flips the model to FAIL-SAFE — when we can't confirm it's safe to act, we
  don't act.

  FAIL-CLOSED: a missing flag — a freshly created table on boot or on a RESTART of this
  process — means BLOCKED, not allowed. "I don't know it's safe" and "it's safe" used to be
  the same answer, and a restart opened a window where input passed until the pollers
  noticed. The gate now starts closed and the guards open it by confirming the world: the
  Guardian writes `corner_ok` every 100ms and Focus writes `focus_ok` every tick (~250ms) —
  in production a restart's closed window lasts at most that. In the suite the pollers are
  off on purpose, so `test_helper` opens the gate once, simulating steady state; tests
  needing it closed write and restore.

  The panic latch is the deliberate exception: missing = NO panic. It records a human
  order, not a live condition — persisting it across a restart would need disk, and the
  real mitigation is the session generation (`Pokex.Bots.Session`): the restart also
  resets the counter, and stale resumes never match the new generation.

  Reads are lock-free straight off ETS (this is a hot path — every actuation checks it); the
  GenServer exists only to own the table across caller crashes.
  """
  use GenServer

  @table :pokex_input_gate

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "True only when ALL guards allow actuation. Missing table or flag → false (fail-closed)."
  def allowed?, do: flag(:corner_ok) and flag(:focus_ok) and flag(:owner_ok)

  @doc "The panic-corner guard: set false while the cursor is parked in the kill corner."
  def set_corner_ok(ok?) when is_boolean(ok?), do: put(:corner_ok, ok?)

  @doc "The focus guard: set false while the game window is not frontmost."
  def set_focus_ok(ok?) when is_boolean(ok?), do: put(:focus_ok, ok?)

  @doc "The single-owner guard: set false while another Pokex VM holds this machine."
  def set_owner_ok(ok?) when is_boolean(ok?), do: put(:owner_ok, ok?)

  @doc """
  True while THIS VM is the machine's owner. Read by the callers that must refuse an ORDER
  (starting the fleet) rather than merely swallow an input — a lock-free ETS read, never a
  call into `Machine.Owner`, so a busy owner can never stall the panel or a worker.
  """
  def owner_ok?, do: flag(:owner_ok)

  @doc """
  The PANIC LATCH. Unlike the two gate flags (which reflect a live condition and reopen when it
  clears), the latch records a HUMAN ORDER — mouse-to-corner — and nothing clears it except the
  human pressing Iniciar bot. Specifically it forbids every AUTO-resume path (the Focus poller's
  refocus resume) from restarting workers over a panic. It does not feed `allowed?/0`: workers
  are halted by the panic itself, and the human's own manual play must never be suppressed.

  This exists because of a real incident (2026-07-11): bot running → game lost focus (Focus
  halted the workers and noted "resume later") → Lucas panicked to the corner → he refocused the
  game to fight manually → Focus's pending resume RESTARTED everything over his panic, and he
  died to it. A panic now outranks every remembered intention.
  """
  # Not via put/2 by history: when the gate flags still defaulted OPEN, put/2's change
  # detection (which reads flag/1) would have skipped the very first set_panic_latch(true).
  # Today both default to false, but the latch keeps its own path — its semantics (missing =
  # no panic) are deliberately different from the gate's (missing = blocked), and sharing
  # put/2 would couple the two defaults again.
  def set_panic_latch(on?) when is_boolean(on?) do
    if panic_latched?() != on?, do: :ets.insert(@table, {:panic_latch, on?})
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc "True while a panic order stands (only Iniciar bot clears it). Missing → false (no panic)."
  def panic_latched? do
    case :ets.lookup(@table, :panic_latch) do
      [{:panic_latch, on?}] -> on?
      _ -> false
    end
  catch
    :error, :badarg -> false
  end

  @doc "All flags at once, for the panel/diagnostics."
  def state,
    do: %{
      corner_ok: flag(:corner_ok),
      focus_ok: flag(:focus_ok),
      owner_ok: flag(:owner_ok),
      panic_latch: panic_latched?()
    }

  # Only write on a real change: ETS writes are cheap but the pollers call these every tick, and
  # keeping the table quiet avoids needless churn.
  defp put(key, ok?) do
    if flag(key) != ok?, do: :ets.insert(@table, {key, ok?})
    :ok
  catch
    :error, :badarg -> :ok
  end

  # FAIL-CLOSED: no table (restart in progress) or no key (nothing confirmed
  # yet) answers BLOCKED. The flag's owning poller opens it by proving the real
  # condition — never an optimistic default.
  defp flag(key) do
    case :ets.lookup(@table, key) do
      [{^key, ok?}] -> ok?
      _ -> false
    end
  catch
    :error, :badarg -> false
  end
end
