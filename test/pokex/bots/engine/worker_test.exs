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

  # O JOGO VOLTA PRA FRENTE SOZINHO. Em 13/09 às 07:21 outro programa abriu uma
  # janela por cima do jogo: os TRÊS leitores apagaram juntos, a leitura piscou
  # sete vezes em 30 s, e oito segundos depois a caçada parou — e ficou parada
  # 3h27. O `Focus` não viu nada, porque a janela cobriu o jogo sem roubar o
  # foco. Subir a janela do jogo conserta os dois casos com uma ação só.
  describe "o resgate da janela" do
    defp cego_por(worker, ms) do
      :sys.replace_state(worker, fn state ->
        %{state | running?: true, hp_blind_since: System.monotonic_time(:millisecond) - ms}
      end)

      send(worker, :tick)
      Worker.status(worker)
    end

    defp worker_que_conta(pai, opts \\ []) do
      maos = [
        front_fun: fn -> send(pai, :fronted) end,
        knock_fun: fn motivo -> send(pai, {:knocked, motivo}) end
      ]

      {:ok, w} = Worker.start_link([name: nil, active: false] ++ maos ++ opts)

      on_exit(fn -> if Process.alive?(w), do: GenServer.stop(w) end)
      :ok = Worker.run(w)
      w
    end

    test "blind for longer than the deadline, it brings the game window to the front" do
      w = worker_que_conta(self())
      cego_por(w, 5_000)

      assert_receive :fronted, 2_000
      assert_receive {:engine_log, :macro, "quadro: 🪟" <> texto}, 2_000
      assert texto =~ "trazendo a janela do jogo pra frente"
    end

    # A FRASE NÃO ESCOLHE UMA CAUSA QUANDO NÃO SABE.
    #
    # Em 14/09 esta linha disse "outro programa pode ter aberto algo por cima"
    # oito vezes seguidas enquanto o personagem já estava na tela de seleção de
    # personagem: o logout do encerramento tinha funcionado às 06:11:20, o jogo
    # voltou pro menu entre 06:11:25 e 06:11:27 (a caixa-preta gravou os dois
    # quadros), e nada tinha sido aberto por cima de nada.
    #
    # Subir a janela continua valendo — é barato e conserta um dos três casos.
    # O que não vale é afirmar o caso errado com toda a confiança.
    test "with both corners dark it names the three suspects, not one" do
      agora = System.monotonic_time(:millisecond)
      WorldState.put(:minimap, %{pos: nil, coord_blank?: true}, agora)
      on_exit(fn -> WorldState.forget(:minimap) end)

      w = worker_que_conta(self())
      cego_por(w, 5_000)

      assert_receive {:engine_log, :macro, "quadro: 🪟" <> texto}, 2_000
      assert texto =~ "saiu do jogo"
      assert texto =~ "por cima"
      assert texto =~ "mudou de lugar"
    end

    # …e com UM canto só apagado a frase continua sendo a de sempre: ali a
    # janela por cima é mesmo o palpite certo.
    test "with one corner dark the message stays the old one" do
      agora = System.monotonic_time(:millisecond)
      WorldState.put(:minimap, %{pos: {10, 20, 5}, coord_blank?: false}, agora)
      on_exit(fn -> WorldState.forget(:minimap) end)

      w = worker_que_conta(self())
      cego_por(w, 5_000)

      assert_receive {:engine_log, :macro, "quadro: 🪟" <> texto}, 2_000
      assert texto =~ "outro programa pode ter aberto algo por cima"
    end

    # Uma tentativa por vez: `front_game/0` custa dois round trips de osascript e
    # a janela leva um instante pra subir.
    test "and it does not fight itself: one attempt per window" do
      w = worker_que_conta(self())
      cego_por(w, 5_000)
      assert_receive :fronted, 2_000

      refute_receive :fronted, 800
    end

    # SÓ COM A CAÇADA RODANDO: quando ele mesmo põe uma janela na frente, a
    # caçada está parada e nada aqui roda — resgatar não é brigar com ele pelo
    # teclado.
    #
    # E A TRANCA É A CLÁUSULA DO TIQUE, uma só: `observe/1` só é alcançado com a
    # caçada de pé, então repetir a pergunta dentro de `rescue_the_window/2`
    # seria uma condição que nenhum teste consegue tornar falsa — uma tranca que
    # lê como tranca e não é. Este teste cobra a que existe.
    test "with the hunt stopped the tick returns without looking at the screen" do
      w = worker_que_conta(self())

      :sys.replace_state(w, fn state ->
        %{state | running?: false, hp_blind_since: System.monotonic_time(:millisecond) - 5_000}
      end)

      send(w, :tick)
      Worker.status(w)

      refute_receive :fronted, 800
    end

    # O ACELERADOR É POR TRECHO: a vista voltando esquece a última subida, senão
    # uma segunda janela 3 s depois seria pulada pelo teto de 5 s e teria que
    # sobreviver sozinha aos 8 s que param a caçada.
    test "vision coming back forgets the last front" do
      w = worker_que_conta(self())
      cego_por(w, 5_000)
      assert_receive :fronted, 2_000

      # A VISTA VOLTANDO DE VERDADE, e ela são DOIS leitores: o acelerador só
      # esquece a subida quando os dois enxergam de novo (`hp_blind_since` E
      # `bar_blind_since`), porque uma janela que ainda cobre metade da tela
      # continua sendo a janela que a gente quer subir.
      WorldState.put(:pokemon, %{hp_pct: 100}, now())
      WorldState.put(:skill_bar, %{ready_keys: ["3", "4"]}, now())
      send(w, :tick)
      Worker.status(w)

      assert %{hp_blind_since: nil, fronted_at: nil} = :sys.get_state(w)
    end

    test "the knob at zero turns it off" do
      Pokex.SettingsStash.stash!(focus_recover_after_ms: 0)
      w = worker_que_conta(self())
      cego_por(w, 5_000)

      refute_receive :fronted, 800
    end
  end

  # A PORTA DO JOGO SÓ ABRE FORA DE BATALHA, e a batida não tinha teste nenhum —
  # foi essa falta que deixou passar o `Logout.request/2` (que PARA a frota,
  # incluindo ESTE worker) no lugar do `knock/2`.
  describe "a batida na porta do encerramento" do
    defp worker_que_bate(pai) do
      {:ok, w} =
        Worker.start_link(
          name: nil,
          active: false,
          knock_fun: fn motivo -> send(pai, {:knocked, motivo}) end
        )

      on_exit(fn -> if Process.alive?(w), do: GenServer.stop(w) end)
      :ok = Worker.run(w)
      w
    end

    # o bolso no fim é o que arma o encerramento, e ele vem do caderninho
    defp bolso_no_fim do
      Pokex.SettingsStash.stash!(revive_stock: 5, engine_wind_down_at: 20)
      Pokex.Bots.ReviveLedger.reset()
      on_exit(&Pokex.Bots.ReviveLedger.reset/0)
    end

    defp cacando(enemies) do
      WorldState.put(:hunt, %{state: :hunting}, now())
      see(Enum.map(1..enemies//1, fn n -> "Bicho#{n}" end))
    end

    test "with the screen clear it knocks on the door" do
      bolso_no_fim()
      w = worker_que_bate(self())
      cacando(0)

      send(w, :tick)
      settle(w)

      assert_receive {:knocked, motivo}, 2_000
      assert motivo =~ "encerrando a noite"
    end

    # …E COM BICHO NA TELA NÃO BATE: o jogo recusa o Ctrl+Q em batalha, e a fase
    # está justamente terminando quem sobrou pra chegar na porta.
    test "but not with a creature still on screen" do
      bolso_no_fim()
      w = worker_que_bate(self())
      cacando(2)

      send(w, :tick)
      settle(w)

      refute_received {:knocked, _}
    end

    # Uma batida por janela: o `Logout` tem o ciclo aperta → espera → confere →
    # repete lá dentro, e chamá-lo por cima dele a cada tique seria tecla
    # segurada.
    test "and it knocks once, not every tick" do
      bolso_no_fim()
      w = worker_que_bate(self())
      cacando(0)

      send(w, :tick)
      settle(w)
      assert_receive {:knocked, _}, 2_000

      send(w, :tick)
      settle(w)
      refute_received {:knocked, _}
    end

    # Com o bolso cheio não há encerramento nenhum, e a porta não é assunto.
    test "with the pocket full nobody touches the door" do
      Pokex.SettingsStash.stash!(revive_stock: 500, engine_wind_down_at: 20)
      Pokex.Bots.ReviveLedger.reset()
      on_exit(&Pokex.Bots.ReviveLedger.reset/0)

      w = worker_que_bate(self())
      cacando(0)

      send(w, :tick)
      settle(w)

      refute_received {:knocked, _}
    end
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
    # SEIS, que é a régua semeada desde 29/08: uma pilha de três deixou de
    # valer a luta, e o teste passaria a medir a régua em vez do quadro.
    test "lands on the blackboard for everyone to read", %{worker: worker} do
      see(~w(Venonat Paras Venomoth Oddish Bellsprout Weepinbell Gloom Vileplume))
      send(worker, :tick)
      settle(worker)

      assert {:ok, picture} = WorldState.get(:situation, 5_000, now())
      assert picture.enemies == 8
      assert picture.worth_fighting? == true
    end

    # A VIDA DO PERSONAGEM, E NÃO A DO POKÉMON. O fato `:player` carrega as duas
    # — `hp_pct` é a criatura, `player_hp` é ele — e o cérebro lia a primeira.
    # Por isso a regra "VOCÊ está apanhando" julgou o pokémon desde que nasceu e
    # nunca disparou: no dia em que o personagem morreu foram 0 tiques dela
    # contra 26 alarmes do suporte (03/09).
    test "a vida do quadro é a DELE, não a do pokémon", %{worker: worker} do
      WorldState.put(:player, %{hp_pct: 100, player_hp: 20}, now())
      send(worker, :tick)
      settle(worker)

      assert {:ok, picture} = WorldState.get(:situation, 5_000, now())
      assert picture.player_hp == 20
    end

    test "an unread battle panel publishes an unknown, never a zero", %{worker: worker} do
      send(worker, :tick)
      settle(worker)

      assert {:ok, picture} = WorldState.get(:situation, 5_000, now())
      assert picture.enemies == nil
      assert picture.blind? == true
    end

    # O ESPECIAL PELA COR chega ao cérebro pelo mesmo quadro-negro: o
    # `ShinyGuard` publica a presença, o quadro a lê. Um bicho só, abaixo da
    # régua de seis — sem a cor ele não vale a luta; com ela, vale, e a postura
    # inteira liga junto: um bicho, um conceito.
    test "a cor do especial atravessa o quadro-negro e vira postura", %{worker: worker} do
      see(~w(Electrode))
      WorldState.put(:special, %{especial?: true, vistos: []}, now())
      send(worker, :tick)
      settle(worker)

      assert {:ok, picture} = WorldState.get(:situation, 5_000, now())
      assert picture.special? == true
      assert picture.worth_fighting? == true
    end

    # Sem varredura recente a resposta é "não sei" — e não saber é especial
    # nenhum: uma postura mantida por fato velho é o bot encarando o que não
    # está mais lá.
    test "fato VELHO não sustenta a postura", %{worker: worker} do
      see(~w(Electrode))
      WorldState.put(:special, %{especial?: true, vistos: []}, now() - 60_000)
      send(worker, :tick)
      settle(worker)

      assert {:ok, picture} = WorldState.get(:situation, 5_000, now())
      assert picture.special? == false
    end

    # The Catcher aiming at a shiny's corpse reaches the picture as
    # `capturing?`, on the colour's own clock (three scans).
    test "the :capture fact rides the picture while fresh", %{worker: worker} do
      see(~w(Venonat))
      WorldState.put(:capture, %{aiming?: true, pending: 1, corpses: []}, now())
      send(worker, :tick)
      settle(worker)

      assert {:ok, %{capturing?: true}} = WorldState.get(:situation, 5_000, now())

      WorldState.put(:capture, %{aiming?: true, pending: 1, corpses: []}, now() - 60_000)
      send(worker, :tick)
      settle(worker)

      assert {:ok, %{capturing?: false}} = WorldState.get(:situation, 5_000, now())
    end

    # A BOLA COMUM TAMBÉM SEGURA OS PÉS. Depois do revive a rota andava em 1,2 s
    # (mediana de 328 rodadas em 10/09) — menos que uma bola e a conferência dela.
    test "ordinary corpses still pending also ride the picture", %{worker: worker} do
      see(~w(Venonat))
      WorldState.put(:capture, %{aiming?: false, pending: 2, corpses: []}, now())
      send(worker, :tick)
      settle(worker)

      assert {:ok, %{capturing?: true}} = WorldState.get(:situation, 5_000, now())

      WorldState.put(:capture, %{aiming?: false, pending: 0, corpses: []}, now())
      send(worker, :tick)
      settle(worker)

      assert {:ok, %{capturing?: false}} = WorldState.get(:situation, 5_000, now())
    end

    # SOMEONE IS THERE TO THROW: the Catcher's `armed?` rides the picture as
    # `catcher_armed?` — it is what lets a closing round hold the feet to look.
    test "an armed catcher rides the picture, a halted one does not", %{worker: worker} do
      see(~w(Venonat))
      WorldState.put(:capture, %{aiming?: false, pending: 0, corpses: [], armed?: true}, now())
      send(worker, :tick)
      settle(worker)

      assert {:ok, %{catcher_armed?: true}} = WorldState.get(:situation, 5_000, now())

      WorldState.put(:capture, %{aiming?: false, pending: 0, corpses: [], armed?: false}, now())
      send(worker, :tick)
      settle(worker)

      assert {:ok, %{catcher_armed?: false}} = WorldState.get(:situation, 5_000, now())
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
    # A CONTAGEM DESCEU PRA :debug em 28/08. A Central passou a desenhar a lista
    # de batalha ao vivo — nome e vida de cada linha — e repetir isso em texto a
    # cada bicho que entra e sai era o feed contando pela terceira vez o que a
    # tela mostra melhor. Ela continua sendo dita: com o debug ligado.
    test "says the count once, not once per tick", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))

      send(worker, :tick)
      settle(worker)
      assert_receive {:engine_log, :debug, text}
      assert text =~ "3 inimigos na tela"
      assert text =~ "Venonat 100%, Paras 100%, Venomoth 100%"
      # the own-row measurement rides the same first tick — see its own test
      assert_receive {:engine_log, :debug, _measurement}
      assert_shadow()

      send(worker, :tick)
      send(worker, :tick)
      settle(worker)

      refute_receive {:engine_log, _level, _}, 20
    end

    test "speaks again when the count changes", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))
      send(worker, :tick)
      settle(worker)
      assert_receive {:engine_log, :debug, _first}
      assert_receive {:engine_log, :debug, _measurement}
      assert_shadow()

      see(~w(Venonat Paras Venomoth Oddish))
      send(worker, :tick)
      settle(worker)

      assert_receive {:engine_log, :debug, text}
      assert text =~ "4 inimigos na tela"
    end

    # PERDER A LISTA NÃO É CONTAGEM: é cegueira, e fica no nível que acorda
    # alguém mesmo com o debug desligado.
    test "says it lost the list rather than reporting an empty screen", %{worker: worker} do
      see(~w(Venonat Paras Venomoth))
      send(worker, :tick)
      settle(worker)
      assert_receive {:engine_log, :debug, _count}
      assert_receive {:engine_log, :debug, _measurement}
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

      assert_receive {:engine_log, :debug, count}
      assert count =~ "2 inimigos"

      # `:debug` since 11/09: the reading flips on every revive (the pokémon
      # leaves the list and comes back) and the Central draws the list live
      assert_receive {:engine_log, :debug, measurement}
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

      assert_receive {:engine_log, :debug, text}
      assert text == "quadro: 3 inimigos na tela"
      assert_shadow()
      refute_receive {:engine_log, _level, _}, 20
    end
  end
end
