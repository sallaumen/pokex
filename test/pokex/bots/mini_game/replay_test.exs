defmodule Pokex.Bots.MiniGame.ReplayTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.MiniGame.{Diag, Export, Replay}

  setup %{tmp_dir: tmp} do
    # A recorded bundle with three DISTINCT frames — the fish walking down the
    # track — landing in three different keep slots: the first tick, a reading
    # the gate refused, and the worst error.
    frames =
      for fish <- [40..54, 100..114, 170..184] do
        name = "frame-#{fish.first}.png"
        path = Pokex.PngFixtures.mini_game_scene!(tmp, name, fish: fish, capsule: 120..134)
        File.read!(path)
      end

    diag =
      frames
      |> Enum.with_index()
      |> Enum.reduce(Diag.new(started_at: 0, track_bar: %{x: 110, width: 13}), fn {bytes, i},
                                                                                  diag ->
        Diag.record(
          diag,
          %{
            at: i * 80,
            cap_ms: 11,
            tick_ms: 13,
            read: :ok,
            fish_y: 0.1 * i,
            fish_aim: 0.1 * i,
            bar_y: 0.0,
            bar_source: :blue,
            accepted: i != 1,
            verdict: if(i == 1, do: :impossible_speed, else: :accepted),
            hold: false
          },
          fn -> {:ok, bytes} end
        )
      end)
      |> Diag.finish(:exit_streak)

    {:ok, bundle, _stats} = Export.write(diag, dir: Path.join(tmp, "exports"), stamp: 1)

    %{bundle: bundle}
  end

  @tag :tmp_dir
  test "reads the saved frames with the CURRENT vision code", %{bundle: bundle} do
    assert {:ok, report} = Replay.run(bundle)

    assert report.track_bar == %{x: 110, width: 13}
    assert report.frames == length(report.samples)

    assert Enum.all?(report.samples, fn sample ->
             sample.read == :ok and is_number(sample.fish_y) and is_number(sample.bar_y) and
               is_number(sample.top) and is_number(sample.bottom) and is_number(sample.blue_px)
           end)

    # the fish walks DOWN the track across the three frames
    fish = Enum.map(report.samples, & &1.fish_y)
    assert fish == Enum.sort(fish)

    # the Detector runs over each saved frame and reports where it found the bar
    # (the synthetic fixture sits below the confidence gate on purpose — the
    # real-frame thresholds are pinned by detector_test, not here)
    assert Enum.all?(report.samples, &(&1.detector.bar_x == 110 and &1.detector.via != nil))
    assert Enum.all?(report.samples, &is_float(&1.detector.confidence))

    # ...and the report carries the same summary shape the live game writes
    assert %{ticks: 3, capture_ms: %{p50: 11}, exit_reason: :replay} = report.summary
    assert is_number(report.summary.error_max)
  end

  @tag :tmp_dir
  test "compares the current read against the one that was recorded", %{bundle: bundle} do
    {:ok, report} = Replay.run(bundle)

    drifts = Enum.map(report.samples, & &1.fish_drift)
    assert Enum.all?(drifts, &is_number/1)
    # the recording's fish_y values were synthetic, so drift is expected to be
    # non-zero here — what matters is that the comparison EXISTS per frame
    assert length(drifts) == 3
  end

  @tag :tmp_dir
  test "never calls Capture and never calls the Rig", %{bundle: bundle} do
    {:ok, _fake} = Pokex.Rig.Fake.start_link(%{})
    before = Pokex.Rig.Fake.calls()

    assert {:ok, report} = Replay.run(bundle)
    assert report.frames == 3

    # The Fake records EVERY call it receives, and Capture reaches the OS only
    # through Rig.capture — so no capture and no actuation in the log is proof
    # the replay stayed offline. (Background pollers of the running app, e.g.
    # the panic-corner cursor watch, are not the replay's doing.)
    assert Enum.all?(Pokex.Rig.Fake.calls() -- before, &(elem(&1, 0) == :cursor_position))
  end

  @tag :tmp_dir
  test "refuses a Rig that is not declared replay-safe", %{bundle: bundle} do
    assert_raise ArgumentError, ~r/replay-safe/, fn ->
      Replay.run(bundle, rig: Pokex.Rig.Mac)
    end

    assert_raise ArgumentError, ~r/replay-safe/, fn ->
      Replay.run(bundle, rig: Pokex.Rig.Fake)
    end
  end

  @tag :tmp_dir
  test "the offline Rig raises on any actuation" do
    assert Replay.NoRig.replay_safe?()
    assert_raise RuntimeError, ~r/offline/, fn -> Replay.NoRig.key_down("space") end
    assert_raise RuntimeError, ~r/offline/, fn -> Replay.NoRig.click(:left, {0, 0}) end
    assert_raise RuntimeError, ~r/offline/, fn -> Replay.NoRig.capture({0, 0, 1, 1}, "x.png") end
  end

  @tag :tmp_dir
  test "says so when the source has nothing to replay", %{tmp_dir: tmp} do
    empty = Path.join(tmp, "empty")
    File.mkdir_p!(empty)

    assert {:error, :no_track_bar} = Replay.run(empty)
    assert {:error, :no_frames} = Replay.run(empty, track_bar: %{x: 10, width: 4})
  end
end
