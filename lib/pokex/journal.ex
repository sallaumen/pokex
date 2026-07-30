defmodule Pokex.Journal do
  @moduledoc """
  O histórico de eventos que NÃO mora na aba do navegador (Frente 4 do plano
  de consolidação).

  O problema real: o feed de atividade vivia nos assigns da LiveView do painel
  — fechar ou recarregar a página apagava a história. "O que aconteceu de
  madrugada?" só tinha resposta se a aba tivesse ficado aberta, e madrugada é
  exatamente quando as coisas dão errado (a estamina queimada de 2026-07-23
  não deixou rastro nenhum).

  Este processo assina os MESMOS tópicos que o painel e normaliza tudo num
  ring buffer: cada evento vira `%{id, at, source, severity, text, generation,
  repeats}`. `at` é relógio de PAREDE (o painel pergunta "que horas isso
  aconteceu?"); `generation` amarra o evento à ordem de sessão vigente
  (`Pokex.Bots.Session`) — "isso foi antes ou depois do meu Stop?" vira
  comparação de inteiro.

  Chatter idêntico consecutivo (mesma origem + mesmo texto) não acumula: o
  evento do topo ganha `repeats` e um `at` novo. Um detector piscando a noite
  toda vira UMA linha honesta ("×340"), não quinhentas.

  Passivo de ponta a ponta: só escuta PubSub, nunca captura nem atua — por
  isso não precisa do gate de env que os vigias ativos têm. O buffer é
  limitado (@max_events); persistência em disco (JSONL) é fatia futura.
  """
  use GenServer

  @topics ~w(fishing combat catcher mini_game game body cavebot logout)
  @journal_topic "journal"
  @max_events 500

  def topic, do: @journal_topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      events: [],
      count: 0,
      next_id: 1,
      max_events: Keyword.get(opts, :max_events, @max_events)
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Os eventos mais recentes, do mais novo pro mais velho.

  Opções: `limit` (padrão 100), `sources` (lista; padrão todas) e
  `min_severity` (`:debug` mostra tudo, `:macro` esconde o chatter,
  `:alarm` só as sirenes).
  """
  def recent(opts \\ [], server \\ __MODULE__), do: GenServer.call(server, {:recent, opts})

  @impl true
  def init(state) do
    Enum.each(@topics, &Phoenix.PubSub.subscribe(Pokex.PubSub, &1))
    {:ok, state}
  end

  @impl true
  def handle_call({:recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    sources = Keyword.get(opts, :sources)
    min = Keyword.get(opts, :min_severity, :debug)

    events =
      state.events
      |> Enum.filter(fn e ->
        (sources == nil or e.source in sources) and
          severity_rank(e.severity) >= severity_rank(min)
      end)
      |> Enum.take(limit)

    {:reply, events, state}
  end

  # -- a normalização: cada tupla que os workers já publicam vira um evento ----

  @impl true
  def handle_info({log, level, text}, state)
      when log in [
             :fishing_log,
             :combat_log,
             :catcher_log,
             :mini_game_log,
             :game_log,
             :body_log,
             :cavebot_log
           ],
      do: {:noreply, record(state, source_of(log), level, text)}

  # legado de 2 elementos (pesca/combate antigos): severidade macro
  def handle_info({log, text}, state)
      when log in [:fishing_log, :combat_log] and is_binary(text),
      do: {:noreply, record(state, source_of(log), :macro, text)}

  def handle_info({:rule_alarm, reason}, state),
    do: {:noreply, record(state, :regra, :alarm, reason)}

  def handle_info({:panic, reason}, state),
    do: {:noreply, record(state, :sistema, :alarm, "PÂNICO: #{reason}")}

  def handle_info({:session_stop, reason}, state),
    do: {:noreply, record(state, :sistema, :alarm, "meta de sessão: #{reason}")}

  def handle_info({:escape, reason, _flee}, state),
    do: {:noreply, record(state, :sistema, :alarm, "fuga de emergência: #{reason}")}

  def handle_info({:logout, %{state: s} = snap}, state) when s in [:out, :failed],
    do:
      {:noreply,
       record(state, :sistema, :alarm, "logout #{s}: #{snap.reason || "?"} #{snap.error || ""}")}

  # snapshots, leituras e todo o resto dos mesmos tópicos: não são eventos
  def handle_info(_msg, state), do: {:noreply, state}

  # -- internos ----------------------------------------------------------------

  # Chatter idêntico consecutivo vira repeats no evento do topo — um detector
  # piscando a noite toda é UMA linha ("×340"), não quinhentas.
  defp record(state, source, severity, text) do
    at = System.system_time(:millisecond)

    case state.events do
      [%{source: ^source, text: ^text} = head | rest] ->
        head = %{head | repeats: head.repeats + 1, at: at}
        broadcast(head)
        %{state | events: [head | rest]}

      events ->
        event = %{
          id: state.next_id,
          at: at,
          source: source,
          severity: normalize_severity(severity),
          text: text,
          generation: safe_generation(),
          repeats: 1
        }

        broadcast(event)

        %{
          state
          | events: Enum.take([event | events], state.max_events),
            count: min(state.count + 1, state.max_events),
            next_id: state.next_id + 1
        }
    end
  end

  defp source_of(:fishing_log), do: :fishing
  defp source_of(:combat_log), do: :combat
  defp source_of(:catcher_log), do: :catcher
  defp source_of(:mini_game_log), do: :mini_game
  defp source_of(:game_log), do: :suporte
  defp source_of(:body_log), do: :body
  defp source_of(:cavebot_log), do: :cavebot

  defp normalize_severity(level) when level in [:debug, :macro, :alarm], do: level
  defp normalize_severity(_outro), do: :macro

  defp severity_rank(:debug), do: 0
  defp severity_rank(:macro), do: 1
  defp severity_rank(:alarm), do: 2

  # A geração amarra o evento à ordem vigente; Session fora do ar → nil, nunca
  # um journal que derruba quem escreve nele.
  defp safe_generation do
    Pokex.Bots.Session.generation()
  catch
    :exit, _reason -> nil
  end

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @journal_topic, {:journal_event, event})
end
