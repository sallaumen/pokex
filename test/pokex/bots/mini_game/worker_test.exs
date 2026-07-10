defmodule Pokex.Bots.MiniGame.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.MiniGame.Worker
  alias Pokex.{Calibration, Settings}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    originals =
      Map.new(
        [
          :mini_game_tick_ms,
          :mini_game_enter_streak,
          :mini_game_exit_streak,
          :mini_game_min_confidence,
          :mini_game_min_dark_ratio,
          :mini_game_anchor_tolerance
        ],
        &{&1, Settings.get(&1)}
      )

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(originals, fn {key, value} -> Settings.put(key, value) end)
    end)

    Settings.put(:mini_game_tick_ms, 20)
    Settings.put(:mini_game_enter_streak, 1)
    Settings.put(:mini_game_exit_streak, 1)
    Settings.put(:mini_game_min_confidence, 0.6)
    Settings.put(:mini_game_min_dark_ratio, 0.34)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 220,
      screen_h: 220,
      water_point: {100, 100},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      arena_region: {0, 0, 220, 220},
      neutral_point: {100, 100}
    })

    %{tmp: tmp}
  end

  @tag :tmp_dir
  test "announces enter and exit transitions while pausing and resuming remembered peers", %{
    tmp: tmp
  } do
    game = png!(tmp, "mini-game.png", true)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}]})
    test = self()

    pause_peers = fn _peers ->
      send(test, :paused)
      [:fishing, :combat]
    end

    resume_peers = fn _peers, paused ->
      send(test, {:resumed, paused})
      :ok
    end

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker =
      start_supervised!({Worker, name: nil, pause_peers: pause_peers, resume_peers: resume_peers})

    assert :ok = Worker.run(worker)

    assert_receive :paused, 1_000
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert_receive {:mini_game_log, :macro, enter_log}, 1_000
    assert enter_log =~ "pausando"

    assert_receive {:resumed, [:fishing, :combat]}, 1_000
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert :ok = Worker.halt(worker)
  end

  @tag :tmp_dir
  test "the input guard reflects the tick-driven in_game? flag (no capture on the hot path)", %{
    tmp: tmp
  } do
    game = png!(tmp, "mini-game.png", true)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})
    test = self()

    pause_peers = fn _peers ->
      send(test, :paused)
      [:fishing]
    end

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil, pause_peers: pause_peers})

    assert :ok = Worker.run(worker)

    # the WATCH TICK enters the game; the guard only mirrors the cached flag
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert {:blocked, :mini_game_active} = Worker.guard_before_input(worker)
    assert {:blocked, :mini_game_active} = Worker.guard_after_input(worker)
    assert Worker.status(worker).state == :playing
  end

  @tag :tmp_dir
  test "the guard never captures or pauses on its own — detection is the tick's job", %{tmp: tmp} do
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, calm}]})
    test = self()

    pause_peers = fn _peers ->
      send(test, :paused)
      []
    end

    worker = start_supervised!({Worker, name: nil, pause_peers: pause_peers})

    assert :ok = Worker.run(worker)

    # no game on screen: the guard is a pure read — :ok, and it pauses nobody
    assert :ok = Worker.guard_before_input(worker)
    assert :ok = Worker.guard_after_input(worker)
    refute_receive :paused, 200
  end

  @tag :tmp_dir
  test "enters the game when the bar sits right of the character, like the real overlay", %{
    tmp: tmp
  } do
    # Real geometry: the game draws the bar ~40px right of the sprite. Player
    # anchor falls back to the arena center (110); the bar is at 144..156. The
    # seeded anchor tolerance must absorb the offset.
    game = png_with_bar_at!(tmp, "offset-game.png", 144..156)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})
    test = self()

    pause_peers = fn _peers ->
      send(test, :paused)
      [:fishing]
    end

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil, pause_peers: pause_peers})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
  end

  @tag :tmp_dir
  test "anchors the bar search at the CALIBRATED player point when one is saved", %{tmp: tmp} do
    # Tight tolerance so only the calibrated anchor (not the arena center) can
    # accept the offset bar — proves the worker prefers calibration.player_point.
    Settings.put(:mini_game_anchor_tolerance, 20)

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | player_point: {150, 110}})

    game = png_with_bar_at!(tmp, "calibrated-game.png", 144..156)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})
    test = self()

    pause_peers = fn _peers ->
      send(test, :paused)
      [:fishing]
    end

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil, pause_peers: pause_peers})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
  end

  defp png!(dir, name, with_bar?),
    do: png_with_bar_at!(dir, name, if(with_bar?, do: 104..116))

  defp png_with_bar_at!(dir, name, bar_x_range) do
    rows =
      for y <- 0..219 do
        for x <- 0..219 do
          if bar_x_range != nil and x in bar_x_range and y in 24..202,
            do: {26, 30, 48, 255},
            else: {150, 120, 86, 255}
        end
      end

    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end
end
