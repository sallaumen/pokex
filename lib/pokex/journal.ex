defmodule Pokex.Journal do
  @moduledoc """
  The event history that does NOT live in the browser tab.

  The real problem: the activity feed lived in the panel LiveView's assigns —
  closing or reloading the page erased the history. "What happened overnight?"
  only had an answer if the tab stayed open, and overnight is exactly when
  things go wrong (the 2026-07-23 burned stamina left no trace).

  This process subscribes to the SAME topics as the panel and normalizes
  everything into a ring buffer: each event becomes `%{id, at, source,
  severity, text, generation, repeats}`. `at` is WALL clock (the panel asks
  "what time did this happen?"); `generation` ties the event to the current
  session order (`Pokex.Bots.Session`) — "was this before or after my Stop?"
  becomes integer comparison.

  Consecutive identical chatter (same source + same text) doesn't accumulate:
  the top event gets `repeats` and a fresh `at`. A detector blinking all night
  is ONE honest line ("×340"), not five hundred.

  Almost passive: it only listens on PubSub, never captures or actuates — but
  it PERSISTS. `:macro` and `:alarm` events become JSONL lines under
  `~/.pokex/journal/` (one file per day; `:debug` chatter stays in memory),
  and boot reseeds the ring from today's and yesterday's files — the history
  survives an app RESTART too, which is how broken overnights usually end.
  Files older than @keep_days are deleted on boot. Disk writes are env-gated
  (`:journal_persist`, false in the suite) so tests never write to the real
  `~/.pokex`; test instances opt in with `persist: true` + a temp home.
  """
  use GenServer

  alias Pokex.Bots.Session

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
  The most recent events, newest first.

  Options: `limit` (default 100), `sources` (list; default all) and
  `min_severity` (`:debug` shows everything, `:macro` hides chatter,
  `:alarm` sirens only).
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

  # 2-element legacy shape (old fishing/combat): macro severity
  def handle_info({log, text}, state)
      when log in [:fishing_log, :combat_log] and is_binary(text),
      do: {:noreply, record(state, source_of(log), :macro, text)}

  # Category (2026-07-30, per-sector mute in the header) — the journal records
  # the TEXT the same; the category only decides whether the panel PLAYS the
  # sound, not whether the fact enters the history.
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

  # snapshots, readings and everything else on the same topics: not events
  def handle_info(_msg, state), do: {:noreply, state}

  # Consecutive identical chatter becomes repeats on the top event — a detector
  # blinking all night is ONE line ("×340"), not five hundred.
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

  # The generation ties the event to the current order; Session down → nil,
  # never a journal that takes its writers down.
  defp safe_generation do
    Session.generation()
  catch
    :exit, _reason -> nil
  end

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @journal_topic, {:journal_event, event})

  @doc false
  def dir, do: Path.join(Pokex.Home.dir(), "journal")

  # Only a NEW event of :macro or above becomes a line — :debug chatter and
  # repeat bumps stay in memory (the line already exists on disk; the ×N is
  # screen comfort, not a new fact). A failing write never takes the journal
  # down: disk is the bonus, the ring is the service.
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

  # Boot reseeds the ring from yesterday+today (newest first in the ring) —
  # the history survives a RESTART, not just a page reload.
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
            _corrupt_line -> []
          end
        end)

      _no_file ->
        []
    end
  end

  # source/severity come back from JSON as strings; only EXISTING atoms pass
  # (to_existing_atom) — a tampered file cannot inflate the atom table.
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

      _no_dir ->
        :ok
    end

    state
  end
end
