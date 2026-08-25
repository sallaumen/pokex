defmodule Pokex.Sim.FleetTest do
  @moduledoc """
  The proof the whole undertaking exists for: the REAL engine, with not one line
  changed, deciding over a world that is not the game.

  It starts its OWN `Engine.Worker` rather than the app-global one — an isolated
  supervisor in a test must never arm the fleet the machine is running.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Bots.Engine
  alias Pokex.Perception.WorldState
  alias Pokex.Sim.Runner

  @facts [:battle, :pokemon, :skill_bar, :minimap, :situation, :orders, :hunt]

  defp route do
    %Route{
      name: "sim",
      waypoints:
        for {x, y, z, gather} <- [{100, 200, 5, nil}, {110, 200, 5, 2_000}] do
          %{
            x: x,
            y: y,
            z: z,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: nil,
            gather_ms: gather,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end

  setup do
    for key <- @facts, do: WorldState.forget(key)
    on_exit(fn -> for key <- @facts, do: WorldState.forget(key) end)

    counter = :counters.new(1, [])
    :counters.put(counter, 1, System.monotonic_time(:millisecond))

    runner =
      start_supervised!(
        {Runner,
         name: nil,
         tick_ms: 10,
         clock: fn -> :counters.get(counter, 1) end,
         route: route(),
         knobs: %{nest_size: 5, nest_radius: 1, screen_w: 199, screen_h: 199, ms_per_tile: 100}}
      )

    Runner.play(runner)
    Runner.tick_now(runner)

    engine = start_supervised!({Engine.Worker, name: nil, active: true}, id: :sim_engine)
    :ok = Engine.Worker.run(engine)

    %{runner: runner, engine: engine, advance: fn ms -> :counters.add(counter, 1, ms) end}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp wait_for_fact(key, tries \\ 200) do
    case WorldState.get(key, 10_000, now()) do
      {:ok, obs} ->
        obs

      _missing when tries > 0 ->
        Process.sleep(10)
        wait_for_fact(key, tries - 1)

      _missing ->
        flunk("the real engine never published #{key} from the fake world")
    end
  end

  @tag :tmp_dir
  @tag :capture_log
  test "the real engine counts the fake world's monsters" do
    picture = wait_for_fact(:situation)

    assert picture.enemies == 5
    refute picture.blind?
  end

  @tag :tmp_dir
  @tag :capture_log
  test "the real engine publishes orders carrying a reason in his own words" do
    orders = wait_for_fact(:orders)

    assert orders.route in [:go, :hold]
    assert orders.fire in [:free, :hold]
    assert is_binary(orders.why)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a pile the ruler rejects reads as not worth fighting", %{runner: runner} do
    Runner.load(runner, route(),
      knobs: %{nest_size: 1, nest_radius: 0, screen_w: 199, screen_h: 199}
    )

    Runner.tick_now(runner)

    picture = wait_for_worth(false)

    assert picture.enemies == 1
    refute picture.worth_fighting?
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a pile above the ruler reads as worth fighting" do
    picture = wait_for_worth(true)

    assert picture.enemies >= 3
    assert picture.worth_fighting?
  end

  defp wait_for_worth(want, tries \\ 200) do
    picture = wait_for_fact(:situation)

    cond do
      picture.worth_fighting? == want -> picture
      tries > 0 -> Process.sleep(10) && wait_for_worth(want, tries - 1)
      true -> flunk("worth_fighting? never became #{want}")
    end
  end
end
