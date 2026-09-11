defmodule Pokex.Bots.Catcher.TrailTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Trail

  # his ultrawide: the character mid-screen, a tile of 151 px
  @me {1695, 686}
  @tile 151

  defp ref(pos \\ {100, 100, 7}), do: %{me: @me, tile: @tile, pos: pos}

  # a creature standing `dx, dy` tiles from the character, as the eye reports it
  defp at(dx, dy, extra \\ %{}) do
    {mx, my} = @me
    Map.merge(%{point: {mx + round(dx * @tile), my + round(dy * @tile)}}, extra)
  end

  defp reading(hostiles, pet), do: %{read?: true, hostiles: hostiles, pet: pet}

  defp look(trail, hostiles, now, opts \\ []) do
    Trail.observe(trail, reading(hostiles, opts[:pet]), ref(opts[:pos] || {100, 100, 7}), now)
  end

  test "the hunted creature is followed while it walks, and its fall is the anchor" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}

    trail =
      Trail.new()
      |> look([at(-2, -3, shiny)], 0)
      |> look([at(-1.5, -2.5)], 250)
      |> look([at(-1, -2)], 500)
      |> look([at(-0.5, -1.5)], 750)
      |> look([at(0, -1)], 1_000)

    assert %{name: "Shiny Golem", screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(0, -1).point

    # the bar is gone: one look is nothing, three is a death — the corpse lies
    # where the creature last stood
    trail = trail |> look([], 1_250) |> look([], 1_500)
    assert Trail.anchors(trail, ref(), 1_500) == []
    assert Trail.hunted(trail, ref())

    trail = look(trail, [], 1_750)

    assert [%{name: "Shiny Golem", px: 394, screen: anchor, fallen_at: 1_750}] =
             Trail.anchors(trail, ref(), 1_750)

    assert anchor == at(0, -1).point
    refute Trail.hunted(trail, ref())
  end

  test "two creatures crossing keep their identities" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      # A (hunted) walks right along y=-2; B walks left along the same row
      |> look([at(-3, -2, shiny), at(3, -2)], 0)
      |> look([at(-2, -2), at(2, -2)], 250)
      |> look([at(-1, -2), at(1, -2)], 500)
      |> look([at(0, -2), at(0, -2)], 750)
      |> look([at(1, -2), at(-1, -2)], 1_000)
      |> look([at(2, -2), at(-2, -2)], 1_250)

    assert %{screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(2, -2).point, "the hunted track swapped to the other creature"
  end

  test "his own pokemon standing on the hunted creature covers it, it does not kill it" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}
    pet_on_top = %{point: at(0, -2).point}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0)
      |> look([], 250, pet: pet_on_top)
      |> look([], 500, pet: pet_on_top)
      |> look([], 750, pet: pet_on_top)
      |> look([], 1_000, pet: pet_on_top)

    assert Trail.anchors(trail, ref(), 1_000) == []
    assert %{name: "Shiny Golem"} = Trail.hunted(trail, ref())

    # …and when the pet steps aside the bar is the same creature
    trail = look(trail, [at(0.5, -2)], 1_250)
    assert %{screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(0.5, -2).point
  end

  test "the character walking does not move the creatures: tracks live in world tiles" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      |> look([at(2, 0, shiny)], 0, pos: {100, 100, 7})
      # the character stepped two tiles right: the same creature is now on him
      |> look([at(0, 0)], 1_000, pos: {102, 100, 7})
      |> look([at(-1, 0)], 2_000, pos: {103, 100, 7})

    assert [_one_track] = Map.values(trail.tracks)
    assert %{world: {102.0, 100.0}} = Trail.hunted(trail, ref({103, 100, 7}))

    # it falls; three looks later the anchor is asked from yet another place
    trail =
      trail
      |> look([], 3_000, pos: {103, 100, 7})
      |> look([], 3_250, pos: {103, 100, 7})
      |> look([], 3_500, pos: {103, 100, 7})

    assert [%{screen: screen}] = Trail.anchors(trail, ref({105, 100, 7}), 3_500)
    assert screen == at(-3, 0).point
  end

  test "a minimap that went blind keeps the last position" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      |> look([at(2, 0, shiny)], 0, pos: {100, 100, 7})
      |> look([at(2, 0)], 250, pos: nil)

    assert %{world: {102.0, 100.0}} = Trail.hunted(trail, %{me: @me, tile: @tile, pos: nil})
  end

  test "the guard's blob names the track under it, or is born as one" do
    trail =
      Trail.new()
      |> look([at(1, 1), at(-2, 0)], 0)
      |> Trail.hunt_at(at(1, 1).point, "Shiny Golem", 200, ref(), 100)

    assert %{name: "Shiny Golem", screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(1, 1).point

    born = Trail.hunt_at(Trail.new(), at(3, 3).point, "Shiny Golem", 200, ref(), 0)
    assert %{name: "Shiny Golem"} = Trail.hunted(born, ref())
  end

  test "an anchor is spent by the ball and dies of old age" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0)
      |> look([], 250)
      |> look([], 500)
      |> look([], 750)

    assert [%{world: world}] = Trail.anchors(trail, ref(), 750)
    assert Trail.anchors(trail, ref(), 750 + 121_000) == []
    assert Trail.anchors(Trail.spend(trail, world), ref(), 750) == []
  end

  # 12:39 of 11/09: eight bars in the pile, and the hunted Shiny Golem was gone
  # from the trail two seconds after the sighting — a miss on ANY other track
  # threw away every track matched before it.
  test "another creature missing a look does not lose the hunted one" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 228}

    trail =
      Trail.new()
      |> look([at(3, 2, shiny), at(-1, 0), at(1, 1), at(0, -2)], 0)
      # the far one blinks out of the reading for a few looks; the shiny stays
      |> look([at(3, 2), at(-1, 0), at(1, 1)], 250)
      |> look([at(2, 2), at(-1, 0), at(1, 1)], 500)
      |> look([at(2, 1), at(-1, 0), at(1, 1), at(0, -2)], 750)

    assert %{name: "Shiny Golem", screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(2, 1).point
    assert map_size(trail.tracks) == 4
  end

  test "an ordinary creature that vanishes is simply forgotten" do
    trail =
      Trail.new()
      |> look([at(1, 1)], 0)
      |> look([], 250)
      |> look([], 500)
      |> look([], 750)
      |> look([], 1_000)

    assert trail.tracks == %{}
    assert trail.anchors == []
  end
end
