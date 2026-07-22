defmodule Pokex.Layout.SentinelTest do
  # async: false — the sentinel and the tests share the "layout" topic
  use ExUnit.Case, async: false

  alias Pokex.Layout.Sentinel

  setup do
    # inert instance: locating would capture the REAL screen
    {:ok, pid} = Sentinel.start_link(name: nil, active: false)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Sentinel.topic())
    %{sentinel: pid}
  end

  test "an inert sentinel never re-locates (tests must not touch the screen)", %{sentinel: pid} do
    Sentinel.suspect(:battle)

    refute_receive {:layout, _}, 200
    assert Process.alive?(pid)
  end

  test "a feed's failure streak reaches the sentinel as a suspicion" do
    Sentinel.suspect(:hud)

    assert_receive {:layout_suspect, :hud}, 500
  end
end
