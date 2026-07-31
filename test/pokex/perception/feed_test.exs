defmodule Pokex.Perception.FeedTest do
  use ExUnit.Case, async: false

  alias Pokex.Perception.{Feed, WorldState}
  alias Pokex.Settings

  # A tiny deterministic spec: region is fixed, the interpreter reports the frame width so
  # different scripted PNGs produce different observations.
  defp spec do
    %{
      key: :feed_test,
      region: fn _calib -> {0, 0, 10, 10} end,
      interval_setting: :feed_battle_ms,
      filename: "feed_test.png",
      interpret: fn frame, _calib, _settings -> %{width: frame.width} end
    }
  end

  defp png!(dir, name, w) do
    rows = for _ <- 1..4, do: List.duplicate({9, 9, 9, 255}, w)
    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  defp save_calibration do
    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      arena_region: {0, 0, 60, 40},
      neutral_point: {52, 36}
    })
  end

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      :ets.delete(:pokex_world, :feed_test)
    end)

    save_calibration()
    :ok
  end

  @tag :tmp_dir
  test "captures only while attached, writes the world, broadcasts on change only",
       %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    b = png!(tmp, "b.png", 12)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}, {:ok, a}, {:ok, b}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)

    refute_receive {:world, :feed_test, _}, 150
    assert WorldState.get(:feed_test, 60_000, now()) == :missing

    :ok = Feed.attach(feed)

    assert_receive {:world, :feed_test, %{width: 8, captured_at: _}}, 1_000
    assert {:ok, %{width: 8}} = WorldState.get(:feed_test, 60_000, now())

    assert_receive {:world, :feed_test, %{width: 12}}, 1_000
    refute_received {:world, :feed_test, %{width: 8}}

    :ok = Feed.detach(feed)
    refute_receive {:world, :feed_test, _}, 300
  end

  @tag :tmp_dir
  # measured: feed captures queued behind the minigame's strip stretched its cadence from 80ms to ~250ms
  test "pauses capture while a minigame is playing and resumes on exit", %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    b = png!(tmp, "b.png", 12)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}, {:ok, b}, {:ok, b}]})

    WorldState.put(:mini_game, %{playing?: true, confidence: 0.9}, now())
    on_exit(fn -> WorldState.forget(:mini_game) end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)
    :ok = Feed.attach(feed)

    refute_receive {:world, :feed_test, _}, 300
    assert WorldState.get(:feed_test, 60_000, now()) == :missing

    WorldState.put(:mini_game, %{playing?: false, confidence: 0.0}, now())
    assert_receive {:world, :feed_test, %{width: 8}}, 1_000
  end

  @tag :tmp_dir
  test "a capture error keeps the last good entry and does not crash", %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}, {:error, :boom}]})

    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)
    :ok = Feed.attach(feed)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    assert_receive {:world, :feed_test, %{width: 8}}, 1_000

    Process.sleep(300)
    assert Process.alive?(feed)
    assert {:ok, %{width: 8}} = WorldState.get(:feed_test, 60_000, now())
  end

  @tag :tmp_dir
  test "a crashed consumer auto-detaches and pauses the feed", %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}]})

    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)

    parent = self()

    consumer =
      spawn(fn ->
        :ok = Feed.attach(feed)
        send(parent, :attached)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :attached, 500

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    assert_receive {:world, :feed_test, _obs}, 1_000

    send(consumer, :die)

    Process.sleep(100)
    flush_world()

    refute_receive {:world, :feed_test, _}, 300
  end

  @tag :tmp_dir
  # Rig.Fake repeats its script tail, so after one good capture every tick fails forever
  test "a consecutive-failure streak reaching the configured threshold logs one loud warning",
       %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}, {:error, :boom}]})

    original = Settings.get(:feed_failure_warn_streak)
    Settings.put(:feed_failure_warn_streak, 2)
    on_exit(fn -> Settings.put(:feed_failure_warn_streak, original) end)

    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Feed.attach(feed)
        Process.sleep(600)
      end)

    assert log =~ "feed feed_test: 2 capturas seguidas falharam"
    assert length(Regex.scan(~r/capturas seguidas falharam/, log)) == 1
  end

  defp flush_world do
    receive do
      {:world, _, _} -> flush_world()
    after
      0 -> :ok
    end
  end

  defp stateful_spec do
    %{
      key: :feed_stateful_test,
      region: fn _calib -> {0, 0, 10, 10} end,
      interval_setting: :feed_battle_ms,
      filename: "feed_stateful_test.png",
      # counts how many frames this ATTACHMENT has seen — resets when the feed resumes
      interpret: fn _frame, _calib, _settings, prev ->
        n = (prev || 0) + 1
        {%{frames_seen: n}, n}
      end
    }
  end

  @tag :tmp_dir
  test "arity-4 interpreters thread state and reset when the feed resumes from idle",
       %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}]})
    on_exit(fn -> :ets.delete(:pokex_world, :feed_stateful_test) end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    {:ok, feed} = Feed.start_link(spec: stateful_spec(), name: nil)

    :ok = Feed.attach(feed)
    assert_receive {:world, :feed_stateful_test, %{frames_seen: 1}}, 1_000
    assert_receive {:world, :feed_stateful_test, %{frames_seen: 2}}, 1_000

    :ok = Feed.detach(feed)
    refute_receive {:world, :feed_stateful_test, _}, 300

    :ok = Feed.attach(feed)
    assert_receive {:world, :feed_stateful_test, %{frames_seen: 1}}, 1_000
  end

  defp now, do: System.monotonic_time(:millisecond)
end
