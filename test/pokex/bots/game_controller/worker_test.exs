defmodule Pokex.Bots.GameController.WorkerTest.FakeBody do
  @moduledoc "Records Body.perform calls and forwards them to the test process."
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:perform, actions, priority, _requested_at}, _from, test) do
    send(test, {:performed, priority, actions})
    {:reply, :ok, test}
  end
end

defmodule Pokex.Bots.GameController.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.GameController.Worker
  alias Pokex.Bots.GameController.WorkerTest.FakeBody
  alias Pokex.{Calibration, Settings}

  @keys [
    :game_tick_ms,
    :rescue_step_ms,
    :rescue_enabled,
    :rescue_cooldown_ms,
    :pokemon_hp_rescue_pct
  ]

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    originals = Map.new(@keys, &{&1, Settings.get(&1)})

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(originals, fn {k, v} -> Settings.put(k, v) end)
    end)

    Settings.put(:game_tick_ms, 20)
    Settings.put(:rescue_step_ms, 0)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      arena_region: {0, 0, 200, 200},
      neutral_point: {500, 500},
      pokemon_hp_region: {0, 0, 20, 4},
      pokemon_photo_point: {40, 620}
    })

    {:ok, body} = FakeBody.start_link(self())
    %{tmp: tmp, body: body}
  end

  # An HP bar PNG: `fill_cols` green columns then dark to `total`.
  defp hp_png(dir, name, fill_cols, total \\ 20) do
    rows =
      for _y <- 1..4 do
        for x <- 1..total, do: if(x <= fill_cols, do: {40, 200, 60, 255}, else: {17, 17, 17, 255})
      end

    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  defp start_worker(body), do: start_supervised!({Worker, name: nil, body: body})

  @tag :tmp_dir
  test "holds (no combo) while the HP bar is full", %{tmp: tmp, body: body} do
    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).hp_pct == 100
  end

  @tag :tmp_dir
  test "fires the survival combo at :critical when HP is below the threshold", %{
    tmp: tmp,
    body: body
  } do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, actions}, 1_000
    # Q → move onto the portrait → Shift+Q → Q → recentre
    assert [{:press, "q"} | _] = actions
    assert {:move, {40, 620}} in actions
    assert {:press, "shift+q"} in actions
    assert {:move, {500, 500}} in actions

    assert Worker.status(worker).counters.rescues >= 1
  end

  @tag :tmp_dir
  test "the cooldown blocks a second combo within the window", %{tmp: tmp, body: body} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})
    # long cooldown so the second, third… ticks are all suppressed
    Settings.put(:rescue_cooldown_ms, 60_000)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, _}, 1_000
    # keeps ticking on the same low HP, but must NOT fire again
    refute_receive {:performed, :critical, _}, 300
    assert Worker.status(worker).counters.rescues == 1
  end

  @tag :tmp_dir
  test "the toggle off disables the combo entirely", %{tmp: tmp, body: body} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})
    Settings.put(:rescue_enabled, false)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).counters.rescues == 0
  end
end
