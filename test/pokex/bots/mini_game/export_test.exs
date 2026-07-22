defmodule Pokex.Bots.MiniGame.ExportTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.MiniGame.{Diag, Export}

  defp diag_with(samples, frames) do
    diag =
      Enum.reduce(0..(samples - 1), Diag.new(started_at: 0, track_bar: %{x: 40, width: 14}), fn i,
                                                                                                diag ->
        Diag.record(
          diag,
          %{
            at: i * 80,
            cap_ms: 10,
            tick_ms: 12,
            read: :ok,
            fish_y: 0.5,
            fish_aim: 0.5,
            bar_y: 0.4,
            bar_source: :blue,
            accepted: true,
            hold: false
          },
          if(i < frames, do: fn -> {:ok, String.duplicate("x", 1_000)} end)
        )
      end)

    Diag.finish(diag, :exit_streak, fn -> {:ok, "last"} end)
  end

  @tag :tmp_dir
  test "writes summary, one JSON line per sample, and the kept frames", %{tmp_dir: tmp} do
    {:ok, path, stats} = Export.write(diag_with(6, 1), dir: tmp, stamp: 1)

    assert stats.samples == 6
    assert Path.basename(path) == "mini_game-1"

    summary = path |> Path.join("summary.json") |> File.read!() |> JSON.decode!()
    assert summary["ticks"] == 6
    assert summary["exit_reason"] == "exit_streak"
    # tuples survive as lists, so a replay can read the geometry back
    assert summary["track_bar"] == %{"x" => 40, "width" => 14}

    lines = path |> Path.join("samples.jsonl") |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 6
    assert Enum.map(lines, &JSON.decode!(&1)["i"]) == [0, 1, 2, 3, 4, 5]

    assert Path.wildcard(Path.join([path, "frames", "*.png"])) != []
  end

  @tag :tmp_dir
  test "keeps at most :keep bundles, oldest deleted first", %{tmp_dir: tmp} do
    for stamp <- 1..5 do
      {:ok, _path, _stats} = Export.write(diag_with(5, 0), dir: tmp, stamp: stamp, keep: 3)
      # File.stat mtime has 1s granularity — order the bundles explicitly.
      age(tmp, stamp)
    end

    remaining = tmp |> File.ls!() |> Enum.sort()
    assert remaining == ["mini_game-3", "mini_game-4", "mini_game-5"]
  end

  @tag :tmp_dir
  test "keeps the exports under the size budget, and never deletes the newest", %{tmp_dir: tmp} do
    # each bundle carries a ~1KB frame; a 0 MB budget means "only the newest"
    for stamp <- 1..4 do
      {:ok, _path, _stats} = Export.write(diag_with(5, 1), dir: tmp, stamp: stamp, max_mb: 0)
      age(tmp, stamp)
    end

    assert File.ls!(tmp) == ["mini_game-4"]
  end

  @tag :tmp_dir
  test "prune leaves foreign files in the exports dir alone", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "latest.json"), "{}")
    {:ok, _path, _stats} = Export.write(diag_with(5, 0), dir: tmp, stamp: 1, keep: 1)

    assert {:ok, []} = Export.prune(dir: tmp, keep: 1, max_mb: 0)
    assert File.exists?(Path.join(tmp, "latest.json"))
    assert File.exists?(Path.join(tmp, "mini_game-1"))
  end

  @tag :tmp_dir
  test "lists bundles newest first", %{tmp_dir: tmp} do
    for stamp <- 1..3 do
      {:ok, _path, _stats} = Export.write(diag_with(5, 0), dir: tmp, stamp: stamp, keep: 10)
      age(tmp, stamp)
    end

    assert Enum.map(Export.list(dir: tmp), & &1.name) ==
             ["mini_game-3", "mini_game-2", "mini_game-1"]
  end

  # Bundles are pruned oldest-first by mtime, and a test writes them all in the
  # same second — push each one's mtime back so the order is unambiguous.
  defp age(dir, stamp) do
    path = Path.join(dir, "mini_game-#{stamp}")
    if File.dir?(path), do: File.touch!(path, System.os_time(:second) - (100 - stamp))
  end
end
