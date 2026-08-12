defmodule Pokex.Machine.Presence do
  @moduledoc """
  Who else is running Pokex on this Mac — so a second server stops being invisible.

  ## Why

  On 2026-08-12 a `mix phx.server` opened in a worktree, only to review the UI, started fishing
  by itself while the real server was hunting. Nobody clicked Iniciar. The cause was the
  `Guardian`'s COMMAND CORNER: parking the mouse in the top-right toggles the fleet, on purpose,
  so that starting the bot doesn't cost the game its focus. But the cursor belongs to the
  MACHINE, not to a VM — every live Pokex polls the same mouse and each obeys on its own.
  `~/.pokex/journal/2026-08-12.jsonl` caught it:

      10:42:22.790  gen=9   canto de comando: ligando o modo hunt
      10:42:22.808  gen=1   canto de comando: ligando o modo still

  Two beams 18ms apart, each with its own `Pokex.Bots.Session` generation (an in-memory counter
  that starts at 0) — `gen=1` being a VM whose very first order in life came from the corner.

  The corner is not the only machine-wide input: the panic corner, the serialized capture queue
  and `PlayerSupport` (which arms itself on boot, with no order at all) are shared too.

  ## Why detection and not a lock

  The obvious fix is a lockfile that makes every later VM read-only. It was written, and
  rejected on purpose: it turns "two servers fight over the mouse" into a new way for the ONE
  real server to go silently dead — an unwritable lock, a crashed owner, a recycled pid, and
  the bot stops hunting while looking perfectly normal. That trade is bad here. A bot that
  doesn't run costs a night; a bot that runs twice costs a bad hour.

  So this module has NO authority. It never touches `InputGate`, never refuses an order, never
  halts a worker. It answers one question — *is another Pokex alive right now, and which one
  started first?* — and the header turns that into a warning the human acts on. The worst
  failure it can produce is a wrong banner.

  ## How

  Every VM drops a card at `<home>/vms/<os_pid>.json` and re-stamps `beat_at` on each poll. A
  card counts as a live neighbour only when BOTH hold: its pid answers `kill -0`, and it was
  stamped within `@stale_after_ms`. The heartbeat is what makes a recycled pid (or an
  `owner.lock` restored from a backup) harmless — a pid alone would announce a Pokex that died
  hours ago. Cards failing either test are swept, so the warning can never get stuck on.

  `first?` compares `started_at`: among the live VMs, the earliest is almost always the real
  server, and the newcomer is the window someone just opened to look at something.

  Every filesystem step is allowed to fail quietly. An unreadable directory means "I can't see
  anybody", never a crash and never a block.
  """
  use GenServer
  require Logger

  alias Pokex.Home

  @dir "vms"
  @topic "machine"
  @poll_ms 3_000
  # A card must be re-stamped this often to count. Comfortably more than @poll_ms, so a VM busy
  # with a slow capture isn't declared dead by its own neighbour.
  @stale_after_ms 15_000

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      dir: Keyword.get(opts, :dir) || default_dir(),
      os_pid: Keyword.get(opts, :os_pid, System.pid()),
      port: Keyword.get(opts, :port, default_port()),
      started_at: Keyword.get(opts, :started_at, now_ms()),
      alive_fun: Keyword.get(opts, :alive_fun, &alive?/1),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      auto_start: Keyword.get(opts, :auto_start, nil),
      others: [],
      first?: true
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  The other live Pokex VMs (`os_pid`, `port`), and whether THIS one started first.

  `others: []` means either that nobody else is running or that we couldn't look — the two are
  deliberately the same answer, because neither may ever be a reason to stop working.
  """
  @spec status(GenServer.server()) :: %{others: [map], first?: boolean}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    # A clean shutdown takes its card with it, so the other window's warning clears at once
    # instead of waiting out the staleness window.
    Process.flag(:trap_exit, true)

    start? =
      case state.auto_start do
        nil -> Application.get_env(:pokex, :machine_presence_auto, true)
        override -> override
      end

    if start?, do: {:ok, schedule(sweep(state))}, else: {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, %{others: state.others, first?: state.first?}, state}

  @impl true
  def handle_info(:poll, state), do: {:noreply, schedule(sweep(state))}

  # `System.cmd` (the liveness check) runs through a port, and trapping exits turns that port's
  # perfectly normal close into a message here. Nothing this process receives is worth crashing
  # over — a detector that dies takes the warning with it.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    File.rm(card_path(state, state.os_pid))
    :ok
  end

  # ── one pass ────────────────────────────────────────────────────────────────

  defp sweep(state) do
    announce(state)
    others = others(state)
    first? = Enum.all?(others, &(&1.started_at >= state.started_at))

    if {others, first?} != {state.others, state.first?} do
      log(others)
      broadcast(others, first?)
    end

    %{state | others: others, first?: first?}
  end

  # Our own card, re-stamped every pass — the heartbeat the neighbours read.
  defp announce(state) do
    File.mkdir_p(state.dir)

    File.write(
      card_path(state, state.os_pid),
      JSON.encode!(%{
        os_pid: to_integer(state.os_pid),
        port: state.port,
        started_at: state.started_at,
        beat_at: now_ms()
      })
    )
  catch
    _kind, _reason -> :ok
  end

  defp others(state) do
    mine = to_integer(state.os_pid)

    state.dir
    |> list()
    |> Enum.map(&read_card(state, &1))
    |> Enum.reject(&(&1 == :error or &1.os_pid == mine))
    |> Enum.filter(&keep?(state, &1))
    |> Enum.sort_by(& &1.started_at)
  end

  # A card earns its place only by proving BOTH that its process exists and that the process
  # still knows it does. Anything else is swept: a warning nobody can clear is worse than none.
  defp keep?(state, card) do
    if alive_card?(state, card) do
      true
    else
      File.rm(card_path(state, card.os_pid))
      false
    end
  end

  defp alive_card?(state, card),
    do: now_ms() - card.beat_at <= @stale_after_ms and state.alive_fun.(card.os_pid)

  defp list(dir) do
    case File.ls(dir) do
      {:ok, files} -> files
      # no directory yet (nobody has ever run here) or unreadable — either way, nobody seen
      {:error, _reason} -> []
    end
  end

  defp read_card(state, file) do
    with {:ok, body} <- File.read(Path.join(state.dir, file)),
         {:ok, %{"os_pid" => os_pid} = map} when is_integer(os_pid) <- JSON.decode(body) do
      %{
        os_pid: os_pid,
        port: map["port"],
        started_at: map["started_at"] || 0,
        beat_at: map["beat_at"] || 0
      }
    else
      # half-written by a VM booting right now, or hand-mangled: ignore it this pass
      _not_a_card -> :error
    end
  end

  defp card_path(state, os_pid), do: Path.join(state.dir, "#{os_pid}.json")

  # `kill -0` asks the kernel whether the pid exists, without touching it. Paired with the
  # heartbeat above, a recycled pid can't keep a dead VM's card alive.
  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  rescue
    # no `kill` on this box: fall back to the heartbeat alone, which is the honest half
    _no_kill -> true
  end

  # ── saying it ───────────────────────────────────────────────────────────────

  defp log([]), do: Logger.info("machine: this is the only Pokex running")

  defp log(others),
    do: Logger.warning("machine: another Pokex is running (#{describe(others)})")

  @doc "Human-readable neighbours, for the log and the on-screen warning."
  @spec describe([map]) :: String.t()
  def describe(others) when is_list(others), do: Enum.map_join(others, ", ", &describe/1)

  def describe(%{os_pid: os_pid, port: port}) when is_integer(port),
    do: "PID #{os_pid}, porta #{port}"

  def describe(%{os_pid: os_pid}), do: "PID #{os_pid}"
  def describe(_unknown), do: "outro processo"

  # Uncrashable: an announcement may never take down the thing that makes the announcement.
  # This also runs before most of the tree is up, so PubSub can legitimately be missing.
  defp broadcast(others, first?) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:machine_presence, %{others: others, first?: first?}}
    )
  catch
    _kind, _reason -> :ok
  end

  defp default_dir, do: Path.join(Home.dir(), @dir)

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
