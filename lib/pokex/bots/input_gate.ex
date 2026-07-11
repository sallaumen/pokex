defmodule Pokex.Bots.InputGate do
  @moduledoc """
  The hard safety floor for ACTUATION. A single named public ETS table holds two independent
  boolean flags; `allowed?/0` is their AND. `Rig.Mac` consults it before EVERY key/click/move
  (never before a capture or a cursor read — sensing must keep working so we can tell when it's
  safe to act again), so no input reaches the OS while the gate is closed.

  Two owners, one flag each, so neither clobbers the other:
    * `:corner_ok` — the `Guardian` clears it while the cursor sits in the panic corner.
    * `:focus_ok`  — the `Focus` poller clears it while the game window is not frontmost.

  Why this exists: with only the "re-front the game then fire the key" guard, a modal menu that
  stole focus (and could not be re-fronted) still received hundreds of stray keystrokes/clicks
  overnight. The gate flips the model to FAIL-SAFE — when we can't confirm it's safe to act, we
  don't act. Defaults to allowed so early boot and the faked-Rig tests are never blocked; the
  pollers set the flags definitively once running.

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

  @doc "True only when BOTH guards allow actuation. Missing table (pre-boot) → true (fail-open)."
  def allowed?, do: flag(:corner_ok) and flag(:focus_ok)

  @doc "The panic-corner guard: set false while the cursor is parked in the kill corner."
  def set_corner_ok(ok?) when is_boolean(ok?), do: put(:corner_ok, ok?)

  @doc "The focus guard: set false while the game window is not frontmost."
  def set_focus_ok(ok?) when is_boolean(ok?), do: put(:focus_ok, ok?)

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
  # Not via put/2: its change-detection reads flag/1, whose missing-key default is TRUE (right
  # for the gate flags, wrong here) — the very first set_panic_latch(true) would be skipped.
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
    do: %{corner_ok: flag(:corner_ok), focus_ok: flag(:focus_ok), panic_latch: panic_latched?()}

  # Only write on a real change: ETS writes are cheap but the pollers call these every tick, and
  # keeping the table quiet avoids needless churn.
  defp put(key, ok?) do
    if flag(key) != ok?, do: :ets.insert(@table, {key, ok?})
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp flag(key) do
    case :ets.lookup(@table, key) do
      [{^key, ok?}] -> ok?
      _ -> true
    end
  catch
    :error, :badarg -> true
  end
end
