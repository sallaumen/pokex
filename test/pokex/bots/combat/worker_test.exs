defmodule Pokex.Bots.Combat.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Combat.Worker
  alias Pokex.Bots.ReviveLedger
  alias Pokex.Bots.SkillClock
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.Settings
  alias Pokex.SettingsStash

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()
    # …e as duas memórias do bot, que agora pertencem à aplicação (não morrem
    # mais com o processo do teste): um F4 pousado no teste anterior é um
    # blackout de 2s neste, e um carimbo velho é uma tecla que não sai.
    ReviveLedger.reset()
    Pokex.Bots.SkillClock.wipe()

    Application.put_env(:pokex, :home_dir, tmp)

    # …e o Tab LIGADO: desde 27/08 a caçada não trava alvo por padrão, e este
    # arquivo prova o worker levando a máquina de Tab até as teclas. O modo sem
    # Tab é decidido na `Logic` e tem os testes dele lá.
    # ESTE ARQUIVO É SOBRE A MÃO QUE APERTA TECLA POR TECLA: Tab, rajada, recibo,
    # retentativa. Esse é o modo Econômico — o Auto Combo aperta uma tecla só e
    # deixa o jogo encadear o resto, e medir a máquina de Tab dentro dele seria
    # medir um bot que não existe.
    # `target_lost_streak: 2` é a semente com que estes testes nasceram ("duas
    # leituras sem o alvo"); o padrão do código virou o dele (1) em 02/09.
    # …e a LIMPEZA DE STATUS desligada, ligada de volta só pelo `describe` que a
    # mede. Ela põe um respiro de 100ms na frente de cada rajada, e este arquivo
    # é cheio de "apertou uma vez só" cronometrado contra a rajada anterior: com
    # ela ligada em todo teste, um respiro a mais vira uma corrida perdida e uma
    # falha por semente (medido em 05/09, sementes 12256 e 858554).
    SettingsStash.stash!(
      skill_burst_every_ms: 0,
      hunt_mode: "economy",
      target_lost_streak: 2,
      status_cure_enabled: false
    )

    SettingsStash.stash_keys!([
      :tab_confirm_ms,
      :tab_max_attempts,
      :hunt_cooldown_ms,
      :combat_world_max_age_ms,
      :skill_keys
    ])

    on_exit(fn ->
      Pokex.TestHome.restore()
      :ets.delete(:pokex_world, :battle)
      :ets.delete(:pokex_world, :arena)
      :ets.delete(:pokex_world, :skill_bar)
      :ets.delete(:pokex_world, :posture)
      # a posture left behind would make the NEXT test's combat pacifist
      :ets.delete(:pokex_world, :posture)
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
    worker = start_supervised!({Worker, name: nil})
    :ok = Worker.run(worker)
    %{worker: worker}
  end

  defp battle_obs(fields) do
    Enum.into(fields, %{
      enemies: [],
      red: [],
      locked?: false,
      locked_row: nil,
      captured_at: System.monotonic_time(:millisecond)
    })
  end

  defp world!(worker, obs) do
    obs = %{obs | captured_at: fresh_captured_at()}
    WorldState.put(:battle, obs, obs.captured_at)
    send(worker, {:world, :battle, obs})
  end

  # Every call gets a captured_at strictly newer than "now" at call time (so a post-Tab
  # frame is deterministically newer than tabbed_at — guards F1's strict freshness check)
  # AND strictly newer than the previous call's (guards Logic's frame dedup: two world!
  # calls in a row must look like two DISTINCT frames, never a re-read of the same one).
  defp fresh_captured_at do
    seq = Process.get(:world_seq, 0) + 5
    Process.put(:world_seq, seq)
    System.monotonic_time(:millisecond) + seq
  end

  defp presses do
    for {:press, key} <- Fake.calls(), do: key
  end

  # What the fight SPENT, with the keys that are not skills taken out: Tab targets and
  # the stance keys set the game's mode. Both ride in the same burst as the damage keys
  # (the stance deliberately so, ahead of the first one), and whether a given burst
  # carried one is a race with the previous burst still being in flight — reading them
  # as skills is what made this file's skill assertions a coin flip.
  defp skill_presses do
    not_skills = [
      Settings.get(:tab_key),
      Settings.get(:attack_mode_key),
      Settings.get(:defense_mode_key),
      # A Status Potion vai na frente do ataque e não é skill: não tem cooldown
      # na barra, não gasta a barra e não é o que mata o bicho.
      Settings.get(:status_cure_key)
    ]

    Enum.reject(presses(), &(&1 in not_skills))
  end

  @tag :tmp_dir
  test "at most ONE key burst in flight — a decision landing mid-burst skips, never stacks", %{
    worker: worker
  } do
    # re-script the Fake with a slow (osascript-like) burst so the first one is still in
    # flight when the next decision arrives
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{press_many_sleep_ms: 250})

    # Tab burst (slow) spawns...
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    # ...and the lock lands while it is STILL in flight → the skill burst must be SKIPPED
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    Process.sleep(400)
    assert presses() == [Settings.get(:tab_key)]

    # burst 1 done → the next locked frame fires a fresh skill burst normally
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> length(presses()) > 1 end)
  end

  # O RELÓGIO TEM QUE ESTAR CARIMBADO ENQUANTO A RAJADA SAI, não depois dela.
  #
  # `press_many` só volta quando a ÚLTIMA tecla saiu — com o intervalo dele
  # (500ms) uma rajada de cinco leva dois segundos e meio — e QUEM LÊ O RELÓGIO
  # NO MEIO precisa achar o carimbo lá. O `HandWatch` drena o teclado a cada
  # 150ms: com o carimbo escrito só no fim, ele via as teclas do próprio bot
  # saindo, não achava carimbo (o da volta anterior tinha 45s) e concluía "foi
  # a mão dele", carimbando cooldown em cima de cooldown. Medido na noite dele
  # de 29/08: 7.703 linhas de "🖐️ tecla N da tua mão", na ordem exata da
  # rajada, e a barra inteira em espera assim que a caçada começava.
  #
  # O rig OLHA O RELÓGIO de dentro da prensa: é a única forma de afirmar ORDEM.
  # Um teste que só espera o carimbo aparecer passa com o carimbo no fim — foi
  # o primeiro que escrevi, e ele passou com o bug em pé.
  defmodule ClockPeekRig do
    use Pokex.RigDouble

    def press_many([], _opts), do: :ok

    def press_many(combos, _opts) do
      carimbadas =
        Enum.count(combos, fn combo -> Pokex.Bots.SkillClock.last_press(combo) != nil end)

      :ets.insert(:combat_clock_peek, {:peek, carimbadas, length(combos)})
      :ok
    end
  end

  @tag :tmp_dir
  test "o relógio das teclas já está carimbado no meio da rajada", %{worker: worker} do
    if :ets.whereis(:combat_clock_peek) == :undefined,
      do: :ets.new(:combat_clock_peek, [:set, :public, :named_table])

    :ets.delete(:combat_clock_peek, :peek)
    Pokex.Bots.SkillClock.wipe()

    anterior = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, ClockPeekRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, anterior) end)

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))

    assert eventually(fn -> :ets.lookup(:combat_clock_peek, :peek) != [] end, 2_000)

    [{:peek, carimbadas, total}] = :ets.lookup(:combat_clock_peek, :peek)

    assert carimbadas == total,
           "a prensa começou com #{total - carimbadas} de #{total} teclas sem carimbo — " <>
             "quem ler o relógio no meio da rajada vê tecla livre"
  end

  # The stance is the one decision this machine LATCHES after deciding it, and the
  # one-burst-in-flight rule is allowed to throw the list it rode in on away. Believing
  # a stance the game never heard is exactly the failure the feature exists to prevent
  # ("uso skill de dano antes de mudar o modo para ataque").
  @tag :tmp_dir
  test "a stance key the one-burst rule threw away is pressed again, never believed", %{
    worker: worker
  } do
    # slow (osascript-like) burst: the Tab spawn is still in flight when the lock lands,
    # so the whole action list behind it — attack stance included — is dropped
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{press_many_sleep_ms: 250})

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    # the fight goes on; the stance never reached the game, so it still has to go out
    assert eventually(
             fn ->
               Settings.get(:attack_mode_key) in presses() or
                 (world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
             end,
             2_000
           )
  end

  @tag :tmp_dir
  test "an enemy observation makes it press Tab", %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))

    assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    assert Worker.status(worker).state == :tabbing

    # the dispatched burst is the pill's "última ação"
    assert %{text: "teclas " <> _, at: at} = Worker.status(worker).last_action
    assert is_integer(at)
  end

  @tag :tmp_dir
  test "a post-Tab locked observation confirms the fight and fires skills", %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    # keep feeding fresh locked frames while we wait, like the real feed's ~120ms writes do —
    # a burst that lands while the (fast) Tab spawn is still alive is legitimately SKIPPED
    # (one-burst-in-flight), and the NEXT fresh frame is what re-fires it
    assert eventually(fn ->
             "1" in presses() or
               (world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
           end)
  end

  @tag :tmp_dir
  test "a fresh :skill_bar fact narrows every skill burst to READY keys only", %{worker: worker} do
    # only "2" is ready → every SKILL press must be "2" (Tab and the stance are not
    # skills and ride along untouched — see skill_presses/0)
    put_fact = fn ->
      at = System.monotonic_time(:millisecond)
      WorldState.put(:skill_bar, %{states: [:cooldown, :ready], ready_keys: ["2"]}, at)
    end

    put_fact.()
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    # keep the fact fresh and the frames flowing (same re-feed dance as the burst tests)
    assert eventually(fn ->
             skills = skill_presses()

             (skills != [] and Enum.uniq(skills) == ["2"]) or
               (put_fact.() && world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
           end)

    skills = skill_presses()
    assert skills != [] and Enum.uniq(skills) == ["2"]
  end

  # "quando você fica tentando matar de um em um, ele é extremamente mais
  # lento" (Lucas, 2026-08-11). The hunt gathers a pile and hands combat the
  # combo HE recorded at that spot; it opens with it the moment the fire is
  # released.
  @tag :tmp_dir
  test "the hunt's combo opens the fight, once, on the edge", %{worker: worker} do
    posture = fn value, combo ->
      WorldState.put(:posture, %{posture: value, combo: combo}, now_ms())
    end

    posture.(:hold_fire, ~w(1 3 4))
    world!(worker, battle_obs(enemies: [0, 1, 2]))
    refute eventually(fn -> "3" in presses() end, 250)

    # released: his combo goes out
    posture.(:free_fight, ~w(1 3 4))
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "4" in presses() end)
    assert "3" in presses()

    # and it is an EDGE, not a per-frame thing
    before = Enum.count(presses(), &(&1 == "4"))
    world!(worker, battle_obs(enemies: [0, 1, 2]))
    world!(worker, battle_obs(enemies: [0, 1, 2]))
    Process.sleep(150)
    assert Enum.count(presses(), &(&1 == "4")) == before
  end

  @tag :tmp_dir
  test "lock lost for the streak broadcasts the kill", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    world!(worker, battle_obs(locked?: false))
    world!(worker, battle_obs(locked?: false))

    assert_receive {:kill}, 1_000
    assert Worker.status(worker).counters.fights == 1
  end

  @tag :tmp_dir
  test "holds itself while the :mini_game fact says playing, restarts fresh when it clears", %{
    worker: worker
  } do
    WorldState.put(:mini_game, %{playing?: true, confidence: 1.0}, now_ms())
    on_exit(fn -> WorldState.forget(:mini_game) end)

    # an enemy shows up mid-game: NO Tab — the worker froze itself
    world!(worker, battle_obs(enemies: [0]))
    refute eventually(fn -> Settings.get(:tab_key) in presses() end, 400)
    assert Worker.status(worker).hold_reason == "mini-game em jogo"

    # game over: leave a fresh battle picture for the resume to read, clear the fact —
    # the worker's own held :wake poll must resume it with NO further :world events
    at = now_ms()
    WorldState.put(:battle, battle_obs(enemies: [0]) |> Map.put(:captured_at, at), at)
    WorldState.forget(:mini_game)

    assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    assert Worker.status(worker).state == :tabbing
    assert Worker.status(worker).hold_reason == nil
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @tag :tmp_dir
  test "halt detaches and goes idle", %{worker: worker} do
    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle

    world!(worker, battle_obs(enemies: [0]))
    refute eventually(fn -> Worker.status(worker).state == :tabbing end, 300)
  end

  @tag :tmp_dir
  test "a static locked-lost screen reaches the kill from :wake polling alone, no further :world events",
       %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    # From here on: NO more :world events (the feed wouldn't broadcast either — the
    # content stopped changing). Simulate the feed's own per-tick ETS writes (a fresh
    # captured_at every ~120ms in production, even when the content is identical)
    # directly against WorldState: the worker's :wake polling must reach the kill on
    # its own, reading the SAME table the real feed writes.
    for _ <- 1..8 do
      at = System.monotonic_time(:millisecond)
      WorldState.put(:battle, battle_obs(locked?: false) |> Map.put(:captured_at, at), at)
      Process.sleep(100)
    end

    assert_receive {:kill}, 1_000
    assert Worker.status(worker).counters.fights == 1
  end

  @tag :tmp_dir
  test "C1: after a kill, free hunting reaches :tabbing again (Tab pressed a 2nd time) via :wake polling alone",
       %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    world!(worker, battle_obs(locked?: false))
    world!(worker, battle_obs(locked?: false))
    assert eventually(fn -> Worker.status(worker).state == :hunting end)
    assert Worker.status(worker).counters.fights == 1

    # The Tab press itself lands via an async spawned task (dispatch/1), so its arrival in
    # Fake can lag a hair behind the synchronous state transition above — eventually, not a
    # bare assert (this used to be masked by sync_arena's now-removed Perception.attach/detach
    # call adding incidental latency to the worker's own message loop). ≥ 1, not == 1: the
    # post-kill probe window now fires additional blind Tabs by design.
    assert eventually(fn -> Enum.any?(presses(), &(&1 == Settings.get(:tab_key))) end)

    # From here on: NO more :world events (the feed wouldn't broadcast either — a
    # non-empty-but-pixel-static battle list is not a content CHANGE). Seed WorldState
    # directly with fresh enemies-present frames on a short loop, exactly like the feed's
    # own per-tick ETS writes — free :hunting's own poll (C1's next_wake fix) must pick
    # them up and press Tab again, with nothing driving it but the worker's :wake timer.
    for _ <- 1..8 do
      at = System.monotonic_time(:millisecond)
      WorldState.put(:battle, battle_obs(enemies: [0]) |> Map.put(:captured_at, at), at)
      Process.sleep(100)
    end

    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    assert Enum.count(presses(), &(&1 == Settings.get(:tab_key))) >= 2
  end

  @tag :tmp_dir
  test "I1: :reattach_battle is a liveness no-op while already attached, worker keeps stepping",
       %{worker: worker} do
    # Exercising the real feed-restart path cheaply isn't practical here (it needs the
    # supervisor to actually kill+restart the registered Feed process); this pins the
    # handler directly: with logic active and already attached, :reattach_battle must not
    # crash or wedge the worker, and a subsequent world event still steps it normally.
    send(worker, :reattach_battle)
    assert Process.alive?(worker)

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
  end

  @tag :tmp_dir
  test "a key-burst failure steps io_failed; repeated failures error the worker out",
       %{worker: worker} do
    send(worker, {:key_burst_failed, :boom})
    status = Worker.status(worker)
    assert status.state in [:hunting, :tabbing, :fighting]
    assert status.counters.failures == 1
    assert status.error == nil

    for _ <- 1..4, do: send(worker, {:key_burst_failed, :boom})

    status = Worker.status(worker)
    assert status.state == :error
    assert status.counters.failures == 5
    assert status.error =~ "boom"

    # once errored, further failures are ignored (no reactivation from a stale async task)
    send(worker, {:key_burst_failed, :boom})
    assert Worker.status(worker).counters.failures == 5
  end

  # "A gente tem que sempre estar garantindo que a skill que a gente validou
  # foi usada mesmo" (Lucas, 2026-08-11). The receipt is the cooldown: a skill
  # that fired is no longer ready.
  describe "confirming the skills actually went off" do
    defp bar!(ready_keys) do
      WorldState.put(
        :skill_bar,
        %{states: nil, ready_keys: ready_keys},
        System.monotonic_time(:millisecond)
      )
    end

    # Publishes the bar the way the real feed does (every ~120ms, forever) for
    # as long as the caller watches. The receipt blocks until a reading captured
    # STRICTLY AFTER the press exists — a same-millisecond one could have been
    # taken before the key landed. Writing that reading ONCE bets it lands in a
    # later millisecond than the press; here the whole dance routinely fits in
    # one, the receipt gives up unread and judges nothing (1 run in 4,
    # 2026-08-11). No frame goes out meanwhile and the Logic dedups on
    # captured_at, so the bar alone can never start a fresh burst.
    defp feeding_bar(ready_keys, watch, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      feed_and_watch(ready_keys, watch, deadline)
    end

    defp feed_and_watch(ready_keys, watch, deadline) do
      bar!(ready_keys)

      cond do
        watch.() -> true
        System.monotonic_time(:millisecond) > deadline -> false
        true -> Process.sleep(20) && feed_and_watch(ready_keys, watch, deadline)
      end
    end

    @tag :tmp_dir
    test "a key still ready after the burst is pressed AGAIN", %{worker: worker} do
      SettingsStash.stash!(skill_keys: ["1"], combat_skill_burst_size: 1)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())

      # ready before the burst…
      bar!(["1"])
      world!(worker, battle_obs(enemies: [0]))
      assert eventually(fn -> Worker.status(worker).state == :tabbing end)

      world!(worker, battle_obs(locked?: true, locked_row: 0))
      assert eventually(fn -> Worker.status(worker).state == :fighting end)

      # the same re-feed dance the other burst tests use: a burst landing while
      # the Tab spawn is alive is legitimately skipped. FRAMES only — a bar
      # rewritten here becomes the verdict of a burst that predates it.
      assert eventually(fn ->
               "1" in presses() or
                 (world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
             end)

      # a fresh frame per poll is a fresh decision, so the dance above can land
      # more than one ORDINARY burst: only presses after this line are retries
      ordinary = Enum.count(presses(), &(&1 == "1"))

      # …and STILL ready after it: the press never landed
      assert feeding_bar(["1"], fn -> logged?("não saiu") end, 2_000)

      # announcing the retry is not doing it: the key has to reach the keyboard
      assert eventually(fn -> Enum.count(presses(), &(&1 == "1")) > ordinary end),
             "não re-apertou: #{inspect(presses())}"
    end

    @tag :tmp_dir
    test "a key that went on cooldown is left alone", %{worker: worker} do
      SettingsStash.stash!(skill_keys: ["1"], combat_skill_burst_size: 1)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())

      bar!(["1"])
      world!(worker, battle_obs(enemies: [0]))
      assert eventually(fn -> Worker.status(worker).state == :tabbing end)

      world!(worker, battle_obs(locked?: true, locked_row: 0))

      assert eventually(fn ->
               "1" in presses() or
                 (world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
             end)

      # it fired: no longer ready. Kept flowing for the reason above plus one
      # more — a receipt with nothing to read answers "don't know", and this
      # refute would pass without the retry path ever being asked the question.
      #
      # The DECISION is what is refuted, not the press count: the dance above
      # can land two ordinary bursts by itself, which counting keys read as a
      # retry (1 run in 12, 2026-08-11). Every retry is announced first, so
      # silence on the log topic is the proof.
      refute feeding_bar([], fn -> logged?("não saiu") end, 400)
    end

    # O relógio do recibo é o da ÚLTIMA tecla, não o da primeira. Uma rajada de
    # n teclas leva (n-1) × gap para sair da mão — 3,3s com o gap dele — e a
    # barra é publicada a cada 400ms. Julgando contra o instante do PEDIDO, o
    # recibo aceita um quadro tirado no MEIO da rajada, onde a cauda ainda não
    # foi apertada e portanto ainda está pronta: "não saiu" fabricado, e uma
    # repressão inteira em cima dele.
    @tag :tmp_dir
    test "o recibo julga contra um quadro de DEPOIS da última tecla, nunca do meio da rajada",
         %{worker: worker} do
      SettingsStash.stash!(skill_keys: ["1"], combat_skill_burst_size: 1)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())

      # a rajada demora a sair da mão, como a dele demora
      Agent.update(Fake, &put_in(&1.script[:press_many_sleep_ms], 600))

      bar!(["1"])
      world!(worker, battle_obs(enemies: [0]))
      assert eventually(fn -> Worker.status(worker).state == :tabbing end)

      world!(worker, battle_obs(locked?: true, locked_row: 0))
      assert eventually(fn -> Worker.status(worker).state == :fighting end)

      # Quadros da barra ENQUANTO a rajada dorme: a tecla ainda não saiu, então
      # ela ainda está pronta — e é exatamente essa leitura do meio da rajada
      # que o recibo antigo aceitava como veredito.
      #
      # CONTADOS, e não até a tecla aparecer: escrever "ainda pronta" até ver o
      # press é uma corrida com o próprio recibo. `Fake.press_many` dorme e SÓ
      # ENTÃO registra, então o instante em que o teste vê a tecla é o mesmo em
      # que o `confirm_burst` carimba o seu relógio — e um último quadro
      # `["1"]` escrito nesse mesmo tique de 20ms cai DEPOIS do carimbo, é
      # aceito com razão, e o refute abaixo falha por um motivo que não é o
      # defeito (1 corrida em 3, medido). Cinco quadros em 100ms cabem folgados
      # nos 600ms da rajada; depois disso só o mundo continua sendo empurrado.
      Enum.each(1..5, fn _ ->
        bar!(["1"])
        Process.sleep(20)
      end)

      assert eventually(
               fn ->
                 "1" in presses() or
                   (world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
               end,
               3_000
             ),
             "a rajada nunca saiu: #{inspect(presses())}"

      # A partir daqui o jogo responde a verdade: a tecla saiu e está em cooldown.
      # O que se refuta é a DECISÃO, não a contagem de teclas — a dança acima
      # solta rajadas ordinárias sozinha, e contá-las lê rajada como repressão
      # (a mesma armadilha anotada no teste do "ainda pronta", acima). Toda
      # repressão é anunciada antes, então o silêncio no tópico é a prova.
      refute feeding_bar([], fn -> logged?("não saiu") end, 900),
             "julgou a tecla contra um quadro do meio da rajada"
    end
  end

  # The engine decides the same question the posture does, but with more than
  # the leg of the route: the count on screen, whether the pile stopped
  # arriving, and the health band. So it OUTRANKS the posture — while it is
  # fresh, and only while it is fresh.
  describe "obeying the engine" do
    # His real Vespiquen: 1 is the control skill the revive borrows, which is
    # exactly the key an ordinary rotation must never spend.
    defp with_vespiquen(worker) do
      Pokex.Pokedex.Team.add("Vespiquen")
      Pokex.Pokedex.Team.set_skills("Vespiquen", %{"1" => :crowd, "3" => :aoe, "6" => :single})
      Pokex.Pokedex.Team.set_active("Vespiquen")
      send(worker, {:team_changed})
    end

    defp orders!(orders) do
      WorldState.put(
        :orders,
        Map.merge(%{fire: :free, opening: [], stun: :hold}, orders),
        System.monotonic_time(:millisecond)
      )
    end

    @tag :tmp_dir
    test "the engine's hold beats a posture that says fight", %{worker: worker} do
      WorldState.put(:posture, %{posture: :free_fight}, System.monotonic_time(:millisecond))
      orders!(%{fire: :hold})
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      refute eventually(fn -> Settings.get(:tab_key) in presses() end, 300)
    end

    # THE FLOOR OF THE WHOLE DESIGN. Orders carry an age; an engine that dies
    # stops refreshing them, and every worker keeps working without it. This is
    # what makes one central brain safe in a hunt that runs eight hours alone.
    @tag :tmp_dir
    test "orders nobody is refreshing go stale and the posture decides again", %{worker: worker} do
      SettingsStash.stash!(engine_orders_max_age_ms: 300)

      WorldState.put(
        :orders,
        %{fire: :hold, opening: [], stun: :hold},
        System.monotonic_time(:millisecond) - 5_000
      )

      WorldState.put(:posture, %{posture: :free_fight}, System.monotonic_time(:millisecond))
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    end

    # The control goes out ONLY when the brain puts it in the hand — and the
    # two halves of the mechanism exist now: the engine's stun branches put
    # the crowd key in `opening` exactly one window before `revive: :now`, and
    # since #429 the support escalates instead of recalling bare when it finds
    # the control cooling. An ordinary fight (no crowd in the brain's hand)
    # still never spends it.
    @tag :tmp_dir
    test "an ordinary fight still never spends the control skill", %{worker: worker} do
      with_vespiquen(worker)

      orders!(%{fire: :free, stun: :now})
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      # Tab proves combat is awake and acting on the freed fire…
      assert eventually(fn -> Settings.get(:tab_key) in presses() end)
      # …and the control key stayed in its holster anyway.
      refute "1" in presses()
    end

    # R10, de verdade: até 28/08 o cérebro carimbava `:stunned` e punha o
    # controle na abertura — e a recomposição local jogava a lista fora, então
    # a janela dos 5s abria sobre um stun que nunca saiu.
    @tag :tmp_dir
    test "o controle do cérebro sai na BORDA em que entra na mão — uma vez", %{worker: worker} do
      with_vespiquen(worker)

      orders!(%{fire: :free, opening: ["1", "3"]})
      world!(worker, battle_obs(enemies: [0, 1, 2]))
      assert eventually(fn -> "1" in presses() end)

      # a mesma ordem repetida (o cérebro republica a cada tique) não re-aperta
      before = Enum.count(presses(), &(&1 == "1"))
      orders!(%{fire: :free, opening: ["1", "3"]})
      world!(worker, battle_obs(enemies: [0, 1, 2]))
      Process.sleep(150)
      assert Enum.count(presses(), &(&1 == "1")) == before

      # a borda de saída limpa a memória; a próxima entrada aperta de novo
      orders!(%{fire: :free, opening: ["3"]})
      world!(worker, battle_obs(enemies: [0, 1, 2]))
      Process.sleep(50)
      orders!(%{fire: :free, opening: ["1", "3"]})
      world!(worker, battle_obs(enemies: [0, 1, 2]))
      assert eventually(fn -> Enum.count(presses(), &(&1 == "1")) == before + 1 end)
    end

    # A mão do cérebro VENCE a recomposição local: a engine compõe o MESMO
    # Strategy.opening com o que o combate não tem (barra lida, tamanho da
    # pilha), então descartá-la era jogar informação fora. O loadout tem duas
    # áreas; o cérebro manda UMA (a mão pequena do bicho bobo) — e é ela que
    # abre, não a lista local inteira.
    @tag :tmp_dir
    test "a abertura obedece a mão do cérebro, não a recomposição local", %{worker: worker} do
      Pokex.Pokedex.Team.add("Golem")

      Pokex.Pokedex.Team.set_skills("Golem", %{
        "1" => :crowd,
        "3" => :aoe,
        "4" => :aoe,
        "6" => :single
      })

      Pokex.Pokedex.Team.set_active("Golem")
      send(worker, {:team_changed})

      orders!(%{fire: :hold, opening: ["4"]})
      world!(worker, battle_obs(enemies: [0, 1, 2]))
      Process.sleep(50)

      orders!(%{fire: :free, opening: ["4"]})
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      assert eventually(fn -> "4" in presses() end)
      refute "3" in presses(), "a recomposição local teria aberto com a 3 também"
    end
  end

  # The hunt asks for quiet by publishing the `:posture` fact; this worker
  # obeys a READING with an age, never a command it has to remember.
  describe "holding fire while the hunt gathers mobs" do
    defp posture!(posture) do
      WorldState.put(:posture, %{posture: posture}, System.monotonic_time(:millisecond))
    end

    @tag :tmp_dir
    test "a full battle list presses nothing while the fact says hold fire", %{worker: worker} do
      posture!(:hold_fire)
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      refute eventually(fn -> Settings.get(:tab_key) in presses() end, 300)
      assert Worker.status(worker).state == :hunting
      assert Worker.status(worker).hold_reason == "segurando o fogo (trecho de mob)"

      posture!(:free_fight)
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      # 3s, not 1: with the pokémon on the field CLASSIFIED (the only way a bot
      # starts since 2026-08-24), the freed fight opens with a burst, and a Tab
      # dispatched while that burst is still running is skipped on purpose —
      # the next decision fires a fresher one.
      # The freed fight OPENS on the pile it gathered — with the pokémon on the
      # field classified (the only way a bot starts since 2026-08-24) that
      # opening is a real burst, and it consumes this observation. The Tab
      # comes on the next one, which in a hunt arrives every ~120ms.
      assert eventually(fn -> Enum.any?(~w(1 2 3 4), &(&1 in presses())) end)

      world!(worker, battle_obs(enemies: [0, 1, 2]))

      assert eventually(fn -> Settings.get(:tab_key) in presses() end, 3_000)
      assert Worker.status(worker).hold_reason == nil
    end

    # The fact ages out on its own: a hunt that dies mid mob stretch must not
    # leave the bot standing pacifist in the crowd it just gathered.
    @tag :tmp_dir
    test "a posture nobody is refreshing goes stale and combat fights again", %{worker: worker} do
      SettingsStash.stash!(posture_max_age_ms: 500)

      WorldState.put(
        :posture,
        %{posture: :hold_fire},
        System.monotonic_time(:millisecond) - 5_000
      )

      world!(worker, battle_obs(enemies: [0]))

      assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    end

    @tag :tmp_dir
    test "with no fact at all it fights, exactly as it always did", %{worker: worker} do
      WorldState.forget(:posture)
      world!(worker, battle_obs(enemies: [0]))

      assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    end
  end

  # The skill HE left marked on the route's kill spot opens the burst. It comes
  # in FRONT because an aura landing after the area damage did nothing at all.
  @tag :tmp_dir
  test "a ordem da rota abre a rajada, na frente do combo", %{worker: worker} do
    posture = fn value, combo, orders ->
      WorldState.put(:posture, %{posture: value, combo: combo, orders: orders}, now_ms())
    end

    posture.(:hold_fire, ~w(3 4), ~w(1))
    world!(worker, battle_obs(enemies: [0, 1, 2]))
    refute eventually(fn -> "4" in presses() end, 250)

    posture.(:free_fight, ~w(3 4), ~w(1))
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "4" in presses() end)
    assert Enum.filter(presses(), &(&1 in ~w(1 3 4))) == ~w(1 3 4)
  end

  # He may have put a 💥 area order on a spot whose opening is already area.
  # Pressing the same key twice only burns its cooldown.
  @tag :tmp_dir
  test "tecla que já está na abertura não é apertada duas vezes", %{worker: worker} do
    posture = fn value ->
      WorldState.put(:posture, %{posture: value, combo: ~w(3 4), orders: ~w(3)}, now_ms())
    end

    posture.(:hold_fire)
    world!(worker, battle_obs(enemies: [0, 1, 2]))
    refute eventually(fn -> "4" in presses() end, 250)

    posture.(:free_fight)
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "4" in presses() end)
    assert Enum.count(presses(), &(&1 == "3")) == 1
  end

  # The dedup is NOT `Enum.uniq/1` over the concatenation: the ordered key
  # keeps its place in FRONT even when the opening already has it. Recorded
  # 3 then 4, ordered 4 → the 4 opens and the 3 follows. Backwards is exactly
  # the bug the order exists to prevent — an aura that lands after the area
  # damage did nothing for anyone.
  @tag :tmp_dir
  test "a tecla ordenada abre, mesmo já estando no meio do combo", %{worker: worker} do
    posture = fn value ->
      WorldState.put(:posture, %{posture: value, combo: ~w(3 4), orders: ~w(4)}, now_ms())
    end

    posture.(:hold_fire)
    world!(worker, battle_obs(enemies: [0, 1, 2]))
    refute eventually(fn -> "3" in presses() end, 250)

    posture.(:free_fight)
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "3" in presses() end)
    assert Enum.filter(presses(), &(&1 in ~w(3 4))) == ~w(4 3)
  end

  # A hunt from an earlier version still publishing the fact without the new
  # field must not crash combat, nor silence the opening.
  @tag :tmp_dir
  test "fato sem o campo orders é lido como sem ordem", %{worker: worker} do
    WorldState.put(:posture, %{posture: :hold_fire, combo: ~w(3)}, now_ms())
    world!(worker, battle_obs(enemies: [0, 1, 2]))
    refute eventually(fn -> "3" in presses() end, 250)

    WorldState.put(:posture, %{posture: :free_fight, combo: ~w(3)}, now_ms())
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "3" in presses() end)
  end

  # Drains combat's own log topic looking for one line, WITHOUT blocking: the
  # Logic narrates on the same topic, so the line being waited on is rarely the
  # first message — and a caller polling while it feeds the world has to be able
  # to ask again and again, rather than parking on a deadline.
  defp logged?(fragment) do
    receive do
      {:combat_log, _level, text} -> String.contains?(text, fragment) or logged?(fragment)
    after
      0 -> false
    end
  end

  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        poll(fun, deadline)
    end
  end

  # A JANELA CEGA DEPOIS DO REVIVE.
  #
  # O revive TIRA o pokémon de campo e o devolve — "esperando Nms o bolo
  # dormir, aí sim tiro o pokémon". Enquanto ele está fora nenhuma skill dele
  # sai, e a barra mostra tudo pronto do mesmo jeito, porque o revive zerou os
  # cooldowns de verdade.
  #
  # O diário de 29/08 mediu o buraco em 242 revives: das teclas que a barra
  # dava como prontas e o jogo ignorou, 91% saíram no primeiro segundo depois
  # de um revive e 54% no segundo, contra ~20% de base no resto da caçada. Cada
  # aperto ali custava três vezes — a tecla, o `combat_skill_gap_ms` inteiro, e
  # um `missed` que ainda comprava uma retentativa em cima.
  describe "a janela cega depois do revive" do
    # A abertura sai na BORDA `:hold_fire -> :free_fight`: o worker precisa ter
    # LATCHADO o segurar num passo seu antes de ver a liberação, senão não há
    # borda — e o teste mediria um silêncio que não é o da janela. É o mesmo
    # preâmbulo de "a full battle list presses nothing while the fact says hold
    # fire", e pela mesma razão.
    defp abre_o_fogo(worker) do
      posture!(:hold_fire)
      world!(worker, battle_obs(enemies: [0, 1, 2]))
      refute eventually(fn -> Settings.get(:tab_key) in presses() end, 300)

      posture!(:free_fight)
      world!(worker, battle_obs(enemies: [0, 1, 2]))
    end

    defp skill_saiu? do
      Enum.any?(~w(1 2 3 4 5 6), &(&1 in presses()))
    end

    @tag :tmp_dir
    test "nenhuma skill sai enquanto o pokémon está voltando", %{worker: worker} do
      SettingsStash.stash!(rescue_blackout_ms: 5_000)
      ReviveLedger.landed()

      abre_o_fogo(worker)

      refute eventually(&skill_saiu?/0, 500),
             "a rajada saiu dentro da janela em que o pokémon não está em campo"
    end

    # A janela conta do F4 QUE SAIU, nunca do despacho do combo: o despacho
    # antecede o F4 pelo settle inteiro (1,5-2s), e a janela contada de lá
    # mirava o lugar errado — cobria o settle (pokémon em campo, tanqueando de
    # propósito) e descobria o 1º segundo pós-F4, onde a noite de 30/08 mediu
    # 320 das 441 teclas engolidas.
    @tag :tmp_dir
    test "o DESPACHO do combo não cala o combate — o settle é hora de bater", %{worker: worker} do
      SettingsStash.stash!(rescue_blackout_ms: 5_000)
      ReviveLedger.note()

      abre_o_fogo(worker)

      assert eventually(&skill_saiu?/0),
             "o combate calou no settle — a janela está contando do despacho de novo"
    end

    @tag :tmp_dir
    test "e volta a atacar assim que a janela fecha", %{worker: worker} do
      SettingsStash.stash!(rescue_blackout_ms: 0)
      ReviveLedger.landed()

      abre_o_fogo(worker)

      assert eventually(&skill_saiu?/0)
    end

    # A trava é sobre o REVIVE, não um mudo global: sem revive anotado ela não
    # existe, por maior que seja a janela. (O resgate também não passa por
    # `try_dispatch` — ele fala direto com o `Body` —, então nada aqui atrasa um
    # stun ou o próprio revive.)
    @tag :tmp_dir
    test "sem revive anotado a janela não existe", %{worker: worker} do
      SettingsStash.stash!(rescue_blackout_ms: 5_000)
      ReviveLedger.reset()

      abre_o_fogo(worker)

      assert eventually(&skill_saiu?/0)
    end
  end

  # A JANELA DO AUTO COMBO. Uma prensa encadeia todas as skills ofensivas do
  # jogo, e uma segunda tecla no meio corta a corrente — então a rotação
  # continua OFERECENDO a tecla a cada tique e é a cerca que a recusa. Oferecer
  # sempre e recusar por fora é o que faz a primeira prensa depois da janela
  # sair na hora, sem um relógio próprio dentro da máquina de luta.
  describe "a janela do Auto Combo" do
    # "Ele continuou andando depois de fechar o grupo" (02/09): a rajada vai
    # direto no rig e as setas são estado do Body — sem soltar antes, o `r`
    # saía com o personagem andando até o tique seguinte do cavebot.
    @tag :tmp_dir
    test "a corrente solta as setas antes de sair", %{worker: worker} do
      SettingsStash.stash!(auto_combo_key: "r", auto_combo_window_ms: 5_000)
      SkillClock.wipe()
      :ok = Pokex.Bots.Body.hold(["up"])
      on_exit(fn -> Pokex.Bots.Body.release() end)
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)
      assert eventually(fn -> "r" in presses() end), "a corrente não saiu: #{inspect(presses())}"

      calls = Fake.calls()
      solta = Enum.find_index(calls, &(&1 == {:key_up, "up"}))
      corrente = Enum.find_index(calls, &(&1 == {:press, "r"}))
      assert solta != nil, "a seta nunca foi solta: #{inspect(calls)}"
      assert solta < corrente, "o r saiu com a seta segurada: #{inspect(calls)}"
      assert Pokex.Bots.Body.held() == []
    end

    @tag :tmp_dir
    test "a corrente sai UMA vez e a janela recusa a segunda", %{worker: worker} do
      SettingsStash.stash!(auto_combo_key: "r", auto_combo_window_ms: 5_000)
      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)

      assert eventually(fn -> "r" in presses() end),
             "a corrente não saiu: #{inspect(presses())}"

      for _ <- 1..5 do
        world!(worker, battle_obs(enemies: [0, 1, 2]))
        Worker.status(worker)
      end

      refute eventually(fn -> Enum.count(presses(), &(&1 == "r")) > 1 end, 400),
             "a corrente foi reiniciada dentro da própria janela: #{inspect(presses())}"
    end

    # O CICLO INTEIRO, que é o que ele descreveu: corrente → barra vazia → revive
    # devolve a barra → corrente de novo. O revive aqui é `SkillClock.reset/0`,
    # que é literalmente o que o F4 faz com o relógio.
    @tag :tmp_dir
    test "depois do revive devolver a barra, a corrente sai de novo", %{worker: worker} do
      SettingsStash.stash!(auto_combo_key: "r", auto_combo_window_ms: 500)
      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)

      assert eventually(fn -> "r" in presses() end),
             "a corrente não saiu: #{inspect(presses())}"

      refute eventually(
               fn ->
                 world!(worker, battle_obs(enemies: [0, 1, 2]))
                 Enum.count(presses(), &(&1 == "r")) > 1
               end,
               800
             ),
             "reapertou com a barra que a própria corrente esvaziou"

      SkillClock.reset()

      assert eventually(
               fn ->
                 world!(worker, battle_obs(enemies: [0, 1, 2]))
                 Enum.count(presses(), &(&1 == "r")) > 1
               end,
               3_000
             ),
             "a corrente não voltou com a barra cheia: #{inspect(presses())}"
    end

    # O DEFEITO DA NOITE DE 02/09, virado teste.
    #
    # No Auto Combo quem aperta as skills é o JOGO, então o relógio das teclas
    # nunca ficava sabendo delas — e `ready_by_clock/3` devolve PRONTA toda
    # tecla sem aperto registrado. O cérebro leu 8 de 8 prontas em 202 das 210
    # amostras da noite dele, `spent?` foi falso nas 210, e as duas regras de
    # revive exigem justamente ele: 21 combos, zero revives, a pilha subindo de
    # 5 pra 9 e ficando lá.
    @tag :tmp_dir
    test "a corrente carimba o relógio — senão a barra parece cheia pra sempre",
         %{worker: worker} do
      SettingsStash.stash!(auto_combo_key: "r", auto_combo_window_ms: 5_000)
      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      barra = Pokex.Bots.SkillBar.keys(4)
      assert SkillClock.ready_by_clock(barra, %{}) == barra, "o relógio já nasceu sujo"

      abre_o_fogo(worker)

      assert eventually(fn ->
               world!(worker, battle_obs(enemies: [0, 1, 2]))
               SkillClock.ready_by_clock(barra, %{}) == []
             end),
             "o relógio não aprendeu a corrente: #{inspect(SkillClock.ready_by_clock(barra, %{}))}"
    end

    # A CORRIDA QUE ELE VIU EM 02/09: 56 combos e 7 revives.
    #
    # Com a barra JÁ vazia a corrente não faz nada no jogo (as skills do bicho
    # estão em cooldown) e faz uma coisa péssima no bot: reabre a janela de 4s,
    # e o revive — que é o que devolveria a barra — perde a vez pra sempre. O
    # cérebro decide a cada 200ms e a mão dispara no frame seguinte: a mão
    # ganhava a corrida toda vez.
    @tag :tmp_dir
    test "com a barra vazia a corrente NÃO sai — o revive é que tem a vez",
         %{worker: worker} do
      SettingsStash.stash!(auto_combo_key: "r", auto_combo_window_ms: 500)
      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      # a barra diz: nenhuma tecla de dano pronta
      WorldState.put(
        :skill_bar,
        %{states: [:cooldown, :cooldown, :cooldown, :cooldown], ready_keys: []},
        System.monotonic_time(:millisecond)
      )

      abre_o_fogo(worker)

      refute eventually(
               fn ->
                 world!(worker, battle_obs(enemies: [0, 1, 2]))
                 Enum.count(presses(), &(&1 == "r")) > 1
               end,
               1_500
             ),
             "a corrente reapertou com a barra vazia: #{inspect(presses())}"
    end

    # E NENHUMA TECLA SOLTA: o modo administra o combo e o revive, e mais nada.
    @tag :tmp_dir
    test "nenhuma skill individual é apertada", %{worker: worker} do
      SettingsStash.stash!(auto_combo_key: "r", auto_combo_window_ms: 5_000)
      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)

      assert eventually(fn -> "r" in presses() end)
      refute Enum.any?(~w(1 2 3 4 5 6 7), &(&1 in presses()))
      refute Settings.get(:tab_key) in presses()
    end
  end

  # A CAUDA DA RAJADA CEDE AO F4. O `blackout?/1` vota uma vez, na LARGADA — e
  # uma rajada leva (n-1) × gap pra sair da mão. Na noite de 30/08 (4h17), 325
  # rajadas foram atravessadas por um F4 no meio: 237 teclas aterrissaram
  # DEPOIS dele, dentro da mesma janela cega que o portão da largada respeita,
  # quase sempre com a tela já vazia. A cerca (`halt?` do `press_many`) é o
  # mesmo veredito, votado antes de cada tecla.
  # A STATUS POTION ANTES DO ATAQUE (05/09).
  #
  # "Meu pokémon pode estar sob efeito de status negativo antes de usar o auto
  # combo": dormindo ou silenciado, a corrente vira tecla morta — nenhuma skill
  # sai, a barra não gasta, e o bot insiste contra a mobada. A poção do slot E
  # cura tudo e é no-op sem status, então o prefixo custa só o respiro.
  describe "a limpeza de status" do
    defp indice(chamada), do: Enum.find_index(Fake.calls(), &(&1 == chamada))

    defp poções, do: Enum.count(presses(), &(&1 == "e"))

    @tag :tmp_dir
    test "a poção sai na frente da corrente", %{worker: worker} do
      SettingsStash.stash!(
        auto_combo_key: "r",
        auto_combo_window_ms: 5_000,
        status_cure_enabled: true,
        status_cure_key: "e"
      )

      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)
      assert eventually(fn -> "r" in presses() end), "a corrente não saiu: #{inspect(presses())}"

      assert indice({:press, "e"}) < indice({:press, "r"}),
             "a corrente saiu antes da poção: #{inspect(Fake.calls())}"
    end

    # O `e` é um aperto de tecla como qualquer outro, e as setas são estado do
    # `Body`: sem soltar antes, ele sairia com o personagem andando — o mesmo
    # defeito que o #495 consertou pro `r`.
    @tag :tmp_dir
    test "a poção espera as setas serem soltas", %{worker: worker} do
      SettingsStash.stash!(
        auto_combo_key: "r",
        auto_combo_window_ms: 5_000,
        status_cure_enabled: true,
        status_cure_key: "e"
      )

      SkillClock.wipe()
      :ok = Pokex.Bots.Body.hold(["up"])
      on_exit(fn -> Pokex.Bots.Body.release() end)
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)
      assert eventually(fn -> "e" in presses() end), "a poção não saiu: #{inspect(presses())}"

      assert indice({:key_up, "up"}) < indice({:press, "e"}),
             "a poção saiu com a seta segurada: #{inspect(Fake.calls())}"
    end

    # UMA LUTA TEM VÁRIAS CORRENTES, e o status que mata é o que chega no meio
    # da mobada — entre a primeira corrente e a terceira. Por isso o Auto Combo
    # limpa em TODA corrente, e não uma vez por luta.
    @tag :tmp_dir
    test "a segunda corrente da mesma luta também leva a poção", %{worker: worker} do
      SettingsStash.stash!(
        auto_combo_key: "r",
        auto_combo_window_ms: 500,
        status_cure_enabled: true,
        status_cure_key: "e"
      )

      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)
      assert eventually(fn -> "r" in presses() end), "a corrente não saiu: #{inspect(presses())}"

      SkillClock.reset()

      assert eventually(
               fn ->
                 world!(worker, battle_obs(enemies: [0, 1, 2]))
                 Enum.count(presses(), &(&1 == "r")) > 1
               end,
               3_000
             ),
             "a corrente não voltou: #{inspect(presses())}"

      assert poções() > 1, "a segunda corrente saiu sem limpar: #{inspect(presses())}"
    end

    # No Econômico a rajada sai quase a cada tique: limpar antes de todas seria
    # um `e` por segundo. A abertura da luta basta.
    @tag :tmp_dir
    test "no Econômico só a abertura limpa", %{worker: worker} do
      SettingsStash.stash!(status_cure_enabled: true, status_cure_key: "e")

      abre_o_fogo(worker)

      assert eventually(fn -> skill_presses() != [] end),
             "nenhuma skill saiu: #{inspect(presses())}"

      for _ <- 1..6 do
        world!(worker, battle_obs(enemies: [0, 1, 2]))
        Worker.status(worker)
      end

      refute eventually(fn -> poções() > 1 end, 500),
             "limpou mais de uma vez na mesma luta: #{inspect(presses())}"

      assert poções() == 1, "a abertura não limpou: #{inspect(presses())}"
    end

    @tag :tmp_dir
    test "desligada, nenhuma poção sai", %{worker: worker} do
      SettingsStash.stash!(
        auto_combo_key: "r",
        auto_combo_window_ms: 5_000,
        status_cure_enabled: false
      )

      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)
      assert eventually(fn -> "r" in presses() end), "a corrente não saiu: #{inspect(presses())}"

      assert poções() == 0, "limpou com a limpeza desligada: #{inspect(presses())}"
    end

    # O `e` não é skill: não tem cooldown na barra, e carimbá-lo faria o relógio
    # das teclas mentir sobre uma tecla que a barra nunca mostra.
    @tag :tmp_dir
    test "a poção não carimba o relógio das teclas", %{worker: worker} do
      SettingsStash.stash!(
        auto_combo_key: "r",
        auto_combo_window_ms: 5_000,
        status_cure_enabled: true,
        status_cure_key: "e"
      )

      SkillClock.wipe()
      :ok = Worker.run(worker, 5_000, :auto_combo)

      abre_o_fogo(worker)
      assert eventually(fn -> "e" in presses() end), "a poção não saiu: #{inspect(presses())}"

      assert SkillClock.pressed_at("e") == nil,
             "a poção virou cooldown na memória do bot"
    end
  end

  describe "a cauda da rajada cede ao F4" do
    @tag :tmp_dir
    test "o F4 aterrissa no meio da rajada e a cauda para no ar", %{worker: worker} do
      SettingsStash.stash!(rescue_blackout_ms: 5_000, skill_keys: ["1"])
      ReviveLedger.reset()
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())

      # a rajada demora a sair da mão, como a dele demora — o Fake dorme o
      # tempo todo ANTES de prensar, então o F4 abaixo aterrissa com folga
      # antes da primeira tecla
      Agent.update(Fake, &put_in(&1.script[:press_many_sleep_ms], 800))

      abre_o_fogo(worker)

      # a rajada LARGOU (o blackout da largada já votou que não havia revive)…
      assert eventually(fn ->
               match?(%{text: "teclas" <> _}, Worker.status(worker).last_action) or
                 (world!(worker, battle_obs(enemies: [0, 1, 2])) && false)
             end),
             "nenhuma rajada largou"

      # …e o F4 aterrissa enquanto ela ainda dorme o gap
      ReviveLedger.landed()

      assert eventually(fn -> logged?("segurei") end, 2_000),
             "a cauda não cedeu ao F4: #{inspect(presses())}"

      refute skill_saiu?(),
             "uma skill aterrissou DEPOIS do F4, dentro da janela cega: #{inspect(presses())}"
    end
  end
end
