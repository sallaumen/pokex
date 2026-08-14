defmodule Pokex.Bots.ShinyGuardTest do
  # async: false — stashes global Settings
  use ExUnit.Case, async: false

  alias Pokex.Bots.InputGate
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.{Settings, SettingsStash}

  setup %{tmp_dir: tmp} do
    # the trophy shelf writes under the Pokex home — keep it out of the real one
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    SettingsStash.stash!(
      shiny_guard_enabled: true,
      shiny_confirm_ms: 40,
      shiny_action: "alarm"
    )

    test = self()
    escape_fun = fn reason -> send(test, {:escaped, reason}) end

    {:ok, guard} = ShinyGuard.start_link(name: nil, active: true, escape_fun: escape_fun)
    %{guard: guard}
  end

  # what Interpret.battle publishes: which rows carry the gold star + the best
  # cluster score seen
  defp shiny_obs(px \\ 40),
    do: %{enemies: [0], red: [0, 0], locked?: false, shiny_rows: [1], shiny_star_run: px}

  defp clean_obs,
    do: %{enemies: [0], red: [0, 0], locked?: false, shiny_rows: [], shiny_star_run: 0}

  # Deliver EXACTLY like the Feed does — a PubSub broadcast on the world topic.
  # The live-sighting bug shipped because tests sent messages straight to the
  # process: an unsubscribed guard passed every test while deaf in production.
  defp world_broadcast(obs) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Perception.topic(),
      {:world, :battle, obs}
    )
  end

  # The feed dedupes: a calm list with a shiny broadcasts ONCE — one message must be
  # enough once the confirm window passes clean.
  @tag :tmp_dir
  @tag :capture_log
  test "a sighting not refuted within the confirm window fires the alarm once", %{
    guard: guard
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    world_broadcast(shiny_obs())

    assert_receive {:rule_alarm, :shiny, reason}, 500
    assert reason =~ "SHINY na lista de batalha"
    assert reason =~ "LUTA"

    world_broadcast(shiny_obs())
    refute_receive {:rule_alarm, _, _}, 150
    _ = ShinyGuard.status(guard)
  end

  # The old bug wrote star_run:, a key record/1 never read — every trophy lost the star
  # measurement.
  @tag :tmp_dir
  @tag :capture_log
  test "the alarm names WHICH shiny it is, and the trophy records the star (star_px)", %{
    guard: guard
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    obs =
      shiny_obs()
      |> Map.put(:enemies_detail, [
        %{row: 0, name: "Wigglytuff", hp_pct: 90, shiny?: false},
        %{row: 1, name: "Golduck", hp_pct: 100, shiny?: true}
      ])

    world_broadcast(obs)

    assert_receive {:rule_alarm, :shiny, reason}, 500
    assert reason =~ "SHINY Golduck"

    assert [trofeu | _] = ShinyLog.entries()
    assert trofeu.star_px == 40
    assert trofeu.note =~ "Golduck"
    _ = ShinyGuard.status(guard)
  end

  @tag :tmp_dir
  test "a clean frame inside the window refutes the sighting (real debounce)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    world_broadcast(shiny_obs())
    world_broadcast(clean_obs())

    refute_receive {:rule_alarm, _, _}, 200
    _ = ShinyGuard.status(guard)
  end

  @tag :tmp_dir
  test "a disabled guard ignores battle observations (combat also attaches the feed)", %{
    guard: guard
  } do
    Settings.put(:shiny_guard_enabled, false)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    world_broadcast(shiny_obs())

    refute_receive {:rule_alarm, _, _}, 200
    _ = ShinyGuard.status(guard)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "action fugir triggers the injected escape protocol", %{guard: _guard} do
    Settings.put(:shiny_action, "escape")

    world_broadcast(shiny_obs(77))

    assert_receive {:escaped, reason}, 500
    assert reason =~ "estrela 77px"
  end

  @tag :tmp_dir
  test "status exposes the guard's state", %{guard: guard} do
    status = ShinyGuard.status(guard)
    assert %{enabled?: _, attached?: false, pending?: false, star_min_columns: _} = status
  end

  @tag :tmp_dir
  test "broadcasts the live reading to the panel meter (throttled)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    world_broadcast(clean_obs())
    assert_receive {:shiny_reading, %{star_run: 0, min_px: _}}, 500

    world_broadcast(clean_obs())
    refute_receive {:shiny_reading, _}, 100
    _ = ShinyGuard.status(guard)
  end

  describe "stop in force (latch set)" do
    setup do
      on_exit(fn -> InputGate.set_panic_latch(false) end)
      :ok
    end

    @tag :tmp_dir
    @tag :capture_log
    test "with the latch set and action fugir, it does not flee" do
      SettingsStash.stash!(shiny_action: "escape")
      InputGate.set_panic_latch(true)

      world_broadcast(shiny_obs())

      refute_receive {:escaped, _}, 500
    end

    @tag :tmp_dir
    @tag :capture_log
    test "with the latch set, the alarm still goes out" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")
      SettingsStash.stash!(shiny_action: "escape")
      InputGate.set_panic_latch(true)

      world_broadcast(shiny_obs())

      assert_receive {:rule_alarm, :shiny, reason}, 1_000
      assert reason =~ "SHINY na lista de batalha"
      assert reason =~ "decida você"
    end

    @tag :tmp_dir
    @tag :capture_log
    test "with the latch free and action fugir, it flees — no regression" do
      SettingsStash.stash!(shiny_action: "escape")
      InputGate.set_panic_latch(false)

      world_broadcast(shiny_obs())

      assert_receive {:escaped, reason}, 1_000
      assert reason =~ "SHINY na lista de batalha"
    end
  end
end
