defmodule Pokex.Bots.PlayerSupport.WorkerTest.FakeBody do
  @moduledoc "Records Body.perform calls and forwards them to the test process."
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:perform, actions, priority, _requested_at}, _from, test) do
    send(test, {:performed, priority, actions})
    {:reply, :ok, test}
  end
end

defmodule Pokex.Bots.PlayerSupport.WorkerTest.BlockingBody do
  @moduledoc "A Body whose perform parks until the test sends :release — the real Body under load."
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:perform, actions, priority, _requested_at}, _from, test) do
    send(test, {:performing, priority, actions})

    receive do
      :release -> :ok
    end

    {:reply, :ok, test}
  end
end

defmodule Pokex.Bots.PlayerSupport.WorkerTest.CrashingBody do
  @moduledoc "A Body that dies on perform — the real Body being restarted mid-call."
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:perform, actions, priority, _requested_at}, _from, test) do
    send(test, {:performing, priority, actions})
    raise "body caiu no meio do perform"
  end
end

defmodule Pokex.Bots.PlayerSupport.WorkerTest.RefusingBody do
  @moduledoc "A Body that refuses every perform, the way a closed gate does."
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:perform, actions, priority, _requested_at}, _from, test) do
    send(test, {:performed, priority, actions})
    {:reply, {:error, :input_gate_closed}, test}
  end
end

