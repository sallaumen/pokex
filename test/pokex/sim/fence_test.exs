defmodule Pokex.Sim.FenceTest do
  use ExUnit.Case, async: false

  alias Pokex.Sim.Fence

  @env_keys [:rig, :perception_feeds_active, :journal_persist]

  setup do
    saved = Map.new(@env_keys, fn key -> {key, Application.get_env(:pokex, key)} end)
    test = self()

    on_exit(fn ->
      :persistent_term.erase({Fence, :arm_state})
      Enum.each(saved, &put_env/1)
    end)

    stop_all = fn reason ->
      send(test, {:stopped, reason, Pokex.Rig.impl()})
      :ok
    end

    %{original: saved.rig, stop_all: stop_all}
  end

  defp put_env({key, nil}), do: Application.delete_env(:pokex, key)
  defp put_env({key, value}), do: Application.put_env(:pokex, key, value)

  defp start_fence(ctx, opts \\ []) do
    running = Keyword.get(opts, :running, [])

    start_supervised!(
      {Fence, name: nil, status: fn -> status_of(running) end, stop_all: ctx.stop_all},
      id: Keyword.get(opts, :id, :fence)
    )
  end

  defp status_of(running) do
    Map.new([:fishing, :combat, :catcher, :mini_game, :player_support, :cavebot], fn name ->
      {name, %{state: if(name in running, do: :walking, else: :idle)}}
    end)
  end

  test "arming swaps the hands for the simulated rig", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Pokex.Rig.impl() == Pokex.Rig.Sim
  end

  test "arming turns the perception feeds off", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Application.get_env(:pokex, :perception_feeds_active) == false
  end

  test "arming keeps the simulation out of the journal on disk", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Application.get_env(:pokex, :journal_persist) == false
  end

  test "arming refuses while a worker is running, naming it", ctx do
    fence = start_fence(ctx, running: [:cavebot])

    assert Fence.arm(fence) == {:error, [:cavebot]}
    refute Fence.armed?()
  end

  test "arming refuses without touching the hands", ctx do
    fence = start_fence(ctx, running: [:combat])
    before = Pokex.Rig.impl()

    assert {:error, _names} = Fence.arm(fence)
    assert Pokex.Rig.impl() == before
  end

  test "arming never stops a running fleet on its own", ctx do
    fence = start_fence(ctx, running: [:cavebot])

    assert {:error, _names} = Fence.arm(fence)
    refute_receive {:stopped, _reason, _rig}
  end

  test "armed? answers without asking the process", ctx do
    fence = start_fence(ctx)
    refute Fence.armed?()

    assert Fence.arm(fence) == :ok
    assert Fence.armed?()
  end

  test "disarming gives the real hands back", ctx do
    fence = start_fence(ctx)
    assert Fence.arm(fence) == :ok

    assert Fence.disarm(fence) == :ok
    assert Application.get_env(:pokex, :rig) == ctx.original
    refute Fence.armed?()
  end

  test "disarming stops the fleet before the real hands come back", ctx do
    fence = start_fence(ctx)
    assert Fence.arm(fence) == :ok

    assert Fence.disarm(fence) == :ok

    assert_receive {:stopped, "simulação desarmada", Pokex.Rig.Sim}
    assert Application.get_env(:pokex, :rig) == ctx.original
  end

  test "arming twice is a no-op rather than a second swap", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Fence.arm(fence) == :ok
    assert Fence.disarm(fence) == :ok
    assert Application.get_env(:pokex, :rig) == ctx.original
  end

  test "disarming an unarmed fence touches nothing", ctx do
    fence = start_fence(ctx)

    assert Fence.disarm(fence) == :ok
    refute_receive {:stopped, _reason, _rig}
    assert Application.get_env(:pokex, :rig) == ctx.original
  end

  @tag :capture_log
  test "a fence killed while armed leaves the next one to stop the fleet first", ctx do
    {:ok, fence} =
      Fence.start_link(name: nil, status: fn -> status_of([]) end, stop_all: ctx.stop_all)

    Process.unlink(fence)
    assert Fence.arm(fence) == :ok
    assert Pokex.Rig.impl() == Pokex.Rig.Sim

    ref = Process.monitor(fence)
    Process.exit(fence, :kill)
    assert_receive {:DOWN, ^ref, :process, ^fence, :killed}
    assert Fence.armed?()

    revived = start_fence(ctx, id: :revived)

    assert_receive {:stopped, _reason, Pokex.Rig.Sim}

    :sys.get_state(revived)

    refute Fence.armed?()
    assert Application.get_env(:pokex, :rig) == ctx.original
  end
end
