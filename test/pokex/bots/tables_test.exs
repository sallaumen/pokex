defmodule Pokex.Bots.TablesTest do
  @moduledoc """
  The bot's memory belongs to the application, not to whoever pressed first.

  CI on 2026-09-02: `SkillClock.reset/0` found its table gone between
  `ensure_table` and `delete_all_objects` — the test process that had lazily
  created it had just exited, and an ETS table dies with its owner.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.{ReviveLedger, SkillClock, SkillTruth, Tables}

  test "the three tables are owned by the application, not by a caller" do
    owner = Process.whereis(Tables)
    assert is_pid(owner)

    for table <- [SkillClock.table(), SkillTruth.table(), ReviveLedger.table()] do
      assert :ets.info(table, :owner) == owner, "#{table} pertence a outro processo"
    end
  end

  test "a caller dying takes nothing with it" do
    parent = self()

    spawn(fn ->
      SkillClock.pressed("3")
      send(parent, :pressed)
    end)

    assert_receive :pressed, 1_000
    Process.sleep(20)

    assert :ets.whereis(SkillClock.table()) != :undefined
    assert :ok = SkillClock.reset()
  end
end
