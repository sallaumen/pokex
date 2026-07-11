defmodule Pokex.Rig.Mac.OsaBusTest do
  use ExUnit.Case, async: false

  alias Pokex.Rig.Mac.OsaBus

  test "commands run one at a time (serialized), results intact" do
    # two 120ms commands fired concurrently: serialized they take >= 240ms end to end
    started = System.monotonic_time(:millisecond)

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> OsaBus.run({"sleep", ["0.12"]}) end)
      end

    results = Task.await_many(tasks, 5_000)
    elapsed = System.monotonic_time(:millisecond) - started

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert elapsed >= 240
  end

  test "a dead bus fails open — the command still runs directly" do
    assert {:ok, out} = OsaBus.run({"echo", ["ainda-rodo"]}, :no_such_bus)
    assert out =~ "ainda-rodo"
  end

  test "a failing command reports the exit" do
    assert {:error, {"false", _code, _out}} = OsaBus.run({"false", []})
  end
end
