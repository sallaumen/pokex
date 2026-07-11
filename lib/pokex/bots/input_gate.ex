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

  @doc "Both flags at once, for the panel/diagnostics."
  def state, do: %{corner_ok: flag(:corner_ok), focus_ok: flag(:focus_ok)}

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
