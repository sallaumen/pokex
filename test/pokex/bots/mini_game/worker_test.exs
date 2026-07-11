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
          :mini_game_anchor_tolerance,
          :mini_game_play_tick_ms,
          :mini_game_min_toggle_ms
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
    Settings.put(:mini_game_play_tick_ms, 20)
    Settings.put(:mini_game_min_toggle_ms, 0)

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

  # --- the playing loop -------------------------------------------------------

  @tag :tmp_dir
  test "plays: fish above the capsule -> holds Space (key_down, never Body)", %{tmp: tmp} do
    game = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil, pause_peers: fn _ -> [] end})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)
  end

  @tag :tmp_dir
  test "plays: fish drops below the capsule -> releases Space", %{tmp: tmp} do
    hold = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)
    release = play_png!(tmp, "release.png", fish: 170..184, capsule: 120..134)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, hold}, {:ok, release}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil, pause_peers: fn _ -> [] end})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    wait_for(fn -> {:key_up, "space"} in Pokex.Rig.Fake.calls() end)

    calls = Pokex.Rig.Fake.calls()
    down = Enum.find_index(calls, &(&1 == {:key_down, "space"}))
    up = Enum.find_index(calls, &(&1 == {:key_up, "space"}))
    assert down != nil and up != nil and down < up
  end

  @tag :tmp_dir
  test "leaving the game always releases Space, even if already released", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil, pause_peers: fn _ -> [] end})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "re-running the worker mid-game releases Space (panel Start while playing)", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil, pause_peers: fn _ -> [] end})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    assert :ok = Worker.run(worker)
    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "halt while holding releases Space", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil, pause_peers: fn _ -> [] end})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    assert :ok = Worker.halt(worker)
    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "a capture failure while holding releases Space", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:error, :boom}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil, pause_peers: fn _ -> [] end})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    wait_for(fn -> {:key_up, "space"} in Pokex.Rig.Fake.calls() end)
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true; calls: #{inspect(Pokex.Rig.Fake.calls())}")

      true ->
        Process.sleep(10)
        wait_for(fun, tries - 1)
    end
  end

  defp png!(dir, name, with_bar?),
    do: png_with_bar_at!(dir, name, if(with_bar?, do: 104..116))

  defp png_with_bar_at!(dir, name, bar_x_range, overlays \\ []) do
    rows =
      for y <- 0..219 do
        for x <- 0..219 do
          cond do
            bar_x_range == nil or x not in bar_x_range ->
              {150, 120, 86, 255}

            true ->
              Enum.find_value(overlays, track_pixel(y), fn {range, color} ->
                if y in range, do: color
              end)
          end
        end
      end

    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  # Track spans rows 10..209; fish is olive (not dark, not blue), capsule blue.
  defp play_png!(dir, name, opts) do
    png_with_bar_at!(dir, name, 104..116, [
      {Keyword.fetch!(opts, :fish), {120, 100, 0, 255}},
      {Keyword.fetch!(opts, :capsule), {0, 160, 255, 255}}
    ])
  end

  defp track_pixel(y) when y in 10..209, do: {26, 30, 48, 255}
  defp track_pixel(_y), do: {150, 120, 86, 255}
end
