defmodule Pokex.Bots.Catcher.StockProofTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.SettingsStash
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    WorldState.clear()
    SettingsStash.stash!(player_mode: "still", capture_enabled: true, corpse_max_balls: 1)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      tile_px: 100,
      neutral_point: {500, 500},
      ball_stock_region: {34, 28, 20, 8}
    })

    {:ok, frame} = Frame.from_file("test/fixtures/hud/hotbar_f1_827.png")
    before_path = Path.join(tmp, "before.raw")
    after_path = Path.join(tmp, "after.raw")
    File.write!(before_path, frame |> Frame.crop({34, 28, 20, 8}) |> Frame.to_raw())
    File.write!(after_path, frame |> Frame.crop({72, 28, 18, 8}) |> Frame.to_raw())
    body = start_supervised!({Pokex.StockProofBody, self()})
    scanner = fn -> %{scanning?: true, corpses: [{150, 250}], captured_at: now()} end
    worker = start_supervised!({Worker, name: nil, body: body, scanner: scanner})
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    WorldState.put(:situation, %{enemies: 0}, now())
    %{worker: worker, body: body, before_path: before_path, after_path: after_path}
  end

  test "photographs before the throw and proves the decrease without a HUD", context do
    start_supervised!({Fake, %{capture: [{:ok, context.before_path}, {:ok, context.after_path}]}})
    :ok = Worker.run(context.worker)
    send(context.worker, {:kill})
    assert_receive {:ball_thrown, 1}, 1_000
    assert await_captures(2)
    assert Worker.status(context.worker).stuck_balls == 0
    refute_received {:catcher_log, :macro, "captura: 🥎 a bola não saiu da mão" <> _}
    refute_received {:catcher_log, :macro, "captura: 🥎 não sei dizer" <> _}
  end

  test "compares the second ball with its own count", context do
    SettingsStash.stash!(corpse_max_balls: 2)

    start_supervised!(
      {Fake,
       %{
         capture: [
           {:ok, context.before_path},
           {:ok, context.after_path},
           {:ok, context.after_path},
           {:ok, context.after_path}
         ]
       }}
    )

    :ok = Worker.run(context.worker)
    send(context.worker, {:kill})
    assert_receive {:ball_thrown, 1}, 1_000
    assert_receive {:ball_thrown, 3}, 4_000
    assert await_captures(4)
    assert Worker.status(context.worker).stuck_balls == 1

    assert_receive {:catcher_log, :macro,
                    "captura: 🥎 a bola não saiu da mão: o estoque de f1 continua em 123" <> _}
  end

  test "uses separate before and after counts for two different queued targets", context do
    start_supervised!(
      {Fake,
       %{
         capture: [
           {:ok, context.before_path},
           {:ok, context.after_path},
           {:ok, context.after_path},
           {:ok, context.after_path}
         ]
       }}
    )

    scene = start_supervised!({Agent, fn -> [{150, 250}, {350, 250}] end})
    scanner = fn -> %{scanning?: true, corpses: Agent.get(scene, & &1), captured_at: now()} end

    worker =
      start_supervised!({Worker, name: nil, body: context.body, scanner: scanner},
        id: :multiple_stock_worker
      )

    :ok = Worker.run(worker)
    send(worker, {:kill})
    assert_receive {:ball_thrown, 1}, 1_000
    Agent.update(scene, fn _ -> [{350, 250}] end)
    assert_receive {:ball_thrown, 3}, 4_000
    Agent.update(scene, fn _ -> [] end)
    assert await_captures(4)
    assert Worker.status(worker).stuck_balls == 1
    assert Pokex.TestWait.eventually(fn -> Worker.status(worker).pending_corpses == 0 end, 2_000)
  end

  test "does not accuse when the marked count becomes unreadable despite a readable HUD",
       context do
    start_supervised!({Fake, %{capture: [{:ok, context.before_path}, {:error, :unavailable}]}})
    WorldState.put(:hud, %{slots: %{f1: 827}}, now())
    :ok = Worker.run(context.worker)
    send(context.worker, {:kill})
    assert_receive {:ball_thrown, 1}, 1_000
    assert await_captures(2)
    assert Worker.status(context.worker).stuck_balls == 0
    refute_received {:catcher_log, :macro, "captura: 🥎 a bola não saiu da mão" <> _}
  end

  test "uses the F2 HUD count instead of the F1 marked region", context do
    SettingsStash.stash!(ball_key: "f2")
    start_supervised!({Fake, %{capture: [{:ok, context.before_path}]}})
    WorldState.put(:hud, %{slots: %{f2: 827}}, now())
    :ok = Worker.run(context.worker)
    send(context.worker, {:kill})
    assert_receive {:ball_thrown, 0}, 1_000

    assert_receive {:catcher_log, :macro,
                    "captura: 🥎 a bola não saiu da mão: o estoque de f2 continua em 827" <> _},
                   4_000

    assert Enum.empty?(Fake.calls())
  end

  defp await_captures(count) do
    Pokex.TestWait.eventually(
      fn ->
        Enum.count(Fake.calls(), &match?({:capture, _, "ball_stock.raw"}, &1)) == count
      end,
      4_000
    )
  end

  defp now, do: System.monotonic_time(:millisecond)
end
