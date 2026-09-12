defmodule Pokex.Bots.Catcher.FactTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Fact
  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Bots.Catcher.Trail

  @ref %{me: {1695, 686}, tile: 151, pos: {100, 100, 7}}

  defp armed, do: Logic.new(%{}) |> Logic.start(0) |> elem(0)

  test "an empty trail and no logic at all are a quiet fact" do
    assert Fact.build(Trail.new(), nil, false, @ref, 0) ==
             %{pending: 0, anchors: 0, hunted?: false, armed?: false}
  end

  test "a bar the guard marked, still standing, is hunted and no body yet" do
    trail =
      Trail.observe(
        Trail.new(),
        %{
          read?: true,
          hostiles: [%{point: {1695, 384}, special?: true, special_name: "Shiny (brilho)"}],
          pet: nil
        },
        @ref,
        0
      )

    assert %{hunted?: true, anchors: 0} = Fact.build(trail, armed(), true, @ref, 0)
  end

  # O PRAZO É DO CATCHER. Ele era emprestado do vigia (`special_color_scan_ms`,
  # a cadência da varredura de cor): duas coisas sem relação, e mexer numa
  # mudava em silêncio quanto tempo o cérebro acreditava na outra.
  test "the fact's shelf life is three pulses of the worker, not the guard's cadence" do
    assert Fact.max_age_ms() == Fact.pulse_ms() * 3
    assert Fact.max_age_ms() == 3_000
  end

  test "the snapshot's capture fields are cut from the same fact" do
    fact = %{pending: 2, anchors: 1, hunted?: true, armed?: true}
    assert Fact.snapshot_fields(fact) == %{pending_corpses: 2, anchors: 1, hunted?: true}
  end
end
