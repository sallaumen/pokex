defmodule Pokex.Bots.Engine.SituationTest do
  @moduledoc """
  The shared tactical picture: what is TRUE, before anybody decides anything.

  Every rule here answers a sentence he said on 2026-08-17, and the picture is
  deliberately honest about not knowing — `nil` is a legal answer, and telling
  "the screen is empty" apart from "I cannot see the screen" is the whole point
  of this module existing.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Situation

  @config %{engage_from: 3, stun_sleep_ms: 2_000}

  # His battle panel as the located layout reads it: one row per creature, with
  # the name read by glyphs against the Pokédex.
  defp battle(names, opts \\ []) do
    detail =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, row} ->
        %{row: row, name: name, hp_pct: 1.0, shiny?: false}
      end)

    %{
      enemies: Enum.to_list(0..(length(names) - 1)//1),
      enemies_detail: detail,
      locked?: Keyword.get(opts, :locked?, false),
      locked_row: nil
    }
  end

  # The same panel WITHOUT a located layout: rows are counted, names are not
  # readable. `enemies_detail` comes back empty (interpret.ex:120).
  defp nameless(count) do
    %{
      enemies: Enum.to_list(0..(count - 1)//1),
      enemies_detail: [],
      locked?: false,
      locked_row: nil
    }
  end

  defp inputs(overrides \\ %{}) do
    Map.merge(
      %{
        battle: battle(~w(Venonat Paras Venomoth)),
        own_hp: 90,
        own_out?: true,
        own_name: "Vespiquen",
        ready_keys: ~w(3 4 5 6 7 8 9),
        damage_keys: ~w(3 4 5 6 7 8 9),
        stun_at: nil,
        prev: nil
      },
      overrides
    )
  end

  describe "counting what is on the screen" do
    test "counts the rows the battle panel shows" do
      picture = Situation.build(inputs(), @config, 1_000)

      assert picture.rows == 3
      assert picture.enemies == 3
    end

    # "lembrando de não contar o próprio, porque o meu é o primeiro sempre da
    # tela de batalha" (2026-08-17). Whether his pokémon appears at all is the
    # measurement this PR exists to settle — so the picture SUBTRACTS it when it
    # recognises it, and says so.
    test "does not count his own pokémon among the enemies" do
      picture =
        inputs(%{battle: battle(~w(Vespiquen Venonat Paras Venomoth))})
        |> Situation.build(@config, 1_000)

      assert picture.rows == 4
      assert picture.enemies == 3
      assert picture.own_row_seen? == true
    end

    # team.json says "Shiny Vileplume"; the panel reads "Vileplume" (his capture
    # of 11/08 22:14). A prefix must never make the bot count itself as an enemy.
    test "recognises his own pokémon even when the panel drops the Shiny prefix" do
      picture =
        inputs(%{battle: battle(~w(Vileplume Venonat)), own_name: "Shiny Vileplume"})
        |> Situation.build(@config, 1_000)

      assert picture.enemies == 1
      assert picture.own_row_seen? == true
    end

    test "says so when his pokémon is NOT among the rows" do
      picture = Situation.build(inputs(), @config, 1_000)
      assert picture.own_row_seen? == false
    end

    # Without a located layout there are no names, so the own row cannot be
    # identified. The count stays RAW and the unknown is stated — a guessed
    # subtraction here is the difference between attacking and walking away.
    test "with no names readable, the count is raw and the own row is unknown" do
      picture =
        inputs(%{battle: nameless(4)})
        |> Situation.build(@config, 1_000)

      assert picture.rows == 4
      assert picture.enemies == 4
      assert picture.own_row_seen? == nil
      assert picture.named == []
    end

    # "não vale nem atacar" below the ruler (R1).
    test "three enemies is worth fighting; two is not" do
      assert Situation.build(inputs(), @config, 1_000).worth_fighting? == true

      picture =
        inputs(%{battle: battle(~w(Venonat Paras))})
        |> Situation.build(@config, 1_000)

      assert picture.worth_fighting? == false
    end
  end

  describe "not seeing the screen" do
    # An empty screen and an unreadable screen are the same pixels to a counter
    # and opposite facts to a decision. `nil` is the honest answer.
    test "a missing battle reading is nil, never zero" do
      picture =
        inputs(%{battle: nil})
        |> Situation.build(@config, 1_000)

      assert picture.rows == nil
      assert picture.enemies == nil
      assert picture.worth_fighting? == false
      assert picture.blind? == true
    end

    test "an empty battle list is zero, and not blind" do
      picture =
        inputs(%{battle: %{enemies: [], enemies_detail: [], locked?: false, locked_row: nil}})
        |> Situation.build(@config, 1_000)

      assert picture.enemies == 0
      assert picture.blind? == false
    end
  end

  describe "is the pile still walking in" do
    test "a count that rose is growing, and the clock restarts" do
      before = Situation.build(inputs(), @config, 1_000)

      picture =
        inputs(%{battle: battle(~w(Venonat Paras Venomoth Oddish)), prev: before})
        |> Situation.build(@config, 1_600)

      assert picture.growing? == true
      assert picture.stable_for_ms == 0
    end

    test "a count that held still measures how long it has held" do
      before = Situation.build(inputs(), @config, 1_000)

      picture =
        inputs(%{prev: before})
        |> Situation.build(@config, 2_800)

      assert picture.growing? == false
      assert picture.stable_for_ms == 1_800
    end

    # A death shrinks the list, and a pile that is dying is not a pile still
    # arriving — the settle clock must not restart on it.
    test "a count that fell is not growing, and does not restart the clock" do
      before = Situation.build(inputs(), @config, 1_000)

      picture =
        inputs(%{battle: battle(~w(Venonat)), prev: before})
        |> Situation.build(@config, 2_800)

      assert picture.growing? == false
      assert picture.stable_for_ms == 1_800
    end

    test "the first reading of a hunt has no history and starts its own clock" do
      picture = Situation.build(inputs(), @config, 5_000)

      assert picture.growing? == false
      assert picture.stable_for_ms == 0
    end
  end

  describe "the stun clock (R4: time alone, never contradicted)" do
    test "a stun pressed just now leaves the screen asleep" do
      picture =
        inputs(%{stun_at: 1_000})
        |> Situation.build(@config, 1_500)

      assert picture.asleep? == true
      assert picture.asleep_until == 3_000
    end

    test "the sleep expires on the clock" do
      picture =
        inputs(%{stun_at: 1_000})
        |> Situation.build(@config, 3_001)

      assert picture.asleep? == false
    end

    test "no stun pressed means no sleep" do
      picture = Situation.build(inputs(), @config, 1_000)

      assert picture.asleep? == false
      assert picture.asleep_until == nil
    end
  end

  describe "cooldowns" do
    # The revive is worth most when the cooldowns are already gone (R3), so the
    # picture has to be able to say that they are.
    test "most damage keys cooling means spent" do
      picture =
        inputs(%{ready_keys: ~w(9)})
        |> Situation.build(@config, 1_000)

      assert picture.spent? == true
    end

    test "a full bar is not spent" do
      assert Situation.build(inputs(), @config, 1_000).spent? == false
    end

    test "no skill-bar reading is an unknown, not a false" do
      picture =
        inputs(%{ready_keys: nil})
        |> Situation.build(@config, 1_000)

      assert picture.spent? == nil
    end

    test "a pokémon with no damage keys classified cannot be spent" do
      picture =
        inputs(%{damage_keys: [], ready_keys: []})
        |> Situation.build(@config, 1_000)

      assert picture.spent? == nil
    end
  end
end
