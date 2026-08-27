defmodule Pokex.Bots.MobStretchTest.SilentBody do
  @moduledoc """
  A Body that only reports. The real one presses through the Rig, and this test
  asserts on exactly what the Rig received — a walking hunt must not be able to
  look like a fighting one.
  """
  use Agent

  def start_link(test), do: Agent.start_link(fn -> test end, name: __MODULE__)

  def hold(keys) do
    send(Agent.get(__MODULE__, & &1), {:held, keys})
    :ok
  end

  def arrow_step(dx, dy, _opts \\ []) do
    send(Agent.get(__MODULE__, & &1), {:stepped, dx, dy})
    {:ok, "right"}
  end

  def perform(_actions, _priority, _server \\ nil), do: :ok
end

defmodule Pokex.Bots.MobStretchTest do
  @moduledoc """
  The two workers, both REAL, wired only by the blackboard.

  Every other test here proves one side of the mob stretch against a double:
  the hunt publishes a fact, or combat obeys one. Neither proves the fact
  actually CROSSES — that the thing the cavebot writes is the thing combat
  reads, under the key and shape it expects. That seam is exactly where a live
  test would otherwise have to find the bug, so it is worth a real Combat.Worker
  pressing a real (faked) keyboard.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.{Route, Store}
  alias Pokex.Bots.Cavebot.Worker, as: Cavebot
  alias Pokex.Bots.Combat
  alias Pokex.Bots.MobStretchTest.SilentBody
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.Settings

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    WorldState.clear()
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Pokex.TestHome.restore()
      Enum.each([:minimap, :battle, :posture, :dungeon], &WorldState.forget/1)
    end)

    Pokex.TeamFixtures.ready!()

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 80, 400},
      neutral_point: {500, 500}
    })

    {:ok, _} = Fake.start_link(%{})
    {:ok, _} = SilentBody.start_link(self())

    combat = start_supervised!({Combat.Worker, name: nil})

    hunt =
      start_supervised!(
        {Cavebot, name: nil, body: SilentBody, combat: combat, active: false},
        id: :hunt
      )

    %{hunt: hunt, combat: combat}
  end

  # waypoint 1 is "mobar daqui", waypoint 3 is "até aqui"
  defp lure_route! do
    {:ok, route} = Route.append(Route.new("mobada"), {100, 100, 7})
    {:ok, route} = Route.append(route, {110, 100, 7})
    {:ok, route} = Route.append(route, {120, 100, 7})

    :ok = Store.add(route |> Route.set_action(0, :lure_start) |> Route.set_action(2, :lure_end))
  end

  defp tick!(hunt) do
    send(hunt, :tick)
    Cavebot.status(hunt)
  end

  defp at!(pos), do: WorldState.put(:minimap, %{pos: pos}, System.monotonic_time(:millisecond))

  # A fresh frame for BOTH readers: the fact combat polls and the event that
  # wakes it, always strictly newer than the last (the Logic dedups frames).
  defp enemies!(combat, count) do
    seq = Process.get(:seq, 0) + 5
    Process.put(:seq, seq)
    at = System.monotonic_time(:millisecond) + seq

    obs = %{
      enemies: Enum.to_list(0..(count - 1)//1),
      enemies_detail: [],
      red: [],
      locked?: false,
      locked_row: nil,
      captured_at: at
    }

    WorldState.put(:battle, obs, at)
    send(combat, {:world, :battle, obs})
  end

  defp free_fire? do
    match?(
      {:ok, %{posture: :free_fight}},
      WorldState.get(:posture, 60_000, System.monotonic_time(:millisecond))
    )
  end

  defp pressed_tab? do
    Settings.get(:tab_key) in for({:press, key} <- Fake.calls(), do: key)
  end

  defp eventually(fun, timeout \\ 800) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> sleep_then(fun, deadline)
    end
  end

  defp sleep_then(fun, deadline) do
    Process.sleep(20)
    poll(fun, deadline)
  end

  test "the hunt silences a REAL combat while it gathers, and frees it at the end", %{
    hunt: hunt,
    combat: combat
  } do
    # the huddle after "até aqui" is real (4s in production); shortened here so
    # the test measures the WIRE, not the wait
    Pokex.SettingsStash.stash!(cavebot_gather_wait_ms: 200)
    # O TAB LIGADO: desde 27/08 a caçada não trava alvo por padrão ("apertar o
    # tab pra ele atacar um inimigo é pior, porque atrapalha a organização dos
    # bichos"), e o sinal de vida deste arquivo é justamente o Tab. O assunto
    # aqui é o FIO entre a caçada e o combate, não a tecla que o combate
    # escolhe — e o combate lê a config quando a caçada o liga, logo abaixo.
    Pokex.SettingsStash.stash!(combat_tab_target: true)

    lure_route!()
    :ok = Cavebot.run(hunt)

    # tick 1 starts combat, tick 2 arrives at "mobar daqui"
    at!({100, 100, 7})
    tick!(hunt)
    tick!(hunt)
    assert Cavebot.status(hunt).luring?

    # three enemies on screen and the real combat worker says nothing
    enemies!(combat, 3)
    refute eventually(&pressed_tab?/0, 300)
    assert Combat.Worker.status(combat).hold_reason == "segurando o fogo (trecho de mob)"

    # meanwhile the hunt keeps walking THROUGH them
    tick!(hunt)
    assert_receive {:held, [_ | _]}, 1_000

    # arrive at "até aqui": the fact flips, and the pile is fought
    at!({110, 100, 7})
    tick!(hunt)
    at!({120, 100, 7})
    tick!(hunt)
    refute Cavebot.status(hunt).luring?

    # still holding while the pile closes in…
    enemies!(combat, 3)
    refute eventually(&pressed_tab?/0, 150)

    # …and free once they are around him. Waiting on the FACT, never on a
    # clock: a sleep long enough today is a flake on a loaded machine.
    assert eventually(fn ->
             tick!(hunt)
             free_fire?()
           end)

    # The freed fight OPENS on the gathered pile first (the pokémon on the field
    # is classified, which is the only way a bot starts now), so the Tab comes
    # on a later observation — feed one more, as a hunt does every ~120ms.
    enemies!(combat, 3)
    enemies!(combat, 3)
    assert eventually(&pressed_tab?/0, 3_000)
  end

  test "a hunt that DIES mid stretch does not leave combat pacifist", %{
    hunt: hunt,
    combat: combat
  } do
    Pokex.SettingsStash.stash!(posture_max_age_ms: 500)

    # O TAB LIGADO: desde 27/08 a caçada não trava alvo por padrão ("apertar o
    # tab pra ele atacar um inimigo é pior, porque atrapalha a organização dos
    # bichos"), e o sinal de vida deste arquivo é justamente o Tab. O assunto
    # aqui é o FIO entre a caçada e o combate, não a tecla que o combate
    # escolhe — e o combate lê a config quando a caçada o liga, logo abaixo.
    Pokex.SettingsStash.stash!(combat_tab_target: true)

    lure_route!()
    :ok = Cavebot.run(hunt)
    at!({100, 100, 7})
    tick!(hunt)
    tick!(hunt)
    assert Cavebot.status(hunt).luring?

    enemies!(combat, 2)
    refute eventually(&pressed_tab?/0, 250)

    # the hunt stops refreshing the fact — here by dying, which is the case no
    # amount of message-passing discipline would have covered
    :ok = stop_supervised(:hunt)
    Process.sleep(700)

    enemies!(combat, 2)

    assert eventually(&pressed_tab?/0),
           "combate ficou pacifista: #{inspect(Combat.Worker.status(combat))}"
  end
end
