defmodule Pokex.Bots.BodyTest.RaisingRig do
  # Test-local Rig double whose press/1 raises for a specific combo, simulating
  # Pokex.Rig.Mac.Commands.press/1's Map.fetch!/2 blowing up on a mis-keyed
  # modifier (e.g. "super+1"). Everything else behaves like Pokex.Rig.Fake so
  # the Body can still run a normal follow-up sequence through it.
  use Pokex.RigDouble

  def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def log, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

  @impl true
  def press("boom"), do: raise(ArgumentError, "unknown modifier")

  def press(combo) do
    Agent.update(__MODULE__, &[combo | &1])
    :ok
  end

  @impl true
  def press_many(combos, opts) do
    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)

    Enum.each(combos, fn combo ->
      Enum.each(1..tap_count, fn _tap -> press(combo) end)
    end)

    :ok
  end
end

defmodule Pokex.Bots.BodyTest.SlowRig do
  # Test-local Rig double: like Pokex.Rig.Fake, but press/1 blocks until
  # released (so a test can deterministically hold the Body busy instead of
  # racing a sleep against near-instant fake calls) and every call is logged
  # in arrival order. Execution order into the Rig is what actually proves
  # priority was honored — racing which caller's post-reply code runs first
  # is not reliable, since GenServer.reply/2 order doesn't guarantee which
  # process the scheduler resumes first. Scoped to this test file only; does
  # not touch the shared Pokex.Rig.Fake used elsewhere.
  use Pokex.RigDouble

  def start_link, do: Agent.start_link(fn -> %{held?: true, log: []} end, name: __MODULE__)

  def release, do: Agent.update(__MODULE__, &%{&1 | held?: false})

  def log, do: __MODULE__ |> Agent.get(& &1.log) |> Enum.reverse()

  @impl true
  def press(combo) do
    wait_release()
    Agent.update(__MODULE__, &%{&1 | log: [combo | &1.log]})
    :ok
  end

  @impl true
  def press_many(combos, opts) do
    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)

    Enum.each(combos, fn combo ->
      Enum.each(1..tap_count, fn _tap -> press(combo) end)
    end)

    :ok
  end

  defp wait_release do
    if Agent.get(__MODULE__, & &1.held?) do
      Process.sleep(1)
      wait_release()
    else
      :ok
    end
  end
end

defmodule Pokex.Bots.BodyTest.SlowMouseRig do
  # Test-local Rig double: `move/1` blocks until released, every other call
  # answers at once and is logged. It is the MOUSE half of `SlowRig` — the
  # shape a test needs to ask "does a key still get out while the pointer is
  # busy?", which is the whole point of the body having two lanes.
  use Pokex.RigDouble

  def start_link, do: Agent.start_link(fn -> %{held?: true, log: []} end, name: __MODULE__)

  def release, do: Agent.update(__MODULE__, &%{&1 | held?: false})

  def log, do: __MODULE__ |> Agent.get(& &1.log) |> Enum.reverse()

  @impl true
  def move(point) do
    record({:move, point})
    wait_release()
    :ok
  end

  @impl true
  def press(combo), do: record({:press, combo})

  @impl true
  def click(button, point), do: record({:click, button, point})

  @impl true
  def cursor_position, do: {:ok, {500, 500}}

  defp record(call) do
    Agent.update(__MODULE__, &%{&1 | log: [call | &1.log]})
    :ok
  end

  defp wait_release do
    if Agent.get(__MODULE__, & &1.held?) do
      Process.sleep(1)
      wait_release()
    else
      :ok
    end
  end
end

defmodule Pokex.Bots.BodyTest.GameOpeningRig do
  alias Pokex.Perception.WorldState

  # Test-local Rig double: press("open") publishes a playing :mini_game fact
  # before returning — simulating the overlay appearing exactly as an input
  # lands. The Body's after-input gate must stop the rest of the sequence.
  use Pokex.RigDouble

  def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def log, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

  @impl true
  def press(combo) do
    Agent.update(__MODULE__, &[combo | &1])

    if combo == "open" do
      WorldState.put(
        :mini_game,
        %{playing?: true, confidence: 1.0},
        System.monotonic_time(:millisecond)
      )
    end

    :ok
  end

  @impl true
  def press_many(combos, opts) do
    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)

    Enum.each(combos, fn combo ->
      Enum.each(1..tap_count, fn _tap -> press(combo) end)
    end)

    :ok
  end
end

