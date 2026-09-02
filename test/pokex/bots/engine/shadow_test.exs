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
    # …e a espera da R12 fora do caminho pelo mesmo motivo: o assunto aqui é a
    # RÉGUA (quem fecha a janela), e a espera que vem depois de fechar tem o
    # bloco dela em `logic_test.exs`.
    Pokex.SettingsStash.stash!(
      engine_pile_settle_ms: 0,
      engine_bunch_ms: 0,
      # …e o alvo do bolo em 1: desde 27/08 a régua só fecha a janela com seis
      # na tela, e estes testes põem quatro. A pergunta aqui é a RÉGUA.
      engine_gather_target: 1
    )

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

  # Desde 02/09 nenhum modo junta andando ("andar até eles chama mais bicho"):
  # seis na tela num trecho de mobada é PARAR e abrir, não puxar.
  test "the orders reach the blackboard", %{worker: worker} do
    see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell))
    hunting(%{luring?: true})
    tick(worker)

    assert orders().route == :hold
    assert orders().fire == :free
    assert orders().why =~ "caindo em cima"
  end

  # O MODO CHEGA AO CÉREBRO PELO FATO DA CAÇADA. É a mesma tela e o mesmo
  # trecho de mobada: o que muda é a rota ter escolhido o Econômico, e a
  # sobreposição de knobs desligar a mobada sem uma linha nova no `Logic`.
  test "o modo econômico não junta pilha", %{worker: worker} do
    see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell))
    hunting(%{luring?: true, mode: :economy})
    tick(worker)

    refute orders().phase == :gathering
    assert orders().route == :hold
    assert orders().fire == :free
  end

  # …e o Auto Combo também não — mas por outro motivo: é o modo das hunts
  # fortes, e lá "andar até eles chama ainda mais bicho" (02/09). Com a mesma
  # tela ele PARA: a rota segura e o fogo abre, porque seis já vale a área.
  test "o auto combo não junta: com a tela cheia ele para e abre", %{worker: worker} do
    see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell))
    hunting(%{luring?: true, mode: :auto_combo})
    tick(worker)

    refute orders().phase == :gathering
    assert orders().route == :hold
  end

  test "with no hunt running there is nothing to decide", %{worker: worker} do
    see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell))
    tick(worker)

    assert orders().phase == :idle
    assert orders().why =~ "sem caçada"
  end

  test "it says out loud what it would have done", %{worker: worker} do
    see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell))
    hunting(%{state: :fighting})
    tick(worker)

    assert_receive {:engine_log, :macro, "quadro: 🧠" <> shadow}
    assert shadow =~ "6 inimigos"
    assert shadow =~ "caindo em cima"
    assert shadow =~ "[liberaria o fogo]"
  end

  # UM monstro num canto não é uma luta — e desde 02/09 também não é uma pilha
  # pra carregar junto: nenhum modo anda pra buscar bicho ("andar até eles chama
  # ainda mais bicho"). O que resta é contar parado e, se ninguém mais vier, o
  # teto da juntada passa reto. Isto cobra o PARADO: nem um passo com a pilha
  # atrás.
  test "it counts a lone monster standing still instead of carrying it along", %{worker: worker} do
    see(~w(Venonat))
    hunting(%{state: :fighting})

    tick(worker)
    assert orders().phase == :sizing
    assert orders().route == :hold
    assert orders().fire == :hold
    assert_receive {:engine_log, :macro, "quadro: 🧠" <> contando}
    assert contando =~ "contando"
  end

  test "nobody obeys yet: the posture the fight reads is untouched", %{worker: worker} do
    see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell))
    hunting(%{state: :fighting})
    tick(worker)
    tick(worker)

    assert orders().fire == :free
    # the fact Combat actually obeys was never written by us
    assert WorldState.get(:posture, 5_000, now()) == :missing
  end

  test "halting takes the orders down with the picture", %{worker: worker} do
    see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell))
    hunting()
    tick(worker)
    assert orders().phase == :travelling

    :ok = Worker.halt(worker)

    assert WorldState.get(:orders, 5_000, now()) == :missing
  end
end
