defmodule Pokex.Bots.Catcher.MultipleTargetsTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Logic

  defp config do
    %{
      corpse_match_tolerance_px: 32,
      corpse_max_balls: 2,
      corpse_ignore_ttl_ms: 120_000,
      corpse_confirm_after_ms: 800,
      feed_corpses_ms: 400
    }
  end

  defp armed do
    {logic, []} = Logic.start(Logic.new(config()), 0)
    logic
  end

  defp obs(corpses, at), do: %{scanning?: true, corpses: corpses, captured_at: at}

  defp obs(corpses, at, source),
    do: %{scanning?: true, source: source, corpses: corpses, captured_at: at}

  test "retains each queued shiny identity after the first target leaves the observation" do
    observation = %{
      scanning?: true,
      source: :anchor,
      corpses: [{100, 200}, {300, 300}],
      known: %{
        {100, 200} => %{name: "Shiny Golem", hunted?: true},
        {300, 300} => %{name: "Shiny Onix", hunted?: true}
      },
      captured_at: 10
    }

    {logic, _} = Logic.step(armed(), observation, 10)
    {logic, actions} = Logic.step(logic, obs([{300, 300}], 900, :anchor), 900)

    assert {:capture_sequence, {300, 300}, "Shiny Onix"} in actions
    assert logic.throw.source == :anchor
    assert Logic.pending(logic) == 1
  end

  test "keeps queued shinies ahead of ordinary corpses when detectors alternate" do
    {logic, _} = Logic.step(armed(), obs([{50, 50}, {80, 150}], 10), 10)

    anchors = %{
      scanning?: true,
      source: :anchor,
      corpses: [{300, 300}, {500, 300}],
      known: %{
        {300, 300} => %{name: "Shiny Golem", hunted?: true},
        {500, 300} => %{name: "Shiny Onix", hunted?: true}
      },
      captured_at: 20
    }

    {logic, _} = Logic.step(logic, anchors, 20)
    {logic, actions} = Logic.step(logic, obs([], 900), 900)
    refute Enum.any?(actions, &match?({:capture_sequence, _, _}, &1))
    {logic, actions} = Logic.step(logic, %{anchors | captured_at: 1_000}, 1_000)
    assert {:capture_sequence, {300, 300}, "Shiny Golem"} in actions
    logic = Logic.ball_refused(logic)
    {logic, actions} = Logic.step(logic, %{anchors | captured_at: 1_010}, 1_010)
    assert {:capture_sequence, {500, 300}, "Shiny Onix"} in actions
    assert Logic.pending(logic) == 3
  end

  test "promotes an already queued corpse when it is identified as shiny" do
    {logic, _} = Logic.step(armed(), obs([{50, 50}, {150, 150}, {300, 300}], 10), 10)

    shiny = %{
      scanning?: true,
      source: :anchor,
      corpses: [{300, 300}],
      known: %{{300, 300} => %{name: "Shiny Golem", hunted?: true}},
      captured_at: 20
    }

    {logic, _} = Logic.step(logic, shiny, 20)
    {logic, _} = Logic.step(logic, obs([], 900), 900)
    {_logic, actions} = Logic.step(logic, %{shiny | captured_at: 1_000}, 1_000)
    assert {:capture_sequence, {300, 300}, "Shiny Golem"} in actions
  end

  test "does not throw at an anchor removed from the current eligible targets" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}, {300, 300}], 10, :anchor), 10)
    {logic, actions} = Logic.step(logic, obs([], 900, :anchor), 900)
    refute Enum.any?(actions, &match?({:capture_sequence, _, _}, &1))
    assert Logic.pending(logic) == 0
  end

  test "discards refused screen targets when the character moves before retrying" do
    first = Map.put(obs([{100, 200}, {300, 300}], 10), :pos, {100, 100, 7})
    {logic, _} = Logic.step(armed(), first, 10)
    logic = Logic.ball_refused(logic)
    next = Map.put(obs([], 20), :pos, {101, 100, 7})
    {logic, actions} = Logic.step(logic, next, 20)
    refute Enum.any?(actions, &match?({:capture_sequence, _, _}, &1))
    assert Logic.pending(logic) == 0
  end

  test "keeps nearby anchor points distinct even inside the image matching tolerance" do
    first = %{
      scanning?: true,
      source: :anchor,
      corpses: [{100, 200}],
      known: %{{100, 200} => %{name: "Shiny Golem", hunted?: true}},
      captured_at: 10
    }

    second = %{
      first
      | corpses: [{100, 200}, {120, 200}],
        known: Map.put(first.known, {120, 200}, %{name: "Shiny Onix", hunted?: true}),
        captured_at: 20
    }

    {logic, _} = Logic.step(armed(), first, 10)
    {logic, _} = Logic.step(logic, second, 20)
    assert Logic.pending(logic) == 2
    next = %{second | corpses: [{120, 200}], captured_at: 900}
    {_logic, actions} = Logic.step(logic, next, 900)
    assert {:capture_sequence, {120, 200}, "Shiny Onix"} in actions
  end
end
