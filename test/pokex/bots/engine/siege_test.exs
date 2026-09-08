defmodule Pokex.Bots.Engine.SiegeTest do
  @moduledoc """
  The siege judged from the eye's reading, as a table.

  Every row is one of the four piles (pinned, covered, loose, unseen) or the
  recall gap, and the words are what his feed will show next to a revive.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Siege

  @config %{pin_tiles: 1, stun_reach_tiles: 3, stun_hold_ms: 4_000}
  @tile 36

  defp hostile(dx, dy, opts \\ []) do
    %{
      point: {dx * @tile, dy * @tile},
      dx: dx,
      dy: dy,
      from_me: max(abs(dx), abs(dy)),
      from_pet: Keyword.get(opts, :from_pet, max(abs(dx), abs(dy))),
      hp_pct: Keyword.get(opts, :hp, 100),
      skull?: Keyword.get(opts, :skull?, false)
    }
  end

  defp pet(dx \\ -1, dy \\ 0),
    do: %{
      point: {dx * @tile, dy * @tile},
      dx: dx,
      dy: dy,
      tiles: max(abs(dx), abs(dy)),
      hp_pct: 90
    }

  defp eye(hostiles, opts \\ []) do
    %{
      read?: true,
      at: Keyword.get(opts, :at, 1_000),
      me: {0, 0},
      pet: Keyword.get(opts, :pet, pet()),
      hostiles: hostiles,
      listed: nil
    }
  end

  describe "without an eye" do
    test "no reading at all: nothing is known and the gap is never open" do
      siege = Siege.build(nil, 3, nil, @config, 1_000)

      assert siege.read? == false
      assert siege.recall_gap_ok? == false
      assert siege.pinned == 0 and siege.loose == 0 and siege.unseen == 0
      assert Siege.summary(siege) == "sem olho → só o sono fresco vale"
    end

    test "an unread picture says how old the last one is" do
      siege = Siege.build(%{read?: false, reason: :no_frame, at: 400}, 3, nil, @config, 1_000)

      assert siege.read? == false
      assert Siege.summary(siege) == "sem olho (foto de 600 ms) → só o sono fresco vale"
    end
  end

  describe "the four piles" do
    test "biting the pokemon is pinned; awake and away is loose; the list's surplus is unseen" do
      siege =
        Siege.build(eye([hostile(-2, 0, from_pet: 1), hostile(3, 0)]), 5, nil, @config, 1_000)

      assert siege.pinned == 1
      assert siege.loose == 1
      assert siege.unseen == 3
      assert siege.covered == 0
      assert siege.nearest_awake_from_me == 2
    end

    test "pin_tiles is the ruler of 'colado'" do
      wide = %{@config | pin_tiles: 2}
      siege = Siege.build(eye([hostile(-3, 0, from_pet: 2)]), 1, nil, wide, 1_000)

      assert siege.pinned == 1 and siege.loose == 0
    end

    test "a fresh cover puts the creatures it reached to sleep" do
      cover = %{at: 500, pet: {-1, 0}, points: [{-2, 0}]}
      siege = Siege.build(eye([hostile(-2, 0, from_pet: 1)]), 1, cover, @config, 1_000)

      assert siege.covered == 1
      assert siege.loose == 0
      assert siege.nearest_awake_from_me == nil
      assert siege.recall_gap_ok? == true
    end

    test "the cover matches within one tile — the creature may have shifted" do
      cover = %{at: 500, pet: {-1, 0}, points: [{-2, 0}]}
      siege = Siege.build(eye([hostile(-3, 1, from_pet: 2)]), 1, cover, @config, 1_000)

      assert siege.covered == 1
    end

    test "a stale cover covers nobody" do
      cover = %{at: 0, pet: {-1, 0}, points: [{-2, 0}]}

      siege =
        Siege.build(eye([hostile(-2, 0, from_pet: 1, skull?: true)]), 1, cover, @config, 5_000)

      assert siege.covered == 0
      assert siege.nearest_awake_from_me == 2
      assert siege.recall_gap_ok? == false
    end

    test "whoever arrived after the stun matches no point and stays awake" do
      cover = %{at: 500, pet: {-1, 0}, points: [{-2, 0}]}

      siege =
        Siege.build(eye([hostile(-2, 0, from_pet: 1), hostile(4, 4)]), 2, cover, @config, 1_000)

      assert siege.covered == 1
      assert siege.loose == 1
      assert siege.nearest_awake_from_me == 4
    end
  end

  describe "the recall gap" do
    test "with skulls the guard is four tiles" do
      close = Siege.build(eye([hostile(3, 0, skull?: true)]), 1, nil, @config, 1_000)
      far = Siege.build(eye([hostile(4, 0, skull?: true)]), 1, nil, @config, 1_000)

      assert close.heavy? and close.recall_gap_ok? == false
      assert far.heavy? and far.recall_gap_ok? == true
    end

    test "without skulls the guard is two" do
      close = Siege.build(eye([hostile(1, 0)]), 1, nil, @config, 1_000)
      far = Siege.build(eye([hostile(2, 0)]), 1, nil, @config, 1_000)

      refute close.heavy?
      assert close.recall_gap_ok? == false
      assert far.recall_gap_ok? == true
    end

    test "the brain's latch makes a skull-less picture heavy" do
      siege = Siege.build(eye([hostile(3, 0)]), 1, nil, @config, 1_000, heavy?: true)

      assert siege.heavy?
      assert siege.recall_gap_ok? == false
    end

    test "unseen creatures are awake somewhere unless the stun is fresh" do
      awake = Siege.build(eye([]), 2, nil, @config, 1_000)
      cover = %{at: 800, pet: {-1, 0}, points: []}
      stacked = Siege.build(eye([]), 2, cover, @config, 1_000)

      assert awake.unseen == 2 and awake.recall_gap_ok? == false
      assert stacked.unseen == 2 and stacked.recall_gap_ok? == true
    end

    test "an empty picture with an empty list is a clear field" do
      siege = Siege.build(eye([]), 0, nil, @config, 1_000)

      assert siege.recall_gap_ok? == true
    end
  end

  describe "the cover" do
    test "takes the pokemon's offset and every creature within the stun's reach" do
      siege =
        Siege.build(
          eye([
            hostile(-2, 0, from_pet: 1),
            hostile(2, 0, from_pet: 3),
            hostile(5, 0, from_pet: 6)
          ]),
          3,
          nil,
          @config,
          1_000
        )

      assert Siege.cover(siege, @config, 1_000) == %{
               at: 1_000,
               pet: {-1, 0},
               points: [{-2, 0}, {2, 0}]
             }
    end

    test "without a pokemon in the picture nobody is covered" do
      siege = Siege.build(eye([hostile(-2, 0, from_pet: nil)], pet: nil), 1, nil, @config, 1_000)

      assert Siege.cover(siege, @config, 1_000) == %{at: 1_000, pet: nil, points: []}
    end

    test "without an eye there is no cover either" do
      siege = Siege.build(nil, 1, nil, @config, 1_000)

      assert Siege.cover(siege, @config, 1_000) == %{at: 1_000, pet: nil, points: []}
    end
  end

  describe "the words" do
    test "a held recall, spelled out" do
      siege =
        Siege.build(eye([hostile(-2, 0, from_pet: 1), hostile(3, 0)]), 5, nil, @config, 1_000)

      assert Siege.summary(siege) ==
               "olho: 1 colado acordado · 1 solto a 3 tiles · 3 sem ver → segurando"
    end

    test "a safe recall in a heavy area, with the pile asleep" do
      cover = %{at: 500, pet: {-1, 0}, points: [{-2, 0}, {-2, 1}]}

      siege =
        Siege.build(
          eye([
            hostile(-2, 0, from_pet: 1, skull?: true),
            hostile(-2, 1, from_pet: 1, skull?: true)
          ]),
          2,
          cover,
          @config,
          1_000
        )

      assert Siege.summary(siege) ==
               "olho (caveira): 2 colados dormindo · ninguém solto · 0 sem ver → revive seguro"
    end

    test "the record is numbers only" do
      siege = Siege.build(eye([hostile(-2, 0, from_pet: 1)]), 3, nil, @config, 1_000)

      assert Siege.record(siege) == %{
               read: true,
               heavy: false,
               pinned: 1,
               covered: 0,
               loose: 0,
               unseen: 2,
               gap: false
             }
    end
  end
end
