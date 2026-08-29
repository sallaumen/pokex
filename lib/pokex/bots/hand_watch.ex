defmodule Pokex.Bots.HandWatch do
  @moduledoc """
  A mão DELE vira fato: os apertos que ele mesmo dá no teclado, lidos e
  carimbados como se o bot tivesse dado.

  "Se eu aqui no meu teclado apertar F4, vai afetar o jogo ali (…) é como se
  fosse um ressurrect que a IA fez. Então tem que fazer todo o efeito de um
  ressurrect mesmo, não tendo partido dela. Isso, em teoria, em qualquer
  botão." (ele, 28/08). Até aqui o vigia nativo de teclado
  (`Pokex.Rig.Mac.KeyEvents.key_watch/2`, polling de 8ms no helper) só era
  armado enquanto a Central GRAVAVA uma rota — numa caçada, a mão dele era
  invisível, o painel acusava dessincronia, e um F4 manual não zerava relógio
  nenhum.

  Este worker é o dono do `key_watch` durante a caçada: arma a fileira (1-0)
  mais a tecla do resgate, drena a cada 150ms, e para cada aperto QUE NÃO
  FOI DO BOT:

    * tecla de skill → `SkillClock.pressed/2` — o painel passa a mostrar o
      cooldown que o jogo está mesmo contando;
    * tecla do resgate → o efeito INTEIRO de um revive: `SkillClock.reset/0`
      (R3 — o revive zera todos os cooldowns) e `ReviveLedger.note/0` (saiu um
      item do bolso dele, contado).

  ## Como se separa a mão dele da nossa

  O helper vê TODO aperto nos códigos vigiados — inclusive os CGEvents que o
  próprio Body posta (é assim que o `KeyProbe` confere os nossos). A
  atribuição usa o carimbo: um aperto visto de uma tecla que o `SkillClock`
  carimbou há menos de `@own_window_ms` é o NOSSO voltando pela janela, e já
  está contado. Shift+tecla é troca de modo, não skill — fica de fora, como o
  `HandsRead` já lê.

  O carimbo é lido por `SkillClock.pressed_at/1`, e não por `last_press/1`,
  porque um revive apaga TODOS os carimbos (R3) e não só o do F4: sem o eco
  que o reset deixa pra trás, cada revive fazia a rajada que o bot tinha
  acabado de disparar chegar aqui órfã e virar "mão do Lucas" 340ms depois —
  e o recarimbo desfazia o reset que o revive tinha acabado de pagar. Foram
  235 atribuições falsas em 242 revives na noite de 29/08, com o R3b se
  desarmando 37 vezes por causa delas.

  E só com o JOGO EM FOCO (`InputGate.focus_ok?/0`): fora de foco, um "4" é
  ele digitando em outro lugar, e carimbar isso inventaria cooldown. (Se
  escapar um — número digitado no chat do jogo —, o `SkillTruth` solta o
  carimbo em ~1s, quando a tela mostrar a tecla pronta.)

  ## Um dono, dois inquilinos

  `key_watch/2` é UM buffer global: armar troca os códigos e drenar esvazia.
  Dois leitores simultâneos roubam eventos um do outro. Então:

    * a CAÇADA liga este worker — `Combat.Worker` chama `attach/0` no `:run` e
      `detach/0` no `:halt`; sem consumidor, o vigia desarma (a lição do
      comentário da Central: um watch armado pra sempre compete com o jogo);
    * a GRAVAÇÃO de rota e a sonda do `/diagnostics` continuam com o drain
      próprio — elas chamam `pause/0` antes e `resume/0` depois, e este worker
      sai da frente. Quem pausou é monitorado: a página que morrer pausada
      devolve o vigia sozinha.

  Inerte na suíte (`:hand_watch_active`), como os feeds: um loop de drain
  contra o rig Fake sujaria a lista de chamadas de qualquer teste de worker.
  """

  use GenServer

  alias Pokex.Bots.{InputGate, ReviveLedger, SkillClock}
  alias Pokex.Bots.Cavebot.HandsRead
  alias Pokex.Bots.KeyProbe
  alias Pokex.Rig.Mac.Commands
  alias Pokex.Settings

  @drain_ms 150
  @error_backoff_ms 2_000
  # O Body carimba no despacho e a rajada leva ~35-500ms entre teclas; um
  # aperto visto até aqui depois do carimbo é o nosso próprio CGEvent.
  @own_window_ms 700
  # O reset do revive do BOT (`:rescue_done`) apaga o carimbo do próprio F4 —
  # num drain atrasado a sighting dele ficaria sem dono e viraria "mão do
  # Lucas": item contado duas vezes e um re-reset apagando os carimbos novos
  # da rajada pós-revive. O caderninho lembra a hora do último despacho, de
  # qualquer mão — o que também impede o F4 DELE repetido em menos de 5s de
  # contar dobrado (o item tem cooldown no jogo de qualquer jeito).
  @bot_revive_window_ms 5_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Liga o vigia pra quem chama (a caçada). Idempotente; morre com o chamador."
  def attach(server \\ __MODULE__), do: safe_call(server, :attach)

  @doc "Desliga pra quem chama. O último a sair desarma o watch."
  def detach(server \\ __MODULE__), do: safe_call(server, :detach)

  @doc "Sai da frente: outro leitor (gravação, sonda) vai armar o key_watch."
  def pause(server \\ __MODULE__), do: safe_call(server, :pause)

  @doc "O outro leitor terminou; volta a vigiar se houver consumidor."
  def resume(server \\ __MODULE__), do: safe_call(server, :resume)

  # As páginas chamam isto de fora da árvore do bot; um vigia ausente (suíte,
  # crash) nunca pode derrubar quem só queria avisar que vai gravar.
  defp safe_call(server, msg) do
    GenServer.call(server, msg)
  catch
    :exit, _vigia_ausente -> :ok
  end

  @impl true
  def init(_opts) do
    # O terminate abaixo é a única chance de desarmar o helper numa queda — sem
    # trap, um crash deixaria o poll de 8ms lendo onze teclas pra sempre.
    Process.flag(:trap_exit, true)
    {:ok, %{consumers: %{}, paused_by: %{}, timer: nil, armed?: false}}
  end

  @impl true
  def terminate(_reason, state) do
    settle(state)
    :ok
  end

  @impl true
  def handle_call(:attach, {pid, _tag}, state) do
    state = put_watcher(state, :consumers, pid)
    {:reply, :ok, poke(state)}
  end

  def handle_call(:detach, {pid, _tag}, state) do
    # Só o ÚLTIMO a sair apaga a luz — desarmar com outro consumidor vivo
    # deixaria a caçada dele sem vigia porque outra página se despediu.
    state = drop_watcher(state, :consumers, pid)
    {:reply, :ok, if(active?(state), do: poke(state), else: settle(state))}
  end

  def handle_call(:pause, {pid, _tag}, state) do
    state = put_watcher(state, :paused_by, pid)
    {:reply, :ok, settle(state)}
  end

  def handle_call(:resume, {pid, _tag}, state) do
    {:reply, :ok, drop_watcher(state, :paused_by, pid) |> poke()}
  end

  @impl true
  def handle_info(:drain, state) do
    state = %{state | timer: nil}

    if active?(state) do
      {:noreply, drain(state)}
    else
      {:noreply, settle(state)}
    end
  end

  # Um consumidor (ou pausador) morreu sem se despedir — a gravação que
  # crashou não pode deixar o vigia pausado pra sempre.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      state
      |> drop_watcher(:consumers, pid)
      |> drop_watcher(:paused_by, pid)

    {:noreply, if(active?(state), do: poke(state), else: settle(state))}
  end

  # Com trap_exit ligado (pelo terminate que desarma o helper), um :EXIT de
  # qualquer processo vira mensagem — e mensagem sem clause derrubaria o vigia
  # pelo motivo errado.
  def handle_info(_msg, state), do: {:noreply, state}

  # -- o laço ------------------------------------------------------------------

  defp drain(state) do
    case Pokex.Rig.impl().key_watch(codes()) do
      {:ok, events} ->
        # A PRIMEIRA DRENAGEM É LIXO, e de propósito. `key_watch/1` ARMA e
        # ESVAZIA na mesma chamada: o que volta na primeira é tudo que o helper
        # acumulou desde que alguém o armou pela última vez — pode ser o que ele
        # jogou nos últimos minutos, até 500 teclas, com idade que ninguém sabe.
        # Carimbar isso é inventar uma barra inteira em cooldown no instante em
        # que a caçada começa. A sonda do /diagnostics já fazia isso ("cada
        # rodada é medida limpa"); este vigia não fazia.
        if state.armed?, do: act(events)

        schedule(%{state | armed?: true}, @drain_ms)

      # Helper indisponível (sem Accessibility, compilando, morto): o rig cai
      # pro osascript pras TECLAS, mas o watch não existe. Insistir devagar —
      # ele pode voltar (a permissão concedida no meio da sessão).
      {:error, _reason} ->
        schedule(state, @error_backoff_ms)
    end
  end

  defp act(events) do
    ctx = %{
      focus_ok?: InputGate.focus_ok?(),
      rescue_code: rescue_code(),
      # `pressed_at/1` e não `last_press/1`: o `SkillClock.reset/0` do revive
      # apaga os carimbos de TODAS as teclas, não só o do F4 — e sem o eco cada
      # revive fazia a rajada que o bot acabou de disparar virar "mão do Lucas"
      # 340ms depois, com o recarimbo desfazendo o reset que o revive tinha
      # acabado de pagar. Foram 235 atribuições falsas em 242 revives na noite
      # de 29/08, e o R3b se desarmando 37 vezes por causa delas.
      last_press: &SkillClock.pressed_at/1,
      revive_noted?: ReviveLedger.noted_within?(@bot_revive_window_ms),
      now: System.monotonic_time(:millisecond)
    }

    events
    |> judge(ctx)
    |> Enum.each(&apply_action/1)
  end

  @doc """
  O julgamento de um drain, puro: cada evento vira `{:stamp, key}`, `:revive`
  ou nada. `ctx` traz o foco, o código do resgate, o relógio (`last_press`),
  se o caderninho anotou um revive há pouco (`revive_noted?`) e o agora —
  tudo injetável, pra mesa de teste.
  """
  @spec judge([map], map) :: [{:stamp, String.t()} | :revive]
  def judge(events, ctx) do
    if ctx.focus_ok? do
      events
      |> Enum.map(&verdict(&1, ctx))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    else
      []
    end
  end

  # shift+tecla é modo (shift+1 ataca, shift+3 volta a mobar), nunca skill.
  defp verdict(%{shift?: true}, _ctx), do: nil

  defp verdict(%{code: code}, ctx) do
    cond do
      code == ctx.rescue_code -> rescue_verdict(ctx)
      key = hotbar_key(code) -> unless_own_press(key, {:stamp, key}, ctx)
      true -> nil
    end
  end

  # Duas testemunhas de que o F4 foi NOSSO: o carimbo do press (que o reset do
  # :rescue_done pode já ter apagado) e a anotação do caderninho, que fica.
  defp rescue_verdict(%{revive_noted?: true}), do: nil
  defp rescue_verdict(ctx), do: unless_own_press(rescue_key(), :revive, ctx)

  # O nosso próprio CGEvent voltando pela janela: o carimbo já existe.
  defp unless_own_press(key, action, ctx) do
    case ctx.last_press.(key) do
      at when is_integer(at) and ctx.now - at <= @own_window_ms -> nil
      _mao_dele -> action
    end
  end

  defp apply_action({:stamp, key}) do
    SkillClock.pressed(key)
    narrate("🖐️ tecla #{key} da tua mão — carimbei o cooldown dela no painel")
  end

  defp apply_action(:revive) do
    # O efeito INTEIRO de um revive, como ele pediu: R3 zera o relógio
    # (o que também limpa as teclas surdas) e o item sai do caderninho.
    SkillClock.reset()
    ReviveLedger.note()
    narrate("🖐️ #{rescue_key()} da tua mão — revive: zerei o relógio (R3) e anotei no estoque")
  end

  defp narrate(text) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Bots.Combat.Worker.topic(),
      {:combat_log, :macro, "combate: " <> text}
    )
  end

  # -- códigos vigiados --------------------------------------------------------

  defp codes, do: Enum.uniq(HandsRead.codes() ++ KeyProbe.codes([rescue_key()]))

  defp rescue_key, do: to_string(Settings.get(:rescue_key))

  defp rescue_code do
    case Commands.keycode(rescue_key()) do
      {:ok, code} -> code
      :error -> nil
    end
  end

  defp hotbar_key(code) do
    Enum.find(~w(1 2 3 4 5 6 7 8 9 0), fn key ->
      match?({:ok, ^code}, Commands.keycode(key))
    end)
  end

  # -- liga/desliga ------------------------------------------------------------

  defp active?(state) do
    enabled?() and state.consumers != %{} and state.paused_by == %{}
  end

  defp enabled?, do: Application.get_env(:pokex, :hand_watch_active, true)

  # Acorda o laço se ele deveria estar rodando e não está.
  defp poke(state) do
    if active?(state) and state.timer == nil, do: schedule(state, 0), else: state
  end

  # Aquieta: cancela o laço e DESARMA o helper uma vez — a lição da Central:
  # "an empty watch list is the off switch", senão ele lê dez teclas a cada
  # 8ms pra sempre, competindo com o jogo que ele está jogando.
  defp settle(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if state.armed? do
      try do
        Pokex.Rig.impl().key_watch([])
      catch
        _kind, _reason -> :ok
      end
    end

    %{state | timer: nil, armed?: false}
  end

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :drain, ms)}
  end

  defp put_watcher(state, field, pid) do
    watchers = Map.fetch!(state, field)

    if Map.has_key?(watchers, pid) do
      state
    else
      Map.put(state, field, Map.put(watchers, pid, Process.monitor(pid)))
    end
  end

  defp drop_watcher(state, field, pid) do
    case Map.pop(Map.fetch!(state, field), pid) do
      {nil, _watchers} ->
        state

      {ref, watchers} ->
        Process.demonitor(ref, [:flush])
        Map.put(state, field, watchers)
    end
  end
end