defmodule Pokex.Bots.PlayerSupport.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.InputGate
  alias Pokex.Bots.PlayerSupport.Worker
  alias Pokex.Bots.SkillClock
  alias Pokex.Bots.PlayerSupport.WorkerTest.BlockingBody
  alias Pokex.Bots.PlayerSupport.WorkerTest.CrashingBody
  alias Pokex.Bots.PlayerSupport.WorkerTest.FakeBody
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.Settings
  alias Pokex.SettingsStash

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    # the combo ships OFF by default; the enabled-path tests turn it on ("toggle off" flips it
    # back). potion_battle_clear_ms: 0 keeps the pre-window tests meaningful (one clear read
    # fires) — the window tests set their own value.
    SettingsStash.stash!(
      support_tick_ms: 20,
      rescue_step_ms: 0,
      # the settle is real time the suite would spend sleeping; the tests that
      # are ABOUT it set their own
      rescue_stun_settle_ms: 0,
      rescue_enabled: true,
      potion_battle_clear_ms: 0
    )

    SettingsStash.stash_keys!([
      :rescue_cooldown_ms,
      :rescue_stun_first,
      :pokemon_hp_rescue_pct,
      :pokemon_hp_full_at_pct,
      :potion_enabled,
      :potion_cooldown_ms,
      :pokemon_hp_potion_pct,
      :heal_skill_enabled,
      :pokemon_hp_heal_pct,
      :heal_skill_cooldown_ms,
      :reposition_enabled,
      :reposition_battle_clear_ms,
      :player_mode,
      :support_waits_capture,
      :support_capture_wait_max_ms,
      :escape_direction,
      :escape_steps,
      :escape_walk_wait_ms,
      :calibration_front_delay_ms
    ])

    on_exit(fn -> WorldState.forget(:pokemon) end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      # matches battle_png/3 (100x400 px): a fixture whose frame is bigger than
      # the region it claims would now read as a 5x capture
      battle_region: {0, 0, 100, 400},
      neutral_point: {500, 500},
      pokemon_hp_region: {0, 0, 20, 4},
      pokemon_photo_point: {40, 620}
    })

    {:ok, body} = FakeBody.start_link(self())
    %{tmp: tmp, body: body}
  end

  # An HP bar PNG: `fill_cols` green columns then dark to `total`.
  defp hp_png(dir, name, fill_cols, total \\ 20) do
    rows = for _y <- 1..4, do: hp_row(fill_cols, total)

    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  defp hp_row(fill_cols, total),
    do:
      for(x <- 1..total, do: if(x <= fill_cols, do: {40, 200, 60, 255}, else: {17, 17, 17, 255}))

  defp start_worker(body), do: start_supervised!({Worker, name: nil, body: body})

  # A battle-body PNG big enough to cover every lock band: all dark-red = a locked fight,
  # all dark = no fight. 100 wide × 400 tall so each 52px band holds thousands of pixels.
  defp battle_png(dir, name, color) do
    rows = for _y <- 1..400, do: List.duplicate(color, 100)
    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  # A VIDA DO PERSONAGEM — a barra vermelha do painel "Pokémon" do PA, que
  # apesar do nome é a vida DELE. Até 28/08 ninguém a lia: o personagem apanha
  # com o pokémon no chão (a noite de 4,9h) e nada media nem avisava.
  describe "a vida do PERSONAGEM" do
    setup %{tmp: tmp} do
      Settings.put(:rescue_enabled, false)
      Settings.put(:potion_enabled, false)
      SettingsStash.stash!(player_hp_floor_pct: 50, player_hp_logout: false)

      {:ok, calib} = Calibration.load()
      :ok = Calibration.save(%{calib | player_hp_region: {0, 100, 20, 4}})

      # a barra vermelha do PA: preenchimento vermelho, trilho azul-ardósia
      red = fn fill ->
        rows =
          for _y <- 1..4 do
            for x <- 1..20,
                do: if(x <= fill, do: {211, 52, 53, 255}, else: {56, 71, 71, 255})
          end

        Pokex.PngFixtures.write!(Path.join(tmp, "player_#{fill}.png"), rows)
      end

      on_exit(fn -> WorldState.forget(:player) end)
      %{red: red}
    end

    # A SENTINELA (30/08): o canto de comando parou a caçada no meio de uma
    # mobada e o personagem morreu AFK em 8 minutos SEM UM ALARME — o halt
    # cancelava o timer e ninguém mais lia a vida DELE. Parar fecha as mãos,
    # nunca os olhos: halted, o monitor nascido automático segue lendo a barra
    # do personagem e gritando no piso.
    @tag :tmp_dir
    test "PARADO, a sentinela segue lendo e grita no piso", %{body: body, red: red} do
      {:ok, _} = Fake.start_link(%{capture: [{:ok, red.(6)}]})
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_supervised!({Worker, name: nil, body: body, auto_monitor: true})
      assert :ok = Worker.halt(worker)

      assert_receive {:rule_alarm, :hp, aviso}, 6_000
      assert aviso =~ "VOCÊ está com"
    end

    # …mas só o monitor de verdade: a suíte inteira roda com auto_monitor
    # desligado, e um halt nela tem que continuar sendo silêncio total.
    @tag :tmp_dir
    test "sem o arranque automático, o halt é silêncio como sempre foi", %{
      body: body,
      red: red
    } do
      {:ok, _} = Fake.start_link(%{capture: [{:ok, red.(6)}]})
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)
      assert :ok = Worker.halt(worker)

      refute_receive {:rule_alarm, :hp, _}, 2_500
    end

    @tag :tmp_dir
    test "a leitura vira o fato :player", %{body: body, red: red} do
      {:ok, _} = Fake.start_link(%{capture: [{:ok, red.(18)}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert eventually(fn ->
               match?(
                 {:ok, %{hp_pct: pct, readable?: true}} when pct >= 85,
                 WorldState.get(:player, 5_000, System.monotonic_time(:millisecond))
               )
             end)
    end

    @tag :tmp_dir
    test "duas leituras abaixo do piso gritam UMA vez, nomeando o personagem", %{
      body: body,
      red: red
    } do
      {:ok, _} = Fake.start_link(%{capture: [{:ok, red.(6)}]})
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:rule_alarm, :hp, msg}, 1_500
      assert msg =~ "VOCÊ"
      assert msg =~ "personagem"

      # uma vez por episódio: a barra segue baixa e a sirene não vira metralhadora
      refute_receive {:rule_alarm, :hp, _de_novo}, 300
    end

    @tag :tmp_dir
    test "acima do piso, silêncio", %{body: body, red: red} do
      {:ok, _} = Fake.start_link(%{capture: [{:ok, red.(18)}]})
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:rule_alarm, :hp, _msg}, 500
    end

    @tag :tmp_dir
    test "com player_hp_logout ligado, o aviso diz que o logout foi pedido", %{
      body: body,
      red: red
    } do
      Settings.put(:player_hp_logout, true)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, red.(6)}]})
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:game_log, :macro, log}, 1_500
      assert log =~ "pedindo LOGOUT"
    end

    @tag :tmp_dir
    test "sem a região marcada, nada é lido e nada grita", %{body: body, red: red} do
      {:ok, calib} = Calibration.load()
      :ok = Calibration.save(%{calib | player_hp_region: nil})
      {:ok, _} = Fake.start_link(%{capture: [{:ok, red.(6)}]})
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:rule_alarm, :hp, _msg}, 500
      assert WorldState.get(:player, 5_000, System.monotonic_time(:millisecond)) == :missing
    end
  end

  # The pokémon's OWN healing skill: the rung above the potion, and the only one
  # that works while it is being hit — a potion is a channel and combat cancels
  # it, so HP falling mid-fight used to have nothing before the revive.
  describe "the pokémon's healing skill" do
    setup do
      Settings.put(:rescue_enabled, false)
      Settings.put(:potion_enabled, false)
      Settings.put(:heal_skill_enabled, true)
      Settings.put(:pokemon_hp_heal_pct, 70)
      Settings.put(:heal_skill_cooldown_ms, 60_000)
      :ok
    end

    defp classify!(name, profile) do
      File.write!(
        Path.join(Pokex.Home.dir(), "pokedex.json"),
        JSON.encode!(%{"species" => [%{"name" => name, "number" => 1, "elements" => ["Grass"]}]})
      )

      Application.put_env(:pokex, :pokedex_path, Path.join(Pokex.Home.dir(), "pokedex.json"))
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_path) end)

      {:ok, _} = Pokex.Pokedex.Team.add(name)
      Pokex.Pokedex.Team.set_skills(name, profile)
      Pokex.Pokedex.Team.set_active(name)
    end

    @tag :tmp_dir
    test "low HP presses the :heal key of the pokémon on the field", %{tmp: tmp, body: body} do
      classify!("Venusaur", %{"3" => :aoe, "8" => :heal})
      low = hp_png(tmp, "low_heal.png", 10)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:performed, :high, [{:press, "8"}]}, 800
    end

    @tag :tmp_dir
    test "a refused heal is named in the feed, and the cooldown still holds", %{tmp: tmp} do
      classify!("Venusaur", %{"8" => :heal})
      low = hp_png(tmp, "low_refused.png", 10)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      {:ok, refusing} = Pokex.Bots.PlayerSupport.WorkerTest.RefusingBody.start_link(self())

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(refusing)
      assert :ok = Worker.run(worker)

      assert_receive {:performed, :high, [{:press, "8"}]}, 800
      assert await_log("cura não saiu") =~ "cura não saiu"
      refute_receive {:performed, :high, _}, 300
    end

    # No combat gate is the WHOLE point: the potion has one and that is the hole
    # this fills.
    @tag :tmp_dir
    test "it fires with a fight locked on screen — where the potion cannot", %{
      tmp: tmp,
      body: body
    } do
      classify!("Venusaur", %{"8" => :heal})
      low = hp_png(tmp, "low_fight.png", 10)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      WorldState.put(
        :battle,
        %{enemies: [0], locked?: true, locked_row: 0},
        System.monotonic_time(:millisecond)
      )

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:performed, :high, [{:press, "8"}]}, 800
    end

    @tag :tmp_dir
    test "a pokémon with no heal classified presses nothing", %{tmp: tmp, body: body} do
      classify!("Venusaur", %{"3" => :aoe})
      low = hp_png(tmp, "low_none.png", 10)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, _priority, _actions}, 300
    end

    @tag :tmp_dir
    test "a full bar presses nothing", %{tmp: tmp, body: body} do
      classify!("Venusaur", %{"8" => :heal})
      full = hp_png(tmp, "full_heal.png", 20)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, full}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, _priority, _actions}, 300
    end

    # The tick is 20ms here; without the cooldown this would be a key every tick.
    @tag :tmp_dir
    test "the cooldown holds it to ONE press, not one per tick", %{tmp: tmp, body: body} do
      classify!("Venusaur", %{"8" => :heal})
      low = hp_png(tmp, "low_once.png", 10)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:performed, :high, [{:press, "8"}]}, 800
      refute_receive {:performed, _priority, _actions}, 300
      assert Worker.status(worker).counters.heals == 1
    end
  end

  @tag :tmp_dir
  test "holds (no combo) while the HP bar is full", %{tmp: tmp, body: body} do
    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, full}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).hp_pct == 100
  end

  # The old reader turned bright game-world pixels into a garbage low-HP % and fired the
  # combo in a loop.
  @tag :tmp_dir
  test "a MINIMIZED party window (region shows game world) reads UNKNOWN and never acts", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, true)
    Settings.put(:potion_enabled, true)

    rows = for _y <- 1..4, do: List.duplicate({120, 180, 235, 255}, 20)
    world = Pokex.PngFixtures.write!(Path.join(tmp, "world.png"), rows)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, world}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    status = Worker.status(worker)
    assert status.hp_pct == nil
    assert status.error =~ "não reconhecida"
    assert status.counters.rescues == 0
    assert status.counters.potions == 0
  end

  @tag :tmp_dir
  test "halt STICKS (panic path): no reads or actions after halt, run re-arms", %{
    tmp: tmp,
    body: body
  } do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)
    Settings.put(:rescue_cooldown_ms, 1)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)
    assert_receive {:performed, :critical, _}, 1_000
    assert Worker.status(worker).state == :monitoring

    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle
    reads_at_halt = Worker.status(worker).counters.reads
    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.reads == reads_at_halt

    # re-published: the halt/re-arm round trip can outlast the fact's fresh window
    orders!(:now)
    assert :ok = Worker.run(worker)
    assert Worker.status(worker).state == :monitoring
    assert_receive {:performed, :critical, _}, 1_000
  end

  # The old client's full bar read raw 95: its rounded tip never painted the last columns of
  # the box. Poké Alliance's reads a true 100, so the correction is off by default and this
  # test asks for it.
  @tag :tmp_dir
  test "the rounded bar tip is corrected: raw 95% reads as a genuinely FULL 100%", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:pokemon_hp_full_at_pct, 95)
    nearly = hp_png(tmp, "nearly.png", 19)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, nearly}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).hp_pct == 100
  end

  @tag :tmp_dir
  test "fires the revive at :critical when HP is below the threshold", %{
    tmp: tmp,
    body: body
  } do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, actions}, 1_000
    assert actions == [{:press, "q"}]

    assert Worker.status(worker).counters.rescues >= 1
  end

  # A VIA QUE PROTEGE O JOGADOR ANTES DO PREFLIGHT. O monitor arranca sozinho no
  # boot (e `BotSupervisor.start_all` o arma ANTES do preflight de propósito,
  # pra que uma calibração quebrada ainda deixe o jogador protegido). O env que
  # decide isso era lido CRU dentro do `init/1`, então na suíte inteira era
  # impossível optar por voltar: nenhum teste jamais viu esse arranque.
  @tag :tmp_dir
  test "com o arranque automático ligado, ele já nasce monitorando", %{tmp: _tmp, body: body} do
    worker = start_supervised!({Worker, name: nil, body: body, auto_monitor: true})

    assert Worker.status(worker).state == :monitoring
  end

  @tag :tmp_dir
  test "e desligado ele espera o run/1, que é como a suíte inteira roda", %{
    tmp: _tmp,
    body: body
  } do
    worker = start_supervised!({Worker, name: nil, body: body, auto_monitor: false})

    assert Worker.status(worker).state == :idle
  end

  # UMA MENSAGEM PERDIDA NÃO PODE DESLIGAR UMA VIA DE SEGURANÇA PRA SEMPRE.
  # `rescuing?` é ligado ao despachar o combo e só volta a false quando o
  # `{:rescue_done, _, _}` chega — e a tarefa que manda essa mensagem é um
  # `spawn` sem link, sem monitor e sem `try`. Se ela morre (o Body cai
  # enquanto ela está parada dentro do `perform`, que espera `:infinity`), a
  # mensagem nunca chega, a flag latcha, e o resgate por vida baixa não sai
  # NUNCA MAIS — nem Parar+Iniciar recupera, porque a flag é estado do
  # processo e o supervisor é `:one_for_one`. Poção e cura seguem saindo, o
  # painel parece saudável, e cada emergência seguinte custa uma morte.
  @tag :tmp_dir
  test "um resgate cuja tarefa morre não desliga o resgate pro resto da noite", %{tmp: tmp} do
    low = hp_png(tmp, "low_latch.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)
    Settings.put(:rescue_cooldown_ms, 1)

    {:ok, blocking} = BlockingBody.start_link(self())
    Process.unlink(blocking)

    worker = start_worker(blocking)
    assert :ok = Worker.run(worker)

    assert_receive {:performing, :critical, _}, 1_000
    assert Worker.status(worker).counters.rescues == 1

    # o corpo morre com a tarefa do resgate parada dentro dele
    Process.exit(blocking, :kill)

    assert wait_until(fn -> Worker.status(worker).counters.rescues >= 2 end),
           "o resgate travou: `rescuing?` nunca voltou a false"
  end

  # "ele não está usando a skill 1, que seria a skill guardada para reviver, e
  # a skill de stun (…) eu morri já por culpa disso!" (Lucas, 2026-08-14).
  # Combat RESERVES the control keys for this exact moment, and plain "direto"
  # never pressed them: reserved by everyone, pressed by nobody.
  @tag :tmp_dir
  test "the reserved control key IS the stun", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_stun_first, true)
    classify!("Gardevoir", %{"1" => :crowd, "3" => :aoe})

    low = hp_png(tmp, "low_reserved.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    # the stun goes out FIRST and alone — the recall waits for its receipt
    assert_receive {:performed, :critical, [{:press, "1"}]}, 1_500
    assert_receive {:performed, :critical, revive}, 1_500
    assert revive == [{:press, "q"}]

    assert await_log("stun do resgate") =~ "guardado no /time"
  end

  @tag :tmp_dir
  test "with no control classified it revives direct, and says why", %{tmp: tmp, body: body} do
    Settings.put(:rescue_stun_first, true)
    classify!("Magikarp", %{"3" => :aoe})

    low = hp_png(tmp, "low_no_control.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, [{:press, "q"} | _]}, 1_500
    assert await_log("sem controle pronto") =~ "revivendo direto"
  end

  @tag :tmp_dir
  # "é só apertar o botão F4" (Lucas, 2026-08-24): one hotkey is the whole
  # revive. A reserved control key EXISTS in this test on purpose — with the
  # prefix off, not even a ready control key may delay the revive.
  test "the revive is one press and nothing more", %{tmp: tmp, body: body} do
    # O prefixo do stun é o PADRÃO desde 25/08 — este teste é sobre a tecla do
    # revive em si, então ele desliga o prefixo pra perguntar só isso.
    SettingsStash.stash!(rescue_stun_first: false)

    SettingsStash.stash_keys!([:rescue_key])
    Settings.put(:rescue_key, "f4")
    classify!("Gardevoir", %{"1" => :crowd, "3" => :aoe})

    low = hp_png(tmp, "low_single_key.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, [{:press, "f4"}]}, 1_500
    refute_receive {:performed, :critical, _anything_else}, 500
  end

  @tag :tmp_dir
  # "eu uso geralmente as skills 1 e 2 para justamente silenciar os pokémons ao
  # redor, colocar eles para dormir, e aí, sim, eu tiro meu Pokémon de campo"
  # (Lucas, 2026-08-11). The stun is its OWN sequence now, so its receipt can
  # be read before the recall strips the field.
  test "stun first: the control keys go out ALONE, and the revive follows", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_stun_first, true)
    classify!("Gardevoir", %{"1" => :crowd, "2" => :crowd})

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    # first sequence: the crowd control, and nothing else — no recall rides
    # along, because it must not happen until this one is confirmed
    assert_receive {:performed, :critical, stun}, 1_000
    assert stun == [{:press, "1"}, {:press, "2"}]

    # second: the revive itself
    assert_receive {:performed, :critical, revive}, 1_000
    assert revive == [{:press, "q"}]
  end

  # 2026-08-14, live: the recall followed the confirmation by ~100ms and the
  # field went empty while the game's sleep was still in flight — the jungle
  # turned on Lucas himself ("quase me fez morrer"). The receipt proves the KEY
  # fired; the monsters take ~800ms to be DOWN. The pokémon keeps tanking
  # through that, and the wait rides INSIDE the revive sequence so nothing can
  # slip between the pile falling asleep and the field emptying.
  @tag :tmp_dir
  test "the recall waits for the sleep to LAND, not just for the key to fire", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_stun_first, true)
    classify!("Gardevoir", %{"1" => :crowd})
    Settings.put(:rescue_confirm_ms, 0)
    Settings.put(:rescue_stun_settle_ms, 500)

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, [{:press, "1"}]}, 1_000
    assert_receive {:performed, :critical, [{:wait, settle} | rest]}, 1_000

    assert settle > 0 and settle <= 500
    assert [{:press, "q"} | _] = rest
  end

  @tag :tmp_dir
  test "with nothing stunned there is nothing to settle: the recall is immediate", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_stun_settle_ms, 500)

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, revive}, 1_000
    assert [{:press, "q"} | _] = revive
  end

  @tag :tmp_dir
  test "the settle counts from the press, so a slow confirmation is not paid twice", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_stun_first, true)
    classify!("Gardevoir", %{"1" => :crowd})
    # the confirmation alone outlasts the settle: nothing is left to wait for
    Settings.put(:rescue_confirm_ms, 300)
    Settings.put(:rescue_stun_settle_ms, 100)

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, [{:press, "1"}]}, 1_000
    assert_receive {:performed, :critical, revive}, 1_500
    assert [{:press, "q"} | _] = revive
  end

  @tag :tmp_dir
  test "an unreadable bar cannot confirm the stun, and the revive happens anyway", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_stun_first, true)
    classify!("Gardevoir", %{"1" => :crowd})
    Settings.put(:rescue_confirm_ms, 0)

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    worker = start_worker(body)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, [{:press, "1"}]}, 1_000
    assert_receive {:performed, :critical, [{:press, "q"} | _]}, 1_000

    # a pokémon left dead is worse than a pokémon revived in the open — but
    # the doubt is SAID, never assumed away (after the dispatch line: the
    # receipt is read by the rescue task, so its note arrives with the report)
    assert await_log("não consegui confirmar o stun") =~ "revivendo assim mesmo"
  end

  @tag :tmp_dir
  test "a single low-HP glitch frame between full reads never fires the combo", %{
    tmp: tmp,
    body: body
  } do
    full = hp_png(tmp, "full.png", 20)
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, full}, {:ok, low}, {:ok, full}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 400
    assert Worker.status(worker).counters.rescues == 0
  end

  @tag :tmp_dir
  test "the cooldown blocks a second combo within the window", %{tmp: tmp, body: body} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)
    Settings.put(:rescue_cooldown_ms, 60_000)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, _}, 1_000
    refute_receive {:performed, :critical, _}, 300
    assert Worker.status(worker).counters.rescues == 1
  end

  # 2026-08-14: the 900ms stun receipt plus the :infinity Body call used to run
  # INSIDE the tick — a panic during a rescue outlived safe_halt's 1s and the
  # Guardian logged "não respondeu em 1000ms" while stopping the fleet.
  @tag :tmp_dir
  test "the rescue never parks the worker: status and halt answer mid-combo", %{tmp: tmp} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)
    {:ok, blocking} = Pokex.Bots.PlayerSupport.WorkerTest.BlockingBody.start_link(self())

    worker = start_worker(blocking)
    assert :ok = Worker.run(worker)

    assert_receive {:performing, :critical, _}, 1_000

    assert Worker.status(worker).counters.rescues == 1
    assert :ok = Worker.halt(worker)

    send(blocking, :release)
  end

  # The 2-tuple form lands in a pseudo-category the panel cannot mute (:geral):
  # these are HP alarms, and today they multiplied (stun that missed, revive
  # refused, fallen revive refused) — an unmutable siren at 3am is a siren he
  # will turn off at the master switch, losing the others with it.
  @tag :tmp_dir
  test "the support's alarms carry the :hp sector, so the mute can reach them", %{
    tmp: tmp
  } do
    low = hp_png(tmp, "low_sector.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)
    {:ok, refusing} = Pokex.Bots.PlayerSupport.WorkerTest.RefusingBody.start_link(self())

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_worker(refusing)
    assert :ok = Worker.run(worker)

    assert_receive {:rule_alarm, :hp, msg}, 1_500
    assert msg =~ "revive"
  end

  @tag :tmp_dir
  test "a refused revive is NAMED, and the cooldown still holds", %{tmp: tmp} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)
    {:ok, refusing} = Pokex.Bots.PlayerSupport.WorkerTest.RefusingBody.start_link(self())
    Settings.put(:rescue_cooldown_ms, 60_000)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_worker(refusing)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, _}, 1_000
    assert_receive {:rule_alarm, :hp, msg}, 1_000
    assert msg =~ "revive"
    assert msg =~ "NÃO saiu"

    refute_receive {:performed, :critical, _}, 300
    assert Worker.status(worker).counters.rescues == 1
  end

  @tag :tmp_dir
  test "a delivered revive is confirmed in the feed", %{tmp: tmp, body: body} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    orders!(:now)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, _}, 1_000
    assert await_log("revive despachado") =~ "revive despachado"
  end

  defp await_log(matching) do
    assert_receive {:game_log, _level, text}, 1_000
    if text =~ matching, do: text, else: await_log(matching)
  end

  # THE ENGINE IS THE ONLY VOICE on when to revive (2026-08-17): "quem manda
  # ser tomada uma poção ou reviver um pokémon não deveria ser só um
  # observador da vida, puramente, porque não é puro assim". A health
  # percentage alone cannot tell a live pile with every cooldown up from a
  # cleared one with nothing left; the old ladder only ever asked the first
  # question. Fresh orders decide WHEN in both directions; stale or missing
  # ones simply hold (PR 7 retired the threshold-only ladder underneath —
  # there is nothing left to fall back to, by design).
  describe "obeying the engine" do
    defp orders!(revive) do
      WorldState.put(:orders, %{revive: revive}, System.monotonic_time(:millisecond))
    end

    @tag :tmp_dir
    test "revives on the engine's word even above the old threshold", %{tmp: tmp, body: body} do
      # 70% — well above the default 50% rescue threshold, which alone would hold
      high = hp_png(tmp, "engine_now.png", 14)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, high}]})
      orders!(:now)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:performed, :critical, _}, 1_500
      assert Worker.status(worker).counters.rescues >= 1
    end

    # R3 in the field: the pile is not down yet, so the revive stays in its
    # holster even though the old ladder — reading nothing but the bar — would
    # already have fired.
    @tag :tmp_dir
    test "holds below the old threshold while the engine is still closing the round", %{
      tmp: tmp,
      body: body
    } do
      low = hp_png(tmp, "engine_hold.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:hold)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, :critical, _}, 400
      assert Worker.status(worker).counters.rescues == 0
    end

    @tag :tmp_dir
    test "his own toggle outranks the engine saying now", %{tmp: tmp, body: body} do
      Settings.put(:rescue_enabled, false)
      low = hp_png(tmp, "engine_disabled.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:now)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, :critical, _}, 400
    end

    # …E DIZ QUE RECUSOU. A chave continua vencendo o cérebro — ela é a mão dele
    # no interruptor —, mas um pedido que morre em silêncio é a coisa mais cara
    # que este bot faz sem contar: em 27/08 a engine pediu revive 556 vezes num
    # dia inteiro, e nenhuma tecla saiu porque `rescue_enabled` nasce desligado.
    @tag :tmp_dir
    test "e ela AVISA, em vez de engolir o pedido", %{tmp: tmp, body: body} do
      Settings.put(:rescue_enabled, false)
      low = hp_png(tmp, "engine_switch_warn.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:now)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:rule_alarm, :hp, aviso}, 800
      assert aviso =~ "chave está DESLIGADA"
    end

    @tag :tmp_dir
    test "com a chave ligada não há aviso nenhum", %{tmp: tmp, body: body} do
      Settings.put(:rescue_enabled, true)
      low = hp_png(tmp, "engine_switch_quiet.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:now)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:rule_alarm, :hp, _aviso}, 400
    end

    # There is no older ladder underneath this one anymore (PR 7): a stale or
    # missing :orders fact holds rather than guessing off HP alone, the same
    # fail-open rule as every other missing fact in this codebase. A brief gap
    # here is bounded by OTP restarting Engine.Worker (a supervised, permanent
    # child of BotSupervisor) within milliseconds of any crash; a failure bad
    # enough to keep it down is bad enough to have already taken Combat and
    # Cavebot down with it.
    @tag :tmp_dir
    test "a stale engine holds — there is no older ladder underneath it anymore", %{
      tmp: tmp,
      body: body
    } do
      low = hp_png(tmp, "engine_stale.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      # a real order, aged well past the fresh window — as good as no engine at all
      WorldState.put(:orders, %{revive: :hold}, System.monotonic_time(:millisecond) - 60_000)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, :critical, _}, 400
      assert Worker.status(worker).counters.rescues == 0
    end

    @tag :tmp_dir
    test "no engine fact at all holds too", %{tmp: tmp, body: body} do
      low = hp_png(tmp, "engine_missing.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, :critical, _}, 400
      assert Worker.status(worker).counters.rescues == 0
    end
  end

  # "se não tem mais outras skills pra usar, pra tentar dar aquele último dano,
  # daí recolhe" (Lucas, 2026-08-14). A bar still showing the key as READY
  # after the press is the receipt saying it never fired.
  describe "a stun that never went out" do
    setup do
      SettingsStash.stash!(rescue_enabled: true, rescue_confirm_ms: 120)
      SettingsStash.stash_keys!([:rescue_stun_settle_ms, :rescue_stun_first])
      Settings.put(:rescue_stun_settle_ms, 0)
      :ok
    end

    # The bar never changes, so every press reads as refused — the only way to
    # walk the refusal path without inventing pixels.
    defp bar_stuck_ready(keys) do
      publisher =
        spawn(fn ->
          Enum.each(1..400, fn _ ->
            WorldState.put(:skill_bar, %{ready_keys: keys}, System.monotonic_time(:millisecond))
            Process.sleep(15)
          end)
        end)

      on_exit(fn -> Process.exit(publisher, :kill) end)
      Process.sleep(30)
    end

    defp stun_first! do
      Settings.put(:rescue_stun_first, true)
    end

    @tag :tmp_dir
    test "everything still in hand is tried BEFORE the field is given up", %{
      tmp: tmp,
      body: body
    } do
      classify!("Gardevoir", %{"1" => :crowd, "2" => :crowd, "3" => :aoe})
      stun_first!()
      bar_stuck_ready(["1", "2", "3"])

      low = hp_png(tmp, "low_last_card.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:now)

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      # the stun that refused — both control keys, the ones /time reserves…
      assert_receive {:performed, :critical, [{:press, "1"}, {:press, "2"}]}, 2_000

      # …then the rest of the hand, never a key already spent
      assert_receive {:performed, :critical, last_card}, 2_000
      assert last_card == [{:press, "3"}]

      # and only THEN does the field empty
      assert_receive {:performed, :critical, revive}, 2_000
      assert List.last(revive) == {:press, "q"}
    end

    @tag :tmp_dir
    test "with nothing left in hand it recalls at once, and says so", %{tmp: tmp, body: body} do
      classify!("Abra", %{"1" => :crowd})
      stun_first!()
      bar_stuck_ready(["1"])

      low = hp_png(tmp, "low_empty_hand.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:now)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:performed, :critical, [{:press, "1"}]}, 2_000
      assert_receive {:performed, :critical, revive}, 2_000
      assert List.last(revive) == {:press, "q"}

      assert await_log("não sobrou skill") =~ "recolhendo agora"
    end
  end

  # "se o pokémon morrer naturalmente, a gente tem que saber lidar com o fluxo"
  # (Lucas, 2026-08-14): when it falls the pokémon window changes shape, so the
  # calibrated strip stops holding a bar — the same `:unrecognized` a covered
  # game produces. What separates them is where the bar WAS.
  describe "when the pokémon falls" do
    setup do
      SettingsStash.stash!(
        rescue_enabled: true,
        pokemon_hp_fainted_below_pct: 35,
        fainted_revive_cooldown_ms: 15_000
      )

      :ok
    end

    # what the region shows once the window has moved off it
    defp world_png(dir, name) do
      rows = for _y <- 1..4, do: List.duplicate({120, 180, 235, 255}, 20)
      Pokex.PngFixtures.write!(Path.join(dir, name), rows)
    end

    defp dying_then_gone(tmp) do
      low = hp_png(tmp, "dying.png", 4)
      gone = world_png(tmp, "gone.png")

      {:ok, _} =
        Fake.start_link(%{
          capture: [{:ok, low}, {:ok, gone}, {:ok, gone}, {:ok, gone}, {:ok, gone}, {:ok, gone}]
        })
    end

    @tag :tmp_dir
    test "the bar vanishing off a dying pokémon brings him back", %{tmp: tmp, body: body} do
      dying_then_gone(tmp)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert await_log("caiu") =~ "revive na hora"
      assert Worker.status(worker).last_action.text == "revive do caído"
    end

    # O F4 RECOLHE O POKÉMON — e os tiques de barra ilegível logo depois são o
    # RESULTADO do revive, não uma morte. `maybe_revive_fallen` precisa só de
    # dois tiques ilegíveis (240ms) mais um `last_seen_hp` abaixo de 35, e
    # `fire_rescue` não limpava esse rastro: o revive que DEU CERTO virava um
    # segundo revive, este SEM prefixo de stun — recolhendo o pokémon de novo na
    # frente de uma pilha acordada, que é o que `rescue_stun_first` existe para
    # impedir. `maybe_revive_fallen` já limpa o rastro depois de si mesma, pelo
    # mesmo motivo e com o mesmo comentário.
    @tag :tmp_dir
    test "o revive que deu certo não é lido como morte dois tiques depois", %{
      tmp: tmp,
      body: body
    } do
      low = hp_png(tmp, "low_then_ball.png", 6)
      gone = world_png(tmp, "ball.png")

      {:ok, _} =
        Fake.start_link(%{
          capture: [{:ok, low}, {:ok, gone}, {:ok, gone}, {:ok, gone}, {:ok, gone}]
        })

      # o cérebro manda reviver: é a porta do RESGATE que abre primeiro
      orders!(:now)
      # e sem segunda chance por ela — o que se mede aqui é a porta do caído
      Settings.put(:rescue_cooldown_ms, 60_000)
      # a carência É o assunto deste teste: fixada, nunca herdada da semente
      Settings.put(:engine_revive_confirm_ms, 3_000)

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert_receive {:performed, :critical, _}, 1_000
      refute_receive {:performed, :critical, _}, 600

      assert Worker.status(worker).counters.rescues == 1
    end

    @tag :tmp_dir
    test "single-key mode: the fallen revive is the same one press, no cursor", %{
      tmp: tmp,
      body: body
    } do
      SettingsStash.stash_keys!([:rescue_key])
      Settings.put(:rescue_key, "f4")
      dying_then_gone(tmp)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert await_log("caiu") =~ "revive na hora"
      assert_receive {:performed, :critical, [{:press, "f4"}]}, 2_000
      refute_receive {:performed, :critical, [{:move, _} | _]}, 500
    end

    @tag :tmp_dir
    test "a HEALTHY bar that vanishes is a covered window, not a death", %{
      tmp: tmp,
      body: body
    } do
      full = hp_png(tmp, "full.png", 20)
      gone = world_png(tmp, "gone.png")

      {:ok, _} = Fake.start_link(%{capture: [{:ok, full}, {:ok, gone}, {:ok, gone}, {:ok, gone}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, :critical, _}, 500
      assert Worker.status(worker).error =~ "não reconhecida"
    end

    # The anti-loop that matters overnight: a pokémon merely STORED in its ball
    # must never drain the revives — the next one costs a fresh live sighting.
    @tag :tmp_dir
    test "one death costs exactly one revive", %{tmp: tmp, body: body} do
      dying_then_gone(tmp)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert await_log("caiu") =~ "revive na hora"
      spent = Worker.status(worker).counters.rescues

      Process.sleep(300)
      assert Worker.status(worker).counters.rescues == spent
    end

    # O outro lado da mesma moeda. O resgate do caído dispara uma vez por morte
    # de propósito; o preço disso era que um revive que NÃO SAIU encerrava a
    # noite, porque ninguém perguntava de novo. Quem pergunta é o cérebro — é o
    # único que sabe se o corpo voltou (`:downed`).
    @tag :tmp_dir
    test "e um revive que não saiu é pedido de novo, quando o cérebro insiste", %{
      tmp: tmp,
      body: body
    } do
      Settings.put(:fainted_revive_cooldown_ms, 1)
      # a carência do revive fresco não é o assunto deste teste: aqui o revive
      # PROVADAMENTE não saiu, e o que se mede é o cérebro pedindo de novo
      Settings.put(:engine_revive_confirm_ms, 500)
      dying_then_gone(tmp)
      orders!(:now)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert await_log("caiu") =~ "revive na hora"
      assert await_log("insiste") =~ "de novo"
      assert Worker.status(worker).counters.rescues >= 2
    end

    @tag :tmp_dir
    test "mas calado o cérebro não é permissão: sem ordem, segue sendo um por morte", %{
      tmp: tmp,
      body: body
    } do
      Settings.put(:fainted_revive_cooldown_ms, 1)
      dying_then_gone(tmp)
      orders!(:hold)
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      assert await_log("caiu") =~ "revive na hora"
      Process.sleep(300)

      assert Worker.status(worker).counters.rescues == 1
    end
  end

  defp await_snapshot(matcher) do
    assert_receive {:game, snap}, 1_000
    if matcher.(snap), do: snap, else: await_snapshot(matcher)
  end

  # 2026-08-14: the gate was only cleared inside act/2, so the branches that
  # never reach it (unreadable bar, capture error, no calibration) kept
  # yesterday's gate on screen — the panel showed "fora de foco" for as long
  # as the reading stayed bad, in front of the real reason.
  @tag :tmp_dir
  test "an unreadable bar clears yesterday's gate instead of parroting it", %{
    tmp: tmp,
    body: body
  } do
    low = hp_png(tmp, "low_gate.png", 6)
    rows = for _y <- 1..4, do: List.duplicate({120, 180, 235, 255}, 20)
    world = Pokex.PngFixtures.write!(Path.join(tmp, "world.png"), rows)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}, {:ok, world}]})

    InputGate.set_focus_ok(false)
    on_exit(fn -> InputGate.set_focus_ok(true) end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    snap = await_snapshot(&(&1.error != nil and &1.error =~ "não reconhecida"))
    refute (snap.hold_reason || "") =~ "fora de foco"
  end

  @tag :tmp_dir
  test "publishes the :pokemon fact — HP when readable, readable?: false when not", %{
    tmp: tmp,
    body: body
  } do
    full = hp_png(tmp, "full.png", 20)
    rows = for _y <- 1..4, do: List.duplicate({120, 180, 235, 255}, 20)
    world = Pokex.PngFixtures.write!(Path.join(tmp, "world.png"), rows)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, full}, {:ok, world}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert wait_until(fn ->
             Pokex.Perception.pokemon() ==
               {:ok, %{hp_pct: 100, readable?: true, fainted?: false}}
           end)

    # a bar that vanishes off a FULL pokémon is a window, never a death
    assert wait_until(fn ->
             Pokex.Perception.pokemon() ==
               {:ok, %{hp_pct: nil, readable?: false, fainted?: false}}
           end)
  end

  defp wait_until(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_500

    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait_until(fun, deadline)
    end
  end

  # The potion gate reads the :battle blackboard entry first, so each test pins WorldState:
  # a stale entry forces the direct capture+interpret fallback; a fresh one is read as-is.
  defp stale_battle! do
    at = System.monotonic_time(:millisecond) - 60_000
    WorldState.put(:battle, %{enemies: [], locked?: false, captured_at: at}, at)
  end

  defp fresh_battle!(fields) do
    at = System.monotonic_time(:millisecond)

    obs =
      Enum.into(fields, %{enemies: [], red: [], locked?: false, locked_row: nil, captured_at: at})

    WorldState.put(:battle, obs, at)
  end

  # During the minigame the Body is locked anyway, and the 120ms HP reads only queued
  # ahead of the game's strip capture (measured: 80ms cadence degraded to ~250ms).
  @tag :tmp_dir
  test "does not read HP while a minigame is in play — frees the broker for the strip", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, true)

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

    WorldState.put(
      :mini_game,
      %{playing?: true, confidence: 0.9},
      System.monotonic_time(:millisecond)
    )

    on_exit(fn -> WorldState.forget(:mini_game) end)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 250
    assert Worker.status(worker).counters.reads == 0
    assert Worker.status(worker).hold_reason =~ "minigame"
  end

  @tag :tmp_dir
  test "sips a potion when HP is below the potion threshold and no fight is engaged", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)

    stale_battle!()
    low = hp_png(tmp, "low.png", 6)
    no_fight = battle_png(tmp, "calm.png", {17, 17, 17, 255})

    # The Fake serves captures SEQUENTIALLY and sticks on the last one, so from
    # the second tick the HP read was getting the all-dark battle frame. That
    # used to "work": every dark pixel counted as the bar's empty track, so a
    # black frame read as a recognised bar at 0% — the very defect that fired
    # the survival combo on a healthy Pokémon (2026-08-07). With the brightness
    # floor a black frame is correctly UNREADABLE, so the fixture has to hand
    # the HP read a real bar on every tick.
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}, {:ok, no_fight}, {:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
    assert Worker.status(worker).counters.potions >= 1
  end

  @tag :tmp_dir
  test "the potion waits out a CONTINUOUS battle-free window before firing", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 300)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, :high, _}, 200
    assert Worker.status(worker).hold_reason == "poção esperando batalha limpa"
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
    assert Worker.status(worker).counters.potions == 1
    assert %{text: "poção", at: _} = Worker.status(worker).last_action
  end

  @tag :tmp_dir
  test "post-fight order: a due potion waits for capture to resolve the corpses", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:support_waits_capture, true)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    send(worker, {:catcher, %{pending_corpses: 1}})
    assert :ok = Worker.run(worker)

    refute_receive {:performed, :high, _}, 300
    assert Worker.status(worker).hold_reason =~ "esperando a captura terminar"

    send(worker, {:catcher, %{pending_corpses: 0}})
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
  end

  @tag :tmp_dir
  test "the cap frees the support if capture wedges (fail-open)", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:support_waits_capture, true)
    Settings.put(:support_capture_wait_max_ms, 150)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    send(worker, {:catcher, %{pending_corpses: 1}})
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 2_000
  end

  @tag :tmp_dir
  test "a LOCKED fight mid-window RESETS the clear clock", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 400)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    Process.sleep(200)
    fresh_battle!(enemies: [0], locked?: true, locked_row: 0)
    Process.sleep(100)
    fresh_battle!(enemies: [0], locked?: false)

    refute_receive {:performed, :high, _}, 250
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
  end

  # The reported bug: potion configured and on, HP low, but a creature sat in the Battle
  # list (the normal state of hunting) and the sip never came.
  @tag :tmp_dir
  test "sips while HUNTING: an enemy merely listed no longer blocks the potion", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 0)

    fresh_battle!(enemies: [%{row: 1, name: "Tentacool"}], locked?: false)
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
    assert Worker.status(worker).counters.potions >= 1
  end

  # The re-aggro the old any-enemy rule protected against, now caught by what actually
  # interrupts a heal: the player's own HP going DOWN. Window 0 removes the clear-window
  # confound — only the damage guard can hold the sip here.
  @tag :tmp_dir
  test "holds the sip while HP is dropping — a re-aggro with no lock ring", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 0)

    fresh_battle!(enemies: [%{row: 1, name: "Tentacool"}], locked?: false)

    frames = for fill <- 13..2//-1, do: {:ok, hp_png(tmp, "hp#{fill}.png", fill)}
    {:ok, _} = Fake.start_link(%{capture: frames})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, :high, _}, 150
    assert Worker.status(worker).hold_reason =~ "há luta"
  end

  @tag :tmp_dir
  test "after a battle clears for the window, the Pokémon is sent back to its spot", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:reposition_enabled, true)
    Settings.put(:reposition_battle_clear_ms, 200)

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | pokemon_spot_point: {450, 380}})

    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, full}]})

    fresh_battle!(enemies: [0])
    worker = start_worker(body)
    assert :ok = Worker.run(worker)
    refute_receive {:performed, _p, _a}, 150
    assert Worker.status(worker).hold_reason == "reposição esperando fim da luta"

    fresh_battle!(enemies: [])
    assert_receive {:performed, :normal, [{:click, :middle, {450, 380}}]}, 1_500
    assert Worker.status(worker).counters.repositions == 1
    assert Worker.status(worker).hold_reason == nil
    assert %{text: "reposição (clique do meio)", at: _} = Worker.status(worker).last_action

    refute_receive {:performed, _p, _a}, 400
  end

  @tag :tmp_dir
  test "flee_to_escape: tile click, walk wait, and arrow steps, all atomic at :critical",
       %{tmp: _tmp, body: body} do
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})
    Settings.put(:escape_direction, "left")
    Settings.put(:escape_steps, 2)
    Settings.put(:escape_walk_wait_ms, 1_500)

    worker = start_worker(body)
    assert :ok = Worker.flee_to_escape(worker)

    assert_receive {:performed, :critical, actions}, 1_000

    assert actions == [
             {:click, :left, {620, 240}},
             {:wait, 1_500},
             {:press, "left"},
             {:wait, 300},
             {:press, "left"}
           ]

    assert %{text: "fuga (escada)", at: _} = Worker.status(worker).last_action
  end

  # A FUGA NÃO PODE SEGURAR QUEM MANDOU FUGIR. `emergency_escape/1` faz
  # latch → fuga → PARAR A FROTA, e a fuga é um `handle_call` que ficava parado
  # dentro do `Body.perform` (que espera `:infinity`) pelo `escape_walk_wait_ms`
  # inteiro. Com o valor DELE (5000ms) a sequência passa dos 5s do timeout
  # padrão de um `GenServer.call`: quem mandou fugir morre de timeout e o
  # `stop_all` NUNCA roda — a frota segue caçando ao lado do shiny que disparou
  # a fuga.
  @tag :tmp_dir
  test "a fuga responde na hora, mesmo com o corpo andando por segundos", %{tmp: _tmp} do
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})

    blocking =
      start_supervised!(%{id: :flee_blocking, start: {BlockingBody, :start_link, [self()]}})

    worker = start_worker(blocking)

    task = Task.async(fn -> Worker.flee_to_escape(worker) end)

    # o corpo está PARADO dentro do perform, como um walk wait de 5s
    assert_receive {:performing, :critical, _actions}, 1_000

    assert Task.yield(task, 300) == {:ok, :ok},
           "a fuga segurou quem mandou fugir enquanto o corpo andava"

    send(blocking, :release)
  end

  @tag :tmp_dir
  test "flee_to_escape without a calibrated ladder: error and no click", %{tmp: _tmp, body: body} do
    worker = start_worker(body)
    assert {:error, :not_calibrated} = Worker.flee_to_escape(worker)
    refute_receive {:performed, _p, _a}, 150
  end

  @tag :tmp_dir
  test "escape with the game OUT of focus: fronts, reopens the gate, and clicks anyway", %{
    tmp: _tmp,
    body: body
  } do
    alias Pokex.Bots.InputGate

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})
    Settings.put(:calibration_front_delay_ms, 1)

    InputGate.set_focus_ok(false)
    on_exit(fn -> InputGate.set_focus_ok(true) end)

    worker = start_worker(body)
    assert :ok = Worker.flee_to_escape(worker)

    assert_receive {:performed, :critical, [{:click, :left, {620, 240}} | _]}, 1_000
    assert InputGate.state().focus_ok
  end

  @tag :tmp_dir
  test "the panic corner vetoes the escape — the human kill switch above all", %{
    tmp: _tmp,
    body: body
  } do
    alias Pokex.Bots.InputGate

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})

    InputGate.set_corner_ok(false)
    on_exit(fn -> InputGate.set_corner_ok(true) end)

    worker = start_worker(body)
    assert {:error, :panic_corner} = Worker.flee_to_escape(worker)
    refute_receive {:performed, _p, _a}, 150
  end

  # The calibrated tile is his fishing spot. Walking, sending the Pokémon back to
  # it after every fight would drag him home and undo the whole trip.
  @tag :tmp_dir
  test "in movimento it never repositions, even with the switch on", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:reposition_enabled, true)
    Settings.put(:reposition_battle_clear_ms, 50)
    Settings.put(:player_mode, "moving")

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | pokemon_spot_point: {450, 380}})

    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, full}]})

    fresh_battle!(enemies: [0])
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    fresh_battle!(enemies: [])
    refute_receive {:performed, _p, [{:click, :middle, _} | _]}, 500
    assert Worker.status(worker).counters.repositions == 0
  end

  @tag :tmp_dir
  test "no battle seen → never repositions (nothing to undo)", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:reposition_enabled, true)
    Settings.put(:reposition_battle_clear_ms, 50)

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | pokemon_spot_point: {450, 380}})

    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, full}]})

    fresh_battle!(enemies: [])
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _p, _a}, 400
  end

  @tag :tmp_dir
  test "an active fight (lock ring) blocks the potion — the channel would be interrupted", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    stale_battle!()
    low = hp_png(tmp, "low.png", 6)
    fight = battle_png(tmp, "fight.png", {160, 20, 20, 255})
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}, {:ok, fight}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.potions == 0
  end

  # An unlocked enemy already counts as in-battle for the game, so the heal channel would
  # be interrupted — the old ring-only gate drank here.
  @tag :tmp_dir
  test "enemies in the battle list block the potion even with NO lock ring (aggro before Tab)",
       %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    stale_battle!()
    low = hp_png(tmp, "low.png", 6)
    aggro = battle_png(tmp, "aggro.png", {40, 200, 60, 255})
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}, {:ok, aggro}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.potions == 0
  end

  # Only the HP frame is scripted: a battle capture would consume a warm repeat frame and
  # misread it — the blackboard answer must win.
  @tag :tmp_dir
  test "a FRESH blackboard entry answers the combat question with no battle capture", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    fresh_battle!(enemies: [0], locked?: true, locked_row: 0)
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.potions == 0
  end

  @tag :tmp_dir
  test "use_potion/1 fires immediately on user intent, no gates", %{tmp: tmp, body: body} do
    Settings.put(:potion_enabled, false)
    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, full}]})

    worker = start_worker(body)
    assert :ok = Worker.use_potion(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 500
    assert Worker.status(worker).counters.potions == 1
  end

  @tag :tmp_dir
  test "the toggle off disables the combo entirely", %{tmp: tmp, body: body} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
    Settings.put(:rescue_enabled, false)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).counters.rescues == 0
  end

  # Every one of these was a SILENT hold before: the toggle was on, the HP was
  # low, and the panel said nothing at all — indistinguishable from a broken
  # feature. Measured 2026-07-22 with a probe: HP 32%, potion enabled, zero
  # sips, hold_reason nil.
  describe "when a closed gate holds the support, the panel says which" do
    @tag :tmp_dir
    test "game out of focus: nothing is typed, and the line explains", %{tmp: tmp, body: body} do
      Settings.put(:rescue_enabled, true)
      Settings.put(:potion_enabled, true)
      fresh_battle!(enemies: [])

      InputGate.set_focus_ok(false)
      on_exit(fn -> InputGate.set_focus_ok(true) end)

      low = hp_png(tmp, "low.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, _priority, _actions}, 200

      status = Worker.status(worker)
      assert status.counters.rescues == 0
      assert status.hold_reason =~ "fora de foco"
      assert status.hp_pct != nil
    end

    @tag :tmp_dir
    test "a due potion but the reading sees a REAL fight: the line says so", %{
      tmp: tmp,
      body: body
    } do
      Settings.put(:rescue_enabled, false)
      Settings.put(:potion_enabled, true)
      Settings.put(:potion_cooldown_ms, 60_000)

      fresh_battle!(enemies: [%{row: 1, name: "Tentacool"}], locked?: true, locked_row: 1)

      low = hp_png(tmp, "low.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, :high, _actions}, 200

      status = Worker.status(worker)
      assert status.counters.potions == 0
      assert status.hp_pct == 30
      assert status.hold_reason =~ "há luta"
    end
  end

  # The monitor that keeps him alive must not be killable by what it reads, nor
  # by whom it calls. `read_hp/1` has been uncrashable since it was written; the
  # calibration load one line above it was not. On 2026-08-27 a transient
  # `Pokex.Layout` :undef inside `Calibration.load/1` terminated this worker on
  # every tick — and at a 120ms cadence, three deaths in 360ms exhaust
  # BotSupervisor's default restart intensity, then the application's, taking
  # the whole VM down with them.
  describe "the tick survives what it reads and whom it calls" do
    @tag :tmp_dir
    test "a calibration file that raises mid-read does not terminate the monitor", %{body: body} do
      File.write!(
        Pokex.Home.calibration_file(),
        JSON.encode!(%{"screen_w" => 1000, "screen_h" => 700})
      )

      worker = start_worker(body)
      ref = Process.monitor(worker)
      assert :ok = Worker.run(worker)

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 300

      status = Worker.status(worker)
      assert status.state == :monitoring
      assert status.error == "calibração ilegível (arquivo corrompido?)"
    end

    # The potion, the heal skill and the reposition call the Body INLINE on this
    # loop — the revive does not (it rides a spawned task, which is why it never
    # showed this up). A Body restarting mid-perform is an EXIT in the caller,
    # and the caller here is the monitor that must survive.
    @tag :tmp_dir
    @tag :capture_log
    test "a Body that dies mid-perform does not take the monitor with it", %{tmp: tmp} do
      Settings.put(:rescue_enabled, false)
      Settings.put(:potion_enabled, true)
      Settings.put(:potion_cooldown_ms, 60_000)

      fresh_battle!(enemies: [])
      low = hp_png(tmp, "low.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})

      {:ok, crashing} = CrashingBody.start_link(self())
      Process.unlink(crashing)

      worker = start_worker(crashing)
      ref = Process.monitor(worker)
      assert :ok = Worker.run(worker)

      assert_receive {:performing, :high, [{:press, "e"}]}, 1_000
      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 300

      status = Worker.status(worker)
      assert status.state == :monitoring
      assert status.counters.failures > 0
    end

    @tag :tmp_dir
    test "the monitor reads again the moment the calibration is readable", %{tmp: tmp, body: body} do
      File.write!(
        Pokex.Home.calibration_file(),
        JSON.encode!(%{"screen_w" => 1000, "screen_h" => 700})
      )

      full = hp_png(tmp, "full.png", 20)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, full}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)
      assert Worker.status(worker).counters.reads == 0

      Calibration.save(%Calibration{
        scale: 1.0,
        screen_w: 1000,
        screen_h: 700,
        pokemon_hp_region: {0, 0, 20, 4}
      })

      assert eventually(fn -> Worker.status(worker).counters.reads > 0 end)
    end
  end

  defp eventually(fun, tries \\ 60) do
    Enum.reduce_while(1..tries, false, fn _try, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  # 28/08: o personagem MORREU num revive sem stun efetivo. A cadeia: o preparo
  # (R11, tela limpa) gastava o controle; quando o revive perigoso chegava, o
  # controle estava gelado e o F4 saía com settle 0 na cara da pilha acordada.
  describe "o preparo não gasta o controle, e o controle gelado escala" do
    @tag :tmp_dir
    test ":prepare é a tecla nua — o controle fica guardado pro revive perigoso",
         %{tmp: tmp, body: body} do
      Settings.put(:rescue_stun_first, true)
      classify!("Gardevoir", %{"1" => :crowd, "3" => :aoe})
      bar_stuck_ready(["1", "3"])
      low = hp_png(tmp, "prepare_bare.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:prepare)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      # o controle está PRONTO — e mesmo assim não sai: a tela está limpa e
      # gastá-lo aqui é deixá-lo gelado pra quando a pilha estiver acordada
      assert_receive {:performed, :critical, [{:press, "q"}]}, 1_500
      refute_receive {:performed, :critical, [{:press, "1"} | _]}, 400
    end

    @tag :tmp_dir
    test "controle classificado e GELADO escala o que sobrou, nunca recolhe nu",
         %{tmp: tmp, body: body} do
      Settings.put(:rescue_stun_first, true)
      classify!("Gardevoir", %{"1" => :crowd, "3" => :aoe})
      # o "1" em cooldown (o preparo de um minuto atrás), a "3" pronta
      bar_stuck_ready(["3"])
      low = hp_png(tmp, "cold_control.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:now)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      # a última cartada sai primeiro (a decisão dele de 14/08: "pra tentar dar
      # aquele último dano, daí recolhe")…
      assert_receive {:performed, :critical, [{:press, "3"}]}, 2_000
      # …e o revive vem DEPOIS dela — nunca um F4 nu na frente da pilha
      assert_receive {:performed, :critical, [{:press, "q"}]}, 2_000

      assert_receive {:rule_alarm, :hp, aviso}, 2_000
      assert aviso =~ "controle em cooldown"
    end

    # 29/08, a outra metade do desperdício: o CÉREBRO manda o controle como
    # prefixo do revive ("controle primeiro, revive na sequência") e meio
    # segundo depois o resgate olha a barra, vê a tecla esfriando e trata como
    # gelada — escalando teclas de dano frias em cima de um bolo JÁ dormido.
    # Foram 60 "controle em cooldown na hora do revive" na corrida de 3h. O
    # carimbo do aperto é a testemunha (o eco sobrevive ao reset), e a espera
    # conta DAQUELE aperto.
    @tag :tmp_dir
    test "controle apertado há pouco NÃO escala — o bolo já está dormindo",
         %{tmp: tmp, body: body} do
      Settings.put(:rescue_stun_first, true)
      # janela larga: numa suíte carregada, subir o worker pode custar mais
      # que os 5s reais — o que se testa é a decisão, não a corrida
      Settings.put(:engine_stun_window_ms, 60_000)
      classify!("Gardevoir", %{"1" => :crowd, "3" => :aoe})
      # o "1" esfriando (o cérebro acabou de usá-lo), a "3" pronta
      bar_stuck_ready(["3"])
      SkillClock.wipe()
      SkillClock.pressed("1")
      on_exit(fn -> SkillClock.wipe() end)

      low = hp_png(tmp, "recent_control.png", 6)
      {:ok, _} = Fake.start_link(%{capture: [{:ok, low}]})
      orders!(:now)

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      # o revive sai — e NENHUMA outra tecla na frente dele: nada de última
      # cartada, nada de re-stun
      assert_receive {:performed, :critical, [{:press, "q"}]}, 2_500
      refute_received {:performed, :critical, [{:press, "3"}]}
      refute_received {:performed, :critical, [{:press, "1"} | _]}
    end
  end
end
