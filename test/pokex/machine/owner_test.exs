defmodule Pokex.Machine.OwnerTest do
  # Touches the app-global InputGate and Rig.Fake — never async.
  use ExUnit.Case, async: false

  alias Pokex.Bots.Body
  alias Pokex.Bots.InputGate
  alias Pokex.Machine.Owner
  alias Pokex.Rig.Fake

  setup do
    dir = Path.join(System.tmp_dir!(), "pokex-owner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    lock = Path.join(dir, "owner.lock")

    on_exit(fn ->
      File.rm_rf(dir)
      # the suite's steady state: the gate open on all flags
      InputGate.set_owner_ok(true)
    end)

    {:ok, lock: lock}
  end

  # A REAL foreign OS process, so "the other VM is alive" is not a mock: the
  # liveness check runs against a pid the kernel really holds.
  defp live_os_process do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["300"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true) end)
    os_pid
  end

  defp write_lock!(path, os_pid, port \\ 4004) do
    File.write!(path, JSON.encode!(%{os_pid: os_pid, port: port, at: 0}))
  end

  # Boots one VM's Owner. Isolated by construction: its own lock path, its own name, and a gate
  # writer that collects instead of touching the global ETS. `auto_start` is explicit because
  # the suite disables the app-wide poll (:machine_owner_auto).
  defp boot_owner(lock, opts \\ []) do
    test = self()

    {:ok, pid} =
      Owner.start_link(
        [
          name: nil,
          auto_start: true,
          lock_path: lock,
          gate_fun: fn ok? -> send(test, {:gate, ok?}) end,
          poll_ms: 50
        ] ++ opts
      )

    pid
  end

  describe "acquiring the machine" do
    test "a VM with no lock present becomes the owner and records its own pid", %{lock: lock} do
      pid = boot_owner(lock)

      assert Owner.status(pid).owner? == true
      assert_receive {:gate, true}

      assert %{"os_pid" => os_pid} = lock |> File.read!() |> JSON.decode!()
      assert to_string(os_pid) == System.pid()
    end

    test "a lock held by a LIVE process makes this VM an observer", %{lock: lock} do
      write_lock!(lock, live_os_process())

      pid = boot_owner(lock)

      assert Owner.status(pid).owner? == false
      assert_receive {:gate, false}
    end

    test "an observer never overwrites the live owner's lock", %{lock: lock} do
      alien = live_os_process()
      write_lock!(lock, alien)

      boot_owner(lock)

      assert %{"os_pid" => ^alien} = lock |> File.read!() |> JSON.decode!()
    end

    test "the observer reports WHO holds the machine, for the on-screen warning", %{lock: lock} do
      alien = live_os_process()
      write_lock!(lock, alien, 4004)

      pid = boot_owner(lock)

      assert %{owner?: false, holder: %{os_pid: ^alien, port: 4004}} = Owner.status(pid)
    end

    test "a lock left behind by a DEAD process is stale — the next VM takes it", %{lock: lock} do
      # a pid that really is gone: spawn it, kill it, and wait for the kernel to stop
      # answering for it — the same question the Owner asks
      dead = live_os_process()
      System.cmd("kill", ["-9", to_string(dead)], stderr_to_stdout: true)

      assert eventually(fn ->
               {_out, status} =
                 System.cmd("kill", ["-0", to_string(dead)], stderr_to_stdout: true)

               status != 0
             end)

      write_lock!(lock, dead)

      pid = boot_owner(lock)

      assert Owner.status(pid).owner? == true
      assert_receive {:gate, true}
    end
  end

  describe "two VMs on one machine" do
    # Two VMs differ by OS pid, so the simulated pair gets its own pids (and a liveness reader
    # that answers for them) rather than sharing this test process's real one.
    defp boot_vm(lock, os_pid, live, opts \\ []) do
      boot_owner(lock, [os_pid: os_pid, alive_fun: fn pid -> pid in live end] ++ opts)
    end

    test "the first owns and the second observes", %{lock: lock} do
      first = boot_vm(lock, 900_001, [900_001])
      second = boot_vm(lock, 900_002, [900_001])

      assert Owner.status(first).owner? == true
      assert Owner.status(second).owner? == false
    end

    test "the second VM promotes itself once the first releases the machine", %{lock: lock} do
      first = boot_vm(lock, 900_001, [900_001])
      second = boot_vm(lock, 900_002, [900_001])
      assert Owner.status(second).owner? == false

      # the first server shuts down cleanly — its lock must not outlive it
      GenServer.stop(first)

      assert eventually(fn -> Owner.status(second).owner? == true end)
    end
  end

  describe "the actuation floor" do
    test "an observer VM cannot act: the gate is shut and the Body refuses out loud" do
      Fake.start_link()
      InputGate.set_owner_ok(false)

      refute InputGate.allowed?()
      assert {:error, :input_gate_closed} = Body.arrow_step(1, 0)
      assert Fake.calls() == []
    end

    test "allowed? is the AND of all three guards" do
      InputGate.set_corner_ok(true)
      InputGate.set_focus_ok(true)
      InputGate.set_owner_ok(true)
      assert InputGate.allowed?()

      InputGate.set_owner_ok(false)
      refute InputGate.allowed?()
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
