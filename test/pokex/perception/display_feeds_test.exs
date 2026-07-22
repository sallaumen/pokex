defmodule Pokex.Perception.DisplayFeedsTest do
  use ExUnit.Case, async: false

  alias Pokex.Perception.DisplayFeeds

  test "covers every feed that has NO other consumer" do
    # The bug this guards: :team and :minimap shipped with no consumer at all,
    # so they never captured and /world showed "?" forever while the tests —
    # which called the interpreters directly — stayed green.
    attachers =
      "lib"
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        Regex.scan(~r/Perception\.attach\(:(\w+)\)/, File.read!(file))
      end)
      |> Enum.map(fn [_all, key] -> String.to_atom(key) end)
      |> MapSet.new()

    declared = Pokex.Perception.feed_specs() |> Enum.map(& &1.key) |> MapSet.new()
    display = MapSet.new(DisplayFeeds.keys())

    orphans = declared |> MapSet.difference(attachers) |> MapSet.difference(display)

    assert MapSet.size(orphans) == 0,
           "feeds nobody ever attaches (they will never capture): #{inspect(MapSet.to_list(orphans))}"
  end

  test "attaching is best-effort — a missing feed never takes the page down" do
    assert is_list(DisplayFeeds.attach_all([:definitely_not_a_feed]))
  end
end
