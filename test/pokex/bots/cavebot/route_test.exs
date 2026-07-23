defmodule Pokex.Bots.Cavebot.RouteTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.Route

  test "append fixa o andar e recusa z divergente" do
    r = Route.new("cavena", "cavena-dg")
    assert {:ok, r} = Route.append(r, {100, 200, 7})
    assert r.z == 7
    assert {:ok, r} = Route.append(r, {101, 200, 7})
    assert length(r.waypoints) == 2
    assert {:error, :floor_mismatch} = Route.append(r, {101, 201, 6})
  end

  test "validate exige waypoints e andar único" do
    assert {:error, :empty} = Route.validate(Route.new("x"))
    {:ok, r} = Route.append(Route.new("x"), {1, 1, 3})
    assert Route.validate(r) == :ok
  end
end
