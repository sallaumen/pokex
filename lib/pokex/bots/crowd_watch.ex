defmodule Pokex.Bots.CrowdWatch do
  @moduledoc """
  THE EYE: it measures, publishes and photographs. It decides nothing yet.

  Every `crowd_scan_every_ms` during a fight (enemies listed, or a revive
  pending), once a second walking with an empty list, it captures the box
  around the character, places every creature (`Pokex.Bots.CrowdScan`) and
  writes the whole reading to the `:crowd` fact, positions included, which
  the first eye threw away. The page learns of every reading by PubSub.

  ## Photos as proof

  Two moments keep a picture with the marks drawn on: the fight opening
  (`open`) and every revive decision the brain makes, fired (`revive`) or
  held by the sleep fence (`held`). The file name carries the verdict. Thirty
  stay. A death is investigated from these.

  ## Cost

  ~9 ms capture + ~18 ms read, measured 2026-09-05. Four looks a second is
  under 12% of the helper's time; `crowd_watch.battle_age_ms` in `Perf` says
  whether the battle feed ever waited behind it.
  """
  use GenServer

  alias Pokex.Bots.CrowdScan
  alias Pokex.Bots.Perf
  alias Pokex.Home
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "engine"
  @walk_ms 1_000
  @idle_ms 1_000
  @keep_photos 30
  @waiting [:bunching, :sizing]
  @no_hunt [nil, :idle, :guarding]
  @walking [:travelling, :post_fight]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :crowd_watch_active, true)),
      look: Keyword.get(opts, :look, &CrowdScan.look/1),
      last: nil,
      last_phase: nil,
      last_line: nil,
      last_why: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "One reading now, WITH the picture: the page's button. Published and broadcast like any other."
  @spec look_now(GenServer.server()) :: CrowdScan.reading()
  def look_now(server \\ __MODULE__), do: GenServer.call(server, :look_now)

  @doc "How long until the next look on the clock, for the current picture (tests)."
  @spec next_look_ms(GenServer.server()) :: pos_integer | :idle
  def next_look_ms(server \\ __MODULE__), do: GenServer.call(server, :next_look_ms)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @topic)
    schedule(@idle_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:look_now, _from, state) do
    case allowed(state, now()) do
      :ok ->
        {reading, state} = look(state, now(), evidence: true)
        {:reply, reading, state}

      {:error, reason} ->
        {:reply, %{read?: false, reason: reason}, state}
    end
  end

  def handle_call(:next_look_ms, _from, state), do: {:reply, cadence(now()), state}

  @impl true
  def handle_info(:look, state) do
    now = now()
    cadence = cadence(now)

    state =
      if allowed(state, now) == :ok and is_integer(cadence),
        do: state |> look(now, evidence: false) |> elem(1),
        else: state

    schedule(if cadence == :idle, do: @idle_ms, else: cadence)
    {:noreply, state}
  end

  # The brain spoke: the opening and every revive decision keep a photo.
  def handle_info({:engine, _picture, orders}, state) do
    {:noreply, state |> photo_on_opening(orders) |> photo_on_decision(orders)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- the clock ---------------------------------------------------------------

  defp cadence(now) do
    case orders(now) do
      nil -> :idle
      %{phase: phase} when phase in @no_hunt -> :idle
      %{phase: phase, revive: revive} -> fight_or_walk(phase, revive, listed(now))
    end
  end

  defp fight_or_walk(phase, revive, listed) do
    if listed > 0 or revive != :hold or phase not in @walking,
      do: Settings.get(:crowd_scan_every_ms),
      else: @walk_ms
  end

  defp allowed(state, now) do
    cond do
      not state.active? or Settings.get(:crowd_watch_enabled) != true -> {:error, :disabled}
      cadence(now) == :idle -> {:error, :no_hunt}
      true -> :ok
    end
  end

  # -- a look ------------------------------------------------------------------

  defp look(state, now, opts) do
    reading = state.look.(Keyword.merge([listed: listed(now), evidence: false], opts))
    published = Map.delete(reading, :evidence)

    WorldState.put(:crowd, published, now)
    measure(reading, now)
    broadcast({:crowd, published})

    {reading, %{narrate(state, reading) | last: reading, last_phase: phase(now)}}
  end

  defp measure(%{read?: true, took_ms: took}, now) do
    Perf.record("crowd_watch.look_ms", took)

    case WorldState.get(:battle, 60_000, now) do
      {:ok, %{captured_at: at}} when is_integer(at) ->
        Perf.record("crowd_watch.battle_age_ms", max(now() - at, 0))

      _no_battle ->
        :ok
    end
  end

  defp measure(_unread, _now), do: Perf.count("crowd_watch.unread")

  defp narrate(state, reading) do
    line = line(reading)

    if line == state.last_line do
      state
    else
      broadcast({:engine_log, :macro, "olho: " <> line})
      %{state | last_line: line}
    end
  end

  defp line(%{read?: true} = r) do
    "👀 vi #{length(r.hostiles)} (lista #{r.listed || "?"}) · #{pet_words(r.pet)} · " <>
      "#{nearest_words(r.hostiles)} · #{skull_words(r.hostiles)} · #{r.took_ms}ms"
  end

  defp line(unread), do: "👀 sem leitura ao redor (#{inspect(Map.get(unread, :reason))})"

  defp pet_words(nil), do: "pokémon não visto"
  defp pet_words(%{tiles: t}), do: "pokémon a #{t} #{tiles(t)}"

  defp nearest_words([]), do: "ninguém perto"
  defp nearest_words([%{from_me: t} | _]), do: "mais perto a #{t} #{tiles(t)}"

  defp skull_words(hostiles),
    do: if(Enum.any?(hostiles, & &1.skull?), do: "caveira", else: "sem caveira")

  defp tiles(1), do: "tile"
  defp tiles(_n), do: "tiles"

  # -- the photos ----------------------------------------------------------------

  # The wait ended in a fight: a fresh picture is the opening.
  defp photo_on_opening(%{last: %{read?: true}, last_phase: before} = state, %{phase: :engaged})
       when before in @waiting do
    {reading, state} = look(state, now(), evidence: true)
    save_photo(reading, "open")
    state
  end

  defp photo_on_opening(state, _orders), do: state

  # One photo per revive SENTENCE: the brain repeats its order every tick.
  defp photo_on_decision(%{last_why: why} = state, %{why: why}), do: state

  defp photo_on_decision(state, %{why: why} = orders) do
    state = %{state | last_why: why}

    with tag when is_binary(tag) <- tag(orders),
         :ok <- allowed(state, now()) do
      {reading, state} = look(state, now(), evidence: true)
      save_photo(reading, tag)
      state
    else
      _nothing_to_keep -> state
    end
  end

  defp tag(%{revive: revive}) when revive in [:now, :prepare], do: "revive"
  defp tag(%{why: why}), do: if(String.contains?(why, "segurando o revive"), do: "held")

  defp save_photo(%{read?: true, evidence: "data:" <> _ = url}, tag) do
    case decode(url) do
      {:ok, bytes} ->
        dir = Path.join(Home.captures_dir(), "crowd")
        File.mkdir_p!(dir)
        Home.write!(Path.join(dir, photo_name(tag)), bytes)
        rotate(dir)

      :error ->
        :ok
    end
  rescue
    _no_photo -> :ok
  end

  defp save_photo(_unread, _tag), do: :ok

  # Millisecond stamp first (so the rotation's sort is chronological), a unique
  # integer second (two decisions in one millisecond are two files).
  defp photo_name(tag) do
    "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}-#{tag}.png"
  end

  defp decode(url) do
    case String.split(url, ",", parts: 2) do
      [_head, body] -> Base.decode64(body)
      _no_body -> :error
    end
  end

  defp rotate(dir) do
    dir
    |> File.ls!()
    |> Enum.sort(:desc)
    |> Enum.drop(@keep_photos)
    |> Enum.each(&File.rm(Path.join(dir, &1)))
  end

  # -- the blackboard --------------------------------------------------------------

  defp orders(now) do
    case WorldState.get(:orders, Settings.get(:engine_orders_max_age_ms), now) do
      {:ok, %{phase: _} = orders} -> Map.put_new(orders, :revive, :hold)
      _no_brain -> nil
    end
  end

  defp phase(now) do
    case orders(now) do
      %{phase: phase} -> phase
      nil -> nil
    end
  end

  defp listed(now) do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, %{enemies: enemies}} when is_list(enemies) -> length(enemies)
      _no_list -> 0
    end
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)
  defp schedule(ms), do: Process.send_after(self(), :look, ms)
  defp now, do: System.monotonic_time(:millisecond)
end
