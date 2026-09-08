defmodule Pokex.Bots.WatchmanTest do
  @moduledoc """
  The watchman: while the bot hunts, samples the readings every second, judges
  every ten, rings on a new problem and again every minute while it lasts,
  says once when a reading comes back, and judges nothing with the game out
  of focus or the bot off.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Watchman
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash!(
      watchman_enabled: true,
      watchman_grace_ms: 8_000,
      watchman_repeat_ms: 60_000,
      watchman_every_ms: 10_000,
      watchman_sample_ms: 1_000,
      watchman_stale_ms: 12_000
    )

    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")
    Phoenix.PubSub.subscribe(Pokex.PubSub, "engine")

    {:ok, world} =
      Agent.start_link(fn ->
        %{active: true, focused: true, problems: [], readings: %{}, now: 100_000, seen: []}
      end)

    watchman =
      start_supervised!(
        {Watchman,
         name: nil,
         auto_start: false,
         active?: fn -> Agent.get(world, & &1.active) end,
         focused?: fn -> Agent.get(world, & &1.focused) end,
         readings: fn _now -> Agent.get(world, & &1.readings) end,
         checks: fn now, last_good ->
           Agent.update(world, &%{&1 | seen: [{now, last_good} | &1.seen]})
           Agent.get(world, & &1.problems)
         end,
         clock: fn -> Agent.get(world, & &1.now) end}
      )

    %{watchman: watchman, world: world}
  end

  defp set(world, changes), do: Agent.update(world, &Map.merge(&1, changes))

  # One judgement of the clock, then a call so it has been handled.
  defp tick(watchman) do
    send(watchman, :check)
    Watchman.problems(watchman)
  end

  # One sample of the clock.
  defp sample(watchman) do
    send(watchman, :sample)
    Watchman.problems(watchman)
  end

  defp advance(world, ms), do: Agent.update(world, &%{&1 | now: &1.now + ms})

  @bar {:skill_bar, "a barra de skills do Torterra não é reconhecida — recalibre"}
  @life {:player, "a vida do PERSONAGEM não é lida — recalibre"}

  test "the first check waits the grace, then a problem rings at once", %{
    watchman: w,
    world: world
  } do
    set(world, %{problems: [@bar]})

    assert tick(w) == []
    refute_receive {:rule_alarm, :setup, _}, 50

    advance(world, 5_000)
    assert tick(w) == []
    refute_receive {:rule_alarm, :setup, _}, 50

    advance(world, 5_000)
    assert tick(w) == [elem(@bar, 1)]
    assert_receive {:rule_alarm, :setup, text}
    assert text =~ "🩺 vigia: a barra de skills do Torterra"
  end

  describe "with the bot running past the grace" do
    setup %{watchman: w, world: world} do
      tick(w)
      advance(world, 10_000)
      :ok
    end

    test "the same problem rings again only after the repeat", %{watchman: w, world: world} do
      set(world, %{problems: [@bar]})
      tick(w)
      assert_receive {:rule_alarm, :setup, _}

      advance(world, 30_000)
      tick(w)
      refute_receive {:rule_alarm, :setup, _}, 50

      advance(world, 30_000)
      tick(w)
      assert_receive {:rule_alarm, :setup, _}
    end

    test "a new problem rings at once, with every standing problem in the line", %{
      watchman: w,
      world: world
    } do
      set(world, %{problems: [@bar]})
      tick(w)
      assert_receive {:rule_alarm, :setup, _}

      advance(world, 10_000)
      set(world, %{problems: [@bar, @life]})
      assert tick(w) == [elem(@life, 1), elem(@bar, 1)]
      assert_receive {:rule_alarm, :setup, text}
      assert text =~ "vida do PERSONAGEM"
      assert text =~ "barra de skills"
    end

    test "a reading that comes back is said once in the feed, without a ring", %{
      watchman: w,
      world: world
    } do
      set(world, %{problems: [@bar]})
      tick(w)
      assert_receive {:rule_alarm, :setup, _}

      advance(world, 10_000)
      set(world, %{problems: []})
      assert tick(w) == []

      assert_receive {:engine_log, :macro,
                      "✅ vigia: voltou — a barra de skills do Torterra não é reconhecida"}

      refute_receive {:rule_alarm, :setup, _}, 50

      advance(world, 10_000)
      tick(w)
      refute_receive {:engine_log, :macro, _}, 50
    end

    test "with the game out of focus nothing is judged", %{watchman: w, world: world} do
      set(world, %{problems: [@bar], focused: false})
      assert tick(w) == []
      refute_receive {:rule_alarm, :setup, _}, 50

      set(world, %{focused: true})
      tick(w)
      assert_receive {:rule_alarm, :setup, _}
    end

    test "the switch off keeps it quiet", %{watchman: w, world: world} do
      SettingsStash.stash!(watchman_enabled: false)
      set(world, %{problems: [@bar]})
      assert tick(w) == []
      refute_receive {:rule_alarm, :setup, _}, 50
    end

    # THE SAMPLER'S MEMORY (2026-09-08): a check that looked at the current
    # frame alone rang seven times in forty minutes, each time inside the two
    # seconds the revive keeps the bar off the screen.
    test "the judgement receives when each reading was last good", %{watchman: w, world: world} do
      set(world, %{readings: %{skill_bar: true, battle: true}})
      sample(w)
      advance(world, 1_000)
      set(world, %{readings: %{skill_bar: false, battle: true}})
      sample(w)
      advance(world, 1_000)
      sample(w)
      advance(world, 8_000)
      tick(w)

      [{judged_at, last_good} | _] = Agent.get(world, & &1.seen)
      assert judged_at == Agent.get(world, & &1.now)
      # the bar was last good at the first sample, ten seconds ago; the battle two seconds ago
      assert last_good.battle == judged_at - 8_000
      assert last_good.skill_bar == judged_at - 10_000
    end

    test "out of focus, nothing is sampled either", %{watchman: w, world: world} do
      set(world, %{readings: %{skill_bar: true}, focused: false})
      sample(w)
      set(world, %{focused: true})
      advance(world, 10_000)
      tick(w)

      [{_at, last_good} | _] = Agent.get(world, & &1.seen)
      # the bar's memory is the start of the watch, never the unfocused sample
      assert last_good.skill_bar == 100_000
    end
  end

  test "stopping the bot forgets everything, and the next start shouts again", %{
    watchman: w,
    world: world
  } do
    set(world, %{problems: [@bar]})
    tick(w)
    advance(world, 10_000)
    tick(w)
    assert_receive {:rule_alarm, :setup, _}

    set(world, %{active: false})
    assert tick(w) == []

    set(world, %{active: true})
    tick(w)
    refute_receive {:rule_alarm, :setup, _}, 50
    advance(world, 10_000)
    tick(w)
    assert_receive {:rule_alarm, :setup, _}
  end

  test "the watch starts with every reading counted good now", %{watchman: w, world: world} do
    tick(w)
    advance(world, 10_000)
    tick(w)

    [{_at, last_good} | _] = Agent.get(world, & &1.seen)
    assert Map.keys(last_good) |> Enum.sort() == [:battle, :player, :pokemon, :skill_bar]
    assert Enum.all?(Map.values(last_good), &(&1 == 100_000))
  end

  test "check_now samples and judges, grace or not", %{watchman: w, world: world} do
    set(world, %{problems: [@bar]})
    assert Watchman.check_now(w) == [elem(@bar, 1)]
    assert_receive {:rule_alarm, :setup, _}
  end

  test "a check that raises does not take the watchman down", %{world: world} do
    watchman =
      start_supervised!(
        {Watchman,
         name: nil,
         auto_start: false,
         active?: fn -> true end,
         focused?: fn -> true end,
         readings: fn _now -> raise "sem chão" end,
         checks: fn _now, _last_good -> raise "sem chão" end,
         clock: fn -> Agent.get(world, & &1.now) end},
        id: :broken_watchman
      )

    tick(watchman)
    advance(world, 10_000)
    sample(watchman)
    send(watchman, :check)
    assert Process.alive?(watchman)
  end
end
