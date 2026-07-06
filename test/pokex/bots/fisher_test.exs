defmodule Pokex.Bots.FisherTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Fisher
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.{Calibration, Settings}

  @fast %{
    tick_ms_watching: 20,
    tick_ms_fighting: 20,
    tick_ms_default: 20,
    wait_focus_ms: 5,
    wait_after_equip_ms: 5,
    wait_assess_ms: 5,
    wait_loot_ms: 5,
    wait_after_capture_ms: 5,
    glow_streak_needed: 1,
    wait_target_verify_ms: 5,
    target_lock_streak: 1,
    humanize_max_ms: 0
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

    {:ok, _} =
      Sensors.Fake.start_link(%{
        glow: [false, true],
        wild: [true, true, true, false],
        target_locked: [100],
        hostile: [{410, 320}]
      })

    fisher = start_supervised!({Fisher, name: nil})
    %{fisher: fisher}
  end

  @tag :tmp_dir
  test "runs the full cycle: fish, fight, loot, capture", %{fisher: fisher} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Fisher.topic())

    assert :ok = Fisher.start_bot(fisher)
    assert_receive {:fisher, %{counters: %{captures: 1}}}, 5_000

    calls = Pokex.Rig.Fake.calls()
    assert {:press, "shift+z"} in calls
    assert {:click, :left, {400, 300}} in calls
    assert {:click, :left, {786, 118}} in calls
    assert {:press, "1"} in calls
    assert {:click, :right, {410, 352}} in calls
    assert {:capture_sequence, {410, 352}} in calls

    assert :ok = Fisher.stop_bot(fisher)
    assert Fisher.status(fisher).state == :idle
  end

  @tag :tmp_dir
  test "start_bot without calibration returns preflight errors", %{fisher: fisher} do
    File.rm!(Pokex.Home.calibration_file())
    assert {:error, [msg]} = Fisher.start_bot(fisher)
    assert msg =~ "calibração"
  end
end
