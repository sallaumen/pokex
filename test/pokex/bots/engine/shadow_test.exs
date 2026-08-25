defmodule Pokex.Bots.Engine.ShadowTest do
  @moduledoc """
  The engine deciding out loud while nobody obeys.

  Trading the brain of a system that runs eight hours unattended without first
  comparing it against a real night would be irresponsible — so this step
  publishes orders and narrates them beside what the bot actually did, and
  changes nothing.

  The last test here is the one that matters most: it proves the orders reach
  the blackboard and the posture the fight really obeys is NOT touched.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Engine.Worker
  alias Pokex.Perception.WorldState

  setup do
    # The settle floor is a real 1.5s of wall clock, and the worker reads the
    # monotonic clock it cannot be lied to about. Zero here makes "the count
    # held still" true on the second reading — the rule under test is the
    # RULER, and `logic_test.exs` is where the floor itself is measured.
    Pokex.SettingsStash.stash!(engine_pile_settle_ms: 0)
    # A brain with no configured pokémon has no hands, and since 2026-08-25 it
    # SAYS so instead of narrating a fight it cannot have. These tests are about
    # the ruler, so they put a creature on the field first.
    Pokex.TeamFixtures.ready!("Bulbasaur",
      count: 4,
      skills: %{"1" => :aoe, "2" => :single, "3" => :single, "4" => :crowd}
    )

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

  defp hunting(overrides \\ %{}) do
    WorldState.put(
      :hunt,
      Map.merge(
        %{
          state: :walking,
          luring?: false,
          gathering?: false,
          wp_index: 12,
          waypoints: 70,
          recovering?: false
        },
        overrides
      ),
      now()
    )
  end

  defp tick(worker) do
    send(worker, :tick)
    Worker.status(worker)
  end

  defp orders do
    {:ok, orders} = WorldState.get(:orders, 5_000, now())
    orders
  end

  defp now, do: System.monotonic_time(:millisecond)

  test "the orders reach the blackboard", %{worker: worker} do
    see(~w(Venonat Paras Venomoth))
    hunting(%{luring?: true})
    tick(worker)

    assert orders().phase == :gathering
    assert orders().route == :go
    assert orders().fire == :hold
    assert orders().why =~ "mobando"
  end

  test "with no hunt running there is nothing to decide", %{worker: worker} do
    see(~w(Venonat Paras Venomoth))
    tick(worker)

    assert orders().phase == :idle
    assert orders().why =~ "sem caçada"
  end

  test "it says out loud what it would have done", %{worker: worker} do
    see(~w(Venonat Paras Venomoth))
    hunting(%{state: :fighting})
    tick(worker)

    assert_receive {:engine_log, :macro, "quadro: 🧠" <> shadow}
    assert shadow =~ "3 inimigos"
    assert shadow =~ "estourando a área"
    assert shadow =~ "[liberaria o fogo]"
  end

  # R1 no campo, na forma que ele deu a ela em 25/08: UM monstro num canto não
  # é uma luta, é uma pilha pra carregar junto enquanto a caçada anda — e a
  # régua de passos é quem diz quando ela vira luta.
  test "it would carry a lone monster along instead of standing next to it", %{worker: worker} do
    see(~w(Venonat))
    hunting(%{state: :fighting})

    tick(worker)
    assert orders().phase == :gathering
    assert orders().route == :go
    assert orders().fire == :hold
    assert_receive {:engine_log, :macro, "quadro: 🧠" <> juntando}
    assert juntando =~ "juntando"
  end

  test "nobody obeys yet: the posture the fight reads is untouched", %{worker: worker} do
    see(~w(Venonat Paras Venomoth))
    hunting(%{state: :fighting})
    tick(worker)
    tick(worker)

    assert orders().fire == :free
    # the fact Combat actually obeys was never written by us
    assert WorldState.get(:posture, 5_000, now()) == :missing
  end

  test "halting takes the orders down with the picture", %{worker: worker} do
    see(~w(Venonat Paras Venomoth))
    hunting()
    tick(worker)
    assert orders().phase == :travelling

    :ok = Worker.halt(worker)

    assert WorldState.get(:orders, 5_000, now()) == :missing
  end
end