defmodule Pokex.Bots.BodyTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Body
  alias Pokex.Bots.InputGate
  alias Pokex.Bots.BodyTest.GameOpeningRig
  alias Pokex.Bots.BodyTest.RaisingRig
  alias Pokex.Bots.BodyTest.SlowMouseRig
  alias Pokex.Bots.BodyTest.SlowRig
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    start_supervised!({Fake, %{}})
    pid = start_body(:body_test_default_body, name: :body_test)
    %{body: pid}
  end

  defp start_body(id, opts) do
    start_supervised!(%{id: id, start: {Body, :start_link, [opts]}})
  end

  test "executes an action sequence atomically through the Rig", %{body: body} do
    assert :ok = Body.perform([{:press, "1"}, {:move, {5, 5}}], :normal, body)

    # Filter out {:cursor_position} — the app-wide Guardian polls the panic
    # corner on its own timer against this same shared Rig.Fake, and its
    # reads may land in this window. What this test actually asserts is that
    # OUR sequence ran, in order, atomically. The trailing move is the cursor
    # RESTORE (the sequence touches the mouse, so the pointer goes back to
    # where it was — Rig.Fake's scripted cursor, {500, 500}).
    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:press, "1"}, {:move, {5, 5}}, {:move, {500, 500}}]
  end

  test "a KEY-ONLY sequence never reads or moves the cursor (no restore overhead)", %{body: body} do
    assert :ok = Body.perform([{:press, "a"}, {:press, "b"}], :normal, body)

    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:press, "a"}, {:press, "b"}]
  end

  # O `:ok` do rig com o portão fechado é um input ENGOLIDO (Rig.Mac.gated/1
  # suprime e responde :ok) — carimbar esse :ok inventava 40-50s de cooldown
  # pra uma tecla que nunca saiu, e a rotação recusava tecla boa depois
  # ("a IA acha que usou uma skill e marca o cooldown, mas ela não saiu",
  # 28/08). O carimbo agora pergunta ao portão.
  test "um press com o portão fechado NÃO carimba o relógio das teclas", %{body: body} do
    alias Pokex.Bots.SkillClock
    SkillClock.wipe()

    InputGate.set_focus_ok(false)
    on_exit(fn -> InputGate.set_focus_ok(true) end)

    assert :ok = Body.perform([{:press, "6"}], :normal, body)
    refute SkillClock.last_press("6")

    InputGate.set_focus_ok(true)
    assert :ok = Body.perform([{:press, "6"}], :normal, body)
    assert SkillClock.last_press("6")

    SkillClock.wipe()
  end

  test "the cursor restore can be turned off", %{body: body} do
    Pokex.Settings.put(:restore_mouse_after_actions, false)
    on_exit(fn -> Pokex.Settings.put(:restore_mouse_after_actions, true) end)

    assert :ok = Body.perform([{:move, {5, 5}}], :normal, body)

    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:move, {5, 5}}]
  end

  test "a :wait action pauses within the sequence without breaking it", %{body: body} do
    elapsed =
      :timer.tc(fn ->
        Body.perform([{:press, "a"}, {:wait, 40}, {:press, "b"}], :normal, body)
      end)
      |> elem(0)

    # the whole sequence (incl. the 40ms wait) is one atomic perform; both presses ran
    assert elapsed >= 40_000
    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:press, "a"}, {:press, "b"}]
  end

  test "the mini game fact stops the rest of a sequence the moment it appears mid-run" do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, GameOpeningRig)

    on_exit(fn ->
      Application.put_env(:pokex, :rig, previous_rig)
      WorldState.forget(:mini_game)
    end)

    start_supervised!(%{id: GameOpeningRig, start: {GameOpeningRig, :start_link, []}})
    body = start_body(:body_test_mini_game_gate_body, name: :body_mini_game_gate_test)

    assert :ok = Body.perform([{:press, "open"}, {:press, "must_not_run"}], :normal, body)
    assert GameOpeningRig.log() == ["open"]
  end

  test "a sequence never starts while the mini game fact says playing", %{body: body} do
    WorldState.put(:mini_game, %{playing?: true, confidence: 1.0}, now_ms())
    on_exit(fn -> WorldState.forget(:mini_game) end)

    assert :ok = Body.perform([{:press, "a"}, {:press, "b"}], :normal, body)

    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == []
  end

  @tag timeout: 2_000
  test "a :high request runs before a queued :normal one" do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, SlowRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    start_supervised!(%{id: SlowRig, start: {SlowRig, :start_link, []}})
    body = start_body(:body_test_priority_body, name: :body_prio)
    test = self()

    # Occupy the body with a press/1 call that genuinely blocks (via SlowRig)
    # until released below, so the low/high requests below provably arrive
    # and queue while the body is busy — not just win a timing race.
    spawn(fn -> Body.perform([{:press, "occupy"}], :normal, body) end)
    wait_until_busy(body)

    # low priority queued first, high second; high must execute first even
    # though both are now waiting behind the occupier. Assert on the order
    # actions actually reached the Rig (SlowRig.log/0), not on which test
    # process's post-reply `send` the scheduler happens to run first.
    spawn(fn ->
      Body.perform([{:press, "low"}], :normal, body)
      send(test, :low_done)
    end)

    wait_until_queued(body, :normal, 1)

    spawn(fn ->
      Body.perform([{:press, "high"}], :high, body)
      send(test, :high_done)
    end)

    wait_until_queued(body, :high, 1)

    SlowRig.release()

    assert_receive :low_done, 500
    assert_receive :high_done, 500
    assert SlowRig.log() == ["occupy", "high", "low"]
  end

  @tag timeout: 2_000
  test "a queued :normal request gets one turn after :high work" do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, SlowRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    start_supervised!(%{id: SlowRig, start: {SlowRig, :start_link, []}})
    body = start_body(:body_test_fairness_body, name: :body_fair)
    test = self()

    spawn(fn -> Body.perform([{:press, "occupy"}], :high, body) end)
    wait_until_busy(body)

    spawn(fn ->
      Body.perform([{:press, "normal"}], :normal, body)
      send(test, :normal_done)
    end)

    wait_until_queued(body, :normal, 1)

    spawn(fn ->
      Body.perform([{:press, "high"}], :high, body)
      send(test, :high_done)
    end)

    wait_until_queued(body, :high, 1)

    SlowRig.release()

    assert_receive :normal_done, 500
    assert_receive :high_done, 500
    assert SlowRig.log() == ["occupy", "normal", "high"]
  end

  @tag timeout: 2_000
  test "a :critical request runs before a queued :high one (survival tops everything)" do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, SlowRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    start_supervised!(%{id: SlowRig, start: {SlowRig, :start_link, []}})
    body = start_body(:body_test_critical_body, name: :body_crit)
    test = self()

    spawn(fn -> Body.perform([{:press, "occupy"}], :normal, body) end)
    wait_until_busy(body)

    # a :high is queued first; a :critical arrives second and must still run FIRST
    spawn(fn ->
      Body.perform([{:press, "high"}], :high, body)
      send(test, :high_done)
    end)

    wait_until_queued(body, :high, 1)

    spawn(fn ->
      Body.perform([{:press, "crit"}], :critical, body)
      send(test, :crit_done)
    end)

    wait_until_queued(body, :critical, 1)

    SlowRig.release()

    assert_receive :high_done, 500
    assert_receive :crit_done, 500
    assert SlowRig.log() == ["occupy", "crit", "high"]
  end

  test "a :critical sequence bypasses the mini-game gate (revive beats the overlay)", %{
    body: body
  } do
    WorldState.put(:mini_game, %{playing?: true, confidence: 1.0}, now_ms())
    on_exit(fn -> WorldState.forget(:mini_game) end)

    # the gate halts a :normal sequence before its first input; a :critical one runs whole
    assert :ok =
             Body.perform([{:press, "q"}, {:press, "shift+q"}, {:press, "q"}], :critical, body)

    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:press, "q"}, {:press, "shift+q"}, {:press, "q"}]
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # DUAS PISTAS, UMA POR ATUADOR. O corpo tinha uma vaga só, e uma poção — que
  # não toca no mouse — esperava atrás de um arremesso de bola ou de um passo
  # de minimapa sem nenhuma razão física. A prioridade só reordena a FILA:
  # `dequeue/1` só é alcançado quando a sequência em voo termina, então nem
  # `:critical` fura o que já está rodando.
  test "uma tecla crítica sai enquanto uma sequência de MOUSE está em voo" do
    body = with_slow_mouse(:body_test_lanes_body, :body_lanes)

    # o mouse fica preso dentro do move
    spawn(fn -> Body.perform([{:move, {5, 5}}, {:click, :left, {5, 5}}], :normal, body) end)
    wait_until_busy(body, :mouse)

    task = Task.async(fn -> Body.perform([{:press, "f4"}], :critical, body) end)

    assert Task.yield(task, 500) == {:ok, :ok},
           "a tecla ficou presa atrás do mouse: #{inspect(SlowMouseRig.log())}"

    assert {:press, "f4"} in SlowMouseRig.log()
    refute {:click, :left, {5, 5}} in SlowMouseRig.log(), "o mouse ainda estava preso"

    SlowMouseRig.release()
  end

  # A outra metade do contrato: quem toca os DOIS atuadores toma as duas pistas
  # e espera as duas. É o que mantém `move → wait → press` inteiro — a vara e a
  # bola miram com o cursor e disparam NELE, e um segundo dono do mouse entre a
  # mira e o tiro joga a pokébola em coordenada vazia.
  test "uma sequência que toca os dois atuadores espera as DUAS pistas" do
    body = with_slow_mouse(:body_test_both_lanes_body, :body_both)

    spawn(fn -> Body.perform([{:move, {5, 5}}], :normal, body) end)
    wait_until_busy(body, :mouse)

    task = Task.async(fn -> Body.perform([{:move, {9, 9}}, {:press, "1"}], :critical, body) end)

    assert Task.yield(task, 300) == nil, "não esperou o mouse: #{inspect(SlowMouseRig.log())}"
    refute {:press, "1"} in SlowMouseRig.log()

    SlowMouseRig.release()
    assert Task.await(task, 1_000) == :ok
  end

  # O CLIQUE DO MEIO É TECLA TANTO QUANTO É MOUSE: é o único clique sem
  # `cliclick`, sai pelo mesmo ajudante nativo de toda tecla — e mesmo assim
  # move o ponteiro, então o cursor volta pro lugar dele.
  test "o clique do meio devolve o cursor", %{body: body} do
    assert :ok = Body.perform([{:click, :middle, {7, 7}}], :normal, body)

    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:click, :middle, {7, 7}}, {:move, {500, 500}}]
  end

  # O PÂNICO NÃO PODE ESPERAR O SONO. Uma espera existe para dar ao jogo o tempo
  # de responder a um input que acabou de acontecer; com o portão fechado NADA
  # aconteceu — toda primitiva está sendo engolida — e a espera vira atraso puro
  # segurando uma pista. O `escape_walk_wait_ms` da fuga (5s, um `Process.sleep`
  # inteiro) era o teto real da janela do pânico por causa disso.
  test "uma espera longa é abandonada quando o portão fecha", %{body: body} do
    # O portão é uma tabela ETS GLOBAL: reabrir só no `on_exit` deixa uma janela
    # entre a saída do processo de teste e o callback, e o arquivo seguinte
    # herda um portão fechado.
    on_exit(fn -> InputGate.set_corner_ok(true) end)

    task = Task.async(fn -> Body.perform([{:wait, 3_000}], :normal, body) end)
    Process.sleep(50)
    InputGate.set_corner_ok(false)

    yielded = Task.yield(task, 900)
    InputGate.set_corner_ok(true)

    assert yielded == {:ok, :ok}, "a sequência dormiu os 3s inteiros com o portão fechado"
  end

  # E o portão ABERTO não encurta nada: uma espera é atômica dentro da
  # sequência por design (a vara arma e só então clica na água).
  test "com o portão aberto a espera é paga inteira", %{body: body} do
    {us, :ok} = :timer.tc(fn -> Body.perform([{:wait, 250}], :normal, body) end)

    assert div(us, 1000) >= 250
  end

  defp with_slow_mouse(id, name) do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, SlowMouseRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    start_supervised!(%{id: SlowMouseRig, start: {SlowMouseRig, :start_link, []}})
    start_body(id, name: name)
  end

  defp wait_until_busy(body, lane \\ :keys) do
    if :sys.get_state(body).lanes[lane] do
      :ok
    else
      Process.sleep(1)
      wait_until_busy(body, lane)
    end
  end

  defp wait_until_queued(body, key, count) do
    if :queue.len(Map.fetch!(:sys.get_state(body), key)) >= count do
      :ok
    else
      Process.sleep(1)
      wait_until_queued(body, key, count)
    end
  end

  test "cursor reads without queueing behind input", %{body: body} do
    assert {:ok, {500, 500}} = Body.cursor(body)
  end

  @tag timeout: 2_000
  test "a raising action reports {:error, :crashed, ...} instead of wedging the Body" do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, Pokex.Bots.BodyTest.RaisingRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    start_supervised!(%{
      id: Pokex.Bots.BodyTest.RaisingRig,
      start: {Pokex.Bots.BodyTest.RaisingRig, :start_link, []}
    })

    body = start_body(:body_test_crash_body, name: :body_crash)

    assert {:error, {:crashed, :error, %ArgumentError{}}} =
             Body.perform([{:press, "boom"}], :normal, body)

    # Prove the Body dequeued and stayed usable: a subsequent normal sequence
    # still executes through the Rig.
    assert :ok = Body.perform([{:press, "1"}], :normal, body)
    assert RaisingRig.log() == ["1"]
  end
end
