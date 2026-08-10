defmodule Pokex.Bots.Cavebot.WalkTestTest do
  @moduledoc """
  The hunt's smallest rehearsal. Its whole value is telling the three failures
  apart — keys not arriving, position not read, or everything fine — so those
  are exactly what is pinned here.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.WalkTest

  defmodule FakeBody do
    @moduledoc false
    def arrow_step(dx, dy, _opts) do
      send(self(), {:stepped, dx, dy})
      key = if abs(dx) >= abs(dy), do: if(dx > 0, do: "right", else: "left"), else: "down"
      {:ok, key}
    end
  end

  defmodule ShutBody do
    @moduledoc false
    def arrow_step(_dx, _dy, _opts), do: {:error, :input_gate_closed}
  end

  defp reader(positions) do
    {:ok, agent} = Agent.start_link(fn -> positions end)

    fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [head | tail] -> {head, tail}
      end)
    end
  end

  defp opts(body, positions) do
    [
      body: body,
      read: reader(positions),
      sleep: fn _ms -> :ok end,
      steps: 3,
      # the real ones front the game and click its neutral point; here they
      # only have to prove they run BEFORE the first press
      front: fn fun -> send(self(), :fronted) && fun.() end,
      focus: fn -> send(self(), :focus_clicked) end
    ]
  end

  # The regression that cost a live test: `Hands` was nested INSIDE WalkTest,
  # below the line that names it, so the default resolved to a top-level
  # `Hands` that does not exist — every real run died with
  # UndefinedFunctionError inside its task, silently, and the button spun
  # "andando…" forever. The injected fake never touched it.
  test "the DEFAULT hands exist and answer arrow_step/3" do
    hands = Pokex.Bots.Cavebot.Hands

    assert Code.ensure_loaded?(hands)
    assert function_exported?(hands, :arrow_step, 3)
    assert hands.arrow_step(0, 0, []) == {:error, :no_direction}
  end

  test "the game is fronted and clicked BEFORE any key goes out" do
    positions = [{10, 10, 7}, {11, 10, 7}]

    assert {:ok, _result} = WalkTest.run(%{x: 20, y: 10}, opts(FakeBody, positions))

    # order matters: a key pressed before the click lands in the BROWSER
    assert_received :fronted
    assert_received :focus_clicked
    assert_received {:stepped, _dx, _dy}
  end

  test "the character moved: it reports from where to where, and how far" do
    positions = [{10, 10, 7}, {11, 10, 7}, {12, 10, 7}, {13, 10, 7}]

    assert {:ok, result} = WalkTest.run(%{x: 20, y: 10}, opts(FakeBody, positions))
    assert result.from == {10, 10, 7}
    assert result.to == {13, 10, 7}
    assert result.tiles == 3
    assert result.presses == ["right", "right", "right"]

    # the direction FOLLOWS the character: each press is aimed from where it
    # now stands, not from the plan made at the start
    assert_received {:stepped, 10, 0}
    assert_received {:stepped, 9, 0}
    assert_received {:stepped, 8, 0}
  end

  test "presses went out and nothing moved: the keys are not reaching the game" do
    assert WalkTest.run(%{x: 20, y: 10}, opts(FakeBody, [{10, 10, 7}])) ==
             {:error, :did_not_move}
  end

  test "no position: nothing is pressed, because walking blind is the disease" do
    assert WalkTest.run(%{x: 20, y: 10}, opts(FakeBody, [nil])) == {:error, :no_position}
    refute_received {:stepped, _dx, _dy}
  end

  test "a shut gate answers out loud, with the reason" do
    assert WalkTest.run(%{x: 20, y: 10}, opts(ShutBody, [{10, 10, 7}])) ==
             {:error, {:refused, :input_gate_closed}}
  end

  test "with no target it still moves — east and one tile is an honest round trip" do
    positions = [{10, 10, 7}, {11, 10, 7}]

    assert {:ok, %{tiles: 1}} = WalkTest.run(nil, [{:steps, 1} | opts(FakeBody, positions)])
    assert_received {:stepped, 1, 0}
  end
end
