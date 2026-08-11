defmodule Pokex.Timers.ScheduleTest do
  @moduledoc """
  Which scheduled actions are due.

  The two shapes he named are the same machine: "8 segundos depois de começar a
  mobar" and "berries (…) a cada 55 minutos" (2026-08-11).
  """
  use ExUnit.Case, async: true

  alias Pokex.Timers.{Schedule, Timer}

  defp aura(after_ms \\ 8_000) do
    %Timer{
      id: "aura-na-mobada",
      name: "aura na mobada",
      trigger: :after_mob,
      after_ms: after_ms,
      category: :buffs
    }
  end

  defp berry(after_ms \\ 3_300_000) do
    %Timer{
      id: "berry",
      name: "berry de XP",
      trigger: :every,
      after_ms: after_ms,
      keys: ["8"]
    }
  end

  defp clocks(overrides),
    do: Map.merge(%{now: 0, started_at: 0, mob_at: nil, last_fired: %{}}, overrides)

  describe "a berry every so often" do
    test "it does not go off the instant the bot starts — it counts from the start" do
      refute Schedule.due?(berry(), clocks(%{now: 0}))
      refute Schedule.due?(berry(), clocks(%{now: 3_299_999}))
      assert Schedule.due?(berry(), clocks(%{now: 3_300_000}))
    end

    test "after it fires, the clock is its own last firing" do
      after_first = clocks(%{now: 3_400_000, last_fired: %{"berry" => 3_300_000}})

      refute Schedule.due?(berry(), after_first)
      assert Schedule.due?(berry(), %{after_first | now: 6_600_000})
    end

    # A bot left running overnight must not owe forty berries at once.
    test "a long silence still owes exactly ONE firing, not a backlog" do
      overdue = clocks(%{now: 100_000_000, last_fired: %{"berry" => 0}})

      assert Schedule.due([berry()], overdue) == [berry()]
    end
  end

  describe "the aura, so long after the mob stretch starts" do
    test "outside a stretch it is not late — it is not counting at all" do
      refute Schedule.due?(aura(), clocks(%{now: 999_999, mob_at: nil}))
      assert Schedule.remaining(aura(), clocks(%{now: 999_999, mob_at: nil})) == nil
    end

    test "it goes off exactly the configured way into the stretch" do
      refute Schedule.due?(aura(), clocks(%{now: 7_999, mob_at: 0}))
      assert Schedule.due?(aura(), clocks(%{now: 8_000, mob_at: 0}))
    end

    # The rule that makes it once-per-stretch rather than once-per-tick.
    test "having fired in THIS stretch, it stops answering" do
      fired = clocks(%{now: 9_000, mob_at: 0, last_fired: %{"aura-na-mobada" => 8_000}})

      refute Schedule.due?(aura(), fired)
      assert Schedule.remaining(aura(), fired) == nil
    end

    # A firing from the PREVIOUS stretch must not silence the next one, which
    # is why the stamp is compared against the stretch and not counted.
    test "the next stretch gets its own firing" do
      next = clocks(%{now: 60_000, mob_at: 52_000, last_fired: %{"aura-na-mobada" => 8_000}})

      refute Schedule.due?(aura(), %{next | now: 55_000})
      assert Schedule.due?(aura(), next)
    end
  end

  describe "what never fires" do
    test "a disabled timer is not due and has no countdown" do
      off = %{berry() | enabled?: false}

      refute Schedule.due?(off, clocks(%{now: 100_000_000}))
      assert Schedule.remaining(off, clocks(%{now: 100_000_000})) == nil
    end
  end

  describe "the countdown the panel shows" do
    test "it counts down, and goes negative when overdue instead of clamping" do
      assert Schedule.remaining(berry(60_000), clocks(%{now: 20_000})) == 40_000
      assert Schedule.remaining(berry(60_000), clocks(%{now: 90_000})) == -30_000
    end

    test "the aura's countdown runs from the start of the stretch" do
      assert Schedule.remaining(aura(), clocks(%{now: 3_000, mob_at: 0})) == 5_000
    end
  end

  describe "two of them at once" do
    test "both fire on the same tick, in the order they are listed" do
      both = clocks(%{now: 3_300_000, mob_at: 3_299_000})

      assert Schedule.due([berry(), aura(1_000)], both) == [berry(), aura(1_000)]
    end

    test "each keeps its OWN stamp" do
      last = Schedule.fired(%{}, berry(), 100)
      last = Schedule.fired(last, aura(), 200)

      assert last == %{"berry" => 100, "aura-na-mobada" => 200}
    end
  end
end
