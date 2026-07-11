defmodule Pokex.Bots.MiniGame.PilotTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.MiniGame.Pilot

  # Mirror of the lab's validated scratch asserts (assets/js/fishing_pilot.js),
  # in track-normalized units: lab px ÷ 548 (track 76..624). The lab scenario
  # constants convert as: y 400 → 0.5912, 340 → 0.4818, 320 → 0.4453,
  # 300 → 0.4088, deadband 13px → 0.0237.
  @reactive %{pilot: :reactive, deadband_pct: 0.0237}
  @predictive %{pilot: :predictive, deadband_pct: 0.0237}
  @now 10_000

  defp bar(y, vy \\ 0.0, pressing \\ false), do: %{y: y, vy: vy, pressing: pressing}

  test "no observations -> released, no target" do
    assert Pilot.decide(@reactive, [], bar(0.59), @now) ==
             %{desired: false, target_y: nil, age_ms: nil}
  end

  test "stale newest observation (>1500ms) -> released even with a far target" do
    result = Pilot.decide(@reactive, [%{y: 0.1, at: @now - 1600}], bar(0.59), @now)
    assert result.desired == false
    assert result.age_ms == 1600
    assert_in_delta result.target_y, 0.1, 0.001
  end

  test "exactly 1500ms old still acts (strict >)" do
    result = Pilot.decide(@reactive, [%{y: 0.1, at: @now - 1500}], bar(0.59), @now)
    assert result.desired == true
  end

  test "reactive: bar far below a fresh target -> press" do
    result = Pilot.decide(@reactive, [%{y: 0.4088, at: @now}], bar(0.5912), @now)
    assert result.desired == true
    assert_in_delta result.target_y, 0.4088, 0.0001
    assert result.age_ms == 0
  end

  test "reactive lead: fish rising -> target above the newest reading" do
    observations = [%{y: 0.4818, at: @now - 100}, %{y: 0.4453, at: @now}]
    result = Pilot.decide(@reactive, observations, bar(0.5912), @now)
    # vy = -0.365/s, lead = -0.0402 -> 0.4051 (lab: 298px)
    assert_in_delta result.target_y, 0.4051, 0.001
  end

  test "reactive hysteresis: inside the deadband nothing changes (stays pressing)" do
    result = Pilot.decide(@reactive, [%{y: 0.4453, at: @now}], bar(0.427, 0.0, true), @now)
    assert result.desired == true
  end

  test "reactive release: bar above target beyond the deadband" do
    result = Pilot.decide(@reactive, [%{y: 0.4453, at: @now}], bar(0.4088, 0.0, false), @now)
    assert result.desired == false
  end

  test "predictive: extrapolates past the newest reading in the motion direction" do
    observations = [%{y: 0.4818, at: @now - 250}, %{y: 0.4453, at: @now - 150}]
    result = Pilot.decide(@predictive, observations, bar(0.5912), @now)
    # decayed vy = -0.365 * 0.25^0.15 = -0.2965; predicted 0.4008; lead -0.0326 -> 0.3682
    assert_in_delta result.target_y, 0.3682, 0.002
    assert result.age_ms == 150
  end

  test "predictive: three observations blend the older pair 2:1" do
    observations = [
      %{y: 0.5182, at: @now - 350},
      %{y: 0.4818, at: @now - 250},
      %{y: 0.4453, at: @now - 150}
    ]

    result = Pilot.decide(@predictive, observations, bar(0.5912), @now)
    # both pairwise slopes equal here, so the blend matches the 2-obs case
    assert_in_delta result.target_y, 0.3682, 0.002
  end

  test "targets clamp to the track" do
    observations = [%{y: 0.0256, at: @now - 100}, %{y: 0.0073, at: @now}]
    result = Pilot.decide(@predictive, observations, bar(0.5912), @now)
    assert result.target_y >= 0.0
  end

  test "ghost velocity: a pre-gap slope must not steer the prediction" do
    observations = [
      %{y: 0.3358, at: @now - 10_200},
      %{y: 0.4088, at: @now - 10_100},
      %{y: 0.4453, at: @now - 100}
    ]

    result = Pilot.decide(@predictive, observations, bar(0.5912), @now)
    assert_in_delta result.target_y, 0.4453, 0.005
  end

  test "brakes on the PREDICTED bar position, not the stale reading" do
    config = Map.put(@reactive, :actuation_ms, 90)
    observations = [%{y: 0.5, at: @now}]

    # bar read 100ms ago at 0.46, falling at +0.30/s: by the time the command
    # lands it will be past the fish — press NOW to brake
    stale_bar = %{y: 0.46, vy: 0.30, pressing: false, at: @now - 100}
    assert Pilot.decide(config, observations, stale_bar, @now).desired == true

    # the same raw reading judged without prediction coasts into the overshoot
    raw_bar = %{y: 0.46, vy: 0.30, pressing: false}
    assert Pilot.decide(@reactive, observations, raw_bar, @now).desired == false
  end

  test "stopping-distance braking replaces the symmetric velocity overrides" do
    # bar rushing DOWN away from a fish above: even full thrust stops past the
    # fish -> press now
    result =
      Pilot.decide(@reactive, [%{y: 0.4453, at: @now}], bar(0.4553, 0.25, false), @now)

    assert result.desired == true

    # bar rushing UP with the fish just above: releasing now still coasts to
    # it (weak gravity) -> release
    result =
      Pilot.decide(@reactive, [%{y: 0.4453, at: @now}], bar(0.4353, -0.26, true), @now)

    assert result.desired == false
  end

  test "asymmetric braking: rising releases early, falling presses only at the fish" do
    fish = [%{y: 0.5, at: @now}]

    # rising fast toward a fish well above: the coast-out alone reaches it -> release
    assert Pilot.decide(@reactive, fish, bar(0.60, -0.5, true), @now).desired == false

    # falling toward a fish below: thrust stops almost instantly, so KEEP
    # falling well past where the old symmetric rule retreated ("recuava")
    assert Pilot.decide(@reactive, fish, bar(0.42, 0.30, false), @now).desired == false

    # ...and press exactly when the stop point reaches the fish
    assert Pilot.decide(@reactive, fish, bar(0.49, 0.30, false), @now).desired == true
  end
end
