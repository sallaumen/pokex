defmodule Pokex.Bots.CrowdWatch do
  @moduledoc """
  THE WAITING EYE, phase 1: it measures, it does not decide.

  "On top and close" is, to this day, a clock: the brain waits `engine_bunch_ms` and calls that
  close. This watcher photographs around the pokémon WHILE the brain waits for the pile
  (`:bunching`, or `:sizing` with a pile worth it) and writes to the feed how many creatures are
  within reach, one tile, the eight neighbouring squares, which is the area reach he measured.
  The brain does NOT read the fact yet; phase 2 is that.

  ## What phase 1 buys

    * the `:crowd` fact in the frame, with `near`, `seen`, `listed`, the origin of the
      measurement and what it cost;
    * one feed line per changed reading, the number the clock used to decide blind;
    * at the OPENING (the wait became `:engaged`), the last photo with its boxes, kept in
      `captures/crowd/`. Calibrating the reader is a night of those photos;
    * two meters in `Perf`: what the photo cost, and HOW LATE THE BATTLE READING WAS while
      it was taken. There is one capture queue (~0.28s per photo, against the battle feed
      at 120ms), and that is what decides whether phase 2 may be switched on.

  ## What it does not do

  Nothing while walking, fighting or reviving: the photo is only taken during the standing wait,
  every 500ms, twelve per wait at most. Off (`crowd_watch_enabled`), the watcher only re-checks
  the switch once a second.
  """
  use GenServer

  alias Pokex.Bots.CrowdScan
  alias Pokex.Bots.Perf
  alias Pokex.Home
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  # The lines travel with the brain's: same table, same feed.
  @topic "engine"
  @reach_tiles 1
  @look_ms 500
  @idle_ms 1_000
  @watching [:bunching, :sizing]
  @keep_photos 30

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :crowd_watch_active, true)),
      look: Keyword.get(opts, :look, &CrowdScan.look/1),
      last: nil,
      last_phase: nil,
      last_line: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "How many tiles from the pokémon still count as within the area's reach."
  @spec reach_tiles() :: pos_integer
  def reach_tiles, do: @reach_tiles

  @doc "One reading now, off the clock: the test and the page's button use it."
  @spec look_now(GenServer.server()) :: :ok
  def look_now(server \\ __MODULE__), do: GenServer.call(server, :look_now)

  @impl true
  def init(state) do
    schedule(@idle_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:look_now, _from, state), do: {:reply, :ok, tick(state)}

  @impl true
  def handle_info(:look, state) do
    state = tick(state)
    schedule(if watching?(state), do: @look_ms, else: @idle_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- o tique -----------------------------------------------------------------

  defp tick(state) do
    now = now()
    phase = phase(now)

    cond do
      not enabled?(state) -> forget(state, phase)
      phase in @watching -> look(state, phase, now)
      opening?(state, phase) -> state |> save_photo(phase) |> forget(phase)
      true -> forget(state, phase)
    end
  end

  defp enabled?(state), do: state.active? and Settings.get(:crowd_watch_enabled) == true

  defp watching?(%{last_phase: phase}), do: phase in @watching

  defp forget(state, phase), do: %{state | last: nil, last_phase: phase}

  # The wait ended in a fight: the last frame is the opening's.
  defp opening?(%{last: last, last_phase: before}, phase),
    do: last != nil and before in @watching and phase == :engaged

  defp look(state, phase, now) do
    listed = listed(now)
    reading = state.look.(listed: listed, evidence: true)
    near = CrowdScan.within(reading, @reach_tiles)

    publish(reading, near, listed, now)
    measure(reading, now)

    %{narrate(state, reading, near, listed) | last: reading, last_phase: phase}
  end

  defp publish(reading, near, listed, now) do
    WorldState.put(
      :crowd,
      %{
        read?: Map.get(reading, :read?, false),
        near: near,
        seen: Map.get(reading, :seen, 0),
        listed: listed,
        anchor: Map.get(reading, :anchor),
        took_ms: Map.get(reading, :took_ms),
        reach_tiles: @reach_tiles,
        reason: Map.get(reading, :reason)
      },
      now
    )
  end

  # The price, on both sides: what the frame cost, and how old the battle was the instant
  # after. Its age is what says whether the queue choked.
  defp measure(%{read?: true, took_ms: took}, now) do
    Perf.record("crowd_watch.look_ms", took)

    case WorldState.get(:battle, 60_000, now) do
      {:ok, %{captured_at: at}} when is_integer(at) ->
        Perf.record("crowd_watch.battle_age_ms", max(now() - at, 0))

      _sem_batalha ->
        :ok
    end
  end

  defp measure(_unread, _now), do: Perf.count("crowd_watch.unread")

  defp narrate(state, reading, near, listed) do
    line = line(reading, near, listed)

    if line == state.last_line do
      state
    else
      broadcast({:engine_log, :macro, "olho: " <> line})
      %{state | last_line: line}
    end
  end

  defp line(%{read?: true} = reading, near, listed) do
    "👀 perto: #{near} de #{listed || "?"} a ≤#{@reach_tiles} tile (vi #{reading.seen}, " <>
      "medido do #{origin_label(reading.anchor)}, #{reading.took_ms}ms)"
  end

  defp line(reading, _near, _listed),
    do: "👀 sem leitura ao redor (#{inspect(Map.get(reading, :reason))})"

  defp origin_label(:pokemon), do: "pokémon"
  defp origin_label(_character), do: "personagem"

  # -- a foto da abertura ------------------------------------------------------

  defp save_photo(%{last: %{read?: true, evidence: "data:" <> _ = url} = last} = state, _phase) do
    listed = Map.get(last, :listed) || "?"
    near = CrowdScan.within(last, @reach_tiles)

    case decode(url) do
      {:ok, png} ->
        dir = Path.join(Home.captures_dir(), "crowd")
        File.mkdir_p!(dir)
        path = Path.join(dir, "#{System.system_time(:millisecond)}-#{near}de#{listed}.png")
        Home.write!(path, png)
        rotate(dir)

        broadcast(
          {:engine_log, :macro,
           "olho: 📷 abriu com #{near} de #{listed} a ≤#{@reach_tiles} tile — foto guardada"}
        )

      :error ->
        :ok
    end

    state
  rescue
    _sem_foto -> state
  end

  defp save_photo(state, _phase), do: state

  defp decode(url) do
    case String.split(url, ",", parts: 2) do
      [_head, body] -> Base.decode64(body)
      _sem_corpo -> :error
    end
  end

  defp rotate(dir) do
    dir
    |> File.ls!()
    |> Enum.sort(:desc)
    |> Enum.drop(@keep_photos)
    |> Enum.each(&File.rm(Path.join(dir, &1)))
  end

  # -- o quadro ----------------------------------------------------------------

  defp phase(now) do
    case WorldState.get(:orders, Settings.get(:engine_orders_max_age_ms), now) do
      {:ok, %{phase: phase}} -> phase
      _sem_cerebro -> nil
    end
  end

  defp listed(now) do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, %{enemies: enemies}} when is_list(enemies) -> length(enemies)
      _sem_lista -> nil
    end
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)
  defp schedule(ms), do: Process.send_after(self(), :look, ms)
  defp now, do: System.monotonic_time(:millisecond)
end
