defmodule Pokex.Bots.MiniGame.DiagTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.MiniGame.Diag

  defp sample(overrides) do
    Map.merge(
      %{
        at: 0,
        cap_ms: 10,
        tick_ms: 12,
        read: :ok,
        fish_y: 0.5,
        fish_aim: 0.5,
        bar_y: 0.5,
        bar_source: :blue,
        accepted: true,
        hold: false
      },
      Map.new(overrides)
    )
  end

  defp png(tag), do: fn -> {:ok, "png-#{tag}"} end

  describe "counters" do
    test "a source flip shows up in the report" do
      diag =
        Diag.new(started_at: 0)
        |> Diag.record(sample(at: 0, bar_source: :blue))
        |> Diag.record(sample(at: 80, bar_source: :blue))
        |> Diag.record(sample(at: 160, bar_source: :fish))
        |> Diag.record(sample(at: 240, bar_source: :blue))

      assert Diag.summary(diag).source_flips == 2

      flips = diag |> Diag.samples() |> Enum.filter(& &1.flip) |> Enum.map(& &1.i)
      assert flips == [2, 3]
    end

    test "a reading refused by the gate records WHY" do
      diag =
        Diag.new(started_at: 0)
        |> Diag.record(sample(at: 0))
        |> Diag.record(sample(at: 80, accepted: false, verdict: :impossible_speed))

      assert Diag.summary(diag).rejected_readings == 1

      refused = diag |> Diag.samples() |> Enum.at(1)
      assert refused.accepted == false
      assert refused.verdict == :impossible_speed
    end

    test "counts blind ticks, lost track and lost fish separately" do
      diag =
        Diag.new(started_at: 0)
        |> Diag.record(sample(at: 0))
        |> Diag.record(sample(at: 80, read: :no_fish, bar_source: nil))
        |> Diag.record(sample(at: 160, read: :no_track, bar_source: nil))

      summary = Diag.summary(diag)
      assert summary.blind_ticks == 2
      assert summary.no_fish == 1
      assert summary.no_track == 1
    end

    test "tracks the longest run without a capsule" do
      sources = [:blue, :fish, :fish, :fish, :blue, :fish]

      diag =
        sources
        |> Enum.with_index()
        |> Enum.reduce(Diag.new(started_at: 0), fn {source, i}, diag ->
          Diag.record(diag, sample(at: i * 80, bar_source: source))
        end)

      assert Diag.summary(diag).max_no_capsule_streak == 3
    end

    test "summarises the error between fish and capsule, and the cadence" do
      diag =
        Diag.new(started_at: 0)
        |> Diag.record(sample(at: 0, cap_ms: 10, tick_ms: 20, fish_aim: 0.5, bar_y: 0.5))
        |> Diag.record(sample(at: 80, cap_ms: 30, tick_ms: 40, fish_aim: 0.9, bar_y: 0.5))
        |> Diag.finish(:exit_streak)

      summary = Diag.summary(diag)

      assert summary.error_max == 0.4
      assert summary.error_mean == 0.2
      assert summary.capture_ms == %{p50: 10, p95: 30, max: 30}
      assert summary.tick_ms.max == 40
      assert summary.gap_ms.max == 80
      assert summary.ticks == 2
      assert summary.exit_reason == :exit_streak
    end
  end

  describe "bounds" do
    test "samples stop at the cap, and the drop is reported" do
      diag =
        Enum.reduce(0..9, Diag.new(started_at: 0, samples_max: 4), fn i, diag ->
          Diag.record(diag, sample(at: i * 80))
        end)

      summary = Diag.summary(diag)
      assert length(Diag.samples(diag)) == 4
      assert summary.samples_recorded == 4
      assert summary.samples_dropped == 6
      # the counters keep counting past the sample cap
      assert summary.ticks == 10
    end

    test "the event frame ring respects its limit" do
      # every tick is an event (a refused reading), so only the newest
      # `frames_max` survive — plus the fixed first/worst slots.
      diag =
        Enum.reduce(0..19, Diag.new(started_at: 0, frames_max: 3), fn i, diag ->
          Diag.record(
            diag,
            sample(at: i * 80, accepted: false, verdict: :impossible_speed),
            png(i)
          )
        end)

      frames = Diag.frames(diag)
      events = Enum.filter(frames, &(&1.tag == :rejected))

      assert length(events) == 3
      assert Enum.map(events, & &1.index) == [17, 18, 19]
      assert length(frames) <= 3 + 2
    end

    test "keeps the first frame, the worst error and the last frame" do
      diag =
        Diag.new(started_at: 0, frames_max: 2)
        |> Diag.record(sample(at: 0, fish_aim: 0.5, bar_y: 0.5), png(:a))
        |> Diag.record(sample(at: 80, fish_aim: 1.0, bar_y: 0.0), png(:worst))
        |> Diag.record(sample(at: 160, fish_aim: 0.6, bar_y: 0.5), png(:c))
        |> Diag.finish(:exit_streak, png(:last))

      by_tag = Map.new(Diag.frames(diag), &{&1.tag, &1})

      assert by_tag[:first].index == 0
      assert by_tag[:max_error].index == 1
      assert by_tag[:max_error].bytes == "png-worst"
      assert by_tag[:last].bytes == "png-last"
    end

    test "an unreadable frame is skipped instead of crashing the game" do
      diag = Diag.record(Diag.new(started_at: 0), sample(at: 0), fn -> {:error, :enoent} end)

      assert Diag.frames(diag) == []
      assert Diag.summary(diag).ticks == 1
    end
  end

  test "records safety releases and actuations" do
    diag =
      Diag.new(started_at: 0)
      |> Diag.record_key_up(:ok)
      |> Diag.record_actuation(true)
      |> Diag.record_actuation(false)
      |> Diag.record_key_up({:error, :boom})

    summary = Diag.summary(diag)
    assert summary.key_down == 1
    assert summary.key_up == 1
    assert summary.safety_key_ups == [":ok", "{:error, :boom}"]
  end
end
