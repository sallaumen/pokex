defmodule Pokex.Engine.EventsTest do
  @moduledoc """
  The night as data. The journal keeps the story; this keeps the numbers, so
  "qual o tamanho médio da pilha na esquina 15" stops being a question only a
  human re-reading prose can answer.
  """
  use ExUnit.Case, async: false

  alias Pokex.Engine.Events

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(&Pokex.TestHome.restore/0)

    {:ok, writer} = Events.start_link(name: nil, persist: true)
    %{writer: writer}
  end

  # A cast is fire-and-forget by design; a call is the cheap barrier that proves
  # the earlier cast was already handled.
  defp settle(writer), do: :sys.get_state(writer)

  test "files a typed record that reads back whole", %{writer: writer} do
    Events.record(:decision, %{phase: :sizing, enemies: 4, why: "contando quem chega"}, writer)
    settle(writer)

    assert [record] = Events.read_day(Date.utc_today())
    assert record["kind"] == "decision"
    assert record["phase"] == "sizing"
    assert record["enemies"] == 4
    assert record["why"] == "contando quem chega"
    assert is_integer(record["at"])
  end

  # The orders name themselves in atoms (`:free`, `:yellow`) and JSON has none.
  # Dropping the record over that would lose exactly the fields worth keeping.
  test "atoms and lists of atoms survive the round trip", %{writer: writer} do
    Events.record(:decision, %{band: :yellow, fire: :free, opening: ~w(3 4 5)}, writer)
    settle(writer)

    assert [record] = Events.read_day(Date.utc_today())
    assert record["band"] == "yellow"
    assert record["fire"] == "free"
    assert record["opening"] == ~w(3 4 5)
  end

  test "keeps every record of the day, oldest first", %{writer: writer} do
    Events.record(:decision, %{n: 1}, writer)
    Events.record(:decision, %{n: 2}, writer)
    Events.record(:decision, %{n: 3}, writer)
    settle(writer)

    assert Events.read_day(Date.utc_today()) |> Enum.map(& &1["n"]) == [1, 2, 3]
  end

  test "a day the bot never ran is empty, not an error" do
    assert Events.read_day(~D[2001-01-01]) == []
  end

  # A kill mid-append leaves half a line. Losing that line is correct; losing
  # the day because of it is not.
  test "a torn last line costs that line and nothing else", %{writer: writer} do
    Events.record(:decision, %{n: 1}, writer)
    settle(writer)

    file = Path.join(Events.dir(), Date.to_iso8601(Date.utc_today()) <> ".jsonl")
    File.write!(file, ~s({"kind":"decision","n":2), [:append])

    assert Events.read_day(Date.utc_today()) |> Enum.map(& &1["n"]) == [1]
  end

  test "writing is off unless the instance opted in", %{tmp_dir: tmp} do
    {:ok, quiet} = Events.start_link(name: nil, persist: false)
    Events.record(:decision, %{n: 1}, quiet)
    :sys.get_state(quiet)

    refute File.exists?(Path.join([tmp, "events"]))
  end
end
