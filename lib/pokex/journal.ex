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

  Quase passivo: só escuta PubSub, nunca captura nem atua — mas PERSISTE.
  Eventos `:macro` e `:alarm` viram linhas JSONL em `~/.pokex/journal/` (um
  arquivo por dia, chatter `:debug` fica só na memória), e o boot ressemeia o
  ring dos arquivos de hoje e de ontem — a história agora sobrevive também ao
  RESTART do app, que é como as madrugadas com problema costumam terminar.
  Arquivos com mais de @keep_days dias são apagados no boot. A escrita em
  disco é gateada por env (`:journal_persist`, false na suíte) para testes
  jamais escreverem no `~/.pokex` real; instâncias de teste optam por entrar
  com `persist: true` + home temporário.
  """
  use GenServer

  @topics ~w(fishing combat catcher mini_game game body cavebot logout)
  @journal_topic "journal"
  @max_events 500
  @keep_days 14

  def topic, do: @journal_topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      events: [],
      count: 0,
      next_id: 1,
      max_events: Keyword.get(opts, :max_events, @max_events),
      persist?: Keyword.get(opts, :persist, Application.get_env(:pokex, :journal_persist, true))
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
    state = if state.persist?, do: state |> prune_old_files() |> reload_from_disk(), else: state
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

  # Categoria (2026-07-30, mudo por setor no header) — o journal registra o
  # TEXTO igual; a categoria só decide se o painel TOCA o som, não se o fato
  # entra na história.
  def handle_info({:rule_alarm, _category, reason}, state),
    do: {:noreply, record(state, :regra, :alarm, reason)}

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
        persist_event(state, event)

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

  # -- persistência ------------------------------------------------------------

  @doc false
  def dir, do: Path.join(Pokex.Home.dir(), "journal")

  # Só evento NOVO de :macro pra cima vira linha — o chatter :debug e as
  # atualizações de repeats ficam na memória (a linha já existe no disco; o ×N
  # é conforto da tela, não fato novo). Uma escrita que falhar jamais derruba o
  # journal: o disco é o bônus, o ring é o serviço.
  defp persist_event(%{persist?: false}, _event), do: :ok
  defp persist_event(_state, %{severity: :debug}), do: :ok

  defp persist_event(_state, event) do
    File.mkdir_p!(dir())

    line =
      Jason.encode!(%{
        at: event.at,
        source: event.source,
        severity: event.severity,
        text: event.text,
        generation: event.generation
      })

    File.write!(day_file(Date.utc_today()), line <> "\n", [:append])
  rescue
    _disco_indisponivel -> :ok
  end

  defp day_file(date), do: Path.join(dir(), Date.to_iso8601(date) <> ".jsonl")

  # O boot ressemeia o ring de ontem+hoje (na ordem, o mais novo primeiro no
  # ring) — a história sobrevive ao RESTART, não só ao reload da página.
  defp reload_from_disk(state) do
    events =
      [Date.add(Date.utc_today(), -1), Date.utc_today()]
      |> Enum.flat_map(&read_day/1)
      |> Enum.take(-state.max_events)
      |> Enum.with_index(1)
      |> Enum.map(fn {e, id} ->
        %{
          id: id,
          at: e["at"],
          source: safe_atom(e["source"]),
          severity: safe_atom(e["severity"]),
          text: e["text"],
          generation: e["generation"],
          repeats: 1
        }
      end)
      |> Enum.reverse()

    %{state | events: events, count: length(events), next_id: length(events) + 1}
  end

  defp read_day(date) do
    case File.read(day_file(date)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"text" => _} = e} -> [e]
            _linha_corrompida -> []
          end
        end)

      _sem_arquivo ->
        []
    end
  end

  # source/severity voltam do JSON como string; só atoms JÁ EXISTENTES passam
  # (to_existing_atom) — um arquivo adulterado não infla a tabela de atoms.
  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :sistema
  end

  defp safe_atom(_outro), do: :sistema

  defp prune_old_files(state) do
    cutoff = Date.add(Date.utc_today(), -@keep_days)

    case File.ls(dir()) do
      {:ok, files} ->
        for f <- files, Path.extname(f) == ".jsonl" do
          case Date.from_iso8601(Path.rootname(f)) do
            {:ok, date} -> if Date.before?(date, cutoff), do: File.rm(Path.join(dir(), f))
            _mantém -> :ok
          end
        end

      _sem_dir ->
        :ok
    end

    state
  end
end
