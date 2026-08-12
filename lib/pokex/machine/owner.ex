defmodule Pokex.Machine.Owner do
  @moduledoc """
  Exactly one Pokex VM may drive this Mac. This process decides whether it is that one.

  ## The incident (2026-08-12)

  A `mix phx.server` was opened in a worktree just to look at the UI, on a different port,
  while the real server was hunting. Minutes after boot it started fishing by itself: the
  header said PARADO right after boot and ATIVO later, and nobody had clicked Iniciar.

  It was not a resume and not a flag left on disk. It was the `Guardian`'s COMMAND CORNER —
  parking the mouse in the top-right toggles the fleet, deliberately, so that starting the bot
  doesn't require clicking the browser and stealing the game's focus. But the cursor is a
  property of the MACHINE, not of a VM: every live Pokex polls the same mouse and each one
  obeys on its own. `~/.pokex/journal/2026-08-12.jsonl` caught it exactly:

      10:42:22.790  gen=9   canto de comando: ligando o modo hunt
      10:42:22.808  gen=1   canto de comando: ligando o modo still

  Two beams, 18ms apart, each with its own `Pokex.Bots.Session` generation (an in-memory
  counter that starts at 0) — and `gen=1` means the freshly booted VM's very first order in
  life came from the corner. The same shape repeats at every boot in that file.

  The corner is not the only shared input: the panic corner, the capture queue and
  `PlayerSupport` (which auto-arms on boot, with no order at all) are machine-wide too. Fixing
  the corner alone would leave the class open, so the fix is ownership, not a patch per input.

  ## The lock

  A lockfile in the Pokex home (`owner.lock`) holds the owning OS pid and its port. The first
  VM to create it EXCLUSIVELY (O_EXCL — the kernel arbitrates the race, not us) owns the
  machine; the others become OBSERVERS: their UI works, their sensing works, and their
  actuation floor (`InputGate`'s `:owner_ok`) stays shut, so the `Rig` swallows every key and
  click and `BotSupervisor` refuses to start the fleet at all.

  Ownership is re-checked on a poll, which buys two things: an observer PROMOTES itself once
  the owner is gone (close the real server and the window you already have open becomes the
  live one — no restart), and an owner that finds someone else's pid in the file steps down.
  Promotion only lifts the ban; it never starts workers. Nothing here ever starts anything.

  Fail-safe in every direction, matching the gate's philosophy — when we can't confirm it's
  safe to act, we don't:

    * a lock whose pid is ALIVE → observe. A recycled pid would answer "alive" for a dead
      owner; that costs a read-only window, never a second actor.
    * a lock whose pid is DEAD → stale, take it. This is the ordinary "the server was killed"
      path, and the only one that must not require deleting a file by hand.
    * an unreadable lock → observe while it is FRESH (a VM that created it microseconds ago
      and hasn't written the body yet), take it over once it is older than `@corrupt_grace_ms`
      (a truncated leftover must not lock the Mac out forever).

  The liveness reader, the gate writer, the pid and the path are all injected, so the tests
  arbitrate against a REAL foreign OS process instead of a mock.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.InputGate
  alias Pokex.Home

  @lock_name "owner.lock"
  @topic "machine"
  @poll_ms 2_000
  # older than this and an unreadable lock is a leftover, not a VM mid-boot
  @corrupt_grace_ms 10_000

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      lock_path: Keyword.get(opts, :lock_path) || default_lock_path(),
      os_pid: Keyword.get(opts, :os_pid, System.pid()),
      port: Keyword.get(opts, :port, default_port()),
      alive_fun: Keyword.get(opts, :alive_fun, &alive?/1),
      gate_fun: Keyword.get(opts, :gate_fun, &InputGate.set_owner_ok/1),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      auto_start: Keyword.get(opts, :auto_start, nil),
      owner?: false,
      holder: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Whether THIS VM owns the machine, plus who holds it when it doesn't — the panel's warning
  needs a name to show ("PID 431, porta 4004").
  """
  @spec status(GenServer.server()) :: %{owner?: boolean, holder: map | nil}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  The verdict for hot paths and for callers that must not risk a call: straight off the
  InputGate's ETS table, which this process keeps in sync.
  """
  @spec owner?() :: boolean
  def owner?, do: InputGate.owner_ok?()

  @impl true
  def init(state) do
    # A clean shutdown must hand the machine over: trapping exits guarantees terminate/2 runs
    # and removes our lock, so the next VM doesn't have to wait for a staleness check.
    Process.flag(:trap_exit, true)

    start? =
      case state.auto_start do
        nil -> Application.get_env(:pokex, :machine_owner_auto, true)
        override -> override
      end

    if start?, do: {:ok, schedule(evaluate(state))}, else: {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, %{owner?: state.owner?, holder: state.holder}, state}

  @impl true
  def handle_info(:poll, state), do: {:noreply, schedule(evaluate(state))}

  # Ignore the exit signals trap_exit turns into messages (linked callers dying).
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.owner?, do: release(state)
    :ok
  end

  # ── the decision ────────────────────────────────────────────────────────────

  defp evaluate(state) do
    case read_lock(state) do
      {:held_by_me, holder} -> settle(state, true, holder)
      {:held, holder} -> settle(state, false, holder)
      {:stale, _holder} -> acquire(state, :clear_first)
      :free -> acquire(state, :as_is)
    end
  end

  # O_EXCL: when two VMs boot at the same instant both land here and the KERNEL picks the
  # winner — the loser's create fails with :eexist and it re-reads to learn who won. We never
  # arbitrate the race ourselves.
  #
  # A stale lock has to be removed before that create, and THAT is the one window this scheme
  # doesn't close: two VMs taking over the same dead owner within microseconds of each other
  # can both end up believing they won. The next poll settles it (the one whose pid is no
  # longer in the file steps down), so the exposure is bounded by `poll_ms` and needs two
  # boots in the same instant to happen at all — while the failure that actually bit us (a
  # second server booted minutes later, next to a LIVE owner) has no race in it whatsoever.
  defp acquire(state, :clear_first) do
    File.rm(state.lock_path)
    acquire(state, :as_is)
  end

  defp acquire(state, :as_is) do
    case File.open(state.lock_path, [:write, :exclusive]) do
      {:ok, file} ->
        IO.binwrite(file, JSON.encode!(claim(state)))
        File.close(file)
        confirm(state)

      {:error, :eexist} ->
        # somebody created it between our read and our create
        confirm(state)

      {:error, reason} ->
        # can't even write the lock (missing home, read-only disk): observe. A VM that cannot
        # claim the machine must not act on it.
        Logger.warning("machine owner: could not take the lock (#{inspect(reason)}) — observing")
        settle(state, false, nil)
    end
  end

  # Ownership is never assumed from a successful write — it is READ BACK. Whoever the file
  # names is the owner, so a lost race resolves into observing instead of a second actor.
  defp confirm(state) do
    case read_lock(state) do
      {:held_by_me, holder} -> settle(state, true, holder)
      {:held, holder} -> settle(state, false, holder)
      # gone or stale again (we lost a takeover race): stay out and retry next poll
      _no_claim -> settle(state, false, nil)
    end
  end

  defp release(state) do
    # only remove a lock that is still OURS: an owner that was superseded must not delete the
    # new owner's claim on its way out
    case read_lock(state) do
      {:held_by_me, _holder} -> File.rm(state.lock_path)
      _someone_else -> :ok
    end
  end

  # Announce only on a CHANGE, and drive the gate on every pass: the gate is fail-closed, so a
  # restart of the InputGate table must be re-confirmed by the next poll, not just at boot.
  defp settle(state, owner?, holder) do
    state.gate_fun.(owner?)

    if owner? != state.owner? do
      log(owner?, holder)
      broadcast(owner?, holder)
    end

    %{state | owner?: owner?, holder: holder}
  end

  defp log(true, _holder), do: Logger.info("machine owner: this VM is in command")

  defp log(false, holder),
    do: Logger.warning("machine owner: another Pokex is in command (#{describe(holder)})")

  # Uncrashable, like the Focus poller's reads: this process decides whether the machine may be
  # touched at all, so no announcement may take it down. It runs BEFORE most of the tree
  # (deliberately — an observer must be read-only from its first millisecond), which means
  # PubSub may not be up yet on the very first pass; a missed banner is nothing, a crashed
  # owner would fail the gate closed and lock the app out of itself.
  defp broadcast(owner?, holder) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:machine_owner, %{owner?: owner?, holder: holder}}
    )
  catch
    _kind, _reason -> :ok
  end

  @doc "Human-readable holder, for logs and the on-screen warning."
  @spec describe(map | nil) :: String.t()
  def describe(%{os_pid: os_pid, port: port}) when is_integer(port),
    do: "PID #{os_pid}, porta #{port}"

  def describe(%{os_pid: os_pid}), do: "PID #{os_pid}"
  def describe(_unknown), do: "outro processo"

  # ── the lockfile ────────────────────────────────────────────────────────────

  defp claim(state), do: %{os_pid: to_integer(state.os_pid), port: state.port, at: now_ms()}

  defp read_lock(state) do
    case File.read(state.lock_path) do
      {:ok, body} -> interpret(state, body)
      {:error, :enoent} -> :free
      {:error, _unreadable} -> :free
    end
  end

  defp interpret(state, body) do
    case decode(body) do
      {:ok, %{os_pid: os_pid} = holder} ->
        cond do
          os_pid == to_integer(state.os_pid) -> {:held_by_me, holder}
          state.alive_fun.(os_pid) -> {:held, holder}
          # the owner's process is gone: the lock is a leftover, not a claim
          true -> {:stale, holder}
        end

      :error ->
        # unreadable: a VM mid-boot (microseconds) or a truncated leftover (forever)
        if old_file?(state.lock_path), do: {:stale, nil}, else: {:held, nil}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{"os_pid" => os_pid} = map} when is_integer(os_pid) ->
        {:ok, %{os_pid: os_pid, port: map["port"], at: map["at"]}}

      _not_a_claim ->
        :error
    end
  end

  defp old_file?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> now_ms() - mtime * 1000 > @corrupt_grace_ms
      _no_stat -> true
    end
  end

  # `kill -0` asks the kernel whether the pid exists without touching it. A pid the OS has
  # recycled answers "alive", which keeps this VM read-only — the safe direction.
  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  rescue
    _no_kill -> true
  end

  defp default_lock_path, do: Path.join(Home.dir(), @lock_name)

  defp default_port do
    :pokex
    |> Application.get_env(PokexWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end

  defp to_integer(os_pid) when is_integer(os_pid), do: os_pid
  defp to_integer(os_pid) when is_binary(os_pid), do: String.to_integer(os_pid)

  defp now_ms, do: System.system_time(:millisecond)

  defp schedule(state) do
    Process.send_after(self(), :poll, max(state.poll_ms, 20))
    state
  end
end
