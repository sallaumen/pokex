defmodule Pokex.Machine.PresenceTest do
  @moduledoc """
  Who else is running Pokex on this Mac.

  Detection ONLY: this module must never be able to stop anything. The tests say so twice —
  once for what it reports, once for what it must not touch.
  """
  use ExUnit.Case, async: true

  alias Pokex.Machine.Presence

  setup do
    dir = Path.join(System.tmp_dir!(), "pokex-presence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # A REAL foreign OS process, so "the other VM is alive" is not a mock: the liveness question
  # goes to the kernel about a pid it really holds.
  defp live_os_process do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["300"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true) end)
    os_pid
  end

  defp dead_os_process do
    os_pid = live_os_process()
    System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)

    assert eventually(fn ->
             {_out, status} =
               System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)

             status != 0
           end)

    os_pid
  end

  # Another VM's card, as that VM would have left it.
  defp write_card!(dir, os_pid, opts \\ []) do
    card = %{
      os_pid: os_pid,
      port: Keyword.get(opts, :port, 4004),
      started_at: Keyword.get(opts, :started_at, 1000),
      beat_at: Keyword.get(opts, :beat_at, System.system_time(:millisecond))
    }

    File.write!(Path.join(dir, "#{os_pid}.json"), JSON.encode!(card))
  end

  # No free-running timer in the suite: a 50ms poll logs whenever it likes, and
  # "whenever" lands outside the window `@tag :capture_log` covers — CI caught
  # one such line on 2026-08-14 with nothing able to say whose it was. Sweeps
  # here are asked for, not waited for: `sweep/1` below sends :poll and reads
  # the status back, and the GenServer serialises the two.
  defp boot(dir, opts \\ []) do
    {:ok, pid} =
      Presence.start_link(
        [name: nil, auto_start: true, dir: dir, poll_ms: :timer.hours(1)] ++ opts
      )

    pid
  end

  defp sweep(pid) do
    send(pid, :poll)
    Presence.status(pid)
  end

  describe "seeing the others" do
    test "a VM alone on the machine reports nobody else", %{dir: dir} do
      assert %{others: [], first?: true} = Presence.status(boot(dir))
    end

    test "a VM leaves a card with its own pid and port", %{dir: dir} do
      boot(dir, port: 4013)

      assert [card] = File.ls!(dir)

      assert %{"os_pid" => os_pid, "port" => 4013} =
               dir |> Path.join(card) |> File.read!() |> JSON.decode!()

      assert to_string(os_pid) == System.pid()
    end

    @tag :capture_log
    test "a card from a LIVE process is another Pokex, named for the warning", %{dir: dir} do
      alien = live_os_process()
      write_card!(dir, alien, port: 4004)

      assert %{others: [%{os_pid: ^alien, port: 4004}]} = Presence.status(boot(dir))
    end

    test "a card from a DEAD process is a leftover, not a neighbour", %{dir: dir} do
      write_card!(dir, dead_os_process())

      assert %{others: []} = Presence.status(boot(dir))
    end

    test "a card nobody has touched in a long time is stale, even if the pid is alive", %{
      dir: dir
    } do
      # a recycled pid would otherwise announce a Pokex that has not existed for hours
      write_card!(dir, live_os_process(), beat_at: 0)

      assert %{others: []} = Presence.status(boot(dir))
    end

    test "a leftover card is swept, so the warning cannot get stuck on", %{dir: dir} do
      write_card!(dir, dead_os_process())

      boot(dir)

      assert eventually(fn -> length(File.ls!(dir)) == 1 end)
    end

    @tag :capture_log
    test "the VM that started EARLIER is the first one — that is the real server", %{dir: dir} do
      write_card!(dir, live_os_process(), started_at: 1)

      assert %{first?: false} = Presence.status(boot(dir, started_at: 2))
    end

    test "a VM that cannot read the directory warns about nobody rather than crashing", %{
      dir: dir
    } do
      assert %{others: [], first?: true} = Presence.status(boot(Path.join(dir, "no/such/place")))
    end
  end

  # The whole point of choosing detection over a lock: this can annoy, never block.
  describe "it cannot stop anything" do
    @tag :capture_log
    test "the actuation floor is untouched — no third flag, nothing shut", %{dir: dir} do
      before = Pokex.Bots.InputGate.state()

      presence = boot(dir, port: 4013)
      write_card!(dir, live_os_process())
      assert sweep(presence).others != []

      assert Pokex.Bots.InputGate.state() == before
      assert Pokex.Bots.InputGate.allowed?()
    end
  end

  defp eventually(fun, tries \\ 40) do
    Enum.reduce_while(1..tries, false, fn _try, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end
end
