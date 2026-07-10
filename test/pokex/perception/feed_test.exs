defmodule Pokex.Perception.FeedTest do
  use ExUnit.Case, async: false

  alias Pokex.Perception.{Feed, WorldState}

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

    # detached → no captures, no world entry
    refute_receive {:world, :feed_test, _}, 150
    assert WorldState.get(:feed_test, 60_000, now()) == :missing

    :ok = Feed.attach(feed)

    # first observation (width 8) lands and broadcasts
    assert_receive {:world, :feed_test, %{width: 8, captured_at: _}}, 1_000
    assert {:ok, %{width: 8}} = WorldState.get(:feed_test, 60_000, now())

    # second capture repeats width 8 → NO new broadcast; third (width 12) → broadcast
    assert_receive {:world, :feed_test, %{width: 12}}, 1_000
    refute_received {:world, :feed_test, %{width: 8}}

    # detach pauses the feed: no more broadcasts
    :ok = Feed.detach(feed)
    refute_receive {:world, :feed_test, _}, 300
  end

  @tag :tmp_dir
  test "a capture error keeps the last good entry and does not crash", %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}, {:error, :boom}]})

    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)
    :ok = Feed.attach(feed)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    assert_receive {:world, :feed_test, %{width: 8}}, 1_000

    # the error tick keeps the entry and the process alive
    Process.sleep(300)
    assert Process.alive?(feed)
    assert {:ok, %{width: 8}} = WorldState.get(:feed_test, 60_000, now())
  end

  defp now, do: System.monotonic_time(:millisecond)
end
