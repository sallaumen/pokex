defmodule Pokex.Bots.Engine.WorkerTest do
  @moduledoc """
  The engine's eyes: it publishes the shared picture and narrates the two
  measurements this step exists to take — how many monsters are really there,
  and whether his own pokémon occupies a row in the battle list.

  Not async: the picture goes on the one shared blackboard every test reads.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Engine.Worker
  alias Pokex.Perception.WorldState

  setup do
    WorldState.clear()
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    {:ok, worker} = Worker.start_link(name: nil, active: false)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)

    :ok = Worker.run(worker)
    assert_receive {:engine_log, :macro, "quadro: olhando a tela" <> _}

    %{worker: worker}
  end

  defp see(names) do
    detail =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, row} -> %{row: row, name: name, hp_pct: 1.0, shiny?: false} end)

    WorldState.put(
      :battle,
      %{
        enemies: Enum.to_list(0..(length(names) - 1)//1),
        enemies_detail: detail,
        locked?: false,
        locked_row: nil
      },
      now()
    )
  end

  # A GenServer call is the cheap barrier: it can only be answered after the
  # :tick already in the mailbox has been handled.
  defp settle(worker), do: Worker.status(worker)

  # The shadow line — what the engine WOULD have ordered — rides every tick that
  # changes the decision. These tests are about the picture, so they consume it
  # and let `shadow_test.exs` be the one that reads it.
  defp assert_shadow do
    assert_receive {:engine_log, :macro, "quadro: 🧠" <> _}
  end

  defp now, do: System.monotonic_time(:millisecond)

  describe "the shared picture" do
    test "lands on the blackboard for everyone to read", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))
      send(worker, :tick)
      settle(worker)

      assert {:ok, picture} = WorldState.get(:situation, 5_000, now())
      assert picture.enemies == 3
      assert picture.worth_fighting? == true
    end

    test "an unread battle panel publishes an unknown, never a zero", %{worker: worker} do
      send(worker, :tick)
      settle(worker)

      assert {:ok, picture} = WorldState.get(:situation, 5_000, now())
      assert picture.enemies == nil
      assert picture.blind? == true
    end

    test "halting takes the picture down with it", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))
      send(worker, :tick)
      settle(worker)

      :ok = Worker.halt(worker)

      assert WorldState.get(:situation, 5_000, now()) == :missing
    end
  end

  describe "narrating (the tick is 200ms — only edges may speak)" do
    test "says the count once, not once per tick", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))

      send(worker, :tick)
      settle(worker)
      assert_receive {:engine_log, :macro, text}
      assert text =~ "3 inimigos na tela"
      assert text =~ "Venonat 100%, Paras 100%, Venomoth 100%"
      # the own-row measurement rides the same first tick — see its own test
      assert_receive {:engine_log, :macro, _measurement}
      assert_shadow()

      send(worker, :tick)
      send(worker, :tick)
      settle(worker)

      refute_receive {:engine_log, :macro, _}, 20
    end

    test "speaks again when the count changes", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))
      send(worker, :tick)
      settle(worker)
      assert_receive {:engine_log, :macro, _first}
      assert_receive {:engine_log, :macro, _measurement}
      assert_shadow()

      see(~w(Venonat Paras Venomoth Oddish))
      send(worker, :tick)
      settle(worker)

      assert_receive {:engine_log, :macro, text}
      assert text =~ "4 inimigos na tela"
    end

    test "says it lost the list rather than reporting an empty screen", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))
      send(worker, :tick)
      settle(worker)
      assert_receive {:engine_log, :macro, _count}
      assert_receive {:engine_log, :macro, _measurement}
      assert_shadow()

      WorldState.forget(:battle)
      send(worker, :tick)
      settle(worker)

      assert_receive {:engine_log, :macro, text}
      assert text =~ "não sei quantos são"
    end

    # THE MEASUREMENT this step exists for. With no pokémon chosen there is no
    # name to match, so the honest reading is "none of these rows is him".
    test "reports whether his own pokémon takes a row", %{worker: worker} do
      see(~w(Venonat Paras))
      send(worker, :tick)
      settle(worker)

      assert_receive {:engine_log, :macro, count}
      assert count =~ "2 inimigos"

      assert_receive {:engine_log, :macro, measurement}
      assert measurement =~ "NÃO aparece na lista"
      assert measurement =~ "2 linha(s)"
    end

    test "stays quiet about the own row while it cannot be told", %{worker: worker} do
      WorldState.put(
        :battle,
        %{enemies: [0, 1, 2], enemies_detail: [], locked?: false, locked_row: nil},
        now()
      )

      send(worker, :tick)
      settle(worker)

      assert_receive {:engine_log, :macro, text}
      assert text == "quadro: 3 inimigos na tela"
      assert_shadow()
      refute_receive {:engine_log, :macro, _}, 20
    end
  end
end
