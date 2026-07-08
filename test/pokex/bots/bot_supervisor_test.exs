defmodule Pokex.Bots.BotSupervisorTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.{Calibration, Settings}

  @fast %{
    wait_focus_ms: 5,
    wait_after_equip_ms: 5,
    wait_cast_settle_ms: 5,
    wait_assess_ms: 5,
    tick_ms_watching: 20,
    tick_ms_fighting: 20,
    tick_ms_default: 20,
    watch_dead_streak_needed: 1000,
    watch_timeout_ms: 30_000,
    calm_streak_needed: 1,
    glow_streak_needed: 1,
    glow_threshold: 500,
    max_consecutive_failures: 5,
    tile_px: 32,
    walk_step_ms: 5,
    wait_loot_ms: 5,
    wait_after_capture_ms: 5,
    humanize_max_ms: 0,
    cast_delay_max_ms: 0,
    hook_delay_min_ms: 0,
    hook_delay_max_ms: 0
  }

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(Settings.defaults(), fn {k, v} -> Settings.put(k, v) end)
    end)

    Enum.each(@fast, fn {k, v} -> Settings.put(k, v) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {368, 268, 64, 64},
      battle_region: {700, 100, 260, 200},
      arena_region: {200, 100, 400, 400},
      neutral_point: {420, 350}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link()

    # glow never crosses threshold (stays "watching" forever, never idles) and the Battle list
    # has no candidate (combat stays in :scanning, idle-scanning) — so both workers report a
    # stable non-idle state right after start_all/0, instead of racing a full cycle to :idle.
    {:ok, _} =
      Sensors.Fake.start_link(%{
        glow: [50],
        battle: [%{enemies: [], red: [0, 0, 0, 0, 0, 0]}],
        hostile: [{410, 320}]
      })

    :ok
  end

  # Every test starts its own BotSupervisor under private names — the real
  # one from Pokex.Application is already running (under the default
  # module-name registrations) for the lifetime of the test suite, so
  # reusing those names here would collide with it.
  defp start_isolated_supervisor(tag) do
    body = :"#{tag}_body"
    guardian = :"#{tag}_guardian"
    fishing = :"#{tag}_fishing"
    combat = :"#{tag}_combat"

    start_supervised!(
      {BotSupervisor, name: nil, body: body, guardian: guardian, fishing: fishing, combat: combat}
    )

    {fishing, combat}
  end

  @tag :tmp_dir
  test "start_all/0 runs both workers, reflected in status/0" do
    {fishing, combat} = start_isolated_supervisor(:start_all_test)

    assert :ok = BotSupervisor.start_all(fishing, combat)

    status = BotSupervisor.status(fishing, combat)
    assert status.fishing.state != :idle
    assert status.combat.state != :idle
  end

  @tag :tmp_dir
  test "stop_all/0 idles both workers and is idempotent on a second call" do
    {fishing, combat} = start_isolated_supervisor(:stop_all_test)

    assert :ok = BotSupervisor.start_all(fishing, combat)
    assert :ok = BotSupervisor.stop_all(fishing, combat)

    status = BotSupervisor.status(fishing, combat)
    assert status.fishing.state == :idle
    assert status.combat.state == :idle

    # A second stop_all/0 while already idle must be a safe no-op — this is
    # exactly what the Guardian does on every poll tick while the cursor
    # sits in the panic corner.
    assert :ok = BotSupervisor.stop_all(fishing, combat)

    status = BotSupervisor.status(fishing, combat)
    assert status.fishing.state == :idle
    assert status.combat.state == :idle
  end

  @tag :tmp_dir
  test "start_all/0 surfaces a preflight/calibration error instead of starting either worker" do
    File.rm!(Pokex.Home.calibration_file())

    {fishing, combat} = start_isolated_supervisor(:error_test)

    assert {:error, [msg]} = BotSupervisor.start_all(fishing, combat)
    assert msg =~ "calibração"

    status = BotSupervisor.status(fishing, combat)
    assert status.fishing.state == :idle
    assert status.combat.state == :idle
  end
end
