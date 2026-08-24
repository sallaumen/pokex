defmodule Pokex.Sim.CalibrateTest do
  use ExUnit.Case, async: false

  alias Pokex.Sim.Calibrate

  @date ~D[2020-01-02]

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    File.mkdir_p!(Path.join(tmp, "journal"))
    File.mkdir_p!(Path.join(tmp, "events"))
    :ok
  end

  defp write_journal(tmp, lines) do
    body = Enum.map_join(lines, "\n", &Jason.encode!/1)
    File.write!(Path.join([tmp, "journal", "#{Date.to_iso8601(@date)}.jsonl"]), body <> "\n")
  end

  defp write_events(tmp, records) do
    body = Enum.map_join(records, "\n", &Jason.encode!/1)
    File.write!(Path.join([tmp, "events", "#{Date.to_iso8601(@date)}.jsonl"]), body <> "\n")
  end

  # One tile every 300ms, walking east on one floor.
  defp walk_lines(count, step_ms \\ 300) do
    for i <- 0..count do
      %{
        at: 1_000_000 + i * step_ms,
        text: "caçada: andar walk de #{100 + i},200,5: faltam 4,0 tiles · leitura de 120ms atrás",
        source: "cavebot",
        severity: "macro"
      }
    end
  end

  @tag :tmp_dir
  test "measures milliseconds per tile from consecutive walk lines", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))

    assert Calibrate.walk_speed(@date).median == 300.0
  end

  @tag :tmp_dir
  test "counts how many samples the measurement rests on", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))

    assert Calibrate.walk_speed(@date).n == 40
  end

  @tag :tmp_dir
  test "refuses to answer a speed from too few hops", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(5))

    assert Calibrate.walk_speed(@date) == nil
  end

  @tag :tmp_dir
  test "drops a pair that changed floor, since a stair is one key and two tiles", %{tmp_dir: tmp} do
    stair = %{
      at: 2_000_000,
      text: "caçada: andar walk de 500,200,6: faltam 1,0 tiles · leitura de 120ms atrás",
      source: "cavebot",
      severity: "macro"
    }

    write_journal(tmp, walk_lines(40) ++ [stair])

    assert Calibrate.walk_speed(@date).n == 40
  end

  @tag :tmp_dir
  test "drops a pair separated by a long gap, since the hunt was doing something else", %{
    tmp_dir: tmp
  } do
    late = %{
      at: 1_000_000 + 40 * 300 + 60_000,
      text: "caçada: andar walk de 200,200,5: faltam 1,0 tiles · leitura de 120ms atrás",
      source: "cavebot",
      severity: "macro"
    }

    write_journal(tmp, walk_lines(40) ++ [late])

    assert Calibrate.walk_speed(@date).n == 40
  end

  @tag :tmp_dir
  test "answers nil for a night that never measured walking", %{tmp_dir: tmp} do
    write_journal(tmp, [%{at: 1, text: "caçada: waypoint 3/67", source: "cavebot"}])

    assert Calibrate.walk_speed(@date) == nil
  end

  @tag :tmp_dir
  test "reads the pile sizes the engine actually opened on", %{tmp_dir: tmp} do
    write_events(tmp, [
      %{at: 1, kind: "decision", phase: "engaged", enemies: 4, stable_ms: 1_800},
      %{at: 2, kind: "decision", phase: "engaged", enemies: 6, stable_ms: 2_200},
      %{at: 3, kind: "decision", phase: "skipping", enemies: 1, stable_ms: 400}
    ])

    pile = Calibrate.piles(@date)

    assert pile.engagements == 2
    assert pile.engaged.median == 6
    assert pile.skipped == 1
  end

  @tag :tmp_dir
  test "reads how long the piles took to stop arriving", %{tmp_dir: tmp} do
    write_events(tmp, [
      %{at: 1, kind: "decision", phase: "engaged", enemies: 4, stable_ms: 1_800},
      %{at: 2, kind: "decision", phase: "engaged", enemies: 5, stable_ms: 2_200}
    ])

    assert Calibrate.piles(@date).settled_ms.median == 2_200
  end

  @tag :tmp_dir
  test "answers nil for a night the engine never filed", %{tmp_dir: _tmp} do
    assert Calibrate.piles(@date) == nil
  end

  @tag :tmp_dir
  test "hands over only the knobs the night could actually answer", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))

    knobs = Calibrate.knobs(@date)

    assert knobs.ms_per_tile == 300
    refute Map.has_key?(knobs, :nest_size)
  end

  @tag :tmp_dir
  test "hands over nothing for a night that measured nothing", %{tmp_dir: _tmp} do
    assert Calibrate.knobs(@date) == %{}
  end

  @tag :tmp_dir
  test "the report carries both halves and the date it read", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))
    write_events(tmp, [%{at: 1, kind: "decision", phase: "engaged", enemies: 4, stable_ms: 900}])

    report = Calibrate.report(@date)

    assert report.date == @date
    assert report.walk.n == 40
    assert report.pile.engagements == 1
  end
end
